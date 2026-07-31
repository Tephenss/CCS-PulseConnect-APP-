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
import '../widgets/custom_loader.dart';
import '../utils/teacher_theme_utils.dart';
import '../utils/app_page_routes.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final _service = NotificationService();
  final _auth = AuthService();
  final _eventService = EventService();

  List<AppNotification> _notifications = [];
  bool _isLoading = true;
  bool _isTeacherTheme = false;
  String _selectedFilter = 'All'; // 'All', 'Unread', 'Events', 'Alerts'
  StreamSubscription<int>? _unreadSubscription;

  Color get _primaryColor =>
      _isTeacherTheme ? TeacherThemeUtils.primary : const Color(0xFFC2410C);
  Color get _accentColor =>
      _isTeacherTheme ? TeacherThemeUtils.dark : const Color(0xFFEA580C);

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

  List<AppNotification> get _filteredNotifications {
    switch (_selectedFilter) {
      case 'Unread':
        return _notifications.where((n) => !n.isRead).toList();
      case 'Events':
        return _notifications
            .where((n) => n.type == NotificationType.event)
            .toList();
      case 'Alerts':
        return _notifications
            .where((n) =>
                n.type == NotificationType.warning ||
                n.type == NotificationType.error ||
                n.type == NotificationType.success)
            .toList();
      case 'All':
      default:
        return _notifications;
    }
  }

  @override
  void dispose() {
    _unreadSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unreadCount = _notifications.where((n) => !n.isRead).length;
    final filteredList = _filteredNotifications;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // ── HERO GRADIENT HEADER ──
            Container(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + 16,
                16,
                20,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: _isTeacherTheme
                      ? [const Color(0xFF380808), const Color(0xFF7F1D1D)]
                      : [
                          const Color(0xFF1C0A0A),
                          const Color(0xFF7F1D1D),
                          const Color(0xFF9A3412)
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(28),
                  bottomRight: Radius.circular(28),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: DevicePerformance.instance.shadowOpacity(0.2),
                    ),
                    blurRadius: DevicePerformance.instance.shadowBlur(20),
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // App Bar Row
                  Row(
                    children: [
                      // Back Button
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                        tooltip: 'Back',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.18),
                          padding: const EdgeInsets.all(8),
                          minimumSize: const Size(36, 36),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Full Title "Notifications" & Badge (Scaled smoothly with FittedBox - ZERO overflow!)
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Notifications',
                                style: TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              if (unreadCount > 0) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 2),
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
                      ),

                      const SizedBox(width: 6),

                      // Read All Button
                      if (unreadCount > 0)
                        InkWell(
                          onTap: _markAllAsRead,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.3),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.done_all_rounded,
                                    color: Colors.amberAccent, size: 14),
                                SizedBox(width: 4),
                                Text(
                                  'Read All',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  // Category Filter Chips (Custom Glass Pills)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      children: [
                        _buildFilterChip('All', _notifications.length),
                        _buildFilterChip('Unread', unreadCount),
                        _buildFilterChip(
                            'Events',
                            _notifications
                                .where((n) => n.type == NotificationType.event)
                                .length),
                        _buildFilterChip(
                            'Alerts',
                            _notifications
                                .where((n) =>
                                    n.type == NotificationType.warning ||
                                    n.type == NotificationType.error ||
                                    n.type == NotificationType.success)
                                .length),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── NOTIFICATIONS LIST ──
            Expanded(
              child: _isLoading
                  ? const Center(child: PulseConnectLoader())
                  : filteredList.isEmpty
                      ? _buildEmptyState()
                      : RefreshIndicator(
                          color: _primaryColor,
                          onRefresh: () => _loadData(force: true),
                          child: ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                            itemCount: filteredList.length,
                            itemBuilder: (context, index) =>
                                _buildNotificationCard(filteredList[index]),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, int count) {
    final isSelected = _selectedFilter == label;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => setState(() => _selectedFilter = label),
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.3),
                width: isSelected ? 1.5 : 1,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? const Color(0xFF7F1D1D) : Colors.white,
                    fontWeight: isSelected ? FontWeight.w900 : FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF7F1D1D).withValues(alpha: 0.12)
                          : Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFF7F1D1D)
                            : Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    _primaryColor.withValues(alpha: 0.15),
                    _accentColor.withValues(alpha: 0.05),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _primaryColor.withValues(alpha: 0.25),
                  width: 2,
                ),
              ),
              child: Icon(
                Icons.notifications_off_outlined,
                color: _primaryColor,
                size: 38,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _selectedFilter == 'All'
                  ? "You're all caught up!"
                  : "No $_selectedFilter notifications",
              style: const TextStyle(
                color: Color(0xFF0F172A),
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _selectedFilter == 'All'
                  ? "No new notifications right now. Event announcements and updates will appear here."
                  : "There are no notifications under the $_selectedFilter category.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 13,
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
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: n.isRead
              ? const Color(0xFFE2E8F0)
              : _primaryColor.withValues(alpha: 0.3),
          width: n.isRead ? 1 : 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: DevicePerformance.instance.shadowOpacity(n.isRead ? 0.03 : 0.08),
            ),
            blurRadius: DevicePerformance.instance.shadowBlur(10),
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () async {
            if (!n.isRead) {
              await _service.markAsRead(n.id);
            }
            await _openNotificationTarget(n);
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Unread Dot Indicator
                if (!n.isRead)
                  Container(
                    margin: const EdgeInsets.only(top: 16, right: 10),
                    width: 8,
                    height: 8,
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

                // Gradient Icon Avatar
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [iconBgStart, iconBgEnd],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
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
                  child: Icon(icon, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 14),

                // Notification Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // Type Tag
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: iconBgStart.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              typeLabel,
                              style: TextStyle(
                                color: iconBgStart,
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          const Spacer(),

                          // Time Label
                          Text(
                            timeStr,
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // Title
                      Text(
                        n.title,
                        style: TextStyle(
                          fontWeight:
                              n.isRead ? FontWeight.w700 : FontWeight.w900,
                          fontSize: 15,
                          color: const Color(0xFF0F172A),
                        ),
                      ),

                      const SizedBox(height: 4),

                      // Message Body
                      Text(
                        n.message,
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 13,
                          height: 1.4,
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
    final role =
        (await _auth.getCurrentUser())?['role']?.toString().toLowerCase() ??
            'student';
    if (!mounted) return;

    if (n.id.startsWith('cert_')) {
      Navigator.of(context).push(
        AppPageRoute(builder: (_) => const StudentCertificates()),
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
        final opensProposalRequirements = n.id.startsWith('proposal_req_') ||
            n.id.startsWith('proposal_under_review_');
        if (opensProposalRequirements) {
          Navigator.of(context).push(
            AppPageRoute(
              builder: (_) => TeacherProposalRequirementsPage(event: event!),
            ),
          );
          return;
        }
        Navigator.of(context).push(
          AppPageRoute(builder: (_) => TeacherEventManage(event: event!)),
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
            content:
                Text('This event is not available for your course/year level.'),
          ),
        );
        return;
      }
    }

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
