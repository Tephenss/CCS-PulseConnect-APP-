import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import 'student_events.dart';
import 'student_tickets.dart';
import 'student_event_details.dart';
import 'student_profile.dart';
import 'student_scan.dart';
import '../welcome_screen.dart';
import '../../services/notification_service.dart';
import '../../services/event_live_service.dart';
import '../../utils/app_page_routes.dart';
import '../../services/offline_backup_service.dart';
import '../../services/offline_sync_service.dart';
import '../../widgets/notifications_modal.dart';
import '../../widgets/animated_greeting_text.dart';
import '../../widgets/card_swap_widget.dart';
import '../../widgets/shiny_text.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/pulseconnect_splash_screen.dart';
import '../../widgets/safe_circle_avatar.dart';
import '../../utils/event_time_utils.dart';
import '../../utils/course_theme_utils.dart';
import '../../widgets/staggered_entrance.dart';

class StudentHome extends StatefulWidget {
  const StudentHome({super.key});

  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends State<StudentHome>
    with WidgetsBindingObserver, TickerProviderStateMixin {
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
  StudentScanMode? _activeScanMode;
  bool _scanMenuOpen = false;
  late final AnimationController _scanMenuController;
  late final Animation<double> _scanMenuAnimation;
  bool _isLoading = true;
  int _unreadCount = 0;
  bool _isOpeningNotifications = false;
  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
  final _notifService = NotificationService();
  final PageController _headerPageController = PageController();
  int _currentHeaderSlide = 0;
  StreamSubscription<int>? _unreadSubscription;
  StreamSubscription<String>? _eventLiveSubscription;
  Timer? _absenceScopeRefreshTimer;
  RealtimeChannel? _scannerAccessChannel;
  Timer? _scannerAccessGuardTimer;
  Timer? _deferredTabsTimer;
  /// Delay Events/Tickets mount so home critical path is not a request storm.
  bool _eventsTabMounted = false;
  bool _ticketsTabMounted = false;

  // Section Selection Gate
  List<Map<String, dynamic>> _sections = [];
  String? _selectedSectionId;
  bool _isUpdatingSection = false;
  String? _sectionError;

  // Attendance Absence Reason Gate
  final TextEditingController _absenceReasonController = TextEditingController();
  List<Map<String, dynamic>> _pendingAbsenceScopes = [];
  String? _selectedAbsenceScopeKey;
  bool _isSubmittingAbsenceReason = false;
  String? _absenceReasonError;
  bool _isGateLoggingOut = false;

  Color _studentPrimary(BuildContext context) =>
      CourseThemeUtils.studentPrimaryForCourse(_user?['course']);
  Color _studentDark(BuildContext context) =>
      CourseThemeUtils.studentDarkForCourse(_user?['course']);
  Color _studentSoft(BuildContext context) =>
      CourseThemeUtils.studentSoftForCourse(_user?['course']);
  Color _studentAction(BuildContext context) =>
      CourseThemeUtils.studentActionForCourse(_user?['course']);
  Color _studentChrome(BuildContext context) =>
      CourseThemeUtils.studentChromeFromPrimary(_studentPrimary(context));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startAbsenceScopeRefreshTicker();
    _eventLiveSubscription = EventLiveService.instance.changes.listen((reason) {
      if (!mounted) return;
      unawaited(_refreshHomeLive(reason));
    });
    _loadData();
    _subscribeToNotifications();
    _scanMenuController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _scanMenuAnimation = CurvedAnimation(
      parent: _scanMenuController,
      curve: Curves.elasticOut,
      reverseCurve: Curves.easeInBack,
    );
  }

  void _toggleScanMenu() {
    final opening = !_scanMenuOpen;
    setState(() => _scanMenuOpen = opening);
    if (opening) {
      _scanMenuController.forward();
    } else {
      _scanMenuController.reverse();
    }
  }

  void _closeScanMenu({bool animated = true}) {
    if (!_scanMenuOpen) return;
    setState(() => _scanMenuOpen = false);
    if (animated) {
      _scanMenuController.reverse();
    } else {
      _scanMenuController.value = 0;
    }
  }

  void _onQrFabTap() {
    if (_currentIndex == 2 && _activeScanMode != null) {
      _switchScanMode();
      return;
    }
    if (_scanMenuOpen) {
      _closeScanMenu();
      return;
    }
    _toggleScanMenu();
  }

  void _switchScanMode() {
    if (_activeScanMode == null) return;
    setState(() {
      _activeScanMode = _activeScanMode == StudentScanMode.assist
          ? StudentScanMode.takeAttendance
          : StudentScanMode.assist;
    });
  }

  void _openScanWithMode(StudentScanMode mode) {
    _closeScanMenu();
    setState(() {
      _activeScanMode = mode;
      _currentIndex = 2;
    });
  }

  void _closeScanner() {
    setState(() {
      _currentIndex = 0;
      _activeScanMode = null;
      _scanMenuOpen = false;
    });
    _scanMenuController.value = 0;
  }

  bool _isHomeCatalogLiveReason(String reason) {
    final offlinePulse = reason.startsWith('offline:');
    final core = offlinePulse ? reason.substring('offline:'.length) : reason;
    return core == 'events' ||
        core.startsWith('events') ||
        core == 'registrations' ||
        core.startsWith('registrations') ||
        core == 'sessions' ||
        core.startsWith('sessions') ||
        core.startsWith('push') ||
        core == 'resume';
  }

