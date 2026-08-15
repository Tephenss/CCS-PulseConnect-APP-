import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_cache_service.dart';
import 'auth_service.dart';
import 'event_service.dart';
import 'mobile_backend_service.dart';
import '../config/env.dart';

enum NotificationType { info, success, warning, error, event }

class AppNotification {
  final String id;
  final String title;
  final String message;
  final DateTime timestamp;
  final NotificationType type;
  bool isRead;
  final String? eventId;
  /// Inbox payload type, e.g. certificate_ready, eval_open, event_published.
  final String? actionType;
  /// Inbox payload route, e.g. certificates, evaluation.
  final String? route;

  AppNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.timestamp,
    this.eventId,
    this.actionType,
    this.route,
    this.type = NotificationType.info,
    this.isRead = false,
  });
}

class NotificationService {
  NotificationService._internal();

  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() => _instance;

  /// Wired from [PushNotificationService.initialize] to avoid import cycles.
  static Future<void> Function({
    required String title,
    required String body,
    String? eventId,
    String? payload,
  })? showEventToast;

  static Future<void> Function({
    required String title,
    required String body,
  })? showCertificateToast;

  final _supabase = Supabase.instance.client;
  final EventService _eventService = EventService();
  final _unreadController = StreamController<int>.broadcast();
  Stream<int> get unreadCountStream => _unreadController.stream;

  RealtimeChannel? _notifChannel;
  Timer? _pollTimer;
  Timer? _refreshDebounceTimer;
  String? _activeUserId;
  List<AppNotification> _cachedNotifications = [];
  List<AppNotification>? _cachedDerivedNotifications;
  DateTime? _lastRefreshAt;
  DateTime? _lastDerivedFetchAt;
  bool _isRefreshing = false;
  bool _pendingForceRefresh = false;
  final Map<String, DateTime> _effectiveEndCache = {};

  static const Duration _refreshCacheTtl = Duration(seconds: 8);
  static const Duration _derivedFetchTtl = Duration(seconds: 20);
  static const String _eventNotificationColumns =
      'id,title,start_at,end_at,status,updated_at,created_at,created_by,proposal_stage,requirements_requested_at,requirements_submitted_at,description,event_structure,event_mode,event_for,allow_registration,cover_image_url,location,event_type';
  static const String _eventNotificationColumnsFallback =
      'id,title,start_at,end_at,status,updated_at,created_at,created_by,proposal_stage,requirements_requested_at,requirements_submitted_at,description,event_mode,event_for,cover_image_url';

  bool get _isCacheFresh =>
      _lastRefreshAt != null &&
      DateTime.now().difference(_lastRefreshAt!) < _refreshCacheTtl;

  bool get _isDerivedFresh =>
      _cachedDerivedNotifications != null &&
      _lastDerivedFetchAt != null &&
      DateTime.now().difference(_lastDerivedFetchAt!) < _derivedFetchTtl;

  void invalidateLiveCaches() {
    _cachedDerivedNotifications = null;
    _lastDerivedFetchAt = null;
    _lastRefreshAt = null;
  }

  String _shownInteractiveNotificationsKey(String userId) =>
      'shown_local_interactive_notifications_$userId';

  String _shownApprovedRegistrationEventsKey(String userId) =>
      'shown_reg_approved_events_$userId';

  String _passwordChangesKey(String userId) => 'pwd_changes_$userId';

  String? _extractApprovedRegistrationEventId(String? notificationId) {
    final trimmed = (notificationId ?? '').trim();
    const prefix = 'reg_access_approved_';
    if (!trimmed.startsWith(prefix) || trimmed.length <= prefix.length) {
      return null;
    }
    return trimmed.substring(prefix.length).trim().isEmpty
        ? null
        : trimmed.substring(prefix.length).trim();
  }

  void dispose() {
    _notifChannel?.unsubscribe();
    _pollTimer?.cancel();
    _refreshDebounceTimer?.cancel();
  }

