import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import '../../services/event_live_service.dart';
import '../../widgets/custom_loader.dart';
import 'student_event_details.dart';
import 'student_event_evaluation.dart';
import 'student_response_view.dart';
import '../../utils/event_time_utils.dart';
import '../../utils/course_theme_utils.dart';
import '../../utils/app_page_routes.dart';

class StudentEvents extends StatefulWidget {
  const StudentEvents({super.key});

  @override
  State<StudentEvents> createState() => _StudentEventsState();
}

class _StudentEventsState extends State<StudentEvents>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _eventService = EventService();
  final Connectivity _connectivity = Connectivity();
  List<Map<String, dynamic>> _activeEvents = [];
  List<Map<String, dynamic>> _expiredEvents = [];
  List<Map<String, dynamic>> _filteredActive = [];
  List<Map<String, dynamic>> _filteredExpired = [];
  final Map<String, bool> _expiredEvaluated = {};
  String _userId = '';
  bool _isLoading = true;

  // Filter state
  String _selectedEventType = 'All';

  late TabController _tabController;
  StreamSubscription<String>? _eventLiveSubscription;
  bool _isRefreshingEvents = false;
  int _eventsLoadGeneration = 0;

  Future<bool> _isOfflineNow() async {
    try {
      final connectivity = await _connectivity.checkConnectivity();
      return connectivity.isEmpty ||
          connectivity.every((result) => result == ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabSelection);
    _eventLiveSubscription = EventLiveService.instance.changes.listen((reason) {
      if (!mounted) return;
      if (!_isStudentEventsLiveReason(reason)) return;
      final offlinePulse = reason.startsWith('offline:');
      final needLoader = _activeEvents.isEmpty && _expiredEvents.isEmpty;
      // Live / push force network when online so deletes show up immediately.
      // Keep loader if we have nothing yet — avoids "No events" flash mid-fetch.
      unawaited(
        _loadEvents(
          showLoader: needLoader,
          forceFresh: !offlinePulse,
        ),
      );
    });
    // Cache paint first, then online catch-up so deleted events don't stick.
    unawaited(_bootstrapEvents());
  }

  Future<void> _bootstrapEvents() async {
    await _loadEvents(forceFresh: false);
    if (!mounted) return;
    if (!await _isOfflineNow()) {
      final needLoader = _activeEvents.isEmpty && _expiredEvents.isEmpty;
      await _loadEvents(showLoader: needLoader, forceFresh: true);
    }
  }

  bool _isStudentEventsLiveReason(String reason) {
    final offlinePulse = reason.startsWith('offline:');
    final core = offlinePulse ? reason.substring('offline:'.length) : reason;
    return core == 'events' ||
        core.startsWith('events') ||
        core == 'registrations' ||
        core.startsWith('registrations') ||
        core == 'registration_access' ||
        core.startsWith('registration_access') ||
        core.startsWith('push');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventLiveSubscription?.cancel();
    _tabController.removeListener(_handleTabSelection);
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Resume should feel live (catch deletes/archives while backgrounded).
      final needLoader = _activeEvents.isEmpty && _expiredEvents.isEmpty;
      _loadEvents(showLoader: needLoader, forceFresh: true);
    }
  }

  void _handleTabSelection() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == 1) {
      _reloadEventsSilently();
    }
  }

  Future<void> _reloadEventsSilently({bool forceFresh = false}) async {
    if (!mounted || _isRefreshingEvents) return;
    await _loadEvents(showLoader: false, forceFresh: forceFresh);
  }

  Future<void> _loadEvents({
    bool showLoader = true,
    bool forceFresh = false,
  }) async {
    if (_isRefreshingEvents && !forceFresh) return;
    final loadGen = ++_eventsLoadGeneration;
    _isRefreshingEvents = true;
    final hasCachedList = _activeEvents.isNotEmpty || _expiredEvents.isNotEmpty;
    if (showLoader && !hasCachedList && mounted) {
      setState(() => _isLoading = true);
    }
    try {
      final offline = await _isOfflineNow();
      final effectiveForceFresh = forceFresh && !offline;
      final prefs = await SharedPreferences.getInstance();

      final authService = AuthService();
      final user = await authService.getCurrentUser();
      final userId = user?['id']?.toString().trim().isNotEmpty == true
          ? user!['id'].toString().trim()
          : (prefs.getString('user_id') ?? '');

      // Same scope path as Home — avoid ALL/ALL false-empty while sections resolve.
      String? yearLevel;
      String? courseCode;
      String? specialization;
      if (userId.isNotEmpty) {
        try {
          final scope = await _eventService.getStudentTargetScope(userId);
          final scopedYear = (scope['yearLevel']?.toString() ?? '').trim();
          final scopedCourse = (scope['courseCode']?.toString() ?? '').trim();
          final scopedSpec = (scope['specialization']?.toString() ?? '').trim();
          yearLevel =
              scopedYear.isEmpty || scopedYear == 'ALL' ? null : scopedYear;
          courseCode = scopedCourse.isEmpty || scopedCourse == 'ALL'
              ? null
              : scopedCourse;
          specialization = scopedSpec.isEmpty ? null : scopedSpec;
        } catch (_) {
          // Fall through to AuthService helpers.
        }
      }
      yearLevel ??= await authService.getStudentYearLevel();
      courseCode ??= await authService.getStudentCourseCode();

      // Paint Active first — Evaluation fetch is heavy and was blocking empty/list.
      final active = await _eventService.getActiveEvents(
        yearLevel: yearLevel,
        courseCode: courseCode,
        specialization: specialization,
        forceFresh: effectiveForceFresh,
      );
      if (!mounted || loadGen != _eventsLoadGeneration) return;

      if (active.isEmpty &&
          _expiredEvents.isEmpty &&
          hasCachedList &&
          offline) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      if (mounted) {
        setState(() {
          _userId = userId;
          _activeEvents = active;
          _applyFilters();
          _isLoading = false;
        });
        _precacheEventCovers(active);
      }

      // Evaluation tab in background (don't gate Active on it).
      if (userId.isEmpty) {
        if (mounted && loadGen == _eventsLoadGeneration) {
          setState(() {
            _expiredEvents = [];
            _expiredEvaluated.clear();
            _applyFilters();
          });
        }
        return;
      }

      final expired = await _eventService.getExpiredEventsOpenForEvaluation(
        studentId: userId,
        yearLevel: yearLevel,
        forceFresh: effectiveForceFresh,
      );
      if (!mounted || loadGen != _eventsLoadGeneration) return;

      final evaluatedMap = <String, bool>{};
      for (final event in expired) {
        final eventId = event['id']?.toString() ?? '';
        if (eventId.isEmpty) continue;
        final rawBundle = event['evaluation_bundle'];
        final bundle = rawBundle is Map<String, dynamic>
            ? rawBundle
            : (rawBundle is Map
                ? Map<String, dynamic>.from(rawBundle)
                : <String, dynamic>{});
        evaluatedMap[eventId] = bundle['is_complete'] == true;
      }

      if (mounted) {
        setState(() {
          _expiredEvents = expired;
          _expiredEvaluated
            ..clear()
            ..addAll(evaluatedMap);
          _applyFilters();
        });
        _precacheEventCovers(expired);
      }
    } finally {
      // Stale generations must not clear loading or the refresh lock — a newer
      // load is still in flight and would flash "No active events found".
      if (loadGen == _eventsLoadGeneration) {
        _isRefreshingEvents = false;
        if (mounted && _isLoading) {
          setState(() => _isLoading = false);
        }
      }
    }
  }

  void _precacheEventCovers(List<Map<String, dynamic>> events) {
    if (!mounted) return;
    var count = 0;
    const maxCovers = 8;
    for (final event in events) {
      if (count >= maxCovers) break;
      final url = (event['cover_image_url'] ?? '').toString().trim();
      if (url.isEmpty) continue;
      count++;
      unawaited(
        precacheImage(
          CachedNetworkImageProvider(url, maxWidth: 800),
          context,
        ),
      );
    }
  }

  void _applyFilters() {
    _filteredActive = _filterList(_activeEvents);
    _filteredExpired = _sortedExpiredEvaluations(_filterList(_expiredEvents));
  }

  List<Map<String, dynamic>> _sortedExpiredEvaluations(
    List<Map<String, dynamic>> events,
  ) {
    final sorted = List<Map<String, dynamic>>.from(events);
    DateTime? endOf(Map<String, dynamic> event) {
      return DateTime.tryParse(
        event['effective_end_at']?.toString() ??
            event['end_at']?.toString() ??
            event['start_at']?.toString() ??
            '',
      );
    }

    sorted.sort((a, b) {
      final aId = a['id']?.toString() ?? '';
      final bId = b['id']?.toString() ?? '';
      final aDone = aId.isNotEmpty && (_expiredEvaluated[aId] ?? false);
      final bDone = bId.isNotEmpty && (_expiredEvaluated[bId] ?? false);
      if (aDone != bDone) return aDone ? 1 : -1;

      final aEnd = endOf(a);
      final bEnd = endOf(b);
      if (aEnd == null && bEnd == null) return 0;
      if (aEnd == null) return 1;
      if (bEnd == null) return -1;
      return bEnd.compareTo(aEnd);
    });
    return sorted;
  }

  Future<void> _openExpiredEvaluation(Map<String, dynamic> event) async {
    final eventId = event['id']?.toString() ?? '';
    if (eventId.isEmpty || _userId.isEmpty) return;

    final hasEvaluated = _expiredEvaluated[eventId] ?? false;
    if (hasEvaluated) {
      await Navigator.push(
        context,
        AppPageRoute(
          builder: (_) =>
              StudentResponseView(eventId: eventId, studentId: _userId),
        ),
      );
      return;
    }

    final success = await Navigator.push(
      context,
      AppPageRoute(
        builder: (_) =>
            StudentEventEvaluationScreen(eventId: eventId, studentId: _userId),
      ),
    );

    if (success == true && mounted) {
      var markedComplete = true;
      try {
        final bundle = await _eventService.getEvaluationBundle(
          eventId: eventId,
          studentId: _userId,
        );
        markedComplete = bundle['is_complete'] == true;
      } catch (_) {
        markedComplete = true; // submit succeeded — prefer submitted UI over stale open
      }
      if (mounted) {
        setState(() {
          _expiredEvaluated[eventId] = markedComplete;
          _applyFilters();
        });
      }
      await _loadEvents(showLoader: false, forceFresh: true);
    }
  }

  List<Map<String, dynamic>> _filterList(List<Map<String, dynamic>> events) {
    return events.where((e) {
      final type = e['event_type'] as String? ?? '';

      if (_selectedEventType != 'All' && type != _selectedEventType) {
        return false;
      }
      return true;
    }).toList();
  }

  void _showFilterSheet() {
    String tempType = _selectedEventType;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final primaryDark = CourseThemeUtils.studentChromeFromPrimary(
              Theme.of(context).colorScheme.primary,
            );
            return Container(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Handle bar
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Text(
                    'Filter Events',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F2937),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Event Type Section
                  const Text(
                    'Event Type',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children:
                        [
                          'All',
                          'Seminar',
                          'Off-Campus Activity',
                          'Sports Event',
                          'Other',
                        ].map((type) {
                          final selected = tempType == type;
                          return ChoiceChip(
                            label: Text(
                              type,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: selected
                                    ? Colors.white
                                    : const Color(0xFF374151),
                              ),
                            ),
                            selected: selected,
                            selectedColor: primaryDark,
                            backgroundColor: Colors.grey.shade100,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            side: BorderSide.none,
                            onSelected: (_) =>
                                setSheetState(() => tempType = type),
                          );
                        }).toList(),
                  ),
                  const SizedBox(height: 28),

                  // Action buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            setSheetState(() {
                              tempType = 'All';
                            });
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: primaryDark,
                            side: BorderSide(color: primaryDark),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'Reset',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: () {
                            setState(() {
                              _selectedEventType = tempType;
                              _applyFilters();
                            });
                            Navigator.pop(context);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryDark,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'Apply Filters',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  bool get _hasActiveFilter => _selectedEventType != 'All';

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final primaryDark = CourseThemeUtils.studentChromeFromPrimary(primaryColor);
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        title: const Text(
          'Events',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 28,
            color: Color(0xFF1F2937),
            letterSpacing: -0.5,
          ),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Stack(
              children: [
                IconButton(
                  icon: const Icon(
                    Icons.tune_rounded,
                    color: Color(0xFF4B5563),
                  ),
                  onPressed: _showFilterSheet,
                  tooltip: 'Filter Events',
                ),
                if (_hasActiveFilter)
                  Positioned(
                    right: 12,
                    top: 12,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFFD4A843),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(70),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(16),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              indicator: BoxDecoration(
                color: primaryDark,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: primaryDark.withValues(alpha: 0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              labelColor: Colors.white,
              unselectedLabelColor: const Color(0xFF6B7280),
              labelStyle: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
              unselectedLabelStyle: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
              tabs: const [
                Tab(text: 'Active'),
                Tab(text: 'Evaluation'),
              ],
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: PulseConnectLoader())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildEventList(
                  _filteredActive,
                  'No active events found',
                  isExpiredTab: false,
                ),
                _buildEventList(
                  _filteredExpired,
                  'No events open for evaluation yet',
                  isExpiredTab: true,
                ),
              ],
            ),
    );
  }

  Widget _buildEventList(
    List<Map<String, dynamic>> events,
    String emptyMessage, {
    required bool isExpiredTab,
  }) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final primaryDark = CourseThemeUtils.studentChromeFromPrimary(primaryColor);
    if (events.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.event_busy_rounded,
              size: 64,
              color: Colors.grey.shade300,
            ),
            const SizedBox(height: 16),
            Text(
              emptyMessage,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade500,
              ),
            ),
            if (_hasActiveFilter) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  setState(() {
                    _selectedEventType = 'All';
                    _applyFilters();
                  });
                },
                child: Text(
                  'Clear filters',
                  style: TextStyle(
                    color: primaryDark,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadEvents(forceFresh: true),
      color: primaryDark,
      child: ListView.builder(
        // Extra bottom space so the last card isn't hidden behind the floating nav bar.
        padding: EdgeInsets.fromLTRB(
          24,
          8,
          24,
          8 + 120 + MediaQuery.of(context).padding.bottom,
        ),
        itemCount: events.length,
        itemBuilder: (context, index) {
          final event = events[index];
          return _buildEventCard(event, showEvaluationActions: isExpiredTab);
        },
      ),
    );
  }

  Widget _buildEventCard(
    Map<String, dynamic> event, {
    required bool showEvaluationActions,
  }) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final primaryDark = CourseThemeUtils.studentChromeFromPrimary(primaryColor);
    final eventId = event['id']?.toString() ?? '';
    final title = event['title'] as String? ?? 'Untitled';
    final startAt = event['start_at'] as String?;
    final eventFor = _getTargetLabel(event['event_for']?.toString());
    String status = (event['status'] as String? ?? 'published').toLowerCase();

    final startDate = parseStoredEventDateTime(startAt);

    // Event becomes expired only after Early Out+1h or end_at+1h.
    if (status != 'archived' &&
        isEventPastLifecycleMap(event, now: DateTime.now())) {
      status = 'expired';
    }

    Color statusBg = const Color(0xFF064E3B);
    String displayStatus = status.toUpperCase();
    if (displayStatus == 'PENDING') {
      statusBg = const Color(0xFFD97706);
    } else if (displayStatus == 'REJECTED') {
      statusBg = const Color(0xFFEF4444);
    } else if (displayStatus == 'APPROVED') {
      statusBg = const Color(0xFF3B82F6);
    } else if (displayStatus == 'ARCHIVED' ||
        displayStatus == 'EXPIRED' ||
        displayStatus == 'FINISHED') {
      statusBg = const Color(0xFF6B7280);
    }

    final hasEvaluated =
        eventId.isNotEmpty && (_expiredEvaluated[eventId] ?? false);

    return GestureDetector(
      onTap: () async {
        if (showEvaluationActions) {
          await _openExpiredEvaluation(event);
        } else {
          await Navigator.push(
            context,
            AppPageRoute(
              builder: (_) => StudentEventDetails(
                eventId: event['id'].toString(),
                initialEvent: event,
              ),
            ),
          );
        }
        // Defer list refresh until after the pop animation settles.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(_loadEvents(showLoader: false));
        });
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            children: [
              Positioned(
                right: -10,
                bottom: -10,
                child: Opacity(
                  opacity: 0.08,
                  child: Image.asset(
                    'assets/CCS.png',
                    width: 160,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox(),
                  ),
                ),
              ),

              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 75,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            primaryDark,
                            CourseThemeUtils.studentDarkFromPrimary(
                              primaryColor,
                            ),
                          ],
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            startDate != null
                                ? DateFormat('dd').format(startDate)
                                : '--',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 28,
                              height: 1.1,
                              letterSpacing: -1,
                            ),
                          ),
                          Text(
                            startDate != null
                                ? DateFormat(
                                    'MMM',
                                  ).format(startDate).toUpperCase()
                                : '---',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              letterSpacing: 1.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            height: 2,
                            width: 12,
                            decoration: BoxDecoration(
                              color: const Color(0xFFD4A843),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Content
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: statusBg.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                displayStatus,
                                style: TextStyle(
                                  color: statusBg,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            Text(
                              title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                                color: Color(0xFF111827),
                                letterSpacing: -0.3,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3F4F6),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(
                                    Icons.people_rounded,
                                    size: 12,
                                    color: Color(0xFF4B5563),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'For: ${eventFor.isEmpty ? 'All' : eventFor}',
                                    style: const TextStyle(
                                      color: Color(0xFF374151),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3F4F6),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(
                                    Icons.schedule_rounded,
                                    size: 12,
                                    color: Color(0xFF4B5563),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    startDate != null
                                        ? DateFormat(
                                            'MMM dd, yyyy  -  h:mm a',
                                          ).format(startDate)
                                        : 'TBA',
                                    style: const TextStyle(
                                      color: Color(0xFF6B7280),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            if (showEvaluationActions) ...[
                              const SizedBox(height: 12),
                              InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () => _openExpiredEvaluation(event),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: hasEvaluated
                                        ? const Color(0xFFECFDF5)
                                        : const Color(0xFFFFF7ED),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: hasEvaluated
                                          ? const Color(
                                              0xFF16A34A,
                                            ).withValues(alpha: 0.25)
                                          : const Color(
                                              0xFFD4A843,
                                            ).withValues(alpha: 0.35),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        hasEvaluated
                                            ? Icons.fact_check_rounded
                                            : Icons.rate_review_rounded,
                                        size: 16,
                                        color: hasEvaluated
                                            ? const Color(0xFF166534)
                                            : const Color(0xFF92400E),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          hasEvaluated
                                              ? 'Evaluation submitted - view response'
                                              : 'Evaluation open - tap to answer',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: hasEvaluated
                                                ? const Color(0xFF166534)
                                                : const Color(0xFF92400E),
                                          ),
                                        ),
                                      ),
                                      Icon(
                                        Icons.chevron_right,
                                        size: 16,
                                        color: hasEvaluated
                                            ? const Color(0xFF166534)
                                            : const Color(0xFF92400E),
                                      ),
                                    ],
                                  ),
                                ),
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
    );
  }

  String _getTargetLabel(String? val) {
    if (val == null || val.toLowerCase() == 'all') return 'All Year Levels';
    if (val.toLowerCase() == 'none') return 'No Target';
    final rawUpper = val.trim().toUpperCase();
    final multi = RegExp(
      r'^COURSE\s*=\s*(ALL|BSIT-SD|BSIT-BA|BSIT|BSCS)\s*;\s*YEARS\s*=\s*([0-9,\sA-Z]+)$',
    ).firstMatch(rawUpper);
    if (multi != null) {
      final courseRaw = multi.group(1) ?? 'ALL';
      final course = courseRaw == 'ALL'
          ? 'All Courses'
          : (courseRaw == 'BSIT' ? 'BSIT (All)' : courseRaw);
      final yearsRaw = (multi.group(2) ?? '')
          .split(',')
          .map((e) => e.trim().toUpperCase())
          .where((e) => ['1', '2', '3', '4'].contains(e))
          .toList();
      const yearLabel = {
        '1': '1st Year',
        '2': '2nd Year',
        '3': '3rd Year',
        '4': '4th Year',
      };
      final years = yearsRaw.isEmpty
          ? 'All Levels'
          : yearsRaw.map((y) => yearLabel[y] ?? y).join(', ');
      return '$course - $years';
    }
    if (rawUpper == 'BSIT') return 'BSIT (All)';
    if (rawUpper == 'BSIT-SD') return 'BSIT-SD';
    if (rawUpper == 'BSIT-BA') return 'BSIT-BA';
    if (rawUpper == 'BSCS') return 'BSCS';
    final map = {
      '1': '1st Year',
      '2': '2nd Year',
      '3': '3rd Year',
      '4': '4th Year',
    };
    return map[val] ?? val;
  }
}