  Future<void> _refreshHomeLive(String reason) async {
    if (!mounted || _user == null) return;
    final userId = _user?['id']?.toString() ?? '';
    if (userId.isEmpty) return;

    if (reason == 'inbox' || reason.startsWith('push')) {
      unawaited(_refreshUnreadCount());
    }

    final offlinePulse = reason.startsWith('offline:');
    final core = offlinePulse ? reason.substring('offline:'.length) : reason;
    if (core == 'registrations' ||
        core.startsWith('registrations') ||
        core == 'registration_access' ||
        core.startsWith('registration_access') ||
        core == 'tickets' ||
        core.startsWith('tickets') ||
        core.contains('registrations') ||
        core.contains('tickets')) {
      unawaited(_refreshAbsenceScopesSilently());
    }

    if (!_isHomeCatalogLiveReason(reason)) return;

    final offline = await _hasNoConnectivity();

    String? yearLevel;
    String? courseCode;
    String? specialization;
    try {
      final scope = await _eventService.getStudentTargetScope(userId);
      final scopedYear = (scope['yearLevel']?.toString() ?? '').trim();
      final scopedCourse = (scope['courseCode']?.toString() ?? '').trim();
      final scopedSpec = (scope['specialization']?.toString() ?? '').trim();
      yearLevel = scopedYear.isEmpty || scopedYear == 'ALL' ? null : scopedYear;
      courseCode =
          scopedCourse.isEmpty || scopedCourse == 'ALL' ? null : scopedCourse;
      specialization = scopedSpec.isEmpty ? null : scopedSpec;
    } catch (_) {
      // Keep compatibility fallback below.
    }

    yearLevel ??= await _authService.getStudentYearLevel();
    courseCode ??= await _authService.getStudentCourseCode();

    final activeEvents = await _eventService.getActiveEvents(
      yearLevel: yearLevel,
      courseCode: courseCode,
      specialization: specialization,
      // Live/push/resume force network when online; offline pulses stay cache-only.
      forceFresh: !offline && !offlinePulse,
    );
    final calendarEvents = List<Map<String, dynamic>>.from(activeEvents);

    if (!mounted) return;
    // Only keep prior cards while offline — online empty means deleted/archived.
    if (activeEvents.isEmpty && _upcomingEvents.isNotEmpty && offline) {
      return;
    }
    setState(() {
      _upcomingEvents = activeEvents.take(5).toList();
      if (!(calendarEvents.isEmpty && _calendarEvents.isNotEmpty && offline)) {
        _calendarEvents = calendarEvents;
      }
    });
  }

