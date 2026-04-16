import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import 'teacher_events_tab.dart';
import 'teacher_profile.dart';
import 'teacher_scan.dart';
import 'teacher_sections.dart';
import '../../services/notification_service.dart';
import '../../widgets/notifications_modal.dart';
import '../../widgets/animated_greeting_text.dart';
import '../../widgets/card_swap_widget.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/shiny_text.dart';
import '../../utils/event_time_utils.dart';
import 'teacher_event_manage.dart';

class TeacherHome extends StatefulWidget {
  const TeacherHome({super.key});

  @override
  State<TeacherHome> createState() => _TeacherHomeState();
}

class _TeacherHomeState extends State<TeacherHome> with WidgetsBindingObserver {
  final _authService = AuthService();
  final _eventService = EventService();
  Map<String, dynamic>? _user;
  List<Map<String, dynamic>> _upcomingEvents = [];
  int _currentIndex = 0;
  bool _isLoading = true;
  int _unreadCount = 0;
  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
  final _notifService = NotificationService();
  final PageController _headerPageController = PageController();
  int _currentHeaderSlide = 0;
  StreamSubscription<int>? _unreadSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
    _subscribeToNotifications();
  }

  void _subscribeToNotifications() {
    _unreadSubscription = _notifService.unreadCountStream.listen((count) {
      if (mounted) {
        setState(() => _unreadCount = count);
      }
    });
  }

  Future<void> _refreshUnreadCount() async {
    try {
      final unread = await _notifService.getUnreadCount(forceRefresh: true);
      if (mounted && unread != _unreadCount) {
        setState(() => _unreadCount = unread);
      }
    } catch (_) {}
  }

  Future<void> _loadData() async {
    final user = await _authService.getCurrentUser();
    
    // Initialize Realtime once user is known
    String teacherId = '';
    if (user != null) {
      final userId = user['id']?.toString() ?? '';
      if (userId.isNotEmpty) {
        _notifService.initRealtime(userId);
        teacherId = userId;
      }
    }

    final events = await _eventService.getTeacherUpcomingEvents(teacherId);
    final unread = await _notifService.getUnreadCount(forceRefresh: true);
    if (mounted) {
      setState(() {
        _user = user;
        _upcomingEvents = events;
        _unreadCount = unread;
        _isLoading = false;
      });
    }
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshUnreadCount();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unreadSubscription?.cancel();
    _headerPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      _buildHomeContent(),
      const TeacherEventsTab(),
      const TeacherScanScreen(),
      const TeacherSections(),
      TeacherProfile(user: _user, onUpdate: _loadData),
    ];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_currentIndex != 0) {
          setState(() => _currentIndex = 0);
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            _isLoading
                ? const Center(child: PulseConnectLoader())
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    switchInCurve: Curves.easeInOut,
                    switchOutCurve: Curves.easeInOut,
                    transitionBuilder: (Widget child, Animation<double> animation) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                    child: Container(
                      key: ValueKey<int>(_currentIndex),
                      child: screens[_currentIndex],
                    ),
                  ),
            
            // New Floating Navigation Bar (Matches user design)
            if (!_isLoading)
              Positioned(
                bottom: 24,
                left: 20,
                right: 20,
                child: Row(
                  children: [
                    // Main Nav Pill
                    Expanded(
                      child: Container(
                        height: 64,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Colors.white, // Solid white for better visibility
                          borderRadius: BorderRadius.circular(32),
                          border: Border.all(color: Colors.grey.shade200, width: 1),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 30,
                              spreadRadius: 2,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildNavItem(Icons.home_rounded, 'Home', 0),
                            _buildNavItem(Icons.event_note_rounded, 'Events', 1),
                            _buildNavItem(Icons.groups_rounded, 'Sections', 3),
                            _buildNavItem(Icons.person_rounded, 'Profile', 4),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Separate QR Button
                    GestureDetector(
                      onTap: () => setState(() => _currentIndex = 2),
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          color: const Color(0xFF064E3B), // Theme Color
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF064E3B).withValues(alpha: 0.4),
                              blurRadius: 20,
                              spreadRadius: 1,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 28),
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

  Widget _buildNavItem(IconData icon, String label, int index) {
    final isActive = _currentIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        padding: EdgeInsets.symmetric(
          horizontal: isActive ? 12 : 8, // Further reduced padding
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF064E3B).withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isActive ? const Color(0xFF064E3B) : Colors.grey.shade400,
              size: 20, // Reduced icon size
            ),
            if (isActive) ...[
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF064E3B),
                  fontWeight: FontWeight.w800,
                  fontSize: 11, // Reduced font size
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHomeContent() {
    final firstName = _user?['first_name'] as String? ?? 'Teacher';

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF064E3B), Color(0xFF047857)],
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFFD4A843), width: 2),
                            image: _user?['photo_url'] != null && (_user?['photo_url'] as String).isNotEmpty
                                ? DecorationImage(
                                    image: (_user?['photo_url'] as String).startsWith('http')
                                        ? NetworkImage(_user?['photo_url'])
                                        : FileImage(File(_user?['photo_url'])),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: _user?['photo_url'] == null || (_user?['photo_url'] as String).isEmpty
                            ? Center(
                                child: Text(
                                  firstName.isNotEmpty ? firstName[0].toUpperCase() : 'T',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20),
                                ),
                              )
                            : null,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _getGreeting(),
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              AnimatedGreetingText(
                                text: firstName,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                ),
                                baseColor: Colors.white,
                                scanColor: const Color(0xFF6EE7B7), // Soft emerald glow for Teacher
                              ),
                            ],
                          ),
                        ),
                        // Notification Bell at the top!
                        Container(
                          margin: const EdgeInsets.only(left: 12),
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned.fill(
                                child: IconButton(
                                  padding: const EdgeInsets.all(10),
                                  splashRadius: 22,
                                  icon: const Icon(Icons.notifications_none_rounded, color: Colors.white),
                                  onPressed: () async {
                                    await _refreshUnreadCount();
                                    final result = await showNotificationsModal(context);

                                    if (result != null && result is int) {
                                      setState(() {
                                        _currentIndex = result;
                                      });
                                    }

                                    await _refreshUnreadCount();
                                  },
                                ),
                              ),
                              if (_unreadCount > 0)
                                Positioned(
                                  top: -4,
                                  right: -4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEF4444),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(color: const Color(0xFF047857), width: 1.5),
                                    ),
                                    constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                                    child: Text(
                                      _unreadCount > 99 ? '99+' : _unreadCount.toString(),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _buildHeaderSlider(),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Upcoming Events Title
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 12), // Reduced top padding
            child: Row(
              children: [
                const Text('Upcoming Events', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1F2937))),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _currentIndex = 1),
                  child: const Text('View All', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF064E3B))),
                ),
              ],
            ),
          ),
        ),

        _upcomingEvents.isEmpty
            ? SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    padding: const EdgeInsets.all(40),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.event_busy_rounded, size: 48, color: Colors.grey.shade300),
                        const SizedBox(height: 12),
                        Text('No upcoming events', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade600)),
                      ],
                    ),
                  ),
                ),
              )
            : SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final event = _upcomingEvents[index];
                    return _buildEventCard(event);
                  },
                  childCount: _upcomingEvents.length,
                ),
              ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)), // Space for floating nav
      ],
    );
  }

  Widget _buildHeaderSlider() {
    return Column(
      children: [
        SizedBox(
          height: 380, // Fixed height for slider (increased to fit calendar)
          child: PageView(
            controller: _headerPageController,
            onPageChanged: (idx) => setState(() => _currentHeaderSlide = idx),
            children: [
              _buildMacbookSlide(),
              _buildMiniCalendar(),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Dots Indicator
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(2, (index) {
            final isActive = _currentHeaderSlide == index;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: isActive ? 20 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: isActive ? const Color(0xFFD4A843) : Colors.white.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(4),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildMacbookSlide() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(20),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const ShinyText(
            text: 'Ready to explore?',
            fontSize: 20,
            speed: 2.5,
            fontWeight: FontWeight.w900,
          ),
          const SizedBox(height: 8),
          Text(
            'Monitor upcoming events, view attendance logs instantly, and manage your assigned sections efficiently.',
            textAlign: TextAlign.left,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 32),
          // Card swap widget - Max ZOOM version
          CardSwapWidget(
            items: const [
              CardSwapItem(imagePath: 'assets/sample summit/image1.jpg', label: 'CCS SUMMIT'),
              CardSwapItem(imagePath: 'assets/sample GA/image1.jpg', label: 'GENERAL ASSEMBLY'),
              CardSwapItem(imagePath: 'assets/sample exhibit/image1.jpg', label: 'CCS EXHIBIT'),
              CardSwapItem(imagePath: 'assets/sample CV/image1.jpg', label: 'COMPANY VISIT'),
            ],
            cardWidth: 250,
            cardHeight: 140,
            cardDistance: 20,
            verticalDistance: 10,
            delay: const Duration(seconds: 4),
            skewAmount: 5,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildMiniCalendar() {
    final now = DateTime.now();
    final monthName = DateFormat('MMMM yyyy').format(_calendarMonth);
    final daysInMonth = DateTime(_calendarMonth.year, _calendarMonth.month + 1, 0).day;
    final firstWeekday = DateTime(_calendarMonth.year, _calendarMonth.month, 1).weekday % 7;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Column(
        children: [
          // Month Header with arrows
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left_rounded, color: Colors.white),
                onPressed: () {
                  setState(() {
                    _calendarMonth = DateTime(_calendarMonth.year, _calendarMonth.month - 1, 1);
                  });
                },
              ),
              Text(
                monthName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right_rounded, color: Colors.white),
                onPressed: () {
                  setState(() {
                    _calendarMonth = DateTime(_calendarMonth.year, _calendarMonth.month + 1, 1);
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 4),

          // Day headers
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: ['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((d) {
              return SizedBox(
                width: 32,
                child: Text(d, textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontWeight: FontWeight.w600, fontSize: 11)),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),

          // Calendar Grid
          ...List.generate(
            ((daysInMonth + firstWeekday + 6) / 7).ceil(),
            (week) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: List.generate(7, (weekday) {
                    final day = week * 7 + weekday - firstWeekday + 1;
                    if (day < 1 || day > daysInMonth) return const SizedBox(width: 32, height: 32);

                    final isToday = day == now.day && _calendarMonth.month == now.month && _calendarMonth.year == now.year;
                    
                    // Check if any event falls on this day
                    final eventsOnThisDay = _upcomingEvents.where((e) {
                      final startAt = e['start_at'] as String?;
                      if (startAt == null) return false;
                      try {
                        final d = parseStoredEventDateTime(startAt);
                        if (d == null) return false;
                        return d.day == day && d.month == _calendarMonth.month && d.year == _calendarMonth.year;
                      } catch (_) { return false; }
                    }).toList();
                    
                    final hasEvent = eventsOnThisDay.isNotEmpty;

                    Widget dayWidget = Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: isToday ? const Color(0xFFD4A843) : Colors.transparent),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('$day', style: TextStyle(color: isToday ? const Color(0xFF064E3B) : Colors.white.withValues(alpha: 0.8), fontWeight: isToday ? FontWeight.w800 : FontWeight.w500, fontSize: 12)),
                          if (hasEvent)
                            Container(width: 4, height: 4, decoration: BoxDecoration(shape: BoxShape.circle, color: isToday ? const Color(0xFF064E3B) : const Color(0xFFD4A843))),
                        ],
                      ),
                    );

                    if (hasEvent) {
                      dayWidget = GestureDetector(
                        onTap: () {
                          showDialog(
                            context: context,
                            builder: (context) {
                              return AlertDialog(
                                title: const Text('Events on this Date', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: eventsOnThisDay.map((e) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.event_rounded, color: Color(0xFF064E3B)),
                                    title: Text(e['title'] ?? 'Event', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                                    subtitle: Text(
                                      e['start_at'] != null
                                          ? (() {
                                              final parsed = parseStoredEventDateTime(e['start_at']);
                                              return parsed != null ? DateFormat('hh:mm a').format(parsed) : '';
                                            })()
                                          : '',
                                    ),
                                    onTap: () {
                                      Navigator.pop(context);
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => TeacherEventManage(event: e),
                                        ),
                                      );
                                    },
                                  )).toList(),
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close', style: TextStyle(color: Color(0xFF064E3B)))),
                                ],
                              );
                            }
                          );
                        },
                        child: dayWidget,
                      );
                    }

                    return dayWidget;
                  }),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // Used only for the AlertDialog above

  Widget _buildEventCard(Map<String, dynamic> event) {
    final title = event['title'] as String? ?? 'Untitled Event';
    final startAt = event['start_at'] as String?;
    final location = event['location'] as String? ?? '';
    final startDate = parseStoredEventDateTime(startAt);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: GestureDetector(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TeacherEventManage(event: event),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.grey.shade200),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 4))],
          ),
          child: Row(
            children: [
              Container(
                width: 56, padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(color: const Color(0xFF064E3B), borderRadius: BorderRadius.circular(14)),
                child: Column(
                  children: [
                    Text(startDate != null ? DateFormat('dd').format(startDate) : '--', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20)),
                    Text(startDate != null ? DateFormat('MMM').format(startDate).toUpperCase() : '---', style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontWeight: FontWeight.w600, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Color(0xFF1F2937)), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    if (startDate != null)
                      Text(DateFormat('hh:mm a').format(startDate), style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontWeight: FontWeight.w500)),
                    if (location.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(Icons.location_on_outlined, size: 13, color: Colors.grey.shade500),
                          const SizedBox(width: 4),
                          Expanded(child: Text(location, style: TextStyle(color: Colors.grey.shade500, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}


