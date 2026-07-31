import 'dart:async';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/device_performance_service.dart';
import '../services/event_service.dart';
import '../services/notification_service.dart';
import '../screens/student/student_certificates.dart';
import '../screens/student/student_event_details.dart';
import '../screens/teacher/teacher_event_manage.dart';
import '../screens/teacher/teacher_proposal_requirements_page.dart';
import 'custom_loader.dart';
import '../utils/teacher_theme_utils.dart';
import '../utils/app_page_routes.dart';

import '../screens/notifications_page.dart';

Future<int?> showNotificationsModal(BuildContext context) {
  if (!context.mounted) {
    return Future<int?>.value(null);
  }

  return Navigator.of(context).push<int>(
    AppPageRoute(
      builder: (_) => const NotificationsPage(),
    ),
  );
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

  Color get _primaryColor => _isTeacherTheme ? TeacherThemeUtils.primary : const Color(0xFFC2410C);
  Color get _accentColor => _isTeacherTheme ? TeacherThemeUtils.dark : const Color(0xFFEA580C);

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
    final role = user?['role']?.toString().toLowerCase() ?? 'student';
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
    double modalWidth = size.width - 24;
    if (modalWidth > 460) modalWidth = 460;
    
    final int unreadCount = _notifications.where((n) => !n.isRead).length;
    final int previewCount = _showAll 
        ? _notifications.length 
        : (_notifications.length > 5 ? 5 : _notifications.length);

    final double modalHeight = _showAll
        ? (size.height * 0.82).clamp(440.0, 720.0)
        : (140.0 + (previewCount == 0 ? 220 : previewCount * 86.0)).clamp(280.0, 520.0);

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: Center(
          child: SizedBox(
            width: modalWidth,
            height: modalHeight,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: const Color(0xFFFAFAFA),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.9),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: DevicePerformance.instance.shadowOpacity(0.35),
                    ),
                    blurRadius: DevicePerformance.instance.shadowBlur(36),
                    spreadRadius: DevicePerformance.instance.enableHeavyShadows ? 2 : 0,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // ── ELEGANT HEADER CONTAINER ──
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: _isTeacherTheme
                            ? [const Color(0xFF380808), const Color(0xFF6B1515)]
                            : [const Color(0xFF1C0A0A), const Color(0xFF7F1D1D), const Color(0xFF9A3412)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Row(
                      children: [
                        // Bell Icon Badge
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.25),
                            ),
                          ),
                          child: const Icon(
                            Icons.notifications_active_rounded,
                            color: Colors.amberAccent,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),

                        // Title & Unread Count Badge (Flexible to prevent any RenderFlex overflow)
                        Expanded(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Flexible(
                                child: Text(
                                  'Notifications',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.white,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                              if (unreadCount > 0) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEF4444),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '$unreadCount NEW',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.4,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(width: 6),

                        // Action Pill: Mark all read
                        if (unreadCount > 0)
                          InkWell(
                            onTap: _markAllAsRead,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.done_all_rounded, color: Colors.amberAccent, size: 14),
                                  const SizedBox(width: 3),
                                  Text(
                                    'Read All',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.9),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                        const SizedBox(width: 2),

                        // Close Button
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                          tooltip: 'Close',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                      ],
                    ),
                  ),

                  // ── BODY LIST ──
                  Expanded(
                    child: _isLoading
                        ? const Center(child: PulseConnectLoader())
                        : _notifications.isEmpty
                            ? _buildEmptyState()
                            : RefreshIndicator(
                                color: _primaryColor,
                                onRefresh: () => _loadData(force: true),
                                child: ListView.builder(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                                  itemCount: previewCount,
                                  itemBuilder: (context, index) => _buildNotificationCard(_notifications[index]),
                                ),
                              ),
                  ),

                  // ── FOOTER ──
                  if (!_isLoading && _notifications.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        border: Border(top: BorderSide(color: Color(0xFFF3F4F6))),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () {
                                if (_notifications.length <= 5) return;
                                setState(() => _showAll = !_showAll);
                              },
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: _notifications.length <= 5
                                      ? Colors.grey.shade300
                                      : _primaryColor.withValues(alpha: 0.5),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    _notifications.length <= 5
                                        ? 'All ${_notifications.length} notifications shown'
                                        : (_showAll ? 'Show Less' : 'See All (${_notifications.length})'),
                                    style: TextStyle(
                                      color: _notifications.length <= 5
                                          ? const Color(0xFF6B7280)
                                          : _primaryColor,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  if (_notifications.length > 5) ...[
                                    const SizedBox(width: 6),
                                    Icon(
                                      _showAll
                                          ? Icons.keyboard_arrow_up_rounded
                                          : Icons.keyboard_arrow_down_rounded,
                                      color: _primaryColor,
                                      size: 18,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    _primaryColor.withValues(alpha: 0.12),
                    _accentColor.withValues(alpha: 0.05),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _primaryColor.withValues(alpha: 0.2),
                ),
              ),
              child: Icon(
                Icons.notifications_off_outlined,
                color: _primaryColor,
                size: 34,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              "You're all caught up!",
              style: TextStyle(
                color: Color(0xFF111827),
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "No new notifications right now. Important event updates & status announcements will appear here.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotificationCard(AppNotification n) {
    final diff = DateTime.now().difference(n.timestamp);
    final timeStr = diff.inDays > 0
        ? '${diff.inDays}d ago'
        : diff.inHours > 0
            ? '${diff.inHours}h ago'
            : diff.inMinutes > 0
                ? '${diff.inMinutes}m ago'
                : 'Just now';

    IconData icon = Icons.notifications_rounded;
    Color iconBgStart = const Color(0xFF2563EB);
    Color iconBgEnd = const Color(0xFF1D4ED8);
    String typeLabel = 'INFO';

    switch (n.type) {
      case NotificationType.success:
        icon = Icons.check_circle_rounded;
        iconBgStart = const Color(0xFF10B981);
        iconBgEnd = const Color(0xFF059669);
        typeLabel = 'SUCCESS';
        break;
      case NotificationType.warning:
        icon = Icons.warning_amber_rounded;
        iconBgStart = const Color(0xFFF59E0B);
        iconBgEnd = const Color(0xFFD97706);
        typeLabel = 'ALERT';
        break;
      case NotificationType.error:
        icon = Icons.error_rounded;
        iconBgStart = const Color(0xFFEF4444);
        iconBgEnd = const Color(0xFFDC2626);
        typeLabel = 'ACTION';
        break;
      case NotificationType.event:
        icon = Icons.event_rounded;
        iconBgStart = const Color(0xFFEA580C);
        iconBgEnd = const Color(0xFFC2410C);
        typeLabel = 'EVENT';
        break;
      case NotificationType.info:
        icon = Icons.info_rounded;
        iconBgStart = const Color(0xFF0EA5E9);
        iconBgEnd = const Color(0xFF0284C7);
        typeLabel = 'UPDATE';
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: n.isRead
              ? const Color(0xFFE5E7EB)
              : _primaryColor.withValues(alpha: 0.25),
          width: n.isRead ? 1 : 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: DevicePerformance.instance.shadowOpacity(n.isRead ? 0.03 : 0.07),
            ),
            blurRadius: DevicePerformance.instance.shadowBlur(8),
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            if (!n.isRead) {
              await _service.markAsRead(n.id);
            }
            await _openNotificationTarget(n);
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Unread Indicator Dot
                if (!n.isRead)
                  Container(
                    margin: const EdgeInsets.only(top: 14, right: 8),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: iconBgStart,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: iconBgStart.withValues(alpha: 0.6),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),

                // Gradient Icon Badge
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [iconBgStart, iconBgEnd],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: iconBgStart.withValues(
                          alpha: DevicePerformance.instance.shadowOpacity(0.3),
                        ),
                        blurRadius: DevicePerformance.instance.shadowBlur(8),
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),

                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // Type Badge
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: iconBgStart.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              typeLabel,
                              style: TextStyle(
                                color: iconBgStart,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                          const Spacer(),
                          // Time Label
                          Text(
                            timeStr,
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),

                      // Title
                      Text(
                        n.title,
                        style: TextStyle(
                          fontWeight: n.isRead ? FontWeight.w700 : FontWeight.w900,
                          fontSize: 13.5,
                          color: const Color(0xFF111827),
                        ),
                      ),

                      const SizedBox(height: 3),

                      // Message
                      Text(
                        n.message,
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 12,
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
        ),
      ),
    );
  }

  Future<void> _openNotificationTarget(AppNotification n) async {
    final role = (await _auth.getCurrentUser())?['role']?.toString().toLowerCase() ?? 'student';
    if (!mounted) return;

    if (n.id.startsWith('cert_')) {
      Navigator.pop(context);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const StudentCertificates()),
      );
      return;
    }

    final eventId = n.eventId?.trim() ?? '';
    if (eventId.isEmpty) return;

    Map<String, dynamic>? event;
    try {
      event = await _eventService.getEventById(eventId);
    } catch (_) {
      event = null;
    }

    if (role == 'teacher') {
      if (event != null && mounted) {
        Navigator.pop(context);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        if (!mounted) return;
        final opensProposalRequirements =
            n.id.startsWith('proposal_req_') ||
            n.id.startsWith('proposal_under_review_');
        if (opensProposalRequirements) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TeacherProposalRequirementsPage(event: event!),
            ),
          );
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => TeacherEventManage(event: event!)),
        );
        return;
      }
    }

    if (role == 'student' && event != null) {
      final user = await _auth.getCurrentUser();
      final userId = user?['id']?.toString().trim() ?? '';
      String? yearLevel;
      String? courseCode;
      String? specialization;
      if (userId.isNotEmpty) {
        final scope = await _eventService.getStudentTargetScope(userId);
        yearLevel = scope['yearLevel'];
        courseCode = scope['courseCode'];
        specialization = scope['specialization'];
      } else {
        yearLevel = await _auth.getStudentYearLevel();
        courseCode = await _auth.getStudentCourseCode();
      }
      final allowed = _eventService.isStudentAllowedForEvent(
        event,
        yearLevel: yearLevel,
        courseCode: courseCode,
        specialization: specialization,
      );
      if (!allowed) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This event is not available for your course/year level.'),
          ),
        );
        return;
      }
    }

    if (!mounted) return;
    Navigator.pop(context);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => StudentEventDetails(
          eventId: eventId,
          initialEvent: event,
        ),
      ),
    );
  }
}
