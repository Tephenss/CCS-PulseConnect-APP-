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
        final updatedAt = DateTime.parse(event['updated_at'] ?? event['created_at']).toLocal();
        final description = event['description'] ?? '';

        // Check if event has already started
        bool hasStarted = startAt.isBefore(now);
        // Check if event has actually ended
        bool isFinished = endAt.isBefore(now);

        // Teacher: Event Approved or Rejected (Draft) Notification
        if (role == 'teacher') {
          if (status == 'approved' && now.difference(updatedAt).inDays <= 7) {
            notifications.add(AppNotification(
              id: 'approved_$eventId',
              title: 'Event Approved',
              message: '"$title" has been approved and is ready to be published.',
              timestamp: updatedAt,
              type: NotificationType.success,
              eventId: eventId,
            ));
          } else if ((status == 'draft' || status == 'archived') && now.difference(updatedAt).inDays <= 7) {
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
        }

        // Student/Teacher: Registration Closed 
        // Admin toggles 'Allow Registration' OFF which sets status to 'draft'
        if (status == 'draft' && now.difference(updatedAt).inDays <= 7) {
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
          // Student/Teacher: New Published Event
          // Visible as long as the event hasn't finished yet
          if (!isFinished && now.difference(updatedAt).inDays <= 7) {
            notifications.add(AppNotification(
              id: 'pub_${eventId}_${updatedAt.millisecondsSinceEpoch}',
              title: 'Registration Open!',
              message: 'Registration is now available for "$title".',
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
          if (now.isAfter(startAt) && now.isBefore(endAt)) {
            final minsUtilEnd = endAt.difference(now).inMinutes;
            if (minsUtilEnd <= 60 && minsUtilEnd > 0) {
              notifications.add(AppNotification(
                id: 'end_$eventId',
                title: 'Ending Soon',
                message: '"$title" ends in $minsUtilEnd minutes.',
                timestamp: endAt.subtract(const Duration(hours: 1)),
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
        if (isFinished || status == 'expired') {
          // Only show recent completions (within last 3 days)
          // Use endAt as the actual time it happened
          if (now.difference(endAt).inDays <= 3 && endAt.isBefore(now)) {
            notifications.add(AppNotification(
              id: 'finished_$eventId',
              title: 'Event Completed',
              message: 'The event "$title" has ended.',
              timestamp: endAt,
              type: NotificationType.error,
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
  }

  // Mark all notifications as read
  Future<void> markAllAsRead([List<String>? ids]) async {
    try {
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
    } catch (e) {
      print("Error in markAllAsRead: $e");
    }
  }

  // Mark specific as read
  Future<void> markAsRead(String id) async {
    try {
      final authService = AuthService();
      final userData = await authService.getCurrentUser();
      if (userData == null) return;
      final userId = userData['id'];

      await _supabase.from('user_notification_reads').upsert({
        'user_id': userId,
        'notification_id': id,
      }, onConflict: 'user_id, notification_id');
    } catch (e) {
      print("Error in markAsRead: $e");
    }
  }

  Future<int> getUnreadCount() async {
    final notifications = await getNotifications();
    return notifications.where((n) => !n.isRead).length;
  }
}
