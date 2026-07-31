import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../main.dart';
import '../screens/student/student_certificates.dart';
import '../screens/student/student_event_details.dart';
import '../screens/student/student_event_evaluation.dart';
import '../screens/teacher/teacher_event_manage.dart';
import '../screens/teacher/teacher_proposal_requirements_page.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_service.dart';
import 'event_live_service.dart';
import 'event_service.dart';
import 'live_ui_sync.dart';
import 'live_ui_sync_pending.dart';
import 'mobile_backend_service.dart';
import 'notification_service.dart';
import '../utils/app_page_routes.dart';

Future<void> _cacheApprovedRegistrationFromPayload(
  Map<String, dynamic> data,
) async {
  final type = (data['type']?.toString() ?? '').trim().toLowerCase();
  if (type != 'reg_approved') {
    return;
  }

  final eventId = (data['event_id']?.toString() ?? '').trim();
  if (eventId.isEmpty) {
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final userId = (prefs.getString('user_id') ?? '').trim();
  if (userId.isEmpty) {
    return;
  }

  final key = 'approved_registration_events_$userId';
  final values = <String>{
    ...(prefs.getStringList(key) ?? const <String>[]),
    eventId,
  };
  await prefs.setStringList(key, values.toList());
}

Future<void> _markApprovedRegistrationNotificationShown(
  String userId,
  String eventId,
) async {
  final trimmedUserId = userId.trim();
  final trimmedEventId = eventId.trim();
  if (trimmedUserId.isEmpty || trimmedEventId.isEmpty) {
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final key = 'shown_reg_approved_events_$trimmedUserId';
  final values = <String>{
    ...(prefs.getStringList(key) ?? const <String>[]),
    trimmedEventId,
  };
  await prefs.setStringList(key, values.toList());
}

Future<void> _markProposalRequirementsNotificationShown(
  String? userId,
  String eventId,
) async {
  final trimmedEventId = eventId.trim();
  if (trimmedEventId.isEmpty) {
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  const genericKey = 'shown_local_interactive_notifications';
  final genericValues = <String>{
    ...(prefs.getStringList(genericKey) ?? const <String>[]),
    'proposal_req_$trimmedEventId',
  };
  await prefs.setStringList(genericKey, genericValues.toList());

  final trimmedUserId = (userId ?? '').trim();
  if (trimmedUserId.isEmpty) {
    return;
  }

  final userKey = 'shown_local_interactive_notifications_$trimmedUserId';
  final userValues = <String>{
    ...(prefs.getStringList(userKey) ?? const <String>[]),
    'proposal_req_$trimmedEventId',
  };
  await prefs.setStringList(userKey, userValues.toList());
}

// Background message handler — must be top-level function
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await _cacheApprovedRegistrationFromPayload(message.data);
  // App/UI code does not run here — stamp a pending sync so the next
  // foreground/resume refreshes lists + bell to match the push.
  final type = (message.data['type']?.toString() ?? '').trim();
  final eventId = (message.data['event_id']?.toString() ?? '').trim();
  final reason = type.isEmpty
      ? 'push'
      : (eventId.isEmpty ? type : '$type:$eventId');
  await LiveUiSyncPending.mark(reason);
}

class PushNotificationService {
  static final PushNotificationService _instance = PushNotificationService._internal();
  factory PushNotificationService() => _instance;
  PushNotificationService._internal();

  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotificationsPlugin = FlutterLocalNotificationsPlugin();

  AuthService get _authService => AuthService();
  EventService get _eventService => EventService();

  Future<void> _cacheRegistrationApprovalIfNeeded(
    Map<String, dynamic> data,
  ) async {
    await _cacheApprovedRegistrationFromPayload(data);
  }

  bool _isCertificatePayload(String payload) {
    return payload.trim().toLowerCase() == 'route:certificates';
  }

  bool _isProposalRequirementsPayload(String payload) {
    return payload.trim().toLowerCase().startsWith(
      'proposal_requirements_requested:',
    );
  }

  String _proposalRequirementsEventId(String payload) {
    final trimmed = payload.trim();
    const prefix = 'proposal_requirements_requested:';
    if (!trimmed.toLowerCase().startsWith(prefix)) {
      return '';
    }
    return trimmed.substring(prefix.length).trim();
  }

  void _openCertificatesScreen() {
    PulseConnectApp.navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (context) => const StudentCertificates(),
      ),
    );
  }

  Future<void> initialize() async {
    // 1. Register background handler
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Wire toast helpers used by NotificationService (avoids import cycles).
    NotificationService.showEventToast = showLocalEventNotification;
    NotificationService.showCertificateToast = showLocalCertificateNotification;

    // 2. Request notification permissions (Android 13+ & iOS)
    NotificationSettings settings = await _firebaseMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional) {
      
      // 3. Handle notification taps (When app is in background but not terminated)
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationClick);

      // 4. Handle notification taps (When app is completely terminated)
      RemoteMessage? initialMessage = await _firebaseMessaging.getInitialMessage();
      if (initialMessage != null) {
        _handleNotificationClick(initialMessage);
      }

      // 5. Initialize Local Notifications for foreground popups
      const AndroidInitializationSettings androidInitSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      const DarwinInitializationSettings iosInitSettings =
          DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const InitializationSettings initSettings = InitializationSettings(
        android: androidInitSettings,
        iOS: iosInitSettings,
      );

      await _localNotificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          final payload = response.payload?.trim() ?? '';
          if (payload.isEmpty) return;
          unawaited(() async {
            if (_isCertificatePayload(payload)) {
              _openCertificatesScreen();
              return;
            }
            if (_isProposalRequirementsPayload(payload)) {
              final eventId = _proposalRequirementsEventId(payload);
              if (eventId.isNotEmpty) {
                final event = await _eventService.getEventById(eventId);
                if (event != null) {
                  PulseConnectApp.navigatorKey.currentState?.push(
                    MaterialPageRoute(
                      builder: (context) =>
                          TeacherProposalRequirementsPage(event: event),
                    ),
                  );
                  return;
                }
              }
            }

            // Local notifications (especially assignment-related) only carry
            // the eventId as payload. Decide the destination based on the
            // current user's role to avoid opening student-only pages.
            final user = await _authService.getCurrentUser();
            final role =
                (user?['role']?.toString() ?? '').trim().toLowerCase();

            if (role == 'teacher') {
              final event = await _eventService.getEventById(payload);
              if (event != null) {
                PulseConnectApp.navigatorKey.currentState?.push(
                  MaterialPageRoute(
                    builder: (context) => TeacherEventManage(event: event),
                  ),
                );
                return;
              }
            }

            // Default fallback for students (or if teacher event fetch fails)
            PulseConnectApp.navigatorKey.currentState?.push(
              AppPageRoute(
                builder: (context) => StudentEventDetails(eventId: payload),
              ),
            );
          }());
        },
      );

      // Create high importance channel for Android
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        'pulseconnect_events',
        'PulseConnect Events',
        description: 'Notifications for new events and registration updates.',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      );

      await _localNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      // 4. Foreground message listener — show local notification popup
      FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
        // Never surface account pushes on Welcome/Login/OTP screens.
        if (!await _hasLoggedInUser()) {
          debugPrint('[FCM] Ignoring foreground push — no logged-in session.');
          return;
        }

        final route = (message.data['route']?.toString() ?? '').trim().toLowerCase();
        final eventId = (message.data['event_id']?.toString() ?? '').trim();
        final type = (message.data['type']?.toString() ?? '').trim().toLowerCase();

        // Sync UI first (before local notification work) so lists/bell don't
        // lag behind the system tray banner.
        debugPrint('[FCM] Foreground push type=$type event=$eventId — syncing UI');
        if ((type == 'student_requirements_approved' ||
                type == 'student_requirements_declined') &&
            eventId.isNotEmpty) {
          EventLiveService.instance.pulseStudentRequirementsReview(
            eventId: eventId,
            type: type,
          );
        } else {
          await LiveUiSync.syncNow(
            type.isNotEmpty
                ? (eventId.isNotEmpty ? '$type:$eventId' : type)
                : 'notification',
          );
        }

        await _cacheRegistrationApprovalIfNeeded(message.data);
        RemoteNotification? notification = message.notification;
        final payload = route == 'certificates'
            ? 'route:certificates'
            : (eventId.isNotEmpty
                  ? (type == 'proposal_requirements_requested'
                        ? 'proposal_requirements_requested:$eventId'
                        : eventId)
                  : null);

        final fallbackTitle =
            route == 'certificates' ? 'Certificate Ready' : 'PulseConnect';
        final fallbackBody = route == 'certificates'
            ? 'Your certificate is now available. Open Certificates to view it.'
            : 'You have a new notification.';

        if (type == 'reg_approved' && eventId.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          final userId = (prefs.getString('user_id') ?? '').trim();
          if (userId.isNotEmpty) {
            await _markApprovedRegistrationNotificationShown(userId, eventId);
          }
        }
        if (type == 'proposal_requirements_requested' && eventId.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          final userId = (prefs.getString('user_id') ?? '').trim();
          await _markProposalRequirementsNotificationShown(userId, eventId);
        }

        try {
          await _localNotificationsPlugin.show(
            notification?.hashCode ??
                DateTime.now().millisecondsSinceEpoch ~/ 1000,
            notification?.title ?? fallbackTitle,
            notification?.body ?? fallbackBody,
            NotificationDetails(
              android: AndroidNotificationDetails(
                channel.id,
                channel.name,
                channelDescription: channel.description,
                icon: '@mipmap/ic_launcher',
                importance: Importance.high,
                priority: Priority.high,
                playSound: true,
                styleInformation: BigTextStyleInformation(
                  notification?.body ?? fallbackBody,
                  contentTitle: notification?.title ?? fallbackTitle,
                  summaryText: 'PulseConnect',
                ),
              ),
              iOS: const DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
              ),
            ),
            payload: payload,
          );
        } catch (e) {
          debugPrint('[FCM] Local notification show failed: $e');
        }
      });

      // Keep token row fresh when Firebase rotates it (only while logged in).
      _firebaseMessaging.onTokenRefresh.listen((_) async {
        if (await _hasLoggedInUser()) {
          await updateToken();
        } else {
          await unregisterCurrentToken();
        }
      });
    }
  }

  Future<void> showLocalEventNotification({
    required String title,
    required String body,
    String? eventId,
    String? payload,
  }) async {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'pulseconnect_events',
      'PulseConnect Events',
      description: 'Notifications for new events and registration updates.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    await _localNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          icon: '@mipmap/ic_launcher',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          styleInformation: BigTextStyleInformation(
            body,
            contentTitle: title,
            summaryText: 'PulseConnect',
          ),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: (payload?.trim().isNotEmpty ?? false) ? payload!.trim() : eventId,
    );
  }

  Future<void> showLocalCertificateNotification({
    required String title,
    required String body,
  }) async {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'pulseconnect_events',
      'PulseConnect Events',
      description: 'Notifications for new events and registration updates.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    await _localNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          icon: '@mipmap/ic_launcher',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          styleInformation: BigTextStyleInformation(
            body,
            contentTitle: title,
            summaryText: 'PulseConnect',
          ),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'route:certificates',
    );
  }

  /// Gets the FCM Token and saves it via PHP (fcm_tokens is revoked from anon).
  Future<void> updateToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      if (userId == null || userId.isEmpty) {
        debugPrint('[FCM] No user_id in SharedPreferences, skipping token save.');
        return;
      }

      String? token = await _firebaseMessaging.getToken();
      if (kDebugMode) {
        debugPrint(
          '[FCM] Device token present: ${token != null && token.isNotEmpty}',
        );
      }

      if (token != null && token.isNotEmpty) {
        // Upsert only — never delete-first (that wiped tokens when upsert failed).
        final saved = await MobileBackendService().secureWrite('fcm_upsert', {
          'token': token,
          'platform': 'android',
        });
        if (saved['ok'] == true) {
          debugPrint('[FCM] Token saved via secure backend.');
        } else {
          debugPrint('[FCM] Token save failed: ${saved['error']}');
        }
      }
    } catch (e) {
      debugPrint('[FCM] Error saving FCM Token: $e');
    }
  }

  /// Remove this device token so logged-out screens stop getting pushes.
  Future<void> unregisterCurrentToken({String? userId}) async {
    try {
      String? token;
      try {
        token = await _firebaseMessaging.getToken();
      } catch (e) {
        debugPrint('[FCM] Could not read token for unregister: $e');
      }

      await MobileBackendService().secureWrite('fcm_delete', {
        if (token != null && token.isNotEmpty) 'token': token,
      });
      debugPrint('[FCM] Device token unregistered.');
    } catch (e) {
      debugPrint('[FCM] Error unregistering FCM Token: $e');
    }
  }

  Future<bool> _hasLoggedInUser() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString('user_id') ?? '').trim().isNotEmpty;
  }

  /// Navigate to a specific event if the notification contains an event_id.
  /// Teachers are routed to TeacherEventManage, students to StudentEventDetails.
  Future<void> _handleNotificationClick(RemoteMessage message) async {
    await _cacheRegistrationApprovalIfNeeded(message.data);
    final type = (message.data['type']?.toString() ?? '').trim().toLowerCase();
    final tappedEventId = (message.data['event_id']?.toString() ?? '').trim();
    // Tapping a push from tray means the underlying data already changed —
    // refresh in-app state immediately when returning to the app.
    if ((type == 'student_requirements_approved' ||
            type == 'student_requirements_declined') &&
        tappedEventId.isNotEmpty) {
      EventLiveService.instance.pulseStudentRequirementsReview(
        eventId: tappedEventId,
        type: type,
      );
    } else {
      await LiveUiSync.syncNow(
        type.isNotEmpty
            ? (tappedEventId.isNotEmpty ? '$type:$tappedEventId' : type)
            : 'opened',
      );
    }

    final route = (message.data['route']?.toString() ?? '').trim().toLowerCase();
    if (route == 'certificates') {
      _openCertificatesScreen();
      return;
    }

    String? eventId = message.data['event_id'];
    if (eventId != null && eventId.isNotEmpty) {
      debugPrint('[FCM] Tapped notification for event_id: $eventId');

      try {
        final user = await _authService.getCurrentUser();
        final role = (user?['role']?.toString() ?? '').toLowerCase();

        if (role == 'teacher') {
          final event = await _eventService.getEventById(eventId);
          if (event != null) {
            if (type == 'proposal_requirements_requested') {
              PulseConnectApp.navigatorKey.currentState?.push(
                MaterialPageRoute(
                  builder: (context) =>
                      TeacherProposalRequirementsPage(event: event),
                ),
              );
              return;
            }
            PulseConnectApp.navigatorKey.currentState?.push(
              MaterialPageRoute(
                builder: (context) => TeacherEventManage(event: event),
              ),
            );
            return;
          }
        }

        if (role == 'student' &&
            (type == 'eval_open' || route == 'evaluation')) {
          final studentId = (user?['id']?.toString() ?? '').trim();
          if (studentId.isNotEmpty) {
            PulseConnectApp.navigatorKey.currentState?.push(
              AppPageRoute(
                builder: (context) => StudentEventEvaluationScreen(
                  eventId: eventId,
                  studentId: studentId,
                ),
              ),
            );
            return;
          }
        }
      } catch (e) {
        debugPrint('[FCM] Notification route fallback: $e');
      }

      PulseConnectApp.navigatorKey.currentState?.push(
        AppPageRoute(
          builder: (context) => StudentEventDetails(eventId: eventId),
        ),
      );
    }
  }
}

