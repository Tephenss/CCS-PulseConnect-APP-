import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';

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
  final _supabase = Supabase.instance.client;

  Future<List<AppNotification>> getNotifications() async {
    List<AppNotification> notifications = [];
    final now = DateTime.now();

    try {
      final authService = AuthService();
      final userData = await authService.getCurrentUser();
      
      if (userData == null) return [];

      final role = userData['role'] ?? 'student';

      final events = await _supabase
          .from('events')
          .select()
          .not('status', 'eq', 'archived')
          .order('start_at', ascending: true);

      for (var event in events) {
        final startAt = DateTime.parse(event['start_at']).toLocal();
        final endAt = DateTime.parse(event['end_at']).toLocal();
        final status = event['status'];
        final title = event['title'];
        final eventId = event['id'].toString();

        final hoursUntilStart = startAt.difference(now).inHours;
        final minsUtilStart = startAt.difference(now).inMinutes;
        final createdAt = DateTime.parse(event['created_at']).toLocal();

        // Check if event is actually expired (start_at has passed)
        // If it has passed, it behaves like an expired/ongoing event
        bool isExpired = startAt.isBefore(now);

        // Teacher: Event Approved Notification
        if (role == 'teacher' && status == 'approved') {
          // If approved recently (e.g. within 7 days)
          if (now.difference(createdAt).inDays <= 7) {
            notifications.add(AppNotification(
              id: 'approved_$eventId',
              title: 'Event Approved',
              message: 'Ang "$title" ay approved na at pwede nang i-publish.',
              timestamp: createdAt.add(const Duration(hours: 1)), // Just an estimate order
              type: NotificationType.success,
              eventId: eventId,
            ));
          }
        }

        if (status == 'published') {
          // Student/Teacher: New Published Event
          if (!isExpired && now.difference(createdAt).inDays <= 7) {
            notifications.add(AppNotification(
              id: 'pub_$eventId',
              title: 'Bagong Event Published!',
              message: 'Available na ang registration para sa "$title".',
              timestamp: createdAt,
              type: NotificationType.info,
              eventId: eventId,
            ));
          }

          if (!isExpired) {
            // Reminders (Within 24 hours)
            if (hoursUntilStart >= 1 && hoursUntilStart <= 24) {
              notifications.add(AppNotification(
                id: 'near_$eventId',
                title: 'Reminder: Malapit na!',
                message: 'Ang "$title" ay magsisimula na bukas!',
                timestamp: now.subtract(const Duration(minutes: 30)),
                type: NotificationType.warning,
                eventId: eventId,
              ));
            }

            // Reminders (Within 1 hour)
            if (hoursUntilStart == 0 && minsUtilStart > 0) {
              notifications.add(AppNotification(
                id: 'start_$eventId',
                title: 'Magsisimula na!',
                message: 'Ang "$title" ay magsisimula na sa loob ng $minsUtilStart minuto.',
                timestamp: now.subtract(const Duration(minutes: 5)),
                type: NotificationType.warning,
                eventId: eventId,
              ));
            }
          }

          // Matatapos na (Event ending within 1 hour)
          if (now.isAfter(startAt) && now.isBefore(endAt)) {
            final minsUtilEnd = endAt.difference(now).inMinutes;
            if (minsUtilEnd <= 60 && minsUtilEnd > 0) {
              notifications.add(AppNotification(
                id: 'end_$eventId',
                title: 'Palapit nang Matapos',
                message: 'Ang "$title" ay matatapos na sa loob ng $minsUtilEnd minuto.',
                timestamp: now.subtract(const Duration(minutes: 2)),
                type: NotificationType.warning,
                eventId: eventId,
              ));
            } else {
              notifications.add(AppNotification(
                id: 'ongoing_$eventId',
                title: 'Ongoing Ngayon',
                message: 'Kasalukuyang ginaganap ang "$title".',
                timestamp: startAt,
                type: NotificationType.success,
                eventId: eventId,
              ));
            }
          }
        }

        // Expired events
        if (isExpired || status == 'expired') {
          // Only show recent completions
          if (now.difference(endAt).inDays <= 3) {
            notifications.add(AppNotification(
              id: 'expired_$eventId',
              title: 'Event Natapos Na',
              message: 'Ang event na "$title" ay tapos na.',
              timestamp: endAt,
              type: NotificationType.error, // Red/Gray indicator
              eventId: eventId,
            ));
          }
        }
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
            message: 'Matagumpay na napalitan ang iyong password.',
            timestamp: DateTime.parse(isoDate),
            type: NotificationType.success,
          ));
        } catch (_) {}
      }

      // Read status tracking
      final lastReadStr = prefs.getString('last_notif_read');
      final lastReadDate = lastReadStr != null ? DateTime.parse(lastReadStr) : DateTime(2000);
      final readIds = prefs.getStringList('read_notif_ids') ?? [];
      
      for (var notif in notifications) {
        if (readIds.contains(notif.id) || notif.timestamp.isBefore(lastReadDate) || notif.timestamp.isAtSameMomentAs(lastReadDate)) {
          notif.isRead = true;
        }
      }

      // Sort by timestamp descending (newest first)
      notifications.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      // Limit to 50 max to prevent performance hit
      if (notifications.length > 50) {
        notifications = notifications.sublist(0, 50);
      }

      return notifications;
    } catch (e) {
      print('Error fetching notifications: $e');
      return [];
    }
  }

  // Method to trigger local password change notification
  Future<void> addPasswordChangeNotification() async {
    final prefs = await SharedPreferences.getInstance();
    final pwdChangedList = prefs.getStringList('pwd_changes') ?? [];
    pwdChangedList.add(DateTime.now().toIso8601String());
    await prefs.setStringList('pwd_changes', pwdChangedList);
  }

  // Clear notifications cache
  Future<void> markAllAsRead() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_notif_read', DateTime.now().toIso8601String());
  }

  // Mark specific as read
  Future<void> markAsRead(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final readIds = prefs.getStringList('read_notif_ids') ?? [];
    if (!readIds.contains(id)) {
      readIds.add(id);
      await prefs.setStringList('read_notif_ids', readIds);
    }
  }

  Future<int> getUnreadCount() async {
    final notifications = await getNotifications();
    return notifications.where((n) => !n.isRead).length;
  }
}
