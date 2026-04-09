import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import 'student_events.dart';
import 'student_tickets.dart';
import 'student_event_details.dart';
import 'student_profile.dart';
import 'student_scan.dart';
import '../notifications_screen.dart';
import '../../services/notification_service.dart';
import '../../widgets/animated_greeting_text.dart';
import '../../widgets/card_swap_widget.dart';
import '../../widgets/shiny_text.dart';
import '../../widgets/custom_loader.dart';

class StudentHome extends StatefulWidget {
  const StudentHome({super.key});

  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends State<StudentHome> {
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
  Timer? _notifTimer;

  // Section Selection Gate
  List<Map<String, dynamic>> _sections = [];
  String? _selectedSectionId;
  bool _isUpdatingSection = false;
  String? _sectionError;

  @override
  void initState() {
    super.initState();
    _loadData();
    _startNotifTimer();
  }

  void _startNotifTimer() {
    _notifTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (mounted && _currentIndex == 0) {
        _refreshUnreadCount();
      }
    });
  }

  Future<void> _refreshUnreadCount() async {
    try {
      final unread = await _notifService.getUnreadCount();
      if (mounted && unread != _unreadCount) {
        setState(() => _unreadCount = unread);
      }
    } catch (_) {}
  }

  Future<void> _loadData() async {
    final user = await _authService.getCurrentUser();
    final events = await _eventService.getUpcomingEvents();
    final unread = await _notifService.getUnreadCount();
    final sections = await _authService.getSections();
    if (mounted) {
      setState(() {
        _user = user;
        _upcomingEvents = events;
        _unreadCount = unread;
        _sections = sections;
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
  void dispose() {
    _notifTimer?.cancel();
    _headerPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Note: Tab 2 (Index 2) is now the StudentScanScreen
    final screens = [
      _buildHomeContent(),
      const StudentEvents(),
      const StudentScanScreen(), 
      const StudentTickets(),
      StudentProfile(user: _user, onUpdate: _loadData),
    ];

    final bool needsSection = _user != null && _user!['section_id'] == null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_currentIndex != 0) {
          setState(() => _currentIndex = 0);
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF9FAFB),
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
                      child: (needsSection ? _buildSectionSelection() : screens[_currentIndex]),
                    ),
                  ),
            
            // New Floating Navigation Bar (Matches user design)
            if (!_isLoading && !needsSection)
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
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly, // More balanced spacing
                          children: [
                            _buildNavItem(Icons.home_rounded, 'Home', 0),
                            _buildNavItem(Icons.event_note_rounded, 'Events', 1),
                            _buildNavItem(Icons.confirmation_num_rounded, 'Tickets', 3),
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
                          color: const Color(0xFF7F1D1D), // Theme Color
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF7F1D1D).withValues(alpha: 0.4),
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

  Widget _buildSectionSelection() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xFF09090B),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Image.asset('assets/CCS.png', height: 48, width: 48, fit: BoxFit.contain),
              const SizedBox(height: 24),
              const Text(
                'Welcome Back!',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              RichText(
                text: TextSpan(
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 14,
                    height: 1.5,
                    fontFamily: 'Inter', // Ensuring font consistency
                  ),
                  children: const [
                    TextSpan(text: 'Please select your current Year Level and Section to continue using the app. Make sure this is correct, as '),
                    TextSpan(
                      text: 'some events are restricted to specific year levels.',
                      style: TextStyle(color: Color(0xFFEAB308), fontWeight: FontWeight.w700), // Amber warning color
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              if (_sectionError != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF450A0A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF7F1D1D)),
                  ),
                  child: Text(
                    _sectionError!,
                    style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
                  ),
                ),
              DropdownButtonFormField<String>(
                value: _selectedSectionId,
                dropdownColor: const Color(0xFF1C1C22),
                iconEnabledColor: const Color(0xFFA1A1AA),
                style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                hint: const Text(
                  'Select Year Level & Section',
                  style: TextStyle(color: Color(0xFF71717A), fontSize: 14),
                ),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF1C1C22),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
                items: _sections.map((s) {
                  return DropdownMenuItem<String>(
                    value: s['id'].toString(),
                    child: Text(s['name'] as String? ?? ''),
                  );
                }).toList(),
                onChanged: (val) => setState(() => _selectedSectionId = val),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isUpdatingSection || _selectedSectionId == null
                      ? null
                      : () {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              title: const Text('Are you sure?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Color(0xFF1F2937))),
                              content: const Text(
                                'Once you select your section, this cannot be changed manually until the next school year reset. Please ensure you have selected your correct current year and section. If you select the wrong section, you might not be able to join some events and your attendance logs will be misplaced.\n\nDo you want to proceed?',
                                style: TextStyle(color: Color(0xFF4B5563), fontSize: 14, height: 1.5),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context), 
                                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF71717A)))
                                ),
                                ElevatedButton(
                                  onPressed: () async {
                                    Navigator.pop(context);
                                    setState(() {
                                      _isUpdatingSection = true;
                                      _sectionError = null;
                                    });
                                    final res = await _authService.updateSection(_selectedSectionId!);
                                    if (res['ok']) {
                                      _loadData(); // Will hide this screen
                                    } else {
                                      setState(() {
                                        _sectionError = res['error'];
                                        _isUpdatingSection = false;
                                      });
                                    }
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF9F1239),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  child: const Text('Yes, Confirm'),
                                ),
                              ],
                            ),
                          );
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF9F1239),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _isUpdatingSection
                      ? const PulseConnectLoader(size: 14)
                      : const Text('Save & Continue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
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
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        padding: EdgeInsets.symmetric(
          horizontal: isActive ? 12 : 8, // Reduced padding to prevent overflow
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF7F1D1D).withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isActive ? const Color(0xFF7F1D1D) : const Color(0xFFA1A1AA),
              size: 20, // Reduced icon size
            ),
            if (isActive) ...[
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF7F1D1D),
                  fontSize: 11, // Reduced font size
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Removed _buildScanItem as it's replaced by the detached FAB in the Stack

  Widget _buildHomeContent() {
    final firstName = _user?['first_name'] as String? ?? 'Student';
    
    return CustomScrollView(
      slivers: [
        // App Bar Header — Solid Dark Maroon Design
        SliverToBoxAdapter(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF450A0A), Color(0xFF7F1D1D)],
              ),
              borderRadius: BorderRadius.vertical(
                bottom: Radius.circular(32),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top row
                    Row(
                      children: [
                        // Profile Avatar
                        GestureDetector(
                          onTap: () {
                            setState(() => _currentIndex = 4);
                          },
                          child: Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(0xFFD4A843), // Gold Border
                                  width: 2,
                                ),
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
                                      firstName.isNotEmpty ? firstName[0].toUpperCase() : 'S',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 20,
                                      ),
                                    ),
                                  )
                                : null,
                            ),
                        ),
                        const SizedBox(width: 14),
                        // Expanded Column for full-width name support
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
                                scanColor: const Color(0xFFFCA5A5), // Soft red/orange glow for Student
                              ),
                            ],
                          ),
                        ),
                        // Notification Bell Only - Logout is in Profile
                        Container(
                          margin: const EdgeInsets.only(left: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.1),
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
                                    setState(() => _currentIndex = result);
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
                                      color: const Color(0xFFEF4444),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: const Color(0xFF7F1D1D), width: 1.5),
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

                    const SizedBox(height: 28),

                    // Header Slider (Laptop Animation / Mini Calendar)
                    _buildHeaderSlider(),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Upcoming Events Section
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16), // Reduced top padding 
            child: Row(
              children: [
                const Text(
                  'Upcoming Events',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1F2937),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _currentIndex = 1),
                  child: const Text(
                    'See All',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF7F1D1D),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Events List
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
                        Icon(Icons.event_busy_rounded,
                            size: 48, color: Colors.grey.shade300),
                        const SizedBox(height: 12),
                        Text(
                          'No upcoming events',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade500,
                          ),
                        ),
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
            'Register for upcoming events, view your e-tickets securely, and track your attendance across the semester.',
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
      padding: const EdgeInsets.all(20),
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
        children: [
          // Month Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.chevron_left_rounded, color: Colors.white, size: 20),
                  onPressed: () {
                    setState(() {
                      _calendarMonth = DateTime(_calendarMonth.year, _calendarMonth.month - 1, 1);
                    });
                  },
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(8),
                ),
              ),
              Text(
                monthName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  letterSpacing: 0.5,
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 20),
                  onPressed: () {
                    setState(() {
                      _calendarMonth = DateTime(_calendarMonth.year, _calendarMonth.month + 1, 1);
                    });
                  },
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Day headers
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: ['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((d) {
              return SizedBox(
                width: 32,
                child: Text(
                  d,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // Calendar Grid
          ...List.generate(
            ((daysInMonth + firstWeekday + 6) / 7).ceil(),
            (week) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: List.generate(7, (weekday) {
                    final day = week * 7 + weekday - firstWeekday + 1;
                    if (day < 1 || day > daysInMonth) {
                      return const SizedBox(width: 32, height: 32);
                    }

                    final isToday = day == now.day && _calendarMonth.month == now.month && _calendarMonth.year == now.year;

                    final eventsOnThisDay = _upcomingEvents.where((e) {
                      final startAt = e['start_at'] as String?;
                      if (startAt == null) return false;
                      try {
                        final d = DateTime.parse(startAt).toLocal();
                        return d.day == day &&
                            d.month == _calendarMonth.month &&
                            d.year == _calendarMonth.year;
                      } catch (_) {
                        return false;
                      }
                    }).toList();

                    final hasEvent = eventsOnThisDay.isNotEmpty;

                    Widget dayWidget = Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isToday
                            ? const Color(0xFFD4A843)
                            : Colors.transparent,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '$day',
                            style: TextStyle(
                              color: isToday
                                  ? const Color(0xFF450A0A)
                                  : Colors.white.withValues(alpha: 0.9),
                              fontWeight: isToday ? FontWeight.w900 : FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          if (hasEvent)
                            Container(
                              margin: const EdgeInsets.only(top: 2),
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isToday
                                    ? const Color(0xFF450A0A)
                                    : Colors.white,
                              ),
                            ),
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
                                backgroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                title: const Text('Events on this Date', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Color(0xFF1F2937))),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: eventsOnThisDay.map((e) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.event_rounded, color: Color(0xFF7F1D1D)),
                                    title: Text(e['title'] ?? 'Event', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF1F2937))),
                                    subtitle: Text(
                                      e['start_at'] != null ? DateFormat('hh:mm a').format(DateTime.parse(e['start_at']).toLocal()) : '',
                                      style: const TextStyle(color: Color(0xFF71717A)),
                                    ),
                                    onTap: () {
                                      Navigator.pop(context);
                                      setState(() => _currentIndex = 1);
                                    },
                                  )).toList(),
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close', style: TextStyle(color: Color(0xFF7F1D1D)))),
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

  Widget _buildEventCard(Map<String, dynamic> event) {
    final title = event['title'] as String? ?? 'Untitled Event';
    final startAt = event['start_at'] as String?;
    final location = event['location'] as String? ?? '';

    DateTime? startDate;
    if (startAt != null) {
      try {
        startDate = DateTime.parse(startAt).toLocal();
      } catch (_) {}
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: GestureDetector(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => StudentEventDetails(eventId: event['id'].toString()),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.grey.shade200),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              // Date Badge
              Container(
                width: 60,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFBE123C), Color(0xFF7F1D1D)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF7F1D1D).withValues(alpha: 0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Text(
                      startDate != null ? DateFormat('dd').format(startDate) : '--',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 22,
                        letterSpacing: -0.5,
                      ),
                    ),
                    Text(
                      startDate != null ? DateFormat('MMM').format(startDate).toUpperCase() : '---',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),

              // Event Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: Color(0xFF1F2937),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    if (startDate != null)
                      Row(
                        children: [
                          const Icon(Icons.schedule_rounded,
                              size: 14, color: Color(0xFF71717A)),
                          const SizedBox(width: 4),
                          Text(
                            DateFormat('hh:mm a').format(startDate),
                            style: const TextStyle(
                              color: Color(0xFF71717A),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    if (location.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.location_on_rounded,
                              size: 14, color: Color(0xFF9CA3AF)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              location,
                              style: const TextStyle(
                                color: Color(0xFF9CA3AF),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // Arrow
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.chevron_right_rounded,
                    color: Color(0xFF9CA3AF), size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
