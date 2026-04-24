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
import '../welcome_screen.dart';
import '../../services/notification_service.dart';
import '../../widgets/notifications_modal.dart';
import '../../widgets/animated_greeting_text.dart';
import '../../widgets/card_swap_widget.dart';
import '../../widgets/shiny_text.dart';
import '../../widgets/custom_loader.dart';
import '../../utils/event_time_utils.dart';
import '../../utils/course_theme_utils.dart';

class StudentHome extends StatefulWidget {
  const StudentHome({super.key});

  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends State<StudentHome> with WidgetsBindingObserver {
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
  Timer? _absenceScopeRefreshTimer;

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
    _loadData();
    _subscribeToNotifications();
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

  Future<void> _loadData() async {
    final user = await _authService.getCurrentUser();
    final userId = user?['id']?.toString() ?? '';
    
    // Initialize Realtime once user is known
    if (user != null) {
      if (userId.isNotEmpty) {
        _notifService.initRealtime(userId);
      }
    }

    final yearLevel = await _authService.getStudentYearLevel();
    final courseCode = await _authService.getStudentCourseCode();
    final events = await _eventService.getUpcomingEvents(
      yearLevel: yearLevel,
      courseCode: courseCode,
    );
    final unread = await _notifService.getUnreadCount(forceRefresh: true);
    final sections = await _authService.getSections();
    final filteredSections = _filterSectionsForDetectedCourse(sections, user);
    final pendingAbsenceScopes = userId.isNotEmpty
        ? await _eventService.getStudentPendingAbsenceScopes(studentId: userId)
        : <Map<String, dynamic>>[];
    String? selectedAbsenceScopeKey = _selectedAbsenceScopeKey;
    if (pendingAbsenceScopes.isEmpty) {
      selectedAbsenceScopeKey = null;
    } else {
      final hasExisting = selectedAbsenceScopeKey != null &&
          pendingAbsenceScopes.any(
            (scope) =>
                (scope['scope_key']?.toString() ?? '') == selectedAbsenceScopeKey,
          );
      selectedAbsenceScopeKey = hasExisting
          ? selectedAbsenceScopeKey
          : (pendingAbsenceScopes.first['scope_key']?.toString());
    }

    if (mounted) {
      setState(() {
        _user = user;
        _upcomingEvents = events;
        _unreadCount = unread;
        _sections = filteredSections;
        if (_selectedSectionId != null &&
            filteredSections.every(
              (section) => section['id']?.toString() != _selectedSectionId,
            )) {
          _selectedSectionId = null;
        }
        _pendingAbsenceScopes = pendingAbsenceScopes;
        _selectedAbsenceScopeKey = selectedAbsenceScopeKey;
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
      _loadData();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unreadSubscription?.cancel();
    _absenceScopeRefreshTimer?.cancel();
    _headerPageController.dispose();
    _absenceReasonController.dispose();
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
    // Note: Tab 2 (Index 2) is now the StudentScanScreen
    final screens = [
      _buildHomeContent(),
      const StudentEvents(),
      const StudentScanScreen(), 
      const StudentTickets(),
      StudentProfile(user: _user, onUpdate: _loadData),
    ];

    final bool needsSection = _user != null && _user!['section_id'] == null;
    final bool needsAbsenceReason =
        _user != null && _pendingAbsenceScopes.isNotEmpty;
    final gateMode = needsSection || needsAbsenceReason;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_currentIndex != 0) {
          setState(() => _currentIndex = 0);
        }
      },
      child: Scaffold(
        backgroundColor: gateMode ? const Color(0xFF09090B) : const Color(0xFFF9FAFB),
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
                      child: needsSection
                          ? _buildSectionSelection()
                          : (needsAbsenceReason
                              ? _buildAbsenceReasonLock()
                              : screens[_currentIndex]),
                    ),
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
                      onTap: () => setState(() => _currentIndex = 2),
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          color: _studentChrome(context),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: _studentChrome(context).withValues(alpha: 0.4),
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
      onTap: () => setState(() => _currentIndex = index),
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

  Widget _buildHomeContent() {
    final firstName = _user?['first_name'] as String? ?? 'Student';
    
    return RefreshIndicator(
      onRefresh: _loadData,
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
                                onPressed: () async {
                                  await _refreshUnreadCount();
                                  if (!mounted) return;
                                  final result = await showNotificationsModal(context);
                                  if (!mounted) return;
                                  if (result is int) {
                                    setState(() => _currentIndex = result);
                                  }
                                  await _refreshUnreadCount();
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

                    final eventsOnThisDay = _upcomingEvents.where((e) {
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
                            Container(
                              margin: const EdgeInsets.only(top: 2),
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isToday
                                    ? _studentDark(context)
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

