import 'package:flutter/material.dart';
import '../../services/notification_service.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import 'student/student_event_details.dart';
import 'teacher/teacher_event_manage.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final _service = NotificationService();
  List<AppNotification> _notifications = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final notifs = await _service.getNotifications();
    if (mounted) {
      setState(() {
        _notifications = notifs;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Colors.white)),
        backgroundColor: const Color(0xFF064E3B),
        centerTitle: true,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.done_all_rounded, color: Colors.white),
            tooltip: 'Mark all as read',
            onPressed: () async {
              await _service.markAllAsRead();
              _loadData();
            },
          ),
        ],
      ),
      body: _isLoading 
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF064E3B)))
          : _notifications.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  color: const Color(0xFF064E3B),
                  onRefresh: _loadData,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                    itemCount: _notifications.length,
                    itemBuilder: (context, index) {
                      final n = _notifications[index];
                      return _buildNotificationCard(n);
                    },
                  ),
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_off_rounded, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          const Text('No notifications yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1F2937))),
          const SizedBox(height: 8),
          Text('We\'ll notify you when something important happens.', style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
        ],
      ),
    );
  }

  Widget _buildNotificationCard(AppNotification n) {
    IconData icon;
    Color color;

    switch (n.type) {
      case NotificationType.success:
        icon = Icons.check_circle_rounded;
        color = Colors.green.shade600;
        break;
      case NotificationType.warning:
        icon = Icons.access_time_filled_rounded;
        color = const Color(0xFFD4A843);
        break;
      case NotificationType.error:
        icon = Icons.event_busy_rounded;
        color = Colors.red.shade400;
        break;
      case NotificationType.event:
        icon = Icons.event_available_rounded;
        color = const Color(0xFF064E3B);
        break;
      default:
        icon = Icons.info_rounded;
        color = Colors.blue.shade400;
    }

    final diff = DateTime.now().difference(n.timestamp);
    String timeStr;
    if (diff.inDays > 0) {
      timeStr = '${diff.inDays}d ago';
    } else if (diff.inHours > 0) {
      timeStr = '${diff.inHours}h ago';
    } else if (diff.inMinutes > 0) {
      timeStr = '${diff.inMinutes}m ago';
    } else {
      timeStr = 'Just now';
    }

    return GestureDetector(
      onTap: () async {
        if (!n.isRead) {
          await _service.markAsRead(n.id);
        }
        
        // Pop back to Home screen and pass index '1' (Events Tab)
        if (mounted) {
          Navigator.pop(context, 1);
        }
      },
      child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: n.isRead ? Colors.white : const Color(0xFF064E3B).withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: n.isRead ? Border.all(color: Colors.grey.shade200) : Border.all(color: const Color(0xFF064E3B).withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10, offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        n.title,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Color(0xFF1F2937)),
                      ),
                    ),
                    Text(
                      timeStr,
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Colors.grey.shade500),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  n.message,
                  style: TextStyle(fontWeight: FontWeight.w500, fontSize: 14, color: Colors.grey.shade700, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    );
  }
}