  void _startAbsenceScopeRefreshTicker() {
    _absenceScopeRefreshTimer?.cancel();
    _absenceScopeRefreshTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => _refreshAbsenceScopesSilently(),
    );
  }

  Future<void> _refreshAbsenceScopesSilently() async {
    final userId = _user?['id']?.toString() ?? '';
    if (!mounted || userId.isEmpty) return;

    final refreshed = await _eventService.getStudentPendingAbsenceScopes(
      studentId: userId,
    );
    if (!mounted) return;

    final oldKeys = _pendingAbsenceScopes
        .map((scope) => scope['scope_key']?.toString() ?? '')
        .where((key) => key.isNotEmpty)
        .toSet();
    final newKeys = refreshed
        .map((scope) => scope['scope_key']?.toString() ?? '')
        .where((key) => key.isNotEmpty)
        .toSet();

    if (oldKeys.length == newKeys.length && oldKeys.containsAll(newKeys)) {
      return;
    }

    String? selected = _selectedAbsenceScopeKey;
    if (refreshed.isEmpty) {
      selected = null;
    } else {
      final stillExists = selected != null &&
          refreshed.any((scope) => (scope['scope_key']?.toString() ?? '') == selected);
      selected = stillExists ? selected : (refreshed.first['scope_key']?.toString());
    }

    setState(() {
      _pendingAbsenceScopes = refreshed;
      _selectedAbsenceScopeKey = selected;
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
        _ensureTabMounted(result);
        setState(() => _currentIndex = result);
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
    try {
      final connectivity = await _connectivity.checkConnectivity();
      return connectivity.isEmpty ||
          connectivity.every((result) => result == ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  Future<void> _refreshScannerAccessGuard(String studentId) async {
    final actorId = studentId.trim();
    if (actorId.isEmpty) return;
    if (await _hasNoConnectivity()) return;

    try {
      await _offlineSyncService.refreshSnapshotForCurrentScanner(
        actorId: actorId,
        isTeacher: false,
      );
    } catch (_) {
      // Keep the shell stable even if access refresh fails.
    }
  }

  void _restartScannerAccessGuard(String studentId) {
    _scannerAccessGuardTimer?.cancel();
    _scannerAccessChannel?.unsubscribe();
    _scannerAccessChannel = null;

    final actorId = studentId.trim();
    if (actorId.isEmpty) return;

    _scannerAccessChannel =
        _supabase.channel('public:student_home_scan_access:$actorId');
    _scannerAccessChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_assistants',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'student_id',
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
        // Only refresh roster while Scan tab is visible.
        if (!mounted || _currentIndex != 2) return;
        unawaited(_refreshScannerAccessGuard(actorId));
      },
    );
  }

  Future<void> _loadData({bool forceFresh = false}) async {
    final user = await _authService.getCurrentUser();
    final userId = user?['id']?.toString() ?? '';
    final hadCachedEvents = _upcomingEvents.isNotEmpty;
    final offline = await _hasNoConnectivity();
    final effectiveForceFresh = forceFresh && !offline;

    unawaited(_primeOfflineReadiness(user));

    // Initialize Realtime once user is known
    if (user != null) {
      if (userId.isNotEmpty) {
        EventLiveService.instance.start(userId: userId);
        _notifService.initRealtime(userId);
      }
    }
    _restartScannerAccessGuard(userId);

    // Soft paint: if we already have cards (e.g. resume), drop splash immediately.
    if (hadCachedEvents && mounted && _isLoading) {
      setState(() {
        _user = user;
        _isLoading = false;
      });
    }

    String? yearLevel;
    String? courseCode;
    String? specialization;
    if (userId.isNotEmpty) {
      try {
        final scope = await _eventService.getStudentTargetScope(userId);
        final scopedYear = (scope['yearLevel']?.toString() ?? '').trim();
        final scopedCourse = (scope['courseCode']?.toString() ?? '').trim();
        final scopedSpec = (scope['specialization']?.toString() ?? '').trim();
        yearLevel = scopedYear.isEmpty || scopedYear == 'ALL' ? null : scopedYear;
        courseCode =
            scopedCourse.isEmpty || scopedCourse == 'ALL' ? null : scopedCourse;
        specialization = scopedSpec.isEmpty ? null : scopedSpec;
      } catch (_) {
        // Keep compatibility fallback below.
      }
    }

    yearLevel ??= await _authService.getStudentYearLevel();
    courseCode ??= await _authService.getStudentCourseCode();

    // Critical path: one events fetch. Calendar on home is derived from it
    // so we do not pay a second near-duplicate PostgREST round-trip.
    final activeEvents = await _eventService.getActiveEvents(
      yearLevel: yearLevel,
      courseCode: courseCode,
      specialization: specialization,
      forceFresh: effectiveForceFresh,
    );
    final events = activeEvents.take(5).toList();
    final calendarEvents = List<Map<String, dynamic>>.from(activeEvents);

    if (mounted) {
      setState(() {
        _user = user;
        if (!(events.isEmpty && hadCachedEvents && offline && !effectiveForceFresh)) {
          _upcomingEvents = events;
        }
        if (!(calendarEvents.isEmpty &&
            _calendarEvents.isNotEmpty &&
            offline &&
            !effectiveForceFresh)) {
          _calendarEvents = calendarEvents;
        }
        _isLoading = false;
      });
      _scheduleDeferredTabMount();
    }

    // Soft open painted from cache — reconcile deletes from Supabase once online.
    if (!forceFresh && !offline && mounted) {
      unawaited(_reconcileHomeEventsAfterCache(
        userId: userId,
        yearLevel: yearLevel,
        courseCode: courseCode,
        specialization: specialization,
      ));
    }

    // Non-critical: unread / sections / absence — after first paint.
    unawaited(
      _loadHomeSecondary(
        user: user,
        userId: userId,
        forceFreshUnread: forceFresh,
      ),
    );
  }

  Future<void> _reconcileHomeEventsAfterCache({
    required String userId,
    String? yearLevel,
    String? courseCode,
    String? specialization,
  }) async {
    try {
      final activeEvents = await _eventService.getActiveEvents(
        yearLevel: yearLevel,
        courseCode: courseCode,
        specialization: specialization,
        forceFresh: true,
      );
      if (!mounted) return;
      final offline = await _hasNoConnectivity();
      if (offline) return;
      final events = activeEvents.take(5).toList();
      final calendarEvents = List<Map<String, dynamic>>.from(activeEvents);
      setState(() {
        _upcomingEvents = events;
        _calendarEvents = calendarEvents;
      });
    } catch (_) {
      // Keep cached home cards if reconcile fails.
    }
  }

  /// Soft secondary home work — must not block splash / first cards.
  Future<void> _loadHomeSecondary({
    required Map<String, dynamic>? user,
    required String userId,
    bool forceFreshUnread = false,
  }) async {
    try {
      final unread = await _notifService.getUnreadCount(
        forceRefresh: forceFreshUnread,
      );

      List<Map<String, dynamic>> filteredSections = _sections;
      final needsSection = user != null && user['section_id'] == null;
      if (needsSection) {
        final sections = await _authService.getSections();
        filteredSections = _filterSectionsForDetectedCourse(sections, user);
      }

      final pendingAbsenceScopes = userId.isNotEmpty
          ? await _eventService.getStudentPendingAbsenceScopes(
              studentId: userId,
            )
          : <Map<String, dynamic>>[];

      String? selectedAbsenceScopeKey = _selectedAbsenceScopeKey;
      if (pendingAbsenceScopes.isEmpty) {
        selectedAbsenceScopeKey = null;
      } else {
        final hasExisting = selectedAbsenceScopeKey != null &&
            pendingAbsenceScopes.any(
              (scope) =>
                  (scope['scope_key']?.toString() ?? '') ==
                  selectedAbsenceScopeKey,
            );
        selectedAbsenceScopeKey = hasExisting
            ? selectedAbsenceScopeKey
            : (pendingAbsenceScopes.first['scope_key']?.toString());
      }

      if (!mounted) return;
      setState(() {
        _unreadCount = unread;
        if (needsSection) {
          _sections = filteredSections;
          if (_selectedSectionId != null &&
              filteredSections.every(
                (section) => section['id']?.toString() != _selectedSectionId,
              )) {
            _selectedSectionId = null;
          }
        }
        _pendingAbsenceScopes = pendingAbsenceScopes;
        _selectedAbsenceScopeKey = selectedAbsenceScopeKey;
      });
    } catch (_) {
      // Keep home usable even if secondary loads fail.
    }
  }

  void _scheduleDeferredTabMount() {
    if (_eventsTabMounted && _ticketsTabMounted) return;
    _deferredTabsTimer?.cancel();
    _deferredTabsTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      if (_eventsTabMounted && _ticketsTabMounted) return;
      setState(() {
        _eventsTabMounted = true;
        _ticketsTabMounted = true;
      });
    });
  }

  void _ensureTabMounted(int index) {
    if (index == 1 && !_eventsTabMounted) {
      setState(() => _eventsTabMounted = true);
    } else if (index == 3 && !_ticketsTabMounted) {
      setState(() => _ticketsTabMounted = true);
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
        isTeacher: false,
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
      _loadData(forceFresh: true);
      final studentId = (_user?['id']?.toString() ?? '').trim();
      if (studentId.isNotEmpty) {
        unawaited(_refreshScannerAccessGuard(studentId));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unreadSubscription?.cancel();
    _eventLiveSubscription?.cancel();
    _absenceScopeRefreshTimer?.cancel();
    _scannerAccessGuardTimer?.cancel();
    _deferredTabsTimer?.cancel();
    _scannerAccessChannel?.unsubscribe();
    _headerPageController.dispose();
    _absenceReasonController.dispose();
    _scanMenuController.dispose();
    super.dispose();
  }

  Map<String, dynamic>? _selectedAbsenceScope() {
    if (_pendingAbsenceScopes.isEmpty) return null;

    final selected = _selectedAbsenceScopeKey;
    if (selected == null || selected.isEmpty) {
      return _pendingAbsenceScopes.first;
    }

    for (final scope in _pendingAbsenceScopes) {
      if ((scope['scope_key']?.toString() ?? '') == selected) {
        return scope;
      }
    }

    return _pendingAbsenceScopes.first;
  }

  String _formatScopeDateTime(dynamic rawIso) {
    final parsed = parseStoredEventDateTime(rawIso?.toString());
    if (parsed == null) return 'N/A';
    return DateFormat('MMM dd, yyyy - h:mm a').format(parsed);
  }

  String _scopeSummaryLabel(Map<String, dynamic> scope) {
    final scopeType = (scope['scope_type']?.toString() ?? 'event').toLowerCase();
    final eventTitle = (scope['event_title']?.toString() ?? 'Event').trim();
    if (scopeType == 'session') {
      final sessionTitle =
          (scope['session_title']?.toString() ?? 'Seminar').trim();
      return '$eventTitle - $sessionTitle';
    }
    return eventTitle;
  }

  String _scopeWindowLabel(Map<String, dynamic> scope) {
    final opens = _formatScopeDateTime(scope['window_opens_at']);
    final closes = _formatScopeDateTime(scope['window_closes_at']);
    return '$opens to $closes';
  }

  Future<void> _logoutFromGate() async {
    if (_isGateLoggingOut) return;
    setState(() => _isGateLoggingOut = true);
    try {
      await _authService.logout();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const WelcomeScreen()),
        (route) => false,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isGateLoggingOut = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to sign out. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildGateLogoutButton() {
    return TextButton.icon(
      onPressed: _isGateLoggingOut ? null : _logoutFromGate,
      style: TextButton.styleFrom(
        foregroundColor: const Color(0xFFF4F4F5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      icon: _isGateLoggingOut
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.logout_rounded, size: 18),
      label: const Text(
        'Logout',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }

  String _detectedCourseCode() {
    final normalized = CourseThemeUtils.normalizeCourse(_user?['course']);
    if (normalized == 'CS') return 'BSCS';
    if (normalized == 'IT') return 'BSIT';
    return '';
  }

  List<Map<String, dynamic>> _filterSectionsForDetectedCourse(
    List<Map<String, dynamic>> source,
    Map<String, dynamic>? user,
  ) {
    final normalizedCourse = CourseThemeUtils.normalizeCourse(user?['course']);
    if (normalizedCourse != 'IT' && normalizedCourse != 'CS') {
      return source;
    }

    return source.where((section) {
      final name = (section['name']?.toString() ?? '').trim().toUpperCase();
      if (name.isEmpty) return false;
      if (normalizedCourse == 'CS') {
        return name.startsWith('BSCS') || name.startsWith('CS ');
      }
      return name.startsWith('BSIT');
    }).toList();
  }

  String? _sectionSelectionSecurityError(String? sectionId) {
    final sid = sectionId?.trim() ?? '';
    if (sid.isEmpty) {
      return 'Please select your current year level and section.';
    }

    final selected = _sections
        .where((item) => (item['id']?.toString() ?? '') == sid)
        .cast<Map<String, dynamic>>()
        .toList();
    if (selected.isEmpty) {
      return 'Selected section is invalid. Please re-select.';
    }

    final label = (selected.first['name']?.toString() ?? '').trim();
    if (label.isEmpty) {
      return 'Section label is invalid. Please re-select.';
    }

    final hasYearIndicator = RegExp(r'(^|[^0-9])[1-4]([^0-9]|$)').hasMatch(label) ||
        label.toLowerCase().contains('year');
    if (!hasYearIndicator) {
      return 'Security check failed: section has no valid year-level marker.';
    }

    return null;
  }

  Future<void> _submitAbsenceReason() async {
    if (_isSubmittingAbsenceReason || _user == null) return;
    final scope = _selectedAbsenceScope();
    if (scope == null) return;

    final studentId = _user?['id']?.toString() ?? '';
    final eventId = scope['event_id']?.toString() ?? '';
    final sessionId = scope['session_id']?.toString();
    final reason = _absenceReasonController.text.trim();

    if (studentId.isEmpty || eventId.isEmpty) {
      setState(() {
        _absenceReasonError = 'Missing event/student context. Please re-login.';
      });
      return;
    }
    if (reason.isEmpty) {
      setState(() {
        _absenceReasonError = 'Please enter your reason before submitting.';
      });
      return;
    }

    setState(() {
      _isSubmittingAbsenceReason = true;
      _absenceReasonError = null;
    });

    final result = await _eventService.submitAbsenceReason(
      studentId: studentId,
      eventId: eventId,
      sessionId: (sessionId == null || sessionId.isEmpty) ? null : sessionId,
      reasonText: reason,
    );

    if (result['ok'] == true) {
      final refreshed = await _eventService.getStudentPendingAbsenceScopes(
        studentId: studentId,
      );
      if (!mounted) return;
      setState(() {
        _pendingAbsenceScopes = refreshed;
        _selectedAbsenceScopeKey = refreshed.isNotEmpty
            ? (refreshed.first['scope_key']?.toString())
            : null;
        _absenceReasonController.clear();
        _isSubmittingAbsenceReason = false;
        _absenceReasonError = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reason submitted successfully.')),
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _isSubmittingAbsenceReason = false;
      _absenceReasonError = result['error']?.toString() ?? 'Failed to submit reason.';
    });
  }

  @override
  Widget build(BuildContext context) {
    // Note: Tab 2 (Index 2) is Scan — built only while selected so the camera
    // does not stay open. Other tabs stay alive (IndexedStack) to preserve
    // cached lists and avoid full-screen reload spinners.
    final bool needsSection = _user != null && _user!['section_id'] == null;
    final bool needsAbsenceReason =
        _user != null && _pendingAbsenceScopes.isNotEmpty;
    final gateMode = needsSection || needsAbsenceReason;

    final tabBody = needsSection
        ? _buildSectionSelection()
        : (needsAbsenceReason
              ? _buildAbsenceReasonLock()
              : IndexedStack(
                  index: _currentIndex,
                  sizing: StackFit.expand,
                  children: [
                    _buildHomeContent(),
                    _eventsTabMounted
                        ? const StudentEvents()
                        : const SizedBox.shrink(),
                    // Keep scan out of the keep-alive stack until opened.
                    _currentIndex == 2 && _activeScanMode != null
                        ? StudentScanScreen(
                            key: ValueKey(_activeScanMode),
                            initialMode: _activeScanMode!,
                            onClose: _closeScanner,
                          )
                        : const SizedBox.shrink(),
                    _ticketsTabMounted
                        ? const StudentTickets()
                        : const SizedBox.shrink(),
                    StudentProfile(user: _user, onUpdate: _loadData),
                  ],
                ));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_scanMenuOpen) {
          _closeScanMenu();
          return;
        }
        if (_currentIndex == 2) {
          _closeScanner();
          return;
        }
        if (_currentIndex != 0) {
          setState(() => _currentIndex = 0);
        }
      },
      child: Scaffold(
        backgroundColor: gateMode ? const Color(0xFF09090B) : Colors.white,
        body: ColoredBox(
          color: gateMode ? const Color(0xFF09090B) : Colors.white,
          child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            _isLoading
                ? const PulseConnectSplashScreen(
                    statusMessage: 'Loading student portal & events...',
                  )
                : tabBody,

            if (_scanMenuOpen)
              Positioned.fill(
                child: GestureDetector(
                  onTap: _closeScanMenu,
                  behavior: HitTestBehavior.opaque,
                  child: FadeTransition(
                    opacity: _scanMenuAnimation,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.32),
                    ),
                  ),
                ),
              ),

            if (!_isLoading && !needsSection && !needsAbsenceReason && _currentIndex != 2)
              Positioned(
                bottom: 94,
                right: 20,
                child: _buildScanFloatingMenu(),
              ),

            // New Floating Navigation Bar (Matches user design)
            if (!_isLoading && !needsSection && !needsAbsenceReason)
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
                      onTap: _onQrFabTap,
                      child: AnimatedBuilder(
                        animation: _scanMenuController,
                        builder: (context, child) {
                          final t = _scanMenuController.value.clamp(0.0, 1.0);
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 280),
                            width: 58,
                            height: 58,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  _studentChrome(context),
                                  _studentPrimary(context),
                                ],
                              ),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: _studentChrome(context)
                                      .withValues(alpha: 0.5),
                                  blurRadius: 20 + (6 * t),
                                  spreadRadius: 1 + (2 * t),
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: child,
                          );
                        },
                        child: AnimatedRotation(
                          turns: _scanMenuOpen ? 0.125 : 0,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOutBack,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            transitionBuilder: (child, anim) => ScaleTransition(
                              scale: anim,
                              child: FadeTransition(opacity: anim, child: child),
                            ),
                            child: Icon(
                              _scanMenuOpen
                                  ? Icons.close_rounded
                                  : Icons.qr_code_scanner_rounded,
                              key: ValueKey(_scanMenuOpen),
                              color: Colors.white,
                              size: 26,
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
        ),
      ),
    );

  }

  Widget _buildAbsenceReasonLock() {
    final selectedScope = _selectedAbsenceScope();
    if (selectedScope == null) {
      return const Center(child: PulseConnectLoader());
    }

    final scopeType =
        (selectedScope['scope_type']?.toString() ?? 'event').toLowerCase();
    final scopeWindow = _scopeWindowLabel(selectedScope);
    final pendingCount = _pendingAbsenceScopes.length;
    final helperText = scopeType == 'session'
        ? 'You missed the seminar scan window. Submit your reason to continue.'
        : 'You missed the event scan window. Submit your reason to continue.';

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xFF09090B),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox(width: 4),
                    _buildGateLogoutButton(),
                  ],
                ),
                _buildGateLogo(),
                const SizedBox(height: 24),
                const Text(
                  'Attendance Follow-Up Required',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  helperText,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C22),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF2F2F36)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _scopeSummaryLabel(selectedScope),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Scan window: $scopeWindow',
                        style: const TextStyle(
                          color: Color(0xFFA1A1AA),
                          fontSize: 12,
                        ),
                      ),
                      if (pendingCount > 1) ...[
                        const SizedBox(height: 8),
                        Text(
                          '$pendingCount pending absence records.',
                          style: const TextStyle(
                            color: Color(0xFFEAB308),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_pendingAbsenceScopes.length > 1) ...[
                  const SizedBox(height: 20),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedAbsenceScopeKey ??
                        (_pendingAbsenceScopes.first['scope_key']?.toString()),
                    dropdownColor: const Color(0xFF1C1C22),
                    iconEnabledColor: const Color(0xFFA1A1AA),
                    style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1C1C22),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    items: _pendingAbsenceScopes.map((scope) {
                      final key = scope['scope_key']?.toString() ?? '';
                      return DropdownMenuItem<String>(
                        value: key,
                        child: Text(_scopeSummaryLabel(scope)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedAbsenceScopeKey = value;
                        _absenceReasonError = null;
                      });
                    },
                  ),
                ],
                const SizedBox(height: 20),
                TextField(
                  controller: _absenceReasonController,
                  minLines: 4,
                  maxLines: 6,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Explain why you missed the scan window...',
                    hintStyle: const TextStyle(color: Color(0xFF71717A)),
                    filled: true,
                    fillColor: const Color(0xFF1C1C22),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    contentPadding: const EdgeInsets.all(14),
                  ),
                ),
                if (_absenceReasonError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _absenceReasonError!,
                    style: const TextStyle(
                      color: Color(0xFFFCA5A5),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isSubmittingAbsenceReason ? null : _submitAbsenceReason,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _studentAction(context),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isSubmittingAbsenceReason
                        ? const PulseConnectLoader(size: 14, color: Colors.white)
                        : const Text(
                            'Submit Reason',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGateLogo() {
    return Image.asset(
      'assets/ccs_lock_logo.png',
      height: 88,
      width: 88,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => Image.asset(
        'assets/BSIT.png',
        height: 88,
        width: 88,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => Image.asset(
          'assets/CCS.png',
          height: 88,
          width: 88,
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  Widget _buildSectionSelection() {
    final courseLabel = _detectedCourseCode();
    final hasCourseFilter = courseLabel.isNotEmpty;
    final hasSelectableSections = _sections.isNotEmpty;

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xFF09090B),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _buildGateLogoutButton(),
                ],
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildGateLogo(),
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
                                fontFamily: 'Inter',
                              ),
                              children: const [
                                TextSpan(
                                  text:
                                      'Please select your current Year Level and Section to continue using the app. Make sure this is correct, as ',
                                ),
                                TextSpan(
                                  text:
                                      'some events are restricted to specific year levels.',
                                  style: TextStyle(
                                    color: Color(0xFFEAB308),
                                    fontWeight: FontWeight.w700,
                                  ),
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
                                color: _studentDark(context),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: _studentChrome(context)),
                              ),
                              child: Text(
                                _sectionError!,
                                style: const TextStyle(
                                  color: Color(0xFFFCA5A5),
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          DropdownButtonFormField<String>(
                            initialValue: _selectedSectionId,
                            dropdownColor: const Color(0xFF1C1C22),
                            iconEnabledColor: const Color(0xFFA1A1AA),
                            style: const TextStyle(
                              fontSize: 14,
                              color: Color(0xFFF4F4F5),
                            ),
                            hint: const Text(
                              'Select Year Level & Section',
                              style: TextStyle(color: Color(0xFF71717A), fontSize: 14),
                            ),
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: const Color(0xFF1C1C22),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 16,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            items: _sections.map((s) {
                              return DropdownMenuItem<String>(
                                value: s['id'].toString(),
                                child: Text(s['name'] as String? ?? ''),
                              );
                            }).toList(),
                            onChanged: (val) => setState(() => _selectedSectionId = val),
                          ),
                          if (!hasSelectableSections) ...[
                            const SizedBox(height: 10),
                            Text(
                              hasCourseFilter
                                  ? 'No sections found for $courseLabel. Please contact admin.'
                                  : 'No sections available right now. Please contact admin.',
                              style: const TextStyle(
                                color: Color(0xFFFCA5A5),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _isUpdatingSection ||
                                      _selectedSectionId == null ||
                                      !hasSelectableSections
                                  ? null
                                  : () {
                                      final securityError =
                                          _sectionSelectionSecurityError(_selectedSectionId);
                                      if (securityError != null) {
                                        setState(() {
                                          _sectionError = securityError;
                                        });
                                        return;
                                      }
                                      showDialog(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          backgroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(20),
                                          ),
                                          title: const Text(
                                            'Are you sure?',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 18,
                                              color: Color(0xFF1F2937),
                                            ),
                                          ),
                                          content: const Text(
                                            'Once you select your section, this cannot be changed manually until the next school year reset. Please ensure you have selected your correct current year and section. If you select the wrong section, you might not be able to join some events and your attendance logs will be misplaced.\n\nDo you want to proceed?',
                                            style: TextStyle(
                                              color: Color(0xFF4B5563),
                                              fontSize: 14,
                                              height: 1.5,
                                            ),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(context),
                                              child: const Text(
                                                'Cancel',
                                                style: TextStyle(color: Color(0xFF71717A)),
                                              ),
                                            ),
                                            ElevatedButton(
                                              onPressed: () async {
                                                Navigator.pop(context);
                                                setState(() {
                                                  _isUpdatingSection = true;
                                                  _sectionError = null;
                                                });
                                                final res = await _authService.updateSection(
                                                  _selectedSectionId!,
                                                );
                                                if (res['ok']) {
                                                  _loadData();
                                                } else {
                                                  setState(() {
                                                    _sectionError = res['error'];
                                                    _isUpdatingSection = false;
                                                  });
                                                }
                                              },
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: _studentAction(context),
                                                foregroundColor: Colors.white,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius: BorderRadius.circular(10),
                                                ),
                                              ),
                                              child: const Text('Yes, Confirm'),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _studentAction(context),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: _isUpdatingSection
                                  ? const PulseConnectLoader(size: 14, color: Colors.white)
                                  : const Text(
                                      'Save & Continue',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
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
      onTap: () {
        _closeScanMenu();
        final switchedToTickets = index == 3 && _currentIndex != 3;
        _ensureTabMounted(index);
        setState(() => _currentIndex = index);
        // IndexedStack keeps Tickets alive — force a fresh pull when opened.
        if (switchedToTickets) {
          EventLiveService.instance.pulseTicketsUi();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        padding: EdgeInsets.symmetric(
          horizontal: isActive ? 12 : 8, // Reduced padding to prevent overflow
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: isActive
              ? _studentChrome(context).withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isActive ? _studentChrome(context) : const Color(0xFFA1A1AA),
              size: 20, // Reduced icon size
            ),
            if (isActive) ...[
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: _studentChrome(context),
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

  Widget _buildScanFloatingMenu() {
    return AnimatedBuilder(
      animation: _scanMenuController,
      builder: (context, child) {
        if (_scanMenuController.value == 0 && !_scanMenuOpen) {
          return const SizedBox.shrink();
        }
        // Clamp for display purposes (elasticOut can exceed 1.0)
        final raw = _scanMenuController.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: raw,
          child: child,
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildScanMenuOption(
            icon: Icons.groups_rounded,
            title: 'Assist Attendance',
            subtitle: 'Help mark peers present',
            iconColor: _studentChrome(context),
            iconBg: _studentSoft(context).withValues(alpha: 0.18),
            mode: StudentScanMode.assist,
            staggerDelay: 0.18,
          ),
          const SizedBox(height: 10),
          _buildScanMenuOption(
            icon: Icons.qr_code_scanner_rounded,
            title: 'Take Attendance',
            subtitle: 'Scan your QR code now',
            iconColor: _studentChrome(context),
            iconBg: _studentSoft(context).withValues(alpha: 0.18),
            mode: StudentScanMode.takeAttendance,
            staggerDelay: 0.0,
          ),
        ],
      ),
    );
  }

  Widget _buildScanMenuOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color iconColor,
    required Color iconBg,
    required StudentScanMode mode,
    required double staggerDelay,
  }) {
    return AnimatedBuilder(
      animation: _scanMenuController,
      builder: (context, child) {
        final raw = _scanMenuController.value;
        final interval = Interval(staggerDelay, 1.0, curve: Curves.easeOutBack);
        final t = interval.transform(raw.clamp(0.0, 1.0));
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(32 * (1 - t), 0),
            child: Transform.scale(
              scale: 0.82 + (0.18 * t),
              alignment: Alignment.centerRight,
              child: child,
            ),
          ),
        );
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openScanWithMode(mode),
          borderRadius: BorderRadius.circular(20),
          splashColor: iconColor.withValues(alpha: 0.12),
          highlightColor: iconColor.withValues(alpha: 0.06),
          child: Container(
            width: 240,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: iconColor.withValues(alpha: 0.18),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: iconColor.withValues(alpha: 0.18),
                  blurRadius: 28,
                  spreadRadius: 0,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(13),
                    boxShadow: [
                      BoxShadow(
                        color: iconColor.withValues(alpha: 0.20),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Icon(icon, color: iconColor, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13.5,
                          color: Color(0xFF111827),
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: 11,
                          color: _studentChrome(context).withValues(alpha: 0.55),
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: iconColor,
                    size: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHomeContent() {
    final firstName = _user?['first_name'] as String? ?? 'Student';
    
    return RefreshIndicator(
      onRefresh: () => _loadData(forceFresh: true),
      color: _studentChrome(context),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
        // App Bar Header â€” Solid Dark Maroon Design
        SliverToBoxAdapter(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_studentDark(context), _studentPrimary(context)],
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
                    StaggeredEntrance(
                      index: 0,
                      slideOffset: 16.0,
                      child: Row(
                        children: [
                          // Profile Avatar
                          GestureDetector(
                            onTap: () {
                              setState(() => _currentIndex = 4);
                            },
                            child: SafeCircleAvatar(
                              size: 50,
                              imagePathOrUrl: _user?['photo_url']?.toString(),
                              fallbackText: firstName.isNotEmpty
                                  ? firstName[0].toUpperCase()
                                  : 'S',
                              backgroundColor: _studentPrimary(context),
                              textColor: Colors.white,
                              borderColor: const Color(0xFFD4A843),
                              borderWidth: 2,
                              textStyle: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 20,
                              ),
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
                                  scanColor: _studentSoft(context),
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
                                  onPressed: _isOpeningNotifications ? null : _openNotificationsModal,
                                ),
                                if (_unreadCount > 0)
                                  Positioned(
                                    top: 8,
                                    right: 10,
                                    child: IgnorePointer(
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFEF4444),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: _studentChrome(context),
                                            width: 1.5,
                                          ),
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
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 28),

                    // Header Slider (Laptop Animation / Mini Calendar)
                    StaggeredEntrance(
                      index: 1,
                      slideOffset: 24.0,
                      child: _buildHeaderSlider(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Upcoming Events Section
        SliverToBoxAdapter(
          child: StaggeredEntrance(
            index: 2,
            slideOffset: 20.0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
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
                    onTap: () {
                      _ensureTabMounted(1);
                      setState(() => _currentIndex = 1);
                    },
                    child: Text(
                      'See All',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _studentChrome(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Events List
        _upcomingEvents.isEmpty
            ? SliverToBoxAdapter(
                child: StaggeredEntrance(
                  index: 3,
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
                ),
              )
            : SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final event = _upcomingEvents[index];
                    return StaggeredEntrance(
                      index: 3 + index,
                      slideOffset: 24.0,
                      child: _buildEventCard(event),
                    );
                  },
                  childCount: _upcomingEvents.length,
                ),
              ),

          const SliverToBoxAdapter(child: SizedBox(height: 100)), // Space for floating nav
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
    final weekCount = ((daysInMonth + firstWeekday + 6) / 7).ceil();

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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final safeHeight = constraints.maxHeight > 0 ? constraints.maxHeight : 300.0;
          const monthRowHeight = 40.0;
          const sectionGap = 12.0;
          const dayHeaderHeight = 20.0;
          final usableGridHeight = (safeHeight -
                  monthRowHeight -
                  sectionGap -
                  dayHeaderHeight -
                  sectionGap)
              .clamp(150.0, 260.0);
          final gridSpacing = weekCount > 1 ? 4.0 : 0.0;
          final cellSize = ((usableGridHeight - (gridSpacing * (weekCount - 1))) / weekCount)
              .clamp(24.0, 32.0);
          final dayFontSize = (cellSize * 0.40).clamp(10.0, 13.0);

          return Column(
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
              const SizedBox(height: sectionGap),

              // Day headers
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: ['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((d) {
                  return SizedBox(
                    width: cellSize,
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
              const SizedBox(height: sectionGap),

              // Calendar Grid
              ...List.generate(
                weekCount,
                (week) {
                  return Padding(
                    padding: EdgeInsets.only(bottom: week == weekCount - 1 ? 0 : gridSpacing),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: List.generate(7, (weekday) {
                    final day = week * 7 + weekday - firstWeekday + 1;
                    if (day < 1 || day > daysInMonth) {
                      return SizedBox(width: cellSize, height: cellSize);
                    }

                    final isToday = day == now.day && _calendarMonth.month == now.month && _calendarMonth.year == now.year;

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
                      width: cellSize,
                      height: cellSize,
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
                                  ? _studentDark(context)
                                  : Colors.white.withValues(alpha: 0.9),
                              fontWeight: isToday ? FontWeight.w900 : FontWeight.w600,
                              fontSize: dayFontSize,
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
                                return Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Row(
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
                                                    color: _studentDark(context)
                                                        .withValues(alpha: 0.35),
                                                    width: 0.5,
                                                  )
                                                : null,
                                          ),
                                        ),
                                    ],
                                  ),
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
                                backgroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                title: const Text('Events on this Date', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Color(0xFF1F2937))),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: eventsOnThisDay.map((e) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                      Icons.event_rounded,
                                      color: _studentChrome(context),
                                    ),
                                    title: Text(e['title'] ?? 'Event', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF1F2937))),
                                    subtitle: Text(
                                      e['start_at'] != null
                                          ? (() {
                                              final parsed = parseStoredEventDateTime(e['start_at']);
                                              return parsed != null ? DateFormat('hh:mm a').format(parsed) : '';
                                            })()
                                          : '',
                                      style: const TextStyle(color: Color(0xFF71717A)),
                                    ),
                                    onTap: () {
                                      Navigator.pop(context);
                                      _ensureTabMounted(1);
                                      setState(() => _currentIndex = 1);
                                    },
                                  )).toList(),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: Text(
                                      'Close',
                                      style: TextStyle(color: _studentChrome(context)),
                                    ),
                                  ),
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
          );
        },
      ),
    );
  }

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
            AppPageRoute(
              builder: (_) => StudentEventDetails(
                eventId: event['id'].toString(),
                initialEvent: event,
              ),
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
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      _studentChrome(context),
                      CourseThemeUtils.studentDarkFromPrimary(_studentPrimary(context)),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: _studentChrome(context).withValues(alpha: 0.22),
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
