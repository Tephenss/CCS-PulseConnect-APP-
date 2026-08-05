import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/app_cache_service.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import 'teacher_events_tab.dart';
import 'teacher_profile.dart';
import 'teacher_scan.dart';
import 'teacher_sections.dart';
import '../../services/notification_service.dart';
import '../../services/event_live_service.dart';
import '../../services/offline_backup_service.dart';
import '../../services/offline_sync_service.dart';
import '../../widgets/notifications_modal.dart';
import '../../widgets/animated_greeting_text.dart';
import '../../widgets/card_swap_widget.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/pulseconnect_splash_screen.dart';
import '../../widgets/safe_circle_avatar.dart';
import '../../widgets/shiny_text.dart';
import '../../utils/event_time_utils.dart';
import 'teacher_event_manage.dart';

class TeacherHome extends StatefulWidget {
  const TeacherHome({super.key});

  @override
  State<TeacherHome> createState() => _TeacherHomeState();
}

class _TeacherHomeState extends State<TeacherHome> with WidgetsBindingObserver {
  final _appCacheService = AppCacheService();
  final _authService = AuthService();
  final Connectivity _connectivity = Connectivity();
  final _eventService = EventService();
  final _offlineSyncService = OfflineSyncService();
  final _offlineBackupService = OfflineBackupService();
  final _supabase = Supabase.instance.client;
  Map<String, dynamic>? _user;
  List<Map<String, dynamic>> _upcomingEvents = [];
  List<Map<String, dynamic>> _calendarEvents = [];
  int _currentIndex = 0;
  /// Once opened, keep TeacherScanScreen mounted so reopening the FAB
  /// does not remount and flash the full-screen loader every time.
  bool _scanVisited = false;
  bool _isLoading = true;
  bool _usingCachedUpcomingEvents = false;
  int _unreadCount = 0;
  bool _isOpeningNotifications = false;
  DateTime _calendarMonth = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    1,
  );
  final _notifService = NotificationService();
  final PageController _headerPageController = PageController();
  int _currentHeaderSlide = 0;
  StreamSubscription<int>? _unreadSubscription;
  StreamSubscription<String>? _eventLiveSubscription;
  RealtimeChannel? _scannerAccessChannel;
  Timer? _scannerAccessGuardTimer;

  // Softer teacher palette (sky â†’ deep) to reduce eye strain vs navy.
  static const Color _teacherPrimary = Color(0xFF0EA5E9); // sky-500
  static const Color _teacherDark = Color(0xFF0C4A6E); // sky-900
  static const Color _teacherMid = Color(0xFF0369A1); // sky-700

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _eventLiveSubscription = EventLiveService.instance.changes.listen((reason) {
      if (!mounted) return;
      unawaited(_refreshTeacherHomeLive(reason));
    });
    _loadData();
    _subscribeToNotifications();
  }

  bool _isTeacherHomeCatalogLiveReason(String reason) {
    final offlinePulse = reason.startsWith('offline:');
    final core = offlinePulse ? reason.substring('offline:'.length) : reason;
    return core == 'events' ||
        core.startsWith('events') ||
        core == 'teacher_assignments' ||
        core.startsWith('teacher_assignments') ||
        core.startsWith('push') ||
        core == 'resume';
  }

  Future<void> _refreshTeacherHomeLive(String reason) async {
    if (!mounted || _user == null) return;
    final teacherId = _user?['id']?.toString() ?? '';
    if (teacherId.isEmpty) return;

    if (reason == 'inbox' || reason.startsWith('push')) {
      unawaited(_refreshUnreadCount());
    }

    if (!_isTeacherHomeCatalogLiveReason(reason)) return;

    final offlinePulse = reason.startsWith('offline:');
    final accessible = await _eventService.getTeacherAccessibleEvents(
      teacherId,
      // Realtime/push/resume hit network; offline soft-signal stays cache-only.
      forceFresh: !offlinePulse,
    );
    final events = _teacherActiveUpcomingEvents(accessible);
    final calendarEvents = _teacherCalendarEvents(accessible);
    if (!mounted) return;
    setState(() {
      _upcomingEvents = events;
      _calendarEvents = calendarEvents;
      _usingCachedUpcomingEvents = offlinePulse;
    });
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

  Future<void> _openNotificationsModal() async {
    if (_isOpeningNotifications) return;
    setState(() => _isOpeningNotifications = true);

    try {
      unawaited(_refreshUnreadCount());
      final result = await showNotificationsModal(context);
      if (!mounted) return;

      if (result is int) {
        setState(() {
          _currentIndex = result;
        });
      }

      unawaited(_refreshUnreadCount());
    } finally {
      if (mounted) {
        setState(() => _isOpeningNotifications = false);
      } else {
        _isOpeningNotifications = false;
      }
    }
  }

  Future<bool> _hasNoConnectivity() async {
    final connectivity = await _connectivity.checkConnectivity();
    return connectivity.isEmpty ||
        connectivity.every((result) => result == ConnectivityResult.none);
  }

  Future<void> _refreshScannerAccessGuard(String teacherId) async {
    final actorId = teacherId.trim();
    if (actorId.isEmpty) return;
    if (await _hasNoConnectivity()) return;

    try {
      await _offlineSyncService.refreshSnapshotForCurrentScanner(
        actorId: actorId,
        isTeacher: true,
      );
    } catch (_) {
      // Keep the shell stable even if access refresh fails.
    }
  }

  void _restartScannerAccessGuard(String teacherId) {
    _scannerAccessGuardTimer?.cancel();
    _scannerAccessChannel?.unsubscribe();
    _scannerAccessChannel = null;

    final actorId = teacherId.trim();
    if (actorId.isEmpty) return;

    _scannerAccessChannel = _supabase.channel(
      'public:teacher_home_scan_access:$actorId',
    );
    _scannerAccessChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_teacher_assignments',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'teacher_id',
        value: actorId,
      ),
      callback: (_) {
        unawaited(_refreshScannerAccessGuard(actorId));
      },
    );
    _scannerAccessChannel!.subscribe();

    _scannerAccessGuardTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) {
        if (!mounted || _currentIndex != 2) return;
        unawaited(_refreshScannerAccessGuard(actorId));
      },
    );
  }

  List<Map<String, dynamic>> _teacherActiveUpcomingEvents(
    List<Map<String, dynamic>> source, {
    int limit = 5,
  }) {
    final now = DateTime.now().toUtc().add(kManilaOffset);
    final filtered = source
        .where((event) => isTeacherActiveEvent(event, now: now))
        .toList();

    filtered.sort((a, b) {
      final dateA = parseStoredEventDateTime(a['start_at']) ?? DateTime(2100);
      final dateB = parseStoredEventDateTime(b['start_at']) ?? DateTime(2100);
      return dateA.compareTo(dateB);
    });

    if (filtered.length <= limit) return filtered;
    return filtered.sublist(0, limit);
  }

  List<Map<String, dynamic>> _teacherCalendarEvents(
    List<Map<String, dynamic>> source,
  ) {
    final now = DateTime.now().toUtc().add(kManilaOffset);
    final filtered = source
        .where((event) => isCalendarVisibleEvent(event, now: now))
        .toList();
    filtered.sort((a, b) {
      final dateA = parseStoredEventDateTime(a['start_at']) ?? DateTime(2100);
      final dateB = parseStoredEventDateTime(b['start_at']) ?? DateTime(2100);
      return dateA.compareTo(dateB);
    });
    return filtered;
  }

  Future<void> _loadData({bool forceFresh = false}) async {
    final user = await _authService.getCurrentUser();
    unawaited(_primeOfflineReadiness(user));

    // Initialize Realtime once user is known
    String teacherId = '';
    if (user != null) {
      final userId = user['id']?.toString() ?? '';
      if (userId.isNotEmpty) {
        EventLiveService.instance.start(userId: userId);
        _notifService.initRealtime(userId);
        teacherId = userId;
      }
    }
    _restartScannerAccessGuard(teacherId);

    final connectivity = await _connectivity.checkConnectivity();
    final isOffline =
        connectivity.isEmpty ||
        connectivity.every((result) => result == ConnectivityResult.none);
    final cacheKey = 'teacher_home_upcoming_events_$teacherId';

    List<Map<String, dynamic>> events = <Map<String, dynamic>>[];
    List<Map<String, dynamic>> calendarEvents = <Map<String, dynamic>>[];
    var usingCachedData = false;

    // Critical-first: paint warm disk cache before network when available.
    if (teacherId.isNotEmpty && !forceFresh) {
      final warm = await _appCacheService.loadJsonList(cacheKey);
      if (warm.isNotEmpty && mounted) {
        events = _teacherActiveUpcomingEvents(warm);
        calendarEvents = _teacherCalendarEvents(warm);
        usingCachedData = true;
        setState(() {
          _user = user;
          _upcomingEvents = events;
          _calendarEvents = calendarEvents;
          _usingCachedUpcomingEvents = true;
          _isLoading = false;
        });
      }
    }

    List<Map<String, dynamic>> accessible = <Map<String, dynamic>>[];
    if (teacherId.isNotEmpty) {
      if (isOffline) {
        final cached = await _appCacheService.loadJsonList(cacheKey);
        events = _teacherActiveUpcomingEvents(cached);
        calendarEvents = _teacherCalendarEvents(cached);
        usingCachedData = true;
      } else {
        accessible = await _eventService.getTeacherAccessibleEvents(
          teacherId,
          forceFresh: forceFresh,
        );
        events = _teacherActiveUpcomingEvents(accessible);
        calendarEvents = _teacherCalendarEvents(accessible);

        // Soft load only: empty active filter may restore warm disk ≤24h.
        // Pull-to-refresh (forceFresh) must show empty when nothing remains.
        if (events.isEmpty && !forceFresh) {
          final cached = await _appCacheService.loadJsonList(cacheKey);
          final lastUpdated = await _appCacheService.lastUpdatedAt(cacheKey);
          final cacheStillFresh =
              cached.isNotEmpty &&
              lastUpdated != null &&
              DateTime.now().difference(lastUpdated) <=
                  const Duration(hours: 24);
          if (cacheStillFresh) {
            events = _teacherActiveUpcomingEvents(cached);
            calendarEvents = _teacherCalendarEvents(cached);
            usingCachedData = true;
          }
        }

        await _appCacheService.saveJsonList(
          cacheKey,
          accessible,
          preserveNonEmptyOnEmpty: !forceFresh,
        );
      }
    }

    // Soft unread on normal open; force only on pull-to-refresh.
    final unread = await _notifService.getUnreadCount(
      forceRefresh: forceFresh,
    );
    if (mounted) {
      setState(() {
        _user = user;
        _upcomingEvents = events;
        _calendarEvents = calendarEvents;
        _usingCachedUpcomingEvents = usingCachedData;
        _unreadCount = unread;
        _isLoading = false;
      });
    }
  }

  Future<void> _primeOfflineReadiness(Map<String, dynamic>? user) async {
    final actorId = (user?['id']?.toString() ?? '').trim();
    if (actorId.isEmpty) {
      await _offlineBackupService.autoBackupIfConfigured();
      return;
    }

    try {
      await _offlineSyncService.refreshSnapshotForCurrentScanner(
        actorId: actorId,
        isTeacher: true,
      );
    } catch (_) {
      // Keep home refresh smooth even if background warmup fails.
    }
    await _offlineBackupService.autoBackupIfConfigured();
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
      unawaited(_refreshTeacherHomeLive('resume'));
      final teacherId = (_user?['id']?.toString() ?? '').trim();
      if (teacherId.isNotEmpty) {
        unawaited(_refreshScannerAccessGuard(teacherId));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unreadSubscription?.cancel();
    _eventLiveSubscription?.cancel();
    _scannerAccessGuardTimer?.cancel();
    _scannerAccessChannel?.unsubscribe();
    _headerPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Events/Sections/Profile stay alive so cached data survives tab switches.
    // Scan stays mounted after first open (camera paused while inactive).
    final screens = [
      _buildHomeContent(),
      const TeacherEventsTab(),
      _scanVisited
          ? TeacherScanScreen(isActive: _currentIndex == 2)
          : const SizedBox.shrink(),
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
                ? const PulseConnectSplashScreen(
                    statusMessage: 'Loading faculty dashboard & events...',
                  )
                : IndexedStack(
                    index: _currentIndex,
                    sizing: StackFit.expand,
                    children: screens,
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
                          color:
                              Colors.white, // Solid white for better visibility
                          borderRadius: BorderRadius.circular(32),
                          border: Border.all(
                            color: Colors.grey.shade200,
                            width: 1,
                          ),
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
                            _buildNavItem(
                              Icons.event_note_rounded,
                              'Events',
                              1,
                            ),
                            _buildNavItem(Icons.groups_rounded, 'Sections', 3),
                            _buildNavItem(Icons.person_rounded, 'Profile', 4),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Separate QR Button
                    GestureDetector(
                      onTap: () => setState(() {
                        _scanVisited = true;
                        _currentIndex = 2;
                      }),
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          color: _teacherPrimary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: _teacherDark.withValues(alpha: 0.4),
                              blurRadius: 20,
                              spreadRadius: 1,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.qr_code_scanner_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
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
          color: isActive
              ? _teacherPrimary.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isActive ? _teacherPrimary : Colors.grey.shade400,
              size: 20, // Reduced icon size
            ),
            if (isActive) ...[
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: _teacherPrimary,
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

    return RefreshIndicator(
      onRefresh: () => _loadData(forceFresh: true),
      color: _teacherPrimary,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_teacherDark, _teacherPrimary],
                ),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(28),
                ),
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
                          SafeCircleAvatar(
                            size: 50,
                            imagePathOrUrl: _user?['photo_url']?.toString(),
                            fallbackText: firstName.isNotEmpty
                                ? firstName[0].toUpperCase()
                                : 'T',
                            backgroundColor: _teacherMid,
                            textColor: Colors.white,
                            borderColor: const Color(0xFFD4A843),
                            borderWidth: 2,
                            textStyle: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 20,
                            ),
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
                                  scanColor: const Color(
                                    0xFF93C5FD,
                                  ), // Soft blue glow for Teacher
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
                                    icon: const Icon(
                                      Icons.notifications_none_rounded,
                                      color: Colors.white,
                                    ),
                                    onPressed: _isOpeningNotifications
                                        ? null
                                        : _openNotificationsModal,
                                  ),
                                ),
                                if (_unreadCount > 0)
                                  Positioned(
                                    top: -4,
                                    right: -4,
                                    child: IgnorePointer(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFEF4444),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: _teacherMid,
                                            width: 1.5,
                                          ),
                                        ),
                                        constraints: const BoxConstraints(
                                          minWidth: 18,
                                          minHeight: 18,
                                        ),
                                        child: Text(
                                          _unreadCount > 99
                                              ? '99+'
                                              : _unreadCount.toString(),
                                          textAlign: TextAlign.center,
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
              padding: const EdgeInsets.fromLTRB(
                24,
                16,
                24,
                12,
              ), // Reduced top padding
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
                      'View All',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _teacherMid,
                      ),
                    ),
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
                          Icon(
                            Icons.event_busy_rounded,
                            size: 48,
                            color: Colors.grey.shade300,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _usingCachedUpcomingEvents
                                ? 'No cached upcoming events'
                                : 'No upcoming events',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          if (_usingCachedUpcomingEvents) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Reconnect once to refresh the latest event list.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.grey.shade500,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final event = _upcomingEvents[index];
                    return _buildEventCard(event);
                  }, childCount: _upcomingEvents.length),
                ),
          const SliverToBoxAdapter(
            child: SizedBox(height: 100),
          ), // Space for floating nav
        ],
      ),
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
            children: [_buildMacbookSlide(), _buildMiniCalendar()],
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
                color: isActive
                    ? const Color(0xFFD4A843)
                    : Colors.white.withValues(alpha: 0.3),
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
              CardSwapItem(
                imagePath: 'assets/sample summit/image1.jpg',
                label: 'CCS SUMMIT',
              ),
              CardSwapItem(
                imagePath: 'assets/sample GA/image1.jpg',
                label: 'GENERAL ASSEMBLY',
              ),
              CardSwapItem(
                imagePath: 'assets/sample exhibit/image1.jpg',
                label: 'CCS EXHIBIT',
              ),
              CardSwapItem(
                imagePath: 'assets/sample CV/image1.jpg',
                label: 'COMPANY VISIT',
              ),
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
    final daysInMonth = DateTime(
      _calendarMonth.year,
      _calendarMonth.month + 1,
      0,
    ).day;
    final firstWeekday =
        DateTime(_calendarMonth.year, _calendarMonth.month, 1).weekday % 7;

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
                icon: const Icon(
                  Icons.chevron_left_rounded,
                  color: Colors.white,
                ),
                onPressed: () {
                  setState(() {
                    _calendarMonth = DateTime(
                      _calendarMonth.year,
                      _calendarMonth.month - 1,
                      1,
                    );
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
                icon: const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white,
                ),
                onPressed: () {
                  setState(() {
                    _calendarMonth = DateTime(
                      _calendarMonth.year,
                      _calendarMonth.month + 1,
                      1,
                    );
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
                child: Text(
                  d,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),

          // Calendar Grid
          ...List.generate(((daysInMonth + firstWeekday + 6) / 7).ceil(), (
            week,
          ) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(7, (weekday) {
                  final day = week * 7 + weekday - firstWeekday + 1;
                  if (day < 1 || day > daysInMonth)
                    return const SizedBox(width: 32, height: 32);

                  final isToday =
                      day == now.day &&
                      _calendarMonth.month == now.month &&
                      _calendarMonth.year == now.year;

                  // Check if any event falls on this day
                  final eventsOnThisDay = _calendarEvents.where((e) {
                    final startAt = e['start_at'] as String?;
                    if (startAt == null) return false;
                    try {
                      final d = parseStoredEventDateTime(startAt);
                      if (d == null) return false;
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
                                ? _teacherDark
                                : Colors.white.withValues(alpha: 0.86),
                            fontWeight: isToday
                                ? FontWeight.w800
                                : FontWeight.w500,
                            fontSize: 12,
                          ),
                        ),
                        if (hasEvent)
                          Builder(
                            builder: (_) {
                              final hasPublished = eventsOnThisDay.any((e) {
                                final s = (e['status']?.toString() ?? '')
                                    .toLowerCase()
                                    .trim();
                                return s == 'published';
                              });
                              final hasUnpublished = eventsOnThisDay.any((e) {
                                final s = (e['status']?.toString() ?? '')
                                    .toLowerCase()
                                    .trim();
                                return s != 'published';
                              });
                              return Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (hasPublished)
                                    Container(
                                      width: 4,
                                      height: 4,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Color(0xFFFACC15),
                                      ),
                                    ),
                                  if (hasPublished && hasUnpublished)
                                    const SizedBox(width: 2),
                                  if (hasUnpublished)
                                    Container(
                                      width: 4,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.white,
                                        border: isToday
                                            ? Border.all(
                                                color: _teacherDark
                                                    .withValues(alpha: 0.35),
                                                width: 0.5,
                                              )
                                            : null,
                                      ),
                                    ),
                                ],
                              );
                            },
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
                              title: const Text(
                                'Events on this Date',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: eventsOnThisDay
                                    .map(
                                      (e) => ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        leading: const Icon(
                                          Icons.event_rounded,
                                          color: _teacherMid,
                                        ),
                                        title: Text(
                                          e['title'] ?? 'Event',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                          ),
                                        ),
                                        subtitle: Text(
                                          e['start_at'] != null
                                              ? (() {
                                                  final parsed =
                                                      parseStoredEventDateTime(
                                                        e['start_at'],
                                                      );
                                                  return parsed != null
                                                      ? DateFormat(
                                                          'hh:mm a',
                                                        ).format(parsed)
                                                      : '';
                                                })()
                                              : '',
                                        ),
                                        onTap: () {
                                          Navigator.pop(context);
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  TeacherEventManage(event: e),
                                            ),
                                          );
                                        },
                                      ),
                                    )
                                    .toList(),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text(
                                    'Close',
                                    style: TextStyle(color: _teacherMid),
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                      child: dayWidget,
                    );
                  }

                  return dayWidget;
                }),
              ),
            );
          }),
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
            MaterialPageRoute(builder: (_) => TeacherEventManage(event: event)),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.grey.shade200),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _teacherMid,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    Text(
                      startDate != null
                          ? DateFormat('dd').format(startDate)
                          : '--',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                      ),
                    ),
                    Text(
                      startDate != null
                          ? DateFormat('MMM').format(startDate).toUpperCase()
                          : '---',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: Color(0xFF1F2937),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    if (startDate != null)
                      Text(
                        DateFormat('hh:mm a').format(startDate),
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    if (location.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            Icons.location_on_outlined,
                            size: 13,
                            color: Colors.grey.shade500,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              location,
                              style: TextStyle(
                                color: Colors.grey.shade500,
                                fontSize: 11,
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
              Icon(
                Icons.chevron_right_rounded,
                color: Colors.grey.shade400,
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
