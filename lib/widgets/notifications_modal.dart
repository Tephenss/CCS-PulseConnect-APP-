import 'dart:async';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/event_service.dart';
import '../services/notification_service.dart';
import '../screens/student/student_certificates.dart';
import '../screens/student/student_event_details.dart';
import '../screens/teacher/teacher_event_manage.dart';
import 'custom_loader.dart';

bool _isNotificationsModalOpen = false;

Future<int?> showNotificationsModal(BuildContext context) {
  if (!context.mounted) {
    return Future<int?>.value(null);
  }

  final route = ModalRoute.of(context);
  if (route == null || !route.isCurrent || _isNotificationsModalOpen) {
    return Future<int?>.value(null);
  }

  _isNotificationsModalOpen = true;
  return showGeneralDialog<int>(
    context: context,
    useRootNavigator: false,
    barrierDismissible: true,
    barrierLabel: 'Notifications',
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) {
      return const _NotificationsFloatingModal();
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: Transform.scale(
          scale: Tween<double>(begin: 0.96, end: 1.0).evaluate(curved),
          child: child,
        ),
      );
    },
  ).whenComplete(() {
    _isNotificationsModalOpen = false;
  });
}

class _NotificationsFloatingModal extends StatefulWidget {
  const _NotificationsFloatingModal();

  @override
  State<_NotificationsFloatingModal> createState() => _NotificationsFloatingModalState();
}

class _NotificationsFloatingModalState extends State<_NotificationsFloatingModal> {
  final _service = NotificationService();
  final _auth = AuthService();
  final _eventService = EventService();

  List<AppNotification> _notifications = [];
  bool _isLoading = true;
  bool _isTeacherTheme = false;
  bool _showAll = false;
  StreamSubscription<int>? _unreadSubscription;

  Color get _themeColor => _isTeacherTheme ? const Color(0xFF059669) : const Color(0xFFB45309);

  @override
  void initState() {
    super.initState();
    _loadData(force: true);
    _unreadSubscription = _service.unreadCountStream.listen((_) {
      _loadData();
    });
  }

  Future<void> _loadData({bool force = false}) async {
    final user = await _auth.getCurrentUser();
    final role = user?['role']?.toString() ?? 'student';
    final notifs = await _service.getNotifications(forceRefresh: force);

    if (!mounted) return;
    setState(() {
      _isTeacherTheme = role == 'teacher';
      _notifications = notifs;
      _isLoading = false;
    });
  }

  Future<void> _markAllAsRead() async {
    if (_notifications.isEmpty) return;
    final ids = _notifications.map((n) => n.id).toList();
    await _service.markAllAsRead(ids);
    await _loadData();
  }

  @override
  void dispose() {
    _unreadSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    double modalWidth = size.width - 28;
    if (modalWidth > 460) modalWidth = 460;
    final double modalHeight = _showAll
        ? (size.height * 0.86).clamp(420.0, 700.0)
        : 430;
    final int previewCount = _showAll ? _notifications.length : (_notifications.length > 5 ? 5 : _notifications.length);

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: Center(
          child: SizedBox(
            width: modalWidth,
            height: modalHeight,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFFE5E7EB)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 30,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                    child: Row(
                      children: [
                        const Text(
                          'Notifications',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111827),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: _markAllAsRead,
                          tooltip: 'Mark all as read',
                          icon: const Icon(Icons.done_all_rounded),
                          color: _themeColor,
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                          color: const Color(0xFF6B7280),
                          tooltip: 'Close',
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _isLoading
                        ? const Center(child: PulseConnectLoader())
                        : _notifications.isEmpty
                            ? _buildEmptyState()
                            : RefreshIndicator(
                                color: _themeColor,
                                onRefresh: () => _loadData(force: true),
                                child: ListView.separated(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  itemCount: previewCount,
                                  separatorBuilder: (_, _) => const Divider(height: 1),
                                  itemBuilder: (context, index) => _buildNotificationRow(_notifications[index]),
                                ),
                              ),
                  ),
                  if (!_isLoading && _notifications.isNotEmpty)
                    Container(
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
                      ),
                      child: TextButton(
                        onPressed: () {
                          if (_notifications.length <= 5) return;
                          setState(() => _showAll = !_showAll);
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: _themeColor,
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                        ),
                        child: Text(
                          _notifications.length <= 5
                              ? 'All notifications shown'
                              : (_showAll ? 'Show Less' : 'See All Notifications'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 66,
            height: 66,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: const Icon(Icons.notifications_none_rounded, color: Color(0xFF9CA3AF), size: 30),
          ),
          const SizedBox(height: 14),
          const Text(
            "You're all caught up!",
            style: TextStyle(
              color: Color(0xFF6B7280),
              fontSize: 21,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationRow(AppNotification n) {
    final diff = DateTime.now().difference(n.timestamp);
    final timeStr = diff.inDays > 0
        ? '${diff.inDays}d ago'
        : diff.inHours > 0
            ? '${diff.inHours}h ago'
            : diff.inMinutes > 0
                ? '${diff.inMinutes}m ago'
                : 'Just now';

    IconData icon = Icons.notifications_rounded;
    Color iconColor = const Color(0xFF2563EB);
    switch (n.type) {
      case NotificationType.success:
        icon = Icons.check_circle_rounded;
        iconColor = const Color(0xFF16A34A);
        break;
      case NotificationType.warning:
        icon = Icons.warning_amber_rounded;
        iconColor = const Color(0xFFD97706);
        break;
      case NotificationType.error:
        icon = Icons.error_rounded;
        iconColor = const Color(0xFFDC2626);
        break;
      case NotificationType.event:
        icon = Icons.event_rounded;
        iconColor = _themeColor;
        break;
      case NotificationType.info:
        icon = Icons.info_rounded;
        iconColor = const Color(0xFF2563EB);
        break;
    }

    return InkWell(
      onTap: () async {
        if (!n.isRead) {
          await _service.markAsRead(n.id);
        }
        await _openNotificationTarget(n);
      },
      child: Container(
        color: n.isRead ? Colors.white : _themeColor.withValues(alpha: 0.06),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          n.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: Color(0xFF111827),
                          ),
                        ),
                      ),
                      Text(
                        timeStr,
                        style: const TextStyle(
                          color: Color(0xFF9CA3AF),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    n.message,
                    style: const TextStyle(
                      color: Color(0xFF4B5563),
                      fontSize: 12.5,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openNotificationTarget(AppNotification n) async {
    final role = (await _auth.getCurrentUser())?['role']?.toString().toLowerCase() ?? 'student';
    if (!mounted) return;

    Navigator.pop(context);

    if (n.id.startsWith('cert_')) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const StudentCertificates()),
      );
      return;
    }

    final eventId = n.eventId?.trim() ?? '';
    if (eventId.isEmpty) return;

    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;

    if (role == 'teacher') {
      try {
        final event = await _eventService.getEventById(eventId);
        if (event != null && mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => TeacherEventManage(event: event)),
          );
          return;
        }
      } catch (_) {
        // Fall through to the student-style event details route if loading fails.
      }
    }

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StudentEventDetails(eventId: eventId)),
    );
  }
}
