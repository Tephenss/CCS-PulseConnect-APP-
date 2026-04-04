import 'package:flutter/material.dart';
import '../main.dart';
import '../screens/student/student_event_details.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Background message handler — must be top-level function
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

class PushNotificationService {
  static final PushNotificationService _instance = PushNotificationService._internal();
  factory PushNotificationService() => _instance;
  PushNotificationService._internal();

  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotificationsPlugin = FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    // 1. Register background handler
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

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
          // This handles clicking custom local notifications in foreground
          // For now, we rely on standard FCM data handling, but could expand here
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
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        RemoteNotification? notification = message.notification;
        AndroidNotification? android = message.notification?.android;

        if (notification != null) {
          _localNotificationsPlugin.show(
            notification.hashCode,
            notification.title,
            notification.body,
            NotificationDetails(
              android: AndroidNotificationDetails(
                channel.id,
                channel.name,
                channelDescription: channel.description,
                icon: '@mipmap/ic_launcher',
                importance: Importance.high,
                priority: Priority.high,
                playSound: true,
              ),
              iOS: const DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
              ),
            ),
          );
        }
      });
    }
  }

  /// Gets the FCM Token and saves it to the `fcm_tokens` table in Supabase.
  /// Uses SharedPreferences user_id since we use custom auth, not Supabase Auth.
  Future<void> updateToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      if (userId == null || userId.isEmpty) {
        print('[FCM] No user_id in SharedPreferences, skipping token save.');
        return;
      }

      String? token = await _firebaseMessaging.getToken();
      print('[FCM] Device token: $token');

      if (token != null) {
        // Step 1: Delete ALL existing rows for this token (any user_id)
        // This ensures one physical device = one row, preventing ghost notifications
        await Supabase.instance.client
            .from('fcm_tokens')
            .delete()
            .eq('token', token);

        // Step 2: Insert fresh row for the currently logged-in user
        await Supabase.instance.client
            .from('fcm_tokens')
            .insert({
              'user_id': userId,
              'token': token,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            });
        print('[FCM] Token saved to Supabase successfully.');
      }
    } catch (e) {
      print('[FCM] Error saving FCM Token: $e');
    }
  }
  /// Navigate to a specific event if the notification contains an event_id
  void _handleNotificationClick(RemoteMessage message) {
    String? eventId = message.data['event_id'];
    if (eventId != null && eventId.isNotEmpty) {
      print('[FCM] Tapped notification for event_id: $eventId');
      
      // Use the global navigator key to push the Detail screen
      PulseConnectApp.navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (context) => StudentEventDetails(eventId: eventId),
        ),
      );
    }
  }
}
