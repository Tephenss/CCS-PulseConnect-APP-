import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'event_service.dart';
import 'push_notification_service.dart';
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

  AppNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.timestamp,
    this.eventId,
    this.type = NotificationType.info,
    this.isRead = false,
  });
}

class NotificationService {
  NotificationService._internal();

  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() => _instance;

  final _supabase = Supabase.instance.client;
  final EventService _eventService = EventService();
  final PushNotificationService _pushNotificationService =
      PushNotificationService();
  final _unreadController = StreamController<int>.broadcast();
  Stream<int> get unreadCountStream => _unreadController.stream;

  RealtimeChannel? _notifChannel;
  Timer? _pollTimer;
  String? _activeUserId;
  List<AppNotification> _cachedNotifications = [];
  DateTime? _lastRefreshAt;
  bool _isRefreshing = false;

  bool get _isCacheFresh =>
      _lastRefreshAt != null &&
      DateTime.now().difference(_lastRefreshAt!) < const Duration(seconds: 8);

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
  }

  /// Initializes realtime listeners for notifications.
  /// Should be called after user login.
  void initRealtime(String userId) {
    if (userId.isEmpty) return;

    final bool needsRebind = _notifChannel == null || _activeUserId != userId;
    if (!needsRebind) {
      _startPolling();
      unawaited(refresh(force: true));
      return;
    }

    _notifChannel?.unsubscribe();
    _pollTimer?.cancel();
    _activeUserId = userId;
    _cachedNotifications = [];
    _lastRefreshAt = null;

    _notifChannel = _supabase.channel('public:notifications_changes:$userId');

    void scheduleRefresh() {
      unawaited(refresh(force: true));
    }

    // Listen for any changes in events (since notifs are derived from these)
    _notifChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'events',
      callback: (payload) {
        scheduleRefresh();
      },
    );

    // Listen for explicit read status changes for this user
    _notifChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'user_notification_reads',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: userId,
      ),
      callback: (payload) {
        final record = payload.newRecord.isNotEmpty
            ? payload.newRecord
            : payload.oldRecord;
        final approvedEventId = _extractApprovedRegistrationEventId(
          record['notification_id']?.toString(),
        );
        if (approvedEventId != null && approvedEventId.isNotEmpty) {
          unawaited(
            _eventService.cacheApprovedRegistrationAccess(
              userId,
              approvedEventId,
            ),
          );
        }
        scheduleRefresh();
      },
    );

    // Listen for "read all" watermark changes
    _notifChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'user_notification_watermarks',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: userId,
      ),
      callback: (payload) {
        scheduleRefresh();
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
    unawaited(refresh(force: true));
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      unawaited(refresh());
    });
  }

  void _emitUnreadCount() {
    if (_unreadController.isClosed) return;
    final unread = _cachedNotifications.where((n) => !n.isRead).length;
    _unreadController.add(unread);
  }

  bool _eventUsesSessionFlow(Map<String, dynamic> event) {
    final structure = event['event_structure']?.toString().toLowerCase() ?? '';
    final mode = event['event_mode']?.toString().toLowerCase() ?? '';
    return event['uses_sessions'] == true ||
        structure == 'one_seminar' ||
        structure == 'two_seminars' ||
        mode == 'seminar_based';
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
    DateTime fallback,
  ) async {
    if (!_eventUsesSessionFlow(event)) {
      return fallback;
    }

    try {
      final eventId = event['id']?.toString() ?? '';
      if (eventId.isEmpty) return fallback;

      final sessions = await _eventService.getEventSessions(eventId);
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

      return effectiveEnd;
    } catch (_) {
      return fallback;
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
      final isProposalApproved = notification.id.startsWith('approved_');
      final isProposalRejected = notification.id.startsWith('reject_');
      if (!isEvalOpen &&
          !isCertificateReady &&
          !isScannerAssigned &&
          !isPublishedEvent &&
          !isRegistrationUpdate &&
          !isRegistrationApproved &&
          !isTeacherAssigned &&
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
          isProposalApproved ||
          isProposalRejected;

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
        await _pushNotificationService.showLocalCertificateNotification(
          title: notification.title,
          body: notification.message,
        );
      } else {
        await _pushNotificationService.showLocalEventNotification(
          title: notification.title,
          body: notification.message,
          eventId: notification.eventId,
        );
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
    if (_isRefreshing) return;
    if (!force && _isCacheFresh) {
      _emitUnreadCount();
      return;
    }

    _isRefreshing = true;
    try {
      final previousNotifications = List<AppNotification>.from(
        _cachedNotifications,
      );
      final nextNotifications = await _fetchNotifications();
      await _showFreshInteractiveNotifications(
        previousNotifications,
        nextNotifications,
      );
      _cachedNotifications = nextNotifications;
      _lastRefreshAt = DateTime.now();
      _emitUnreadCount();
    } finally {
      _isRefreshing = false;
    }
  }

  Future<List<AppNotification>> getNotifications({bool forceRefresh = false}) async {
    if (forceRefresh || !_isCacheFresh) {
      await refresh(force: true);
    }
    return List<AppNotification>.from(_cachedNotifications);
  }

  Future<List<AppNotification>> _fetchNotifications() async {
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
      final registeredEventIds = <String>{};
      final teacherAssignedEventIds = <String, DateTime?>{};
      final approvedRegistrationRows = <Map<String, dynamic>>[];
      final approvedSignalRows = <Map<String, dynamic>>[];
      String? studentYearLevel;
      String? studentCourseCode;

      if (role == 'student') {
        studentYearLevel = await authService.getStudentYearLevel();
        studentCourseCode = await authService.getStudentCourseCode();
      }

      if (role == 'student' && currentUserId.isNotEmpty) {
        try {
          final regs = await _supabase
              .from('event_registrations')
              .select('event_id')
              .eq('student_id', currentUserId);
          for (final row in (regs as List)) {
            final eventId = row['event_id']?.toString() ?? '';
            if (eventId.isNotEmpty) {
              registeredEventIds.add(eventId);
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
          final signalRows = await _supabase
              .from('user_notification_reads')
              .select('notification_id,read_at')
              .eq('user_id', currentUserId)
              .like('notification_id', 'reg_access_approved_%')
              .limit(60);

          for (final raw in List<Map<String, dynamic>>.from(signalRows)) {
            final row = _asStringMap(raw);
            final signalEventId = _extractApprovedRegistrationEventId(
              row['notification_id']?.toString(),
            );
            if (signalEventId == null || signalEventId.isEmpty) {
              continue;
            }

            approvedSignalRows.add({
              'event_id': signalEventId,
              'payment_status': 'paid',
              'payment_note': '',
              'updated_at': row['read_at'] ?? DateTime.now().toIso8601String(),
            });
          }
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
        events = await _supabase
            .from('events')
            .select()
            .order('start_at', ascending: true);
      } catch (e) {
        debugPrint('Notifications: failed to load events: $e');
      }

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
              )) {
            continue;
          }

          final startAt = _tryParseLocalDate(event['start_at']);
          final endAt = _tryParseLocalDate(event['end_at']);
          if (startAt == null || endAt == null) {
            // Skip malformed legacy rows instead of dropping all notifications.
            continue;
          }

          final effectiveEndAt = await _resolveEffectiveEventEnd(event, endAt);
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
          final allowsOpenRegistration = _eventAllowsOpenRegistration(event);
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
          // New Published Event / Registration Open
          // Visible to Students and Assigned Teachers as long as the event hasn't finished yet
          bool shouldNotify = (role == 'teacher' && isTeacherAssigned) ||
              (role == 'student' && allowsOpenRegistration);
          
          if (shouldNotify && !isFinished && now.difference(updatedAt).inDays <= 7) {
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

        try {
          dynamic rows;
          try {
            rows = await _supabase
                .from('event_assistants')
                .select(
                  'id, event_id, assigned_by_teacher_id, allow_scan, assigned_at, created_at, updated_at, events(title)',
                )
                .eq('student_id', currentUserId)
                .eq('allow_scan', true)
                .limit(60);
          } catch (_) {
            try {
              rows = await _supabase
                  .from('event_assistants')
                  .select(
                    'id, event_id, assigned_by_teacher_id, allow_scan, assigned_at, events(title)',
                  )
                  .eq('student_id', currentUserId)
                  .eq('allow_scan', true)
                  .limit(60);
            } catch (_) {
              // Compatibility fallback for old schemas where timestamp
              // and/or assigning-teacher columns are unavailable.
              rows = await _supabase
                  .from('event_assistants')
                  .select('id, event_id, allow_scan, assigned_at')
                  .eq('student_id', currentUserId)
                  .eq('allow_scan', true)
                  .limit(60);
            }
          }

          final candidateRows = <Map<String, dynamic>>[];
          final teacherIds = <String>{};
          final eventIds = <String>{};

          for (final raw in (rows as List)) {
            final row = _asStringMap(raw);
            final eventId = row['event_id']?.toString().trim() ?? '';
            final assignedBy =
                row['assigned_by_teacher_id']?.toString().trim() ?? '';
            if (eventId.isEmpty || assignedBy.isEmpty) continue;

            candidateRows.add(row);
            teacherIds.add(assignedBy);
            eventIds.add(eventId);
          }

          if (candidateRows.isNotEmpty &&
              teacherIds.isNotEmpty &&
              eventIds.isNotEmpty) {
            final allowedTeacherEventPairs = <String>{};
            try {
              final teacherAssignmentRows = await _supabase
                  .from('event_teacher_assignments')
                  .select('event_id,teacher_id')
                  .inFilter('event_id', eventIds.toList())
                  .inFilter('teacher_id', teacherIds.toList())
                  .eq('can_scan', true)
                  .limit(500);

              for (final raw
                  in List<Map<String, dynamic>>.from(teacherAssignmentRows)) {
                final eventId = raw['event_id']?.toString().trim() ?? '';
                final teacherId = raw['teacher_id']?.toString().trim() ?? '';
                if (eventId.isEmpty || teacherId.isEmpty) continue;
                allowedTeacherEventPairs.add('$eventId|$teacherId');
              }
            } catch (_) {
              // Fail closed for security: don't show scanner assignment
              // notifications when assignment verification is unavailable.
            }

            for (final row in candidateRows) {
              final eventId = row['event_id']?.toString().trim() ?? '';
              final assignedBy =
                  row['assigned_by_teacher_id']?.toString().trim() ?? '';
              if (eventId.isEmpty || assignedBy.isEmpty) continue;
              if (!allowedTeacherEventPairs.contains('$eventId|$assignedBy')) {
                continue;
              }

              final assignedAtRaw =
                  row['updated_at'] ?? row['assigned_at'] ?? row['created_at'];
              final assignedAt = _tryParseLocalDate(assignedAtRaw) ?? now;
              final revisionSource = (row['updated_at'] ??
                      row['assigned_at'] ??
                      row['created_at'] ??
                      row['id'] ??
                      '$eventId-$assignedBy')
                  .toString();
              final revisionHash = revisionSource.hashCode.abs();

              final event = _extractRelatedMap(row['events']);
              final eventTitle =
                  event['title']?.toString().trim().isNotEmpty == true
                      ? event['title'].toString().trim()
                      : 'Event';

              notifications.add(
                AppNotification(
                  id: 'scan_assign_${eventId}_$revisionHash',
                  title: 'Scanner Assignment',
                  message:
                      'You were assigned by the admin/teacher to help take attendance for "$eventTitle". Open the QR Scanner when instructed.',
                  timestamp: assignedAt,
                  type: NotificationType.info,
                  eventId: eventId,
                ),
              );
            }
          }
        } catch (_) {
          // Keep notifications working if assistant assignment lookup fails.
        }

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
      DateTime lastReadDate = DateTime(2000);
      List<String> readIds = [];
      try {
        final userId = userData['id'];
        
        // Get watermark
        final watermarkResponse = await _supabase
            .from('user_notification_watermarks')
            .select('last_read_at')
            .eq('user_id', userId)
            .maybeSingle();
            
        if (watermarkResponse != null) {
          lastReadDate = DateTime.parse(watermarkResponse['last_read_at'] as String).toLocal();
        }

        // Get individual read IDs
        final readsResponse = await _supabase
            .from('user_notification_reads')
            .select('notification_id')
            .eq('user_id', userId);
            
        readIds = (readsResponse as List).map((row) => row['notification_id'] as String).toList();
      } catch (e) {
         debugPrint("Error fetching Supabase read statuses: $e");
      }
      
      for (var notif in notifications) {
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

      // Sort by timestamp descending (newest first)
      // If timestamps are equal, put manual actions (pub/reg_closed) on top
      notifications.sort((a, b) {
        int cmp = b.timestamp.compareTo(a.timestamp);
        if (cmp != 0) return cmp;
        
        // Priority for specific IDs if timestamps are within the same minute
        bool aIsManual = a.id.startsWith('pub_') || a.id.startsWith('reg_closed_') || a.id.startsWith('reject_') || a.id.startsWith('approved_');
        bool bIsManual = b.id.startsWith('pub_') || b.id.startsWith('reg_closed_') || b.id.startsWith('reject_') || b.id.startsWith('approved_');
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
      debugPrint('Notifications: fatal fetch error: $e');
      return [];
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

      // 1. Update timestamp watermark on Supabase
      await _supabase.from('user_notification_watermarks').upsert({
        'user_id': userId,
        'last_read_at': DateTime.now().toUtc().toIso8601String()
      });

      // 2. If specific IDs are provided, add them to the explicit read list on Supabase
      if (ids != null && ids.isNotEmpty) {
        final List<Map<String, dynamic>> records = ids.map((id) => {
          'user_id': userId,
          'notification_id': id,
        }).toList();
        
        await _supabase.from('user_notification_reads').upsert(records, onConflict: 'user_id, notification_id');
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

      await _supabase.from('user_notification_reads').upsert({
        'user_id': userId,
        'notification_id': id,
      }, onConflict: 'user_id, notification_id');

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