  /// Initializes realtime listeners for notifications.
  /// Should be called after user login.
  void initRealtime(String userId) {
    if (userId.isEmpty) return;

    final bool needsRebind = _notifChannel == null || _activeUserId != userId;
    if (!needsRebind) {
      _startPolling();
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        unawaited(refresh(force: true));
      });
      return;
    }

    _notifChannel?.unsubscribe();
    _pollTimer?.cancel();
    _activeUserId = userId;
    _cachedNotifications = [];
    _lastRefreshAt = null;

    _notifChannel = _supabase.channel('public:notifications_changes:$userId');

    void scheduleRefresh({bool force = true}) {
      _refreshDebounceTimer?.cancel();
      _refreshDebounceTimer = Timer(const Duration(milliseconds: 120), () {
        unawaited(refresh(force: force));
      });
    }

    // Catalog realtime only — notification PII tables are locked from anon (048).
    // Inbox refresh uses PHP secureRead + polling instead.
    _notifChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'events',
      callback: (payload) async {
        final offline = await EventService.isLikelyOffline();
        if (!offline) {
          // Soft: cancel in-flight only — disk cache stays for offline reopen.
          AppCacheService().cancelInFlightPrefix('fetch:');
        }
        invalidateLiveCaches();
        scheduleRefresh(force: true);
      },
    );

    // Listen for assignments to this teacher
    _notifChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_teacher_assignments',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'teacher_id',
        value: userId,
      ),
      callback: (payload) {
        scheduleRefresh();
      },
    );

    // Listen for student QR assistant assignment changes.
    _notifChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_assistants',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'student_id',
        value: userId,
      ),
      callback: (payload) {
        scheduleRefresh();
      },
    );

    // Listen for student certificate issuance so the bell updates immediately.
    _notifChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'certificates',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'student_id',
        value: userId,
      ),
      callback: (payload) {
        scheduleRefresh();
      },
    );

    _notifChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_session_certificates',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'student_id',
        value: userId,
      ),
      callback: (payload) {
        scheduleRefresh();
      },
    );

    _notifChannel!.subscribe();
    _startPolling();
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      unawaited(refresh(force: true));
    });
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 120), (_) {
      unawaited(refresh(force: false));
    });
  }

  /// Pause inbox polling while the app is backgrounded (resume via [resumePolling]).
  void pausePolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void resumePolling() {
    if (_activeUserId == null || _activeUserId!.isEmpty) return;
    _startPolling();
  }

  void _emitUnreadCount() {
    if (_unreadController.isClosed) return;
    final unread = _cachedNotifications.where((n) => !n.isRead).length;
    _unreadController.add(unread);
  }

  bool _eventUsesSessionFlow(Map<String, dynamic> event) {
    final structure = event['event_structure']?.toString().toLowerCase() ?? '';
    final mode = event['event_mode']?.toString().toLowerCase() ?? '';
    return structure == 'one_seminar' ||
        structure == 'two_seminars' ||
        mode == 'seminar_based';
  }

  Future<List<dynamic>> _loadEventsForNotifications() async {
    try {
      return await _supabase
          .from('events')
          .select(_eventNotificationColumns)
          .inFilter('status', [
            'published',
            'draft',
            'pending',
            'approved',
            'archived',
            'expired',
            'finished',
          ])
          .order('updated_at', ascending: false)
          .limit(80);
    } catch (e) {
      debugPrint('Notifications: events fallback select: $e');
      return await _supabase
          .from('events')
          .select(_eventNotificationColumnsFallback)
          .inFilter('status', [
            'published',
            'draft',
            'pending',
            'approved',
            'archived',
            'expired',
            'finished',
          ])
          .order('updated_at', ascending: false)
          .limit(80);
    }
  }

  DateTime? _tryParseLocalDate(dynamic raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    return DateTime.tryParse(text)?.toLocal();
  }

  Map<String, dynamic> _asStringMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  Map<String, dynamic> _extractRelatedMap(dynamic raw) {
    if (raw is List && raw.isNotEmpty) {
      return _asStringMap(raw.first);
    }
    return _asStringMap(raw);
  }

  bool _registrationAccessRowAllows(Map<String, dynamic> row) {
    if (row['approved'] == true) {
      return true;
    }

    final status = (row['payment_status']?.toString() ?? '')
        .trim()
        .toLowerCase();
    return status == 'paid' || status == 'waived';
  }

  bool _eventAllowsOpenRegistration(Map<String, dynamic> event) {
    final raw = event['allow_registration'];
    if (raw is bool) return raw;
    final text = raw?.toString().trim().toLowerCase() ?? '';
    if (text.isEmpty) return true;
    return text == 'true' || text == '1' || text == 'yes' || text == 'on';
  }

  String _sessionNotificationTitle(Map<String, dynamic> session) {
    final title = session['title']?.toString().trim() ?? '';
    if (title.isNotEmpty) return title;
    final topic = session['topic']?.toString().trim() ?? '';
    if (topic.isNotEmpty) return topic;
    return 'Seminar';
  }

  Future<List<AppNotification>> _loadCertificateNotifications(
    String userId,
  ) async {
    final notifications = <AppNotification>[];
    final trimmedUserId = userId.trim();
    if (trimmedUserId.isEmpty) {
      return notifications;
    }

    try {
      final simpleRows = await _supabase
          .from('certificates')
          .select('id, issued_at, event_id, events(title)')
          .eq('student_id', trimmedUserId)
          .order('issued_at', ascending: false)
          .limit(40);

      for (final raw in List<Map<String, dynamic>>.from(simpleRows)) {
        final row = _asStringMap(raw);
        final certId = row['id']?.toString().trim() ?? '';
        final issuedAt = _tryParseLocalDate(row['issued_at']);
        if (certId.isEmpty || issuedAt == null) {
          continue;
        }

        final eventId = row['event_id']?.toString().trim() ?? '';
        final event = _extractRelatedMap(row['events']);
        final eventTitle = event['title']?.toString().trim().isNotEmpty == true
            ? event['title'].toString().trim()
            : 'Event';

        notifications.add(
          AppNotification(
            id: 'cert_simple_$certId',
            title: 'Certificate Ready',
            message:
                'Your certificate for "$eventTitle" is now available in Certificates.',
            timestamp: issuedAt,
            type: NotificationType.success,
            eventId: eventId.isEmpty ? null : eventId,
            actionType: 'certificate_ready',
            route: 'certificates',
          ),
        );
      }
    } catch (_) {
      // Keep notification feed working even if certificate lookup fails.
    }

    try {
      final sessionRows = await _supabase
          .from('event_session_certificates')
          .select(
            'id, issued_at, session_id, '
            'event_sessions(id, event_id, title, topic, events(id, title))',
          )
          .eq('student_id', trimmedUserId)
          .order('issued_at', ascending: false)
          .limit(60);

      for (final raw in List<Map<String, dynamic>>.from(sessionRows)) {
        final row = _asStringMap(raw);
        final certId = row['id']?.toString().trim() ?? '';
        final issuedAt = _tryParseLocalDate(row['issued_at']);
        if (certId.isEmpty || issuedAt == null) {
          continue;
        }

        final session = _extractRelatedMap(row['event_sessions']);
        final event = _extractRelatedMap(session['events']);
        final eventId = event['id']?.toString().trim() ??
            session['event_id']?.toString().trim() ??
            '';
        final eventTitle = event['title']?.toString().trim().isNotEmpty == true
            ? event['title'].toString().trim()
            : 'Event';
        final sessionTitle = _sessionNotificationTitle(session);

        notifications.add(
          AppNotification(
            id: 'cert_session_$certId',
            title: 'Certificate Ready',
            message:
                'Your certificate for "$eventTitle - $sessionTitle" is now available in Certificates.',
            timestamp: issuedAt,
            type: NotificationType.success,
            eventId: eventId.isEmpty ? null : eventId,
            actionType: 'certificate_ready',
            route: 'certificates',
          ),
        );
      }
    } catch (_) {
      // Keep notification feed working even if seminar certificate lookup fails.
    }

    return notifications;
  }

  Future<DateTime> _resolveEffectiveEventEnd(
    Map<String, dynamic> event,
    DateTime fallback, {
    Map<String, List<Map<String, dynamic>>>? sessionsByEventId,
  }) async {
    if (!_eventUsesSessionFlow(event)) {
      return fallback;
    }

    try {
      final eventId = event['id']?.toString() ?? '';
      if (eventId.isEmpty) return fallback;

      final cachedEnd = _effectiveEndCache[eventId];
      if (cachedEnd != null) {
        return cachedEnd;
      }

      final sessions = sessionsByEventId?[eventId] ??
          await _eventService.getEventSessions(eventId);
      if (sessions.isEmpty) return fallback;

      var effectiveEnd = fallback;
      for (final session in sessions) {
        final sessionEnd =
            _tryParseLocalDate(session['end_at']) ??
            _tryParseLocalDate(session['start_at']);
        if (sessionEnd != null && sessionEnd.isAfter(effectiveEnd)) {
          effectiveEnd = sessionEnd;
        }
      }

      _effectiveEndCache[eventId] = effectiveEnd;
      return effectiveEnd;
    } catch (_) {
      return fallback;
    }
  }

  Future<Map<String, List<Map<String, dynamic>>>> _batchFetchEventSessions(
    Iterable<String> eventIds,
  ) async {
    final ids = eventIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) {
      return {};
    }

    try {
      final rows = await _supabase
          .from('event_sessions')
          .select('event_id,end_at,start_at')
          .inFilter('event_id', ids);

      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final raw in List<Map<String, dynamic>>.from(rows)) {
        final eventId = raw['event_id']?.toString().trim() ?? '';
        if (eventId.isEmpty) continue;
        grouped.putIfAbsent(eventId, () => []).add(raw);
      }
      return grouped;
    } catch (_) {
      return {};
    }
  }

  bool _isHostedMobilePushConfigured() {
    final raw = Env.mobilePushApiBaseUrl.trim();
    if (raw.isEmpty) return false;
    if (raw.contains('YOUR-WEB-DOMAIN')) return false;

    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    if (!(uri.scheme == 'http' || uri.scheme == 'https')) return false;

    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty || host == 'your-web-domain') return false;
    return true;
  }

  Future<void> _showFreshInteractiveNotifications(
    List<AppNotification> previousNotifications,
    List<AppNotification> nextNotifications,
  ) async {
    final previousIds = previousNotifications.map((n) => n.id).toSet();
    final prefs = await SharedPreferences.getInstance();
    final activeUserId = (_activeUserId ?? '').trim();
    final shownIds = <String>{
      ...(prefs.getStringList('shown_local_interactive_notifications') ?? const <String>[]),
      if (activeUserId.isNotEmpty)
        ...(prefs.getStringList(_shownInteractiveNotificationsKey(activeUserId)) ??
            const <String>[]),
    };
    final shownApprovedEvents = <String>{
      if (activeUserId.isNotEmpty)
        ...(prefs.getStringList(
              _shownApprovedRegistrationEventsKey(activeUserId),
            ) ??
            const <String>[]),
    };
    var didChange = false;
    var didChangeApprovedEvents = false;
    final hostedPushConfigured = _isHostedMobilePushConfigured();

    for (final notification in nextNotifications) {
      final isEvalOpen = notification.id.startsWith('eval_open_');
      final isCertificateReady = notification.id.startsWith('cert_');
      final isScannerAssigned = notification.id.startsWith('scan_assign_');
      final isPublishedEvent = notification.id.startsWith('pub_');
      final isRegistrationUpdate = notification.id.startsWith('reg_closed_');
      final isRegistrationApproved = notification.id.startsWith(
        'reg_approved_',
      );
      final isTeacherAssigned = notification.id.startsWith('assign_');
      final isProposalRequirementsRequested = notification.id.startsWith(
        'proposal_req_',
      );
      final isProposalUnderReview = notification.id.startsWith(
        'proposal_under_review_',
      );
      final isProposalApproved = notification.id.startsWith('approved_');
      final isProposalRejected = notification.id.startsWith('reject_');
      if (!isEvalOpen &&
          !isCertificateReady &&
          !isScannerAssigned &&
          !isPublishedEvent &&
          !isRegistrationUpdate &&
          !isRegistrationApproved &&
          !isTeacherAssigned &&
          !isProposalRequirementsRequested &&
          !isProposalUnderReview &&
          !isProposalApproved &&
          !isProposalRejected) {
        continue;
      }

      final isPushBackedInteractive =
          isScannerAssigned ||
          isPublishedEvent ||
          isRegistrationUpdate ||
          isRegistrationApproved ||
          isTeacherAssigned ||
          isProposalRequirementsRequested ||
          isProposalUnderReview ||
          isProposalApproved ||
          isProposalRejected ||
          isEvalOpen ||
          isCertificateReady;

      // Registration open/closed updates are already emitted as push from web APIs.
      // Never mirror them as local popup to prevent duplicate tray notifications.
      if (isPublishedEvent || isRegistrationUpdate) {
        shownIds.add(notification.id);
        didChange = true;
        continue;
      }

      // When hosted push is enabled, these interactive entries are already
      // delivered through FCM. Skip local popup to avoid duplicate tray cards.
      if (hostedPushConfigured && isPushBackedInteractive) {
        shownIds.add(notification.id);
        didChange = true;
        continue;
      }

      final shouldSkip =
          notification.isRead ||
          previousIds.contains(notification.id) ||
          shownIds.contains(notification.id);
      final approvedEventAlreadyShown =
          isRegistrationApproved &&
          notification.eventId != null &&
          notification.eventId!.trim().isNotEmpty &&
          shownApprovedEvents.contains(notification.eventId!.trim());
      if (shouldSkip) {
        continue;
      }
      if (approvedEventAlreadyShown) {
        shownIds.add(notification.id);
        didChange = true;
        continue;
      }

      if (isCertificateReady) {
        final showCert = showCertificateToast;
        if (showCert != null) {
          await showCert(
            title: notification.title,
            body: notification.message,
          );
        }
      } else {
        final payload =
            isProposalRequirementsRequested && notification.eventId != null
            ? 'proposal_requirements_requested:${notification.eventId!.trim()}'
            : null;
        final showEvent = showEventToast;
        if (showEvent != null) {
          await showEvent(
            title: notification.title,
            body: notification.message,
            eventId: notification.eventId,
            payload: payload,
          );
        }
      }
      shownIds.add(notification.id);
      didChange = true;
      if (isRegistrationApproved &&
          notification.eventId != null &&
          notification.eventId!.trim().isNotEmpty) {
        shownApprovedEvents.add(notification.eventId!.trim());
        didChangeApprovedEvents = true;
      }
    }

    if (didChange) {
      final shownList = shownIds.toList();
      if (activeUserId.isNotEmpty) {
        await prefs.setStringList(
          _shownInteractiveNotificationsKey(activeUserId),
          shownList,
        );
      } else {
        await prefs.setStringList(
          'shown_local_interactive_notifications',
          shownList,
        );
      }
    }

    if (didChangeApprovedEvents && activeUserId.isNotEmpty) {
      await prefs.setStringList(
        _shownApprovedRegistrationEventsKey(activeUserId),
        shownApprovedEvents.toList(),
      );
    }
  }

  Future<void> refresh({bool force = false}) async {
    if (_isRefreshing) {
      // Don't drop force refreshes that arrive while a fetch is in flight
      // (realtime + FCM often overlap) — queue one follow-up pass.
      if (force) {
        _pendingForceRefresh = true;
      }
      return;
    }
    if (!force && _isCacheFresh) {
      _emitUnreadCount();
      return;
    }

    _isRefreshing = true;
    try {
      final previousNotifications = List<AppNotification>.from(
        _cachedNotifications,
      );
      final nextNotifications = await _fetchNotifications(
        forceDerived: force || !_isDerivedFresh,
      );
      await _showFreshInteractiveNotifications(
        previousNotifications,
        nextNotifications,
      );
      _cachedNotifications = nextNotifications;
      _lastRefreshAt = DateTime.now();
      _emitUnreadCount();
    } finally {
      _isRefreshing = false;
      if (_pendingForceRefresh) {
        _pendingForceRefresh = false;
        unawaited(refresh(force: true));
      }
    }
  }

  Future<List<AppNotification>> getNotifications({bool forceRefresh = false}) async {
    if (forceRefresh || !_isCacheFresh) {
      await refresh(force: true);
    }
    return List<AppNotification>.from(_cachedNotifications);
  }

  NotificationType _notificationTypeFromInbox(String rawType) {
    switch (rawType.trim().toLowerCase()) {
      case 'success':
      case 'certificate_ready':
      case 'certificate':
      case 'reg_approved':
      case 'student_requirements_approved':
        return NotificationType.success;
      case 'warning':
      case 'eval_open':
      case 'proposal_rejected':
      case 'proposal-rejected':
      case 'student_requirements_declined':
        return NotificationType.warning;
      case 'error':
        return NotificationType.error;
      case 'event':
      case 'event_published':
      case 'reg_open':
        return NotificationType.event;
      default:
        return NotificationType.info;
    }
  }

  Map<String, dynamic> _parseInboxData(dynamic raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  Future<List<AppNotification>> _fetchInboxNotifications(String userId) async {
    if (userId.isEmpty) {
      return [];
    }

    try {
      List<Map<String, dynamic>> rows = [];
      if (MobileBackendService.isConfigured) {
        final res = await MobileBackendService().secureRead(
          table: 'user_notifications',
          select:
              'id,title,body,notification_type,event_id,data,created_at,updated_at',
          filters: {'user_id': userId},
          limit: 50,
        );
        if (res['ok'] == true && res['rows'] is List) {
          rows = List<Map<String, dynamic>>.from(
            (res['rows'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
          );
        } else if (res['ok'] != true) {
          debugPrint('Notifications: inbox fetch error: ${res['error']}');
          return [];
        }
      } else {
        final raw = await _supabase
            .from('user_notifications')
            .select(
              'id,title,body,notification_type,event_id,data,created_at,updated_at',
            )
            .eq('user_id', userId)
            .order('created_at', ascending: false)
            .limit(50);
        rows = List<Map<String, dynamic>>.from(raw);
      }

      // Newest first if backend didn't order.
      rows.sort((a, b) {
        final aAt = DateTime.tryParse(
              (a['updated_at'] ?? a['created_at'] ?? '').toString(),
            ) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = DateTime.tryParse(
              (b['updated_at'] ?? b['created_at'] ?? '').toString(),
            ) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return bAt.compareTo(aAt);
      });

      final notifications = <AppNotification>[];
      for (final raw in rows) {
        final row = _asStringMap(raw);
        final id = row['id']?.toString().trim() ?? '';
        if (id.isEmpty) {
          continue;
        }

        final createdRaw =
            row['updated_at']?.toString() ?? row['created_at']?.toString() ?? '';
        final timestamp = _tryParseLocalDate(createdRaw) ?? DateTime.now();
        final dataMap = _parseInboxData(row['data']);
        final actionType = (dataMap['type']?.toString() ?? '').trim();
        final route = (dataMap['route']?.toString() ?? '').trim();
        final dataEventId = (dataMap['event_id']?.toString() ?? '').trim();
        final rowEventId = row['event_id']?.toString().trim() ?? '';
        final eventId = rowEventId.isNotEmpty
            ? rowEventId
            : (dataEventId.isNotEmpty ? dataEventId : null);
        final inboxType = actionType.isNotEmpty
            ? actionType
            : (row['notification_type']?.toString() ?? 'info');

        notifications.add(
          AppNotification(
            id: 'inbox_$id',
            title: row['title']?.toString() ?? 'Notification',
            message: row['body']?.toString() ?? '',
            timestamp: timestamp,
            type: _notificationTypeFromInbox(inboxType),
            eventId: eventId,
            actionType: actionType.isNotEmpty ? actionType : inboxType,
            route: route.isNotEmpty ? route : null,
          ),
        );
      }

      return notifications;
    } catch (e) {
      debugPrint('Notifications: inbox fetch error: $e');
      return [];
    }
  }

  Future<List<AppNotification>> _fetchNotifications({
    bool forceDerived = false,
  }) async {
    List<AppNotification> notifications = [];
    final now = DateTime.now();

    try {
      final authService = AuthService();
      final userData = await authService.getCurrentUser();
      
      if (userData == null) return [];

      final role =
          userData['role']?.toString().trim().toLowerCase() ?? 'student';
      final currentUserId =
          (userData['id']?.toString().trim().isNotEmpty == true)
              ? userData['id'].toString().trim()
              : (_activeUserId ?? '');

      final inboxNotifications =
          await _fetchInboxNotifications(currentUserId);
      notifications.addAll(inboxNotifications);

      if (!forceDerived && _isDerivedFresh) {
        notifications.addAll(_cachedDerivedNotifications!);
        await _applyNotificationReadStates(notifications, currentUserId);
        notifications.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        if (notifications.length > 50) {
          notifications = notifications.sublist(0, 50);
        }
        return notifications;
      }

      final derivedNotifications = await _fetchDerivedNotifications(
        role: role,
        currentUserId: currentUserId,
        now: now,
        inboxNotifications: inboxNotifications,
      );
      _cachedDerivedNotifications = derivedNotifications;
      _lastDerivedFetchAt = DateTime.now();
      notifications.addAll(derivedNotifications);
      await _applyNotificationReadStates(notifications, currentUserId);
      notifications.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      if (notifications.length > 50) {
        notifications = notifications.sublist(0, 50);
      }
      return notifications;
    } catch (e) {
      debugPrint('Notifications: fatal fetch error: $e');
      if (_cachedDerivedNotifications != null) {
        notifications.addAll(_cachedDerivedNotifications!);
      }
      return notifications;
    }
  }

  Future<List<AppNotification>> _fetchDerivedNotifications({
    required String role,
    required String currentUserId,
    required DateTime now,
    required List<AppNotification> inboxNotifications,
  }) async {
    List<AppNotification> notifications = [];
    try {
      final authService = AuthService();
      final inboxEventIds = <String>{
        for (final item in inboxNotifications)
          if (item.eventId != null && item.eventId!.isNotEmpty) item.eventId!,
      };
      final registeredEventIds = <String>{};
      final teacherAssignedEventIds = <String, DateTime?>{};
      final approvedRegistrationRows = <Map<String, dynamic>>[];
      final approvedSignalRows = <Map<String, dynamic>>[];
      String? studentYearLevel;
      String? studentCourseCode;
      String? studentSpecialization;

      if (role == 'student') {
        if (currentUserId.isNotEmpty) {
          final scope = await _eventService.getStudentTargetScope(currentUserId);
          final scopedYear = (scope['yearLevel']?.toString() ?? '').trim();
          final scopedCourse = (scope['courseCode']?.toString() ?? '').trim();
          final scopedSpec = (scope['specialization']?.toString() ?? '').trim();
          studentYearLevel =
              scopedYear.isEmpty || scopedYear == 'ALL' ? null : scopedYear;
          studentCourseCode =
              scopedCourse.isEmpty || scopedCourse == 'ALL' ? null : scopedCourse;
          studentSpecialization = scopedSpec.isEmpty ? null : scopedSpec;
        } else {
          studentYearLevel = await authService.getStudentYearLevel();
          studentCourseCode = await authService.getStudentCourseCode();
        }
      }

      if (role == 'student' && currentUserId.isNotEmpty) {
        try {
          if (MobileBackendService.isConfigured) {
            final res = await MobileBackendService().secureRead(
              table: 'event_registrations',
              select: 'event_id',
              filters: {'student_id': currentUserId},
              limit: 500,
            );
            if (res['ok'] == true && res['rows'] is List) {
              for (final row in (res['rows'] as List)) {
                if (row is! Map) continue;
                final eventId = row['event_id']?.toString() ?? '';
                if (eventId.isNotEmpty) {
                  registeredEventIds.add(eventId);
                }
              }
            }
          }
        } catch (_) {
          // Keep notifications working even if registration lookup fails.
        }

        try {
          final rows = await _supabase
              .from('event_registration_access')
              .select('event_id,approved,payment_status,payment_note,updated_at')
              .eq('student_id', currentUserId)
              .order('updated_at', ascending: false)
              .limit(60);

          for (final raw in List<Map<String, dynamic>>.from(rows)) {
            final row = _asStringMap(raw);
            if (_registrationAccessRowAllows(row)) {
              approvedRegistrationRows.add(row);
            }
          }
        } catch (_) {
          // Keep notifications working even if approval lookup fails.
        }

        try {
          if (MobileBackendService.isConfigured) {
            final res = await MobileBackendService().secureRead(
              table: 'user_notification_reads',
              select: 'notification_id,read_at',
              filters: {'user_id': currentUserId},
              limit: 60,
            );
            if (res['ok'] == true && res['rows'] is List) {
              for (final raw in List<Map<String, dynamic>>.from(
                (res['rows'] as List)
                    .map((e) => Map<String, dynamic>.from(e as Map)),
              )) {
                final row = _asStringMap(raw);
                final nid = row['notification_id']?.toString() ?? '';
                if (!nid.startsWith('reg_access_approved_')) continue;
                final signalEventId = _extractApprovedRegistrationEventId(nid);
                if (signalEventId == null || signalEventId.isEmpty) continue;
                approvedSignalRows.add({
                  'event_id': signalEventId,
                  'payment_status': 'paid',
                  'payment_note': '',
                  'updated_at':
                      row['read_at'] ?? DateTime.now().toIso8601String(),
                });
              }
            }
          }
          // Do not SELECT user_notification_reads via anon (locked in 048).
        } catch (_) {
          // Keep notifications working even if signal lookup fails.
        }
      }

      if (role == 'teacher' && currentUserId.isNotEmpty) {
        try {
          final rows = await _supabase
              .from('event_teacher_assignments')
              .select('event_id, assigned_at')
              .eq('teacher_id', currentUserId);
          for (final row in (rows as List)) {
            final eventId = row['event_id']?.toString() ?? '';
            final assignedAtStr = row['assigned_at'] as String? ?? '';
            if (eventId.isNotEmpty) {
              teacherAssignedEventIds[eventId] = assignedAtStr.isNotEmpty 
                  ? DateTime.parse(assignedAtStr).toLocal() 
                  : null;
            }
          }
        } catch (_) {
          // Keep notifications working even if assignment lookup fails.
        }
      }

      List<dynamic> events = const [];
      try {
        events = await _loadEventsForNotifications();
      } catch (e) {
        debugPrint('Notifications: failed to load events: $e');
      }

      final seminarEventIds = <String>{};
      for (final rawEvent in events) {
        if (rawEvent is! Map) continue;
        final event = Map<String, dynamic>.from(rawEvent);
        if (_eventUsesSessionFlow(event)) {
          final eventId = event['id']?.toString().trim() ?? '';
          if (eventId.isNotEmpty) {
            seminarEventIds.add(eventId);
          }
        }
      }
      final sessionsByEventId = await _batchFetchEventSessions(seminarEventIds);

      final eventsById = <String, Map<String, dynamic>>{};
      for (final rawEvent in events) {
        try {
          final event = Map<String, dynamic>.from(rawEvent as Map);
          final eventId = event['id']?.toString().trim() ?? '';
          if (eventId.isNotEmpty) {
            eventsById[eventId] = event;
          }
        } catch (_) {
          // Ignore malformed event rows in map construction.
        }
      }

      for (final rawEvent in events) {
        try {
          final event = Map<String, dynamic>.from(rawEvent as Map);
          if (role == 'student' &&
              !_eventService.isStudentAllowedForEvent(
                event,
                yearLevel: studentYearLevel,
                courseCode: studentCourseCode,
                specialization: studentSpecialization,
              )) {
            continue;
          }

          final startAt = _tryParseLocalDate(event['start_at']);
          final endAt = _tryParseLocalDate(event['end_at']);
          if (startAt == null || endAt == null) {
            // Skip malformed legacy rows instead of dropping all notifications.
            continue;
          }

          final effectiveEndAt = await _resolveEffectiveEventEnd(
            event,
            endAt,
            sessionsByEventId: sessionsByEventId,
          );
          final status = event['status'];
          final title = event['title'];
          final eventId = event['id'].toString();
          final createdBy = event['created_by']?.toString() ?? '';

          final hoursUntilStart = startAt.difference(now).inHours;
          final minsUtilStart = startAt.difference(now).inMinutes;
          final updatedAt =
              _tryParseLocalDate(event['updated_at']) ??
              _tryParseLocalDate(event['created_at']) ??
              startAt;
          final proposalStage =
              (event['proposal_stage']?.toString() ?? '').trim().toLowerCase();
          final requirementsRequestedAt =
              _tryParseLocalDate(event['requirements_requested_at']) ??
              updatedAt;
          final requirementsSubmittedAt =
              _tryParseLocalDate(event['requirements_submitted_at']) ??
              updatedAt;
          final description = event['description'] ?? '';

          // Check if event has actually ended
          final bool isFinished = !effectiveEndAt.isAfter(now);
          final bool isTeacherCreator =
              role == 'teacher' &&
              currentUserId.isNotEmpty &&
              createdBy == currentUserId;
          final bool isTeacherAssigned =
              role == 'teacher' && teacherAssignedEventIds.containsKey(eventId);
          final DateTime? assignedAt =
              isTeacherAssigned ? teacherAssignedEventIds[eventId] : null;

          // Teacher assignments - show as new entry in modal list
          if (role == 'teacher' && isTeacherAssigned && assignedAt != null) {
            if (now.difference(assignedAt).inDays <= 7) {
              notifications.add(
                AppNotification(
                  id: 'assign_$eventId',
                  title: 'Assigned to Event',
                  message: 'You have been assigned to "$title".',
                  timestamp: assignedAt,
                  type: NotificationType.info,
                  eventId: eventId,
                ),
              );
            }
          }

          // Teacher: show proposal notifications only for own proposals.
          if (role == 'teacher') {
            if (isTeacherCreator &&
                status == 'pending' &&
                proposalStage == 'requirements_requested' &&
                now.difference(requirementsRequestedAt).inDays <= 7) {
              notifications.add(
                AppNotification(
                  id: 'proposal_req_$eventId',
                  title: 'Proposal Documents Requested',
                  message:
                      'Admin listed the required documents for "$title". Open the Approval tab and upload them.',
                  timestamp: requirementsRequestedAt,
                  type: NotificationType.warning,
                  eventId: eventId,
                  actionType: 'proposal_requirements_requested',
                ),
              );
            } else if (isTeacherCreator &&
                status == 'pending' &&
                proposalStage == 'under_review' &&
                now.difference(requirementsSubmittedAt).inDays <= 7) {
              notifications.add(
                AppNotification(
                  id: 'proposal_under_review_$eventId',
                  title: 'Proposal Under Review',
                  message:
                      'Your uploaded proposal documents for "$title" are now under admin review.',
                  timestamp: requirementsSubmittedAt,
                  type: NotificationType.info,
                  eventId: eventId,
                ),
              );
            } else if (isTeacherCreator &&
                status == 'approved' &&
                now.difference(updatedAt).inDays <= 7) {
              notifications.add(
                AppNotification(
                  id: 'approved_$eventId',
                  title: 'Event Approved',
                  message: '"$title" has been approved and is ready to be published.',
                  timestamp: updatedAt,
                  type: NotificationType.success,
                  eventId: eventId,
                ),
              );
            } else if (isTeacherCreator &&
                (status == 'draft' || status == 'archived') &&
                now.difference(updatedAt).inDays <= 7) {
              // Extract rejection reason if present
              String reasonMsg = 'Your proposal requires changes.';
              final regExp = RegExp(r'\[REJECT_REASON:\s*(.*?)\]');
              final match = regExp.firstMatch(description);
              if (match != null) {
                reasonMsg = 'Reason: ${match.group(1)}';
              }

              notifications.add(
                AppNotification(
                  id: 'reject_$eventId',
                  title: 'Proposal Review Required',
                  message: '"$title" has been rejected. $reasonMsg',
                  timestamp: updatedAt,
                  type: NotificationType.error,
                  eventId: eventId,
                ),
              );
            }

            // Teacher should only receive event timeline updates for events they created or were assigned to.
            if (!isTeacherCreator && !isTeacherAssigned) {
              continue;
            }
          }

          // Registration updates are student-only.
          // Admin toggles 'Allow Registration' OFF which sets status to 'draft'
          if (role == 'student' &&
              status == 'draft' &&
              now.difference(updatedAt).inDays <= 7) {
            // Double check it's not a REJECTED proposal (which teachers see above)
            bool isRejected = description.contains('[REJECT_REASON:');

            if (!isRejected) {
              notifications.add(
                AppNotification(
                  id: 'reg_closed_${eventId}_${updatedAt.millisecondsSinceEpoch}',
                  title: 'Registration Closed',
                  message: 'Registration for "$title" is now closed.',
                  timestamp: updatedAt,
                  type: NotificationType.warning,
                  eventId: eventId,
                ),
              );
            }
          }

          if (status == 'published') {
          // New Published Event — show for targeted students/teachers even if registration is closed.
          final studentQualified = role == 'student' &&
              _eventService.isStudentAllowedForEvent(
                event,
                yearLevel: studentYearLevel,
                courseCode: studentCourseCode,
                specialization: studentSpecialization,
              );
          bool shouldNotify = (role == 'teacher' && isTeacherAssigned) ||
              studentQualified;

          if (shouldNotify && !isFinished && now.difference(updatedAt).inDays <= 30) {
            if (!inboxEventIds.contains(eventId)) {
              notifications.add(AppNotification(
                id: 'pub_${eventId}_${updatedAt.millisecondsSinceEpoch}',
                title: role == 'student' ? 'Registration Open!' : 'Event Published!',
                message: role == 'student'
                    ? 'Registration is now available for "$title".'
                    : 'The event "$title" has been published and is now visible to students.',
                timestamp: updatedAt,
                type: NotificationType.info,
                eventId: eventId,
              ));
            }
          }

          if (!isFinished) {
            // Reminders (Within 24 hours)
            if (hoursUntilStart >= 1 && hoursUntilStart <= 24) {
              notifications.add(AppNotification(
                id: 'near_$eventId',
                title: 'Reminder: Starting Soon!',
                message: '"$title" starts tomorrow!',
                timestamp: startAt.subtract(const Duration(days: 1)),
                type: NotificationType.warning,
                eventId: eventId,
              ));
            }

            // Reminders (Within 1 hour)
            if (hoursUntilStart == 0 && minsUtilStart > 0) {
              notifications.add(AppNotification(
                id: 'start_$eventId',
                title: 'Starting Now!',
                message: '"$title" starts in $minsUtilStart minutes.',
                timestamp: startAt.subtract(const Duration(hours: 1)),
                type: NotificationType.warning,
                eventId: eventId,
              ));
            }
          }

          // Matatapos na (Event ending within 1 hour)
          if (now.isAfter(startAt) && now.isBefore(effectiveEndAt)) {
            final minsUtilEnd = effectiveEndAt.difference(now).inMinutes;
            if (minsUtilEnd <= 60 && minsUtilEnd > 0) {
              notifications.add(AppNotification(
                id: 'end_$eventId',
                title: 'Ending Soon',
                message: '"$title" ends in $minsUtilEnd minutes.',
                timestamp: effectiveEndAt.subtract(const Duration(hours: 1)),
                type: NotificationType.warning,
                eventId: eventId,
              ));
            } else {
              notifications.add(AppNotification(
                id: 'ongoing_$eventId',
                title: 'Ongoing Now',
                message: '"$title" is currently ongoing.',
                timestamp: startAt,
                type: NotificationType.success,
                eventId: eventId,
              ));
            }
          }
          }

        // Expired/Finished events
          if (isFinished || status == 'expired' || status == 'finished') {
          // Only show recent completions (within last 3 days)
          // Use endAt as the actual time it happened
          if (now.difference(effectiveEndAt).inDays <= 3 &&
              !effectiveEndAt.isAfter(now)) {
            if (role == 'student') {
              if (registeredEventIds.contains(eventId)) {
                bool shouldShowEvaluation = false;
                try {
                  final bundle = await _eventService.getEvaluationBundle(
                    eventId: eventId,
                    studentId: currentUserId,
                  );
                  shouldShowEvaluation = bundle['ok'] == true &&
                      bundle['is_eligible'] == true &&
                      bundle['has_questions'] == true &&
                      bundle['is_complete'] != true;
                } catch (_) {}

                if (shouldShowEvaluation) {
                notifications.add(AppNotification(
                  id: 'eval_open_$eventId',
                  title: 'Evaluation Open',
                  message: '"$title" ended. Tap to answer the evaluation.',
                  timestamp: effectiveEndAt,
                  type: NotificationType.warning,
                  eventId: eventId,
                  actionType: 'eval_open',
                  route: 'evaluation',
                ));
                }
              }
            } else {
              notifications.add(AppNotification(
                id: 'finished_$eventId',
                title: 'Event Completed',
                message: 'The event "$title" has ended.',
                timestamp: effectiveEndAt,
                type: NotificationType.error,
                eventId: eventId,
              ));
            }
          }
          }
        } catch (eventError) {
          debugPrint('Notifications: skipped malformed event row: $eventError');
          continue;
        }
      }

      if (role == 'student' && currentUserId.isNotEmpty) {
        final seenApprovedNotificationEvents = <String>{};
        for (final row in approvedRegistrationRows) {
          final eventId = row['event_id']?.toString().trim() ?? '';
          if (eventId.isEmpty || registeredEventIds.contains(eventId)) {
            continue;
          }

          final updatedAt = _tryParseLocalDate(row['updated_at']) ?? now;
          if (now.difference(updatedAt).inDays > 7) {
            continue;
          }

          final event = eventsById[eventId];
          if (event == null) {
            continue;
          }

          final status = event['status']?.toString().trim().toLowerCase() ?? '';
          if (status != 'published') {
            continue;
          }

          final title = event['title']?.toString().trim().isNotEmpty == true
              ? event['title'].toString().trim()
              : 'Event';
          final paymentNote = row['payment_note']?.toString().trim() ?? '';
          final noteSuffix = paymentNote.isNotEmpty
              ? ' Note: $paymentNote'
              : '';

          notifications.add(
            AppNotification(
              id: 'reg_approved_${eventId}_${updatedAt.millisecondsSinceEpoch}',
              title: 'Registration Approved',
              message:
                  'You are now approved to register for "$title".$noteSuffix',
              timestamp: updatedAt,
              type: NotificationType.success,
              eventId: eventId,
            ),
          );
          seenApprovedNotificationEvents.add(eventId);
        }

        for (final row in approvedSignalRows) {
          final eventId = row['event_id']?.toString().trim() ?? '';
          if (eventId.isEmpty ||
              registeredEventIds.contains(eventId) ||
              seenApprovedNotificationEvents.contains(eventId)) {
            continue;
          }

          final updatedAt = _tryParseLocalDate(row['updated_at']) ?? now;
          if (now.difference(updatedAt).inDays > 7) {
            continue;
          }

          final event = eventsById[eventId];
          if (event == null) {
            continue;
          }

          final status = event['status']?.toString().trim().toLowerCase() ?? '';
          if (status != 'published') {
            continue;
          }

          final title = event['title']?.toString().trim().isNotEmpty == true
              ? event['title'].toString().trim()
              : 'Event';

          notifications.add(
            AppNotification(
              id: 'reg_approved_signal_${eventId}_${updatedAt.millisecondsSinceEpoch}',
              title: 'Registration Approved',
              message: 'You are now approved to register for "$title".',
              timestamp: updatedAt,
              type: NotificationType.success,
              eventId: eventId,
            ),
          );
        }

        // Scanner-assignment bell items used to SELECT event_assistants every
        // 90s (including a created_at column that does not exist → 42703 spam).
        // Assignments are delivered by FCM / mobile_push_dispatch instead.
        debugPrint('[NOTIF] assistants_poll_disabled_v4');

        notifications.addAll(
          await _loadCertificateNotifications(currentUserId),
        );
      }

      // Add local 'Password Changed' notifications
      final prefs = await SharedPreferences.getInstance();
      final activeUserId = currentUserId.trim();
      final pwdChangedList = <String>[
        ...(activeUserId.isNotEmpty
            ? (prefs.getStringList(_passwordChangesKey(activeUserId)) ??
                const <String>[])
            : const <String>[]),
        ...(prefs.getStringList('pwd_changes') ?? const <String>[]),
      ];
      for (int i = 0; i < pwdChangedList.length; i++) {
        final isoDate = pwdChangedList[i];
        try {
          notifications.add(AppNotification(
            id: 'pwd_$i',
            title: 'Security Alert',
            message: 'Your password has been successfully changed.',
            timestamp: DateTime.parse(isoDate),
            type: NotificationType.success,
          ));
        } catch (_) {}
      }

      // Fetch read status tracking from Supabase
      await _applyNotificationReadStates(notifications, currentUserId);

      // Sort by timestamp descending (newest first)
      // If timestamps are equal, put manual actions (pub/reg_closed) on top
      notifications.sort((a, b) {
        int cmp = b.timestamp.compareTo(a.timestamp);
        if (cmp != 0) return cmp;
        
        // Priority for specific IDs if timestamps are within the same minute
        bool aIsManual = a.id.startsWith('pub_') || a.id.startsWith('reg_closed_') || a.id.startsWith('reject_') || a.id.startsWith('approved_') || a.id.startsWith('inbox_');
        bool bIsManual = b.id.startsWith('pub_') || b.id.startsWith('reg_closed_') || b.id.startsWith('reject_') || b.id.startsWith('approved_') || b.id.startsWith('inbox_');
        aIsManual = aIsManual || a.id.startsWith('reg_approved_');
        bIsManual = bIsManual || b.id.startsWith('reg_approved_');
        if (aIsManual && !bIsManual) return -1;
        if (!aIsManual && bIsManual) return 1;
        
        return b.id.compareTo(a.id);
      });

      // Limit to 50 max to prevent performance hit
      if (notifications.length > 50) {
        notifications = notifications.sublist(0, 50);
      }

      return notifications;
    } catch (e) {
      debugPrint('Notifications: derived fetch error: $e');
      return _cachedDerivedNotifications ?? notifications;
    }
  }

  Future<void> _applyNotificationReadStates(
    List<AppNotification> notifications,
    String currentUserId,
  ) async {
    if (currentUserId.isEmpty || notifications.isEmpty) {
      return;
    }

    DateTime lastReadDate = DateTime(2000);
    List<String> readIds = [];
    try {
      if (MobileBackendService.isConfigured) {
        final wm = await MobileBackendService().secureRead(
          table: 'user_notification_watermarks',
          select: 'last_read_at',
          filters: {'user_id': currentUserId},
          limit: 1,
        );
        final wmRows = (wm['ok'] == true && wm['rows'] is List)
            ? List<Map<String, dynamic>>.from(
                (wm['rows'] as List)
                    .map((e) => Map<String, dynamic>.from(e as Map)),
              )
            : <Map<String, dynamic>>[];
        if (wmRows.isNotEmpty) {
          final raw = wmRows.first['last_read_at']?.toString() ?? '';
          final parsed = DateTime.tryParse(raw);
          if (parsed != null) lastReadDate = parsed.toLocal();
        }

        final reads = await MobileBackendService().secureRead(
          table: 'user_notification_reads',
          select: 'notification_id',
          filters: {'user_id': currentUserId},
          limit: 500,
        );
        final readRows = (reads['ok'] == true && reads['rows'] is List)
            ? List<Map<String, dynamic>>.from(
                (reads['rows'] as List)
                    .map((e) => Map<String, dynamic>.from(e as Map)),
              )
            : <Map<String, dynamic>>[];
        readIds = readRows
            .map((row) => row['notification_id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toList();
      } else {
        // Locked tables — no anon fallback after 048.
        readIds = [];
      }
    } catch (e) {
      debugPrint('Error fetching Supabase read statuses: $e');
    }

    for (final notif in notifications) {
      if (readIds.contains(notif.id)) {
        notif.isRead = true;
        continue;
      }

      final isScannerAssigned = notif.id.startsWith('scan_assign_');
      if (!isScannerAssigned &&
          (notif.timestamp.isBefore(lastReadDate) ||
              notif.timestamp.isAtSameMomentAs(lastReadDate))) {
        notif.isRead = true;
      }
    }
  }

  // Method to trigger local password change notification
  Future<void> addPasswordChangeNotification() async {
    final prefs = await SharedPreferences.getInstance();
    final activeUserId = (_activeUserId ?? '').trim();
    final key = activeUserId.isNotEmpty
        ? _passwordChangesKey(activeUserId)
        : 'pwd_changes';
    final pwdChangedList = prefs.getStringList(key) ?? [];
    pwdChangedList.add(DateTime.now().toIso8601String());
    await prefs.setStringList(key, pwdChangedList);
    await refresh(force: true);
  }

  // Mark all notifications as read
  Future<void> markAllAsRead([List<String>? ids]) async {
    try {
      if (_cachedNotifications.isNotEmpty) {
        for (final notif in _cachedNotifications) {
          notif.isRead = true;
        }
        _emitUnreadCount();
      }

      final authService = AuthService();
      final userData = await authService.getCurrentUser();
      if (userData == null) return;
      final userId = userData['id'];

      if (MobileBackendService.isConfigured) {
        await MobileBackendService().secureWrite('notification_read', {
          'table': 'user_notification_watermarks',
          'payload': {
            'user_id': userId,
            'last_read_at': DateTime.now().toUtc().toIso8601String(),
          },
        });
        if (ids != null && ids.isNotEmpty) {
          for (final id in ids) {
            await MobileBackendService().secureWrite('notification_read', {
              'table': 'user_notification_reads',
              'payload': {
                'user_id': userId,
                'notification_id': id,
              },
            });
          }
        }
      } else {
        // Notification tables are locked from anon — skip when BFF unavailable.
        return;
      }

      await refresh(force: true);
    } catch (e) {
      debugPrint("Error in markAllAsRead: $e");
    }
  }

  // Mark specific as read
  Future<void> markAsRead(String id) async {
    try {
      final existing = _cachedNotifications.where((n) => n.id == id);
      if (existing.isNotEmpty) {
        for (final notif in existing) {
          notif.isRead = true;
        }
        _emitUnreadCount();
      }

      final authService = AuthService();
      final userData = await authService.getCurrentUser();
      if (userData == null) return;
      final userId = userData['id'];

      if (MobileBackendService.isConfigured) {
        await MobileBackendService().secureWrite('notification_read', {
          'table': 'user_notification_reads',
          'payload': {
            'user_id': userId,
            'notification_id': id,
          },
        });
      } else {
        // Notification tables are locked from anon — skip when BFF unavailable.
        return;
      }

      await refresh(force: true);
    } catch (e) {
      debugPrint("Error in markAsRead: $e");
    }
  }

  Future<int> getUnreadCount({bool forceRefresh = false}) async {
    if (forceRefresh || !_isCacheFresh) {
      await refresh(force: true);
    }
    return _cachedNotifications.where((n) => !n.isRead).length;
  }
}
