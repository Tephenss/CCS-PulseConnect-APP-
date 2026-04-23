import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'event_service.dart';
import 'push_notification_service.dart';

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

  Future<void> _showFreshInteractiveNotifications(
    List<AppNotification> previousNotifications,
    List<AppNotification> nextNotifications,
  ) async {
    final previousIds = previousNotifications.map((n) => n.id).toSet();
    final prefs = await SharedPreferences.getInstance();
    final shownIds = (prefs.getStringList('shown_local_interactive_notifications') ?? [])
        .toSet();
    var didChange = false;

    for (final notification in nextNotifications) {
      final isEvalOpen = notification.id.startsWith('eval_open_');
      final isCertificateReady = notification.id.startsWith('cert_');
      final isScannerAssigned = notification.id.startsWith('scan_assign_');
      if ((!isEvalOpen && !isCertificateReady && !isScannerAssigned) ||
          notification.isRead ||
          previousIds.contains(notification.id) ||
          shownIds.contains(notification.id)) {
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
    }

    if (didChange) {
      await prefs.setStringList(
        'shown_local_interactive_notifications',
        shownIds.toList(),
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

      final role = userData['role'] ?? 'student';
      final currentUserId = userData['id']?.toString() ?? '';
      final registeredEventIds = <String>{};
      final teacherAssignedEventIds = <String, DateTime?>{};

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

      final events = await _supabase
          .from('events')
          .select()
          .order('start_at', ascending: true);

      for (var event in events) {
        final startAt = DateTime.parse(event['start_at']).toLocal();
        final endAt = DateTime.parse(event['end_at']).toLocal();
        final effectiveEndAt = await _resolveEffectiveEventEnd(event, endAt);
        final status = event['status'];
        final title = event['title'];
        final eventId = event['id'].toString();
        final createdBy = event['created_by']?.toString() ?? '';

        final hoursUntilStart = startAt.difference(now).inHours;
        final minsUtilStart = startAt.difference(now).inMinutes;
        final updatedAt = DateTime.parse(event['updated_at'] ?? event['created_at']).toLocal();
        final description = event['description'] ?? '';

        // Check if event has actually ended
        final bool isFinished = !effectiveEndAt.isAfter(now);
        final bool isTeacherCreator = role == 'teacher' && currentUserId.isNotEmpty && createdBy == currentUserId;
        final bool isTeacherAssigned = role == 'teacher' && teacherAssignedEventIds.containsKey(eventId);
        final DateTime? assignedAt = isTeacherAssigned ? teacherAssignedEventIds[eventId] : null;

        // Teacher assignments - show as new entry in modal list
        if (role == 'teacher' && isTeacherAssigned && assignedAt != null) {
          if (now.difference(assignedAt).inDays <= 7) {
            notifications.add(AppNotification(
              id: 'assign_$eventId',
              title: 'Assigned to Event',
              message: 'You have been assigned to "$title".',
              timestamp: assignedAt,
              type: NotificationType.info,
              eventId: eventId,
            ));
          }
        }

        // Teacher: show proposal notifications only for own proposals.
        if (role == 'teacher') {
          if (isTeacherCreator && status == 'approved' && now.difference(updatedAt).inDays <= 7) {
            notifications.add(AppNotification(
              id: 'approved_$eventId',
              title: 'Event Approved',
              message: '"$title" has been approved and is ready to be published.',
              timestamp: updatedAt,
              type: NotificationType.success,
              eventId: eventId,
            ));
          } else if (isTeacherCreator && (status == 'draft' || status == 'archived') && now.difference(updatedAt).inDays <= 7) {
            // Extract rejection reason if present
            String reasonMsg = 'Your proposal requires changes.';
            final regExp = RegExp(r'\[REJECT_REASON:\s*(.*?)\]');
            final match = regExp.firstMatch(description);
            if (match != null) {
              reasonMsg = 'Reason: ${match.group(1)}';
            }

            notifications.add(AppNotification(
              id: 'reject_$eventId',
              title: 'Proposal Review Required',
              message: '"$title" has been rejected. $reasonMsg',
              timestamp: updatedAt,
              type: NotificationType.error,
              eventId: eventId,
            ));
          }

          // Teacher should only receive event timeline updates for events they created or were assigned to.
          if (!isTeacherCreator && !isTeacherAssigned) {
            continue;
          }
        }

        // Registration updates are student-only.
        // Admin toggles 'Allow Registration' OFF which sets status to 'draft'
        if (role == 'student' && status == 'draft' && now.difference(updatedAt).inDays <= 7) {
          // Double check it's not a REJECTED proposal (which teachers see above)
          bool isRejected = description.contains('[REJECT_REASON:');
          
          if (!isRejected) {
             notifications.add(AppNotification(
              id: 'reg_closed_${eventId}_${updatedAt.millisecondsSinceEpoch}',
              title: 'Registration Closed',
              message: 'Registration for "$title" is now closed.',
              timestamp: updatedAt,
              type: NotificationType.warning,
              eventId: eventId,
            ));
          }
        }

        if (status == 'published') {
          // New Published Event / Registration Open
          // Visible to Students and Assigned Teachers as long as the event hasn't finished yet
          bool shouldNotify = (role == 'student') || (role == 'teacher' && isTeacherAssigned);
          
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
      }

      if (role == 'student' && currentUserId.isNotEmpty) {
        try {
          final rows = await _supabase
              .from('event_assistants')
              .select('event_id, assigned_by_teacher_id, allow_scan, created_at, events(title)')
              .eq('student_id', currentUserId)
              .eq('allow_scan', true)
              .not('assigned_by_teacher_id', 'is', null)
              .limit(60);

          for (final raw in (rows as List)) {
            final row = _asStringMap(raw);
            final eventId = row['event_id']?.toString() ?? '';
            if (eventId.isEmpty) continue;

            final assignedAtRaw = row['created_at'];
            final assignedAt = _tryParseLocalDate(assignedAtRaw);
            if (assignedAt == null) continue;
            if (now.difference(assignedAt).inDays > 14) continue;

            final event = _extractRelatedMap(row['events']);
            final eventTitle = event['title']?.toString().trim().isNotEmpty == true
                ? event['title'].toString().trim()
                : 'Event';

            notifications.add(
              AppNotification(
                id: 'scan_assign_$eventId',
                title: 'Scanner Assignment',
                message:
                    'You were assigned by the admin/teacher to help take attendance for "$eventTitle". Open the QR Scanner when instructed.',
                timestamp: assignedAt,
                type: NotificationType.info,
                eventId: eventId,
              ),
            );
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
      final pwdChangedList = prefs.getStringList('pwd_changes') ?? [];
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
         print("Error fetching Supabase read statuses: $e");
      }
      
      for (var notif in notifications) {
        if (readIds.contains(notif.id) || notif.timestamp.isBefore(lastReadDate) || notif.timestamp.isAtSameMomentAs(lastReadDate)) {
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
      return [];
    }
  }

  // Method to trigger local password change notification
  Future<void> addPasswordChangeNotification() async {
    final prefs = await SharedPreferences.getInstance();
    final pwdChangedList = prefs.getStringList('pwd_changes') ?? [];
    pwdChangedList.add(DateTime.now().toIso8601String());
    await prefs.setStringList('pwd_changes', pwdChangedList);
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
      print("Error in markAllAsRead: $e");
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
      print("Error in markAsRead: $e");
    }
  }

  Future<int> getUnreadCount({bool forceRefresh = false}) async {
    if (forceRefresh || !_isCacheFresh) {
      await refresh(force: true);
    }
    return _cachedNotifications.where((n) => !n.isRead).length;
  }
}
