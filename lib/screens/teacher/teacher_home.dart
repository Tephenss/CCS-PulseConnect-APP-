import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import '../welcome_screen.dart';
import 'teacher_events_tab.dart';
import 'teacher_profile.dart';
import 'teacher_scan.dart';
import 'teacher_sections.dart';
import '../notifications_screen.dart';
import '../../services/notification_service.dart';

class TeacherHome extends StatefulWidget {
  const TeacherHome({super.key});

  @override
  State<TeacherHome> createState() => _TeacherHomeState();
}

class _TeacherHomeState extends State<TeacherHome> {
  final _authService = AuthService();
  final _eventService = EventService();
  Map<String, dynamic>? _user;
  List<Map<String, dynamic>> _upcomingEvents = [];
  int _currentIndex = 0;
  bool _isLoading = true;
  int _unreadCount = 0;
  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
  final _notifService = NotificationService();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final user = await _authService.getCurrentUser();
    final events = await _eventService.getUpcomingEvents();
    final unread = await _notifService.getUnreadCount();
    if (mounted) {
      setState(() {
        _user = user;
        _upcomingEvents = events;
        _unreadCount = unread;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      _buildHomeContent(),
      const TeacherEventsTab(),
      const TeacherScanScreen(),
      const TeacherSections(),
      const TeacherProfile(),
    ];

    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF064E3B)))
          : screens[_currentIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(Icons.home_rounded, 'Home', 0),
                _buildNavItem(Icons.event_note_rounded, 'Events', 1),
                // Custom Scan Button in the middle
                GestureDetector(
                  onTap: () => setState(() => _currentIndex = 2),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4A843),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFD4A843).withValues(alpha: 0.4),
                          blurRadius: 10, offset: const Offset(0, 4)
                        ),
                      ],
                    ),
                    child: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF064E3B), size: 28),
                  ),
                ),
                _buildNavItem(Icons.groups_rounded, 'Sections', 3),
                _buildNavItem(Icons.person_rounded, 'Profile', 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    final isActive = _currentIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0xFF064E3B).withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isActive ? const Color(0xFF064E3B) : Colors.grey.shade400,
              size: 24,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeContent() {
    final firstName = _user?['first_name'] as String? ?? 'Teacher';
    final gradeAdvisor = _user?['grade_advisor'] as String? ?? 'General Faculty';

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
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.2),
                            border: Border.all(color: const Color(0xFFD4A843).withValues(alpha: 0.6), width: 2),
                          ),
                          child: Center(
                            child: Text(
                              firstName[0].toUpperCase(),
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFD4A843).withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  gradeAdvisor,
                                  style: const TextStyle(color: Color(0xFFD4A843), fontSize: 11, fontWeight: FontWeight.w700),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$firstName',
                                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
                              ),
                            ],
                          ),
                        ),
                        // Notification Bell at the top!
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Stack(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.notifications_none_rounded, color: Colors.white),
                                onPressed: () async {
                                  final result = await Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (context) => const NotificationsScreen()),
                                  );
                                  
                                  if (result != null && result is int) {
                                    setState(() {
                                      _currentIndex = result;
                                    });
                                  }
                                  
                                  _loadData();
                                },
                              ),
                              if (_unreadCount > 0)
                                Positioned(
                                  top: 8,
                                  right: 10,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: Colors.red.shade600,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: const Color(0xFF047857), width: 1.5),
                                    ),
                                    constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                                    child: Center(
                                      child: Text(
                                        _unreadCount > 9 ? '9+' : _unreadCount.toString(),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                        ),
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
                    _buildMiniCalendar(),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Upcoming Events Title
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
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
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _buildMiniCalendar() {
    final now = DateTime.now();
    final monthName = DateFormat('MMMM yyyy').format(_calendarMonth);
    final daysInMonth = DateTime(_calendarMonth.year, _calendarMonth.month + 1, 0).day;
    final firstWeekday = DateTime(_calendarMonth.year, _calendarMonth.month, 1).weekday % 7;

    return Container(
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
                        final d = DateTime.parse(startAt);
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
                                      e['start_at'] != null ? DateFormat('hh:mm a').format(DateTime.parse(e['start_at'])) : '',
                                    ),
                                    onTap: () {
                                      Navigator.pop(context);
                                      // Focus the event optionally
                                      setState(() => _currentIndex = 1);
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
  Widget _buildAlertDialog(BuildContext context, List<Map<String, dynamic>> events) {
    return AlertDialog(
      title: const Text('Events on this date', style: TextStyle(fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: events.length,
          itemBuilder: (context, index) {
            final e = events[index];
            return ListTile(
              leading: const Icon(Icons.event_rounded, color: Color(0xFF064E3B)),
              title: Text(e['title'] ?? 'Event', style: const TextStyle(fontWeight: FontWeight.w700)),
              onTap: () {
                 Navigator.pop(context);
                 setState(() => _currentIndex = 1);
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close', style: TextStyle(color: Color(0xFF064E3B))))
      ],
    );
  }

  Widget _buildEventCard(Map<String, dynamic> event) {
    final title = event['title'] as String? ?? 'Untitled Event';
    final startAt = event['start_at'] as String?;
    final location = event['location'] as String? ?? '';
    DateTime? startDate;
    if (startAt != null) { try { startDate = DateTime.parse(startAt); } catch (_) {} }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: GestureDetector(
        onTap: () {
          // Nav to Teacher Event Detail
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
