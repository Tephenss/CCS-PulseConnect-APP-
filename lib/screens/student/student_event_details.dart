import 'package:flutter/material.dart';
import '../../widgets/app_snackbar.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import '../../services/event_service.dart';
import '../../services/event_live_service.dart';
import '../../widgets/custom_loader.dart';
import 'student_ticket_view.dart';
import 'student_registration_requirements_page.dart';
import '../../utils/event_time_utils.dart';
import '../../utils/course_theme_utils.dart';
import '../../widgets/shiny_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/device_performance_service.dart';
import '../../utils/app_page_routes.dart';

class _EventDetailsSnapshot {
  final Map<String, dynamic> event;
  final List<Map<String, dynamic>> sessions;
  final bool isRegistered;
  final bool isRegistrationResolved;
  final bool isAccessDenied;
  final bool canRegisterNow;
  final bool approvalRequired;
  final bool requirementsRequired;
  final bool requirementsApproved;
  final String requirementsStatus;
  final String registrationMessage;
  final bool hasStudentRequirements;
  final int participantCount;
  final DateTime cachedAt;
  final String revision;

  const _EventDetailsSnapshot({
    required this.event,
    required this.sessions,
    required this.isRegistered,
    required this.isRegistrationResolved,
    required this.isAccessDenied,
    required this.canRegisterNow,
    required this.approvalRequired,
    required this.requirementsRequired,
    required this.requirementsApproved,
    required this.requirementsStatus,
    required this.registrationMessage,
    required this.hasStudentRequirements,
    required this.participantCount,
    required this.cachedAt,
    required this.revision,
  });
}

class StudentEventDetails extends StatefulWidget {
  final String eventId;
  final Map<String, dynamic>? initialEvent;

  const StudentEventDetails({
    super.key,
    required this.eventId,
    this.initialEvent,
  });

  /// Clears in-memory CTA cache (logout / account switch).
  static void clearUiCache([String? eventId]) {
    _StudentEventDetailsState.clearDetailsCache(eventId);
  }

  @override
  State<StudentEventDetails> createState() => _StudentEventDetailsState();
}

class _StudentEventDetailsState extends State<StudentEventDetails>
    with WidgetsBindingObserver {
  static final Map<String, _EventDetailsSnapshot> _detailsCache = {};
  static const Duration _detailsUiTtl = Duration(minutes: 3);

  static void clearDetailsCache([String? eventId]) {
    if (eventId == null || eventId.trim().isEmpty) {
      _detailsCache.clear();
      return;
    }
    final suffix = '|${eventId.trim()}';
    _detailsCache.removeWhere((key, _) => key.endsWith(suffix));
  }

  static String _detailsCacheKey(String eventId, String userId) {
    final event = eventId.trim();
    final user = userId.trim();
    if (event.isEmpty) return '';
    if (user.isEmpty) return event;
    return '$user|$event';
  }

  final _eventService = EventService();
  final _supabase = Supabase.instance.client;
  String _userId = '';
  Map<String, dynamic>? _event;
  bool _isLoading = true;
  bool _isRegistered = false;
  bool _isRegistrationResolved = false;
  bool _isRegistering = false;
  bool _isPrimaryActionInProgress = false;
  bool _isOpeningRequirements = false;
  bool _isAccessDenied = false;
  bool _canRegisterNow = false;
  bool _approvalRequired = false;
  bool _requirementsRequired = false;
  bool _requirementsApproved = false;
  String _requirementsStatus = '';
  String _registrationMessage = '';
  bool _hasStudentRequirements = false;
  int _participantCount = 0;
  List<Map<String, dynamic>> _eventSessions = [];
  bool _isRefreshingEvent = false;
  bool _eventCoverResolved = false;
  bool _pendingForceRefresh = false;
  bool _suppressCapacityRefresh = false;
  int _eventLoadToken = 0;
  Timer? _approvalRefreshTimer;
  Timer? _capacityRefreshTimer;
  Timer? _registrationAccessRefreshTimer;
  Timer? _livePulseDebounce;
  RealtimeChannel? _approvalChannel;
  RealtimeChannel? _capacityChannel;
  String _approvalChannelUserId = '';
  StreamSubscription<String>? _eventLiveSubscription;

  Color _studentPrimary(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
  Color _studentDark(BuildContext context) =>
      CourseThemeUtils.studentDarkFromPrimary(_studentPrimary(context));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hydrateInitialEventOnly();
    unawaited(_hydrateFromUserCache());
    _eventLiveSubscription = EventLiveService.instance.changes.listen(
      _onLiveEventPulse,
    );
    _loadEvent(silent: _event != null);
    _scheduleApprovalRefresh();
  }

  void _onLiveEventPulse(String reason) {
    if (!mounted) return;
    final eventId = widget.eventId;
    final targetsThisEvent =
        reason.contains(eventId) ||
        reason == 'events' ||
        reason.startsWith('events:') ||
        reason.contains('student_submissions') ||
        reason.contains('student_requirements') ||
        reason.contains('registration_access') ||
        reason.startsWith('push:student_requirements');

    if (!targetsThisEvent && !reason.startsWith('push:')) {
      return;
    }

    // Optimistic UI so Under Review → Approved doesn't wait on network.
    if (reason.contains('student_requirements_approved') &&
        (reason.contains(eventId) || reason.endsWith(eventId))) {
      _applyOptimisticRequirementsReview(approved: true);
    } else if (reason.contains('student_requirements_declined') &&
        (reason.contains(eventId) || reason.endsWith(eventId))) {
      _applyOptimisticRequirementsReview(approved: false);
    }

    _eventService.clearStudentRequirementsCache(eventId);
    _eventService.invalidateEventDetailCache(eventId);
    clearDetailsCache(eventId);
    // Coalesce bursts of realtime/push pulses — avoid stacking full reloads.
    _livePulseDebounce?.cancel();
    _livePulseDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || _isRefreshingEvent) return;
      unawaited(_loadEvent(silent: true, forceFresh: true));
    });
  }

  void _applyOptimisticRequirementsReview({required bool approved}) {
    if (!mounted) return;
    setState(() {
      if (_hasStudentRequirements ||
          _requirementsRequired ||
          _isRegistered ||
          (_event != null && !_eventLooksFree(_event!))) {
        _requirementsRequired = true;
      }
      _requirementsApproved = approved;
      _requirementsStatus = approved ? 'approved' : 'declined';
      if (!_isRegistered) {
        if (approved) {
          _canRegisterNow = true;
          _registrationMessage = '';
        } else {
          _canRegisterNow = false;
          if (_registrationMessage.isEmpty) {
            _registrationMessage =
                'Your documents were declined. Please update and resubmit.';
          }
        }
      } else if (approved) {
        _registrationMessage = '';
      }
      _isRegistrationResolved = true;
    });
    _storeDetailsSnapshot();
    _scheduleApprovalRefresh();
  }

  void _hydrateInitialEventOnly() {
    if (widget.initialEvent != null) {
      _event = Map<String, dynamic>.from(widget.initialEvent!);
      _isLoading = false;
      _eventCoverResolved =
          (_event?['cover_image_url']?.toString() ?? '').trim().isNotEmpty;
      // Event list data has no per-user payment/doc state — wait for load.
      _isRegistrationResolved = false;
      _approvalRequired = false;
      _canRegisterNow = false;
      _requirementsRequired = false;
      _requirementsApproved = false;
      _requirementsStatus = '';
      _registrationMessage = '';
    }
  }

  Future<void> _hydrateFromUserCache() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    if (userId.isEmpty || !mounted) return;

    _userId = userId;
    final loadTokenAtStart = _eventLoadToken;
    final cacheKey = _detailsCacheKey(widget.eventId, userId);
    final cached = _detailsCache[cacheKey];
    if (cached == null ||
        DateTime.now().difference(cached.cachedAt) > _detailsUiTtl) {
      return;
    }
    if (!mounted || loadTokenAtStart != _eventLoadToken) return;
    // Don't paint stale CTA over a load that already finished.
    if (_isRegistrationResolved && !_isLoading) return;

    _applySnapshot(cached);
    if (!mounted || loadTokenAtStart != _eventLoadToken) return;

    setState(() {
      _isLoading = false;
      _eventCoverResolved =
          (_event?['cover_image_url']?.toString() ?? '').trim().isNotEmpty;
      final paid = _event != null && !_eventLooksFree(_event!);
      if (paid &&
          _approvalRequired &&
          !_canRegisterNow &&
          !_isRegistered) {
        _isRegistrationResolved = true;
      } else if (_requirementsRequired &&
          !_requirementsApproved &&
          !_isRegistered) {
        _isRegistrationResolved = true;
      } else if (_isRegistered &&
          !(_requirementsRequired && !_requirementsApproved)) {
        _isRegistrationResolved = true;
      } else if (!paid &&
          !_isRegistered &&
          !_canRegisterNow &&
          !_approvalRequired &&
          !_isAccessDenied &&
          !_isRegistrationClosedForEvent()) {
        _isRegistrationResolved = false;
      }
    });
  }

  void _applySnapshot(_EventDetailsSnapshot snap) {
    _event = Map<String, dynamic>.from(snap.event);
    _eventSessions = List<Map<String, dynamic>>.from(
      snap.sessions.map((s) => Map<String, dynamic>.from(s)),
    );
    _isRegistered = snap.isRegistered;
    _isRegistrationResolved = snap.isRegistrationResolved;
    _isAccessDenied = snap.isAccessDenied;
    _canRegisterNow = snap.canRegisterNow;
    _approvalRequired = snap.approvalRequired;
    _requirementsRequired = snap.requirementsRequired;
    _requirementsApproved = snap.requirementsApproved;
    _requirementsStatus = snap.requirementsStatus;
    _registrationMessage = snap.registrationMessage;
    if (_approvalRequired &&
        !_canRegisterNow &&
        !_isRegistered &&
        (_registrationMessage.isEmpty ||
            !_registrationMessage.contains('₱'))) {
      _registrationMessage = _settlePaymentMessage(_event);
    }
    _hasStudentRequirements = snap.hasStudentRequirements;
    _participantCount = snap.participantCount;
  }

  String _detailsRevision({
    required Map<String, dynamic> event,
    required bool isRegistered,
    required int participantCount,
    required String requirementsStatus,
    required bool requirementsApproved,
    bool? canRegisterNow,
    bool? approvalRequired,
  }) {
    return [
      event['updated_at']?.toString() ?? '',
      event['cover_image_url']?.toString() ?? '',
      event['status']?.toString() ?? '',
      event['registered_count']?.toString() ?? '',
      event['allow_registration']?.toString() ?? '',
      event['is_free_event']?.toString() ?? '',
      isRegistered ? '1' : '0',
      participantCount.toString(),
      requirementsStatus,
      requirementsApproved ? '1' : '0',
      canRegisterNow == true ? '1' : '0',
      approvalRequired == true ? '1' : '0',
    ].join('|');
  }

  void _storeDetailsSnapshot() {
    final event = _event;
    if (event == null || !_isRegistrationResolved) return;
    if (_userId.trim().isEmpty) return;

    final revision = _detailsRevision(
      event: event,
      isRegistered: _isRegistered,
      participantCount: _participantCount,
      requirementsStatus: _requirementsStatus,
      requirementsApproved: _requirementsApproved,
      canRegisterNow: _canRegisterNow,
      approvalRequired: _approvalRequired,
    );

    _detailsCache[_detailsCacheKey(widget.eventId, _userId)] = _EventDetailsSnapshot(
      event: Map<String, dynamic>.from(event),
      sessions: _eventSessions
          .map((s) => Map<String, dynamic>.from(s))
          .toList(growable: false),
      isRegistered: _isRegistered,
      isRegistrationResolved: _isRegistrationResolved,
      isAccessDenied: _isAccessDenied,
      canRegisterNow: _canRegisterNow,
      approvalRequired: _approvalRequired,
      requirementsRequired: _requirementsRequired,
      requirementsApproved: _requirementsApproved,
      requirementsStatus: _requirementsStatus,
      registrationMessage: _registrationMessage,
      hasStudentRequirements: _hasStudentRequirements,
      participantCount: _participantCount,
      cachedAt: DateTime.now(),
      revision: revision,
    );
  }

  @override
  void dispose() {
    // Invalidate any in-flight loads so they cannot call setState mid-pop.
    _eventLoadToken++;
    _eventLiveSubscription?.cancel();
    _approvalRefreshTimer?.cancel();
    _capacityRefreshTimer?.cancel();
    _registrationAccessRefreshTimer?.cancel();
    _livePulseDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);

    // Defer realtime teardown — sync unsubscribe during pop janks the transition.
    final approvalChannel = _approvalChannel;
    final capacityChannel = _capacityChannel;
    _approvalChannel = null;
    _capacityChannel = null;
    _approvalChannelUserId = '';

    super.dispose();

    scheduleMicrotask(() {
      approvalChannel?.unsubscribe();
      capacityChannel?.unsubscribe();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _approvalRefreshTimer?.cancel();
      _capacityRefreshTimer?.cancel();
      _registrationAccessRefreshTimer?.cancel();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _scheduleApprovalRefresh();
      _scheduleCapacityRefresh();
      _scheduleRegistrationAccessRefresh();
      _loadEvent(silent: true, forceFresh: true);
    }
  }

  void _scheduleApprovalRefresh() {
    _approvalRefreshTimer?.cancel();
    final pendingDocs = _requirementsRequired && !_requirementsApproved;
    if (!pendingDocs && (_isRegistered || _canRegisterNow || _isAccessDenied)) {
      return;
    }

    // Poll much faster while docs are under review so approve feels instant.
    final pendingReview = pendingDocs && _requirementsStatus == 'pending_review';
    final interval = pendingReview
        ? const Duration(seconds: 20)
        : const Duration(seconds: 60);

    _approvalRefreshTimer = Timer.periodic(interval, (_) {
      if (!mounted) return;
      final stillPending = _requirementsRequired && !_requirementsApproved;
      if (!stillPending && (_isRegistered || _canRegisterNow || _isAccessDenied)) {
        _approvalRefreshTimer?.cancel();
        return;
      }
      if (_requirementsStatus == 'pending_review' || stillPending) {
        _eventService.clearStudentRequirementsCache(widget.eventId);
      }
      unawaited(_loadEvent(silent: true, forceFresh: stillPending && _isRegistered));
    });
  }

  void _scheduleCapacityRefresh() {
    _capacityRefreshTimer?.cancel();

    final limit = _eventService.registrationLimitFromEvent(_event);
    if (limit == null || _isRegistered) {
      return;
    }

    _capacityRefreshTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!mounted || _isRegistered || _suppressCapacityRefresh) {
        _capacityRefreshTimer?.cancel();
        return;
      }
      unawaited(_loadEvent(silent: true));
    });
  }

  /// Poll while viewing details so Allow Registration toggles apply even if
  /// Supabase realtime is delayed/disabled for the events table.
  void _scheduleRegistrationAccessRefresh() {
    _registrationAccessRefreshTimer?.cancel();
    if (_isRegistered) return;

    // Keep this light — forceFresh every 5s was janking the UI (100+ skipped frames).
    _registrationAccessRefreshTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) {
        if (!mounted || _isRegistered || _isRefreshingEvent) {
          if (_isRegistered) _registrationAccessRefreshTimer?.cancel();
          return;
        }
        unawaited(_loadEvent(silent: true));
      },
    );
  }

  void _bindCapacityRealtime() {
    final limit = _eventService.registrationLimitFromEvent(_event);
    if (limit == null) {
      _capacityChannel?.unsubscribe();
      _capacityChannel = null;
      return;
    }

    _capacityChannel?.unsubscribe();
    _capacityChannel = _supabase.channel(
      'student_event_capacity:${widget.eventId}',
    );

    _capacityChannel!.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'events',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'id',
        value: widget.eventId,
      ),
      callback: (_) {
        if (_suppressCapacityRefresh || _isRegistered) return;
        unawaited(_loadEvent(silent: true));
      },
    );

    _capacityChannel!.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'event_registrations',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'event_id',
        value: widget.eventId,
      ),
      callback: (_) {
        if (_suppressCapacityRefresh || _isRegistered) return;
        unawaited(_loadEvent(silent: true));
      },
    );

    _capacityChannel!.subscribe();
  }

  bool _payloadAllowsRegistration(Map<String, dynamic> payload) {
    final approved = payload['approved'];
    final paymentStatus = (payload['payment_status']?.toString() ?? '')
        .trim()
        .toLowerCase();

    final approvedBool =
        approved == true ||
        (approved?.toString().trim().toLowerCase() == 'true') ||
        (approved?.toString().trim() == '1');

    return approvedBool || paymentStatus == 'paid' || paymentStatus == 'waived';
  }

  void _applyApprovedRegistrationState(String userId) {
    unawaited(
      _eventService.cacheApprovedRegistrationAccess(userId, widget.eventId),
    );
    if (!mounted) return;
    setState(() {
      _canRegisterNow = true;
      _approvalRequired = false;
      _registrationMessage = '';
      _isRegistrationResolved = true;
    });
    unawaited(_loadEvent(silent: true));
  }

  void _bindApprovalRealtime(String userId) {
    final trimmedUserId = userId.trim();
    if (trimmedUserId.isEmpty) {
      _approvalChannel?.unsubscribe();
      _approvalChannel = null;
      _approvalChannelUserId = '';
      return;
    }

    if (_approvalChannel != null && _approvalChannelUserId == trimmedUserId) {
      return;
    }

    _approvalChannel?.unsubscribe();
    _approvalChannelUserId = trimmedUserId;

    _approvalChannel = _supabase.channel(
      'public:student_registration_access:$trimmedUserId:${widget.eventId}',
    );

    _approvalChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_registration_access',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'student_id',
        value: trimmedUserId,
      ),
      callback: (payload) {
        final record = payload.newRecord.isNotEmpty
            ? payload.newRecord
            : payload.oldRecord;
        final eventId = (record['event_id']?.toString() ?? '').trim();
        if (eventId != widget.eventId) {
          return;
        }
        if (_payloadAllowsRegistration(record)) {
          _applyApprovedRegistrationState(trimmedUserId);
        }
      },
    );

    // Allow Registration toggle updates this event row — refresh CTA immediately.
    _approvalChannel!.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'events',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'id',
        value: widget.eventId,
      ),
      callback: (_) {
        _eventService.invalidateEventDetailCache(widget.eventId);
        clearDetailsCache(widget.eventId);
        unawaited(_loadEvent(silent: true, forceFresh: true));
      },
    );

    _approvalChannel!.subscribe();
  }

  bool _isRegistrationClosedForEvent() {
    if (_isRegistered || _event == null) return false;
    return _eventService.isEventAtCapacity(
          _event,
          participantCount: _participantCount,
        ) ||
        isEventRegistrationWindowClosed(_event!);
  }

  String _registrationClosedMessage() {
    if (_event != null &&
        _eventService.isEventAtCapacity(
          _event,
          participantCount: _participantCount,
        )) {
      return 'Registration is full for this event.';
    }
    return 'Registration is closed for this event.';
  }

  Map<String, dynamic>? _eventSeed() {
    if (_event != null) return Map<String, dynamic>.from(_event!);
    if (widget.initialEvent != null) {
      return Map<String, dynamic>.from(widget.initialEvent!);
    }
    return null;
  }

  Map<String, dynamic> _mergeEventData(
    Map<String, dynamic>? baseEvent,
    Map<String, dynamic>? registrationSettings,
  ) {
    final seed = _eventSeed();
    final merged = _eventService.mergeEventRegistrationSettings(
      baseEvent ?? seed,
      registrationSettings,
    );
    if (merged.isEmpty && seed != null) {
      return Map<String, dynamic>.from(seed);
    }

    final knownCover = [
      baseEvent?['cover_image_url'],
      seed?['cover_image_url'],
      widget.initialEvent?['cover_image_url'],
    ]
        .map((value) => (value ?? '').toString().trim())
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (knownCover.isNotEmpty &&
        (merged['cover_image_url'] ?? '').toString().trim().isEmpty) {
      merged['cover_image_url'] = knownCover;
    }

    return merged;
  }

  void _resolveCtaFailClosed() {
    if (!mounted) return;
    final paid = _event != null && !_eventLooksFree(_event!);
    setState(() {
      _isLoading = false;
      if (!_isRegistered && (paid || _approvalRequired)) {
        _approvalRequired = paid || _approvalRequired;
        _canRegisterNow = false;
        _requirementsRequired = false;
        _requirementsApproved = false;
        _requirementsStatus = '';
        _registrationMessage = _settlePaymentMessage(_event);
        _isRegistrationResolved = true;
      } else if (_isRegistered) {
        final pendingDocs = _requirementsRequired && !_requirementsApproved;
        // Keep checking until doc gate is known — don't flash wrong CTA.
        _isRegistrationResolved = !pendingDocs;
      } else {
        // Weak network on free events: keep Checking... — never guess Registered/Closed.
        _isRegistrationResolved = false;
      }
    });
  }

  Future<void> _loadEvent({bool silent = false, bool forceFresh = false}) async {
    if (_isRefreshingEvent) {
      if (forceFresh) _pendingForceRefresh = true;
      return;
    }
    _isRefreshingEvent = true;
    final loadToken = ++_eventLoadToken;
    final hasKnownCover =
        (_event?['cover_image_url']?.toString() ?? '').trim().isNotEmpty;
    if (mounted && !hasKnownCover) {
      setState(() => _eventCoverResolved = false);
    }

    final canStaySilent = silent || _event != null;
    if (!canStaySilent && mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      await _loadEventData(
        silent: canStaySilent,
        forceFresh: forceFresh,
        loadToken: loadToken,
      ).timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          if (!mounted || loadToken != _eventLoadToken) return;
          _resolveCtaFailClosed();
        },
      );
    } catch (_) {
      if (mounted && loadToken == _eventLoadToken) {
        if (_event == null && widget.initialEvent != null) {
          setState(() {
            _event = Map<String, dynamic>.from(widget.initialEvent!);
          });
        }
        if (!_isRegistrationResolved) {
          _resolveCtaFailClosed();
        } else if (!canStaySilent) {
          setState(() => _isLoading = false);
        }
      }
    } finally {
      if (loadToken == _eventLoadToken && mounted) {
        setState(() {
          _eventCoverResolved = true;
        });
      }
      if (loadToken == _eventLoadToken) {
        _isRefreshingEvent = false;
      }
      if (_pendingForceRefresh && mounted && loadToken == _eventLoadToken) {
        _pendingForceRefresh = false;
        // Defer chained refresh so we don't stack work on the same frame.
        scheduleMicrotask(() {
          if (!mounted || _isRefreshingEvent) return;
          unawaited(_loadEvent(silent: true, forceFresh: true));
        });
      }
    }
  }

  Future<void> _recoverEventRegistrationState() async {
    if (!mounted || _isRegistered) return;

    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    if (userId.isEmpty) {
      if (mounted) setState(() => _isRegistrationResolved = true);
      return;
    }

    try {
      final event = _event;
      final looksPaid = event != null && !_eventLooksFree(event);

      // Paid events: fail closed to Settle Payment — never invent Submit Docs.
      if (looksPaid) {
        if (mounted) {
          setState(() {
            _approvalRequired = true;
            _canRegisterNow = false;
            _requirementsRequired = false;
            _requirementsApproved = false;
            _requirementsStatus = '';
            _registrationMessage = _settlePaymentMessage(event);
            _isRegistrationResolved = true;
          });
        }
        return;
      }

      final requirementRows = await _eventService
          .fetchEventStudentRequirementsList(
            widget.eventId,
            studentId: userId,
          )
          .timeout(
            const Duration(seconds: 6),
            onTimeout: () => <Map<String, dynamic>>[],
          );

      if (!mounted) return;
      setState(() {
        _hasStudentRequirements = requirementRows.isNotEmpty;
        if (requirementRows.isNotEmpty && !_isRegistrationClosedForEvent()) {
          _requirementsRequired = true;
          _requirementsApproved = false;
          _requirementsStatus = _requirementsStatus.isEmpty
              ? 'incomplete'
              : _requirementsStatus;
          _canRegisterNow = false;
          if (_registrationMessage.isEmpty) {
            _registrationMessage =
                'Upload the required documents before registering.';
          }
        }
        _isRegistrationResolved = true;
      });
    } catch (_) {
      if (mounted) setState(() => _isRegistrationResolved = true);
    }
  }

  Future<void> _loadEventData({
    required bool silent,
    bool forceFresh = false,
    int loadToken = 0,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? '';
      _userId = userId;
      if (forceFresh) {
        _eventService.clearStudentRequirementsCache(widget.eventId);
        if (!_isRegistrationResolved) {
          clearDetailsCache(widget.eventId);
        }
      }
      _bindApprovalRealtime(userId);
      final missingCover =
          ((_event?['cover_image_url'] ?? '').toString().trim().isEmpty);
    final results = await Future.wait([
        _eventService.getEventById(
          widget.eventId,
          forceFresh: forceFresh || missingCover,
        ),
      _eventService.isRegistered(widget.eventId, userId),
        _eventService.getEventRegistrationSettings(
          widget.eventId,
          forceFresh: forceFresh,
        ),
      _eventService.getEventSessions(widget.eventId),
      ]).timeout(const Duration(seconds: 8));

      if (!mounted || loadToken != _eventLoadToken) return;

      final baseEvent = results[0] as Map<String, dynamic>?;
      final isRegisteredResult = results[1] as bool;
      var isReg = isRegisteredResult;
      final registrationSettings = results[2] as Map<String, dynamic>?;
    final sessions = results[3] as List<Map<String, dynamic>>;
      final event = _mergeEventData(baseEvent, registrationSettings);

      // Paint event content ASAP. If payment just cleared and registration flips
      // true, keep CTA unresolved until docs gate is known (no See Ticket flash).
      if (mounted && loadToken == _eventLoadToken) {
      setState(() {
          if (event.isNotEmpty) {
            _event = {
              ...?_event,
              ...event,
              if (sessions.isNotEmpty) ...{
                'event_mode': 'seminar_based',
                'uses_sessions': true,
                'event_structure': sessions.length > 1
                    ? 'two_seminars'
                    : 'one_seminar',
                'session_count': sessions.length,
              },
            };
          }
          _eventSessions = sessions;
          final becameRegistered = isReg && !_isRegistered;
        _isRegistered = isReg;
          final looksPaid =
              event.isNotEmpty ? !_eventLooksFree(event) : false;
          if (becameRegistered &&
              (looksPaid || _hasStudentRequirements) &&
              !_requirementsApproved) {
            _isRegistrationResolved = false;
            if (_hasStudentRequirements) {
              _requirementsRequired = true;
            }
          }
          _isLoading = false;
        });
      }

      List<dynamic> secondary;
      try {
        secondary = await Future.wait([
          _eventService.getRegistrationSnapshot(widget.eventId),
          _eventService.getParticipantCount(
            widget.eventId,
            eventHint: event.isNotEmpty ? event : null,
          ),
          if (!isReg && userId.isNotEmpty)
            _eventService.getTicketForEvent(widget.eventId, userId)
          else
            Future<Map<String, dynamic>>.value({}),
          if (event.isNotEmpty && userId.isNotEmpty)
            _eventService
                .getStudentRegistrationAvailability(
                  widget.eventId,
                  userId,
                  preloadedEvent: Map<String, dynamic>.from(event),
                )
                .timeout(
                  // Slow devices / weak networks were returning {} at 4s and the
                  // CTA wrongly became "Registration Closed" until a later refresh.
                  const Duration(seconds: 8),
                  onTimeout: () => <String, dynamic>{},
                )
          else
            Future<Map<String, dynamic>>.value({}),
          if (userId.isNotEmpty)
            _eventService
                .getStudentRequirementsInfo(widget.eventId, userId)
                .timeout(
                  const Duration(seconds: 10),
                  onTimeout: () => {'ok': false},
                )
          else
            Future<Map<String, dynamic>>.value({'ok': false}),
          if (userId.isNotEmpty)
            _eventService
                .fetchEventStudentRequirementsList(
                  widget.eventId,
                  studentId: userId,
                )
                .timeout(
                  const Duration(seconds: 10),
                  onTimeout: () => <Map<String, dynamic>>[],
                )
          else
            Future<List<Map<String, dynamic>>>.value([]),
        ]).timeout(const Duration(seconds: 14));
      } on TimeoutException {
        if (mounted && loadToken == _eventLoadToken) {
          // Don't flip to a different CTA on timeout — keep Checking... unless paid/settle.
          if (!_isRegistrationResolved) {
            _resolveCtaFailClosed();
          }
        }
        return;
      }

      if (!mounted || loadToken != _eventLoadToken) return;
      final snapshot = secondary[0] as Map<String, dynamic>?;
      final count = secondary[1] as int;
      final ticket = secondary[2] as Map<String, dynamic>;
      final availability = secondary[3] as Map<String, dynamic>;
      final reqInfo = secondary[4] as Map<String, dynamic>;
      final requirementRows = List<Map<String, dynamic>>.from(
        secondary[5] as List? ?? const [],
      );

      if (snapshot != null && event.isNotEmpty) {
        event.addAll(_eventService.applyRegistrationSnapshot(event, snapshot));
      }
      if (event.isNotEmpty) {
        event['registered_count'] = count;
      }

      if (!isReg && ticket.isNotEmpty) {
        isReg = true;
      }

      var accessDenied = false;
      var canRegisterNow = false;
      var approvalRequired = false;
      var requirementsRequired = false;
      var requirementsApproved = false;
      var requirementsStatus = '';
      var registrationMessage = '';
      var paymentCleared = false;
      final eventLooksPaid = event.isNotEmpty && !_eventLooksFree(event);

      if (event.isNotEmpty && !isReg && availability.isNotEmpty) {
        accessDenied = availability['targetAllowed'] == false;
        canRegisterNow = availability['allowed'] == true;
        approvalRequired = availability['approvalRequired'] == true;
        paymentCleared = availability['paymentCleared'] == true;
        requirementsRequired = availability['requirementsRequired'] == true;
        requirementsApproved = availability['requirementsApproved'] == true;
        requirementsStatus =
            (availability['requirementsStatus'] as String? ?? '').trim();
        registrationMessage = (availability['message'] as String? ?? '').trim();
        // Prefer priced settle copy whenever the event fee is known.
        if (approvalRequired && !canRegisterNow && eventLooksPaid) {
          registrationMessage = _settlePaymentMessage(event);
        }
      } else if (event.isNotEmpty && !isReg && availability.isEmpty) {
        // Live refresh / timeout must not invent Submit Documents for paid events.
        if (eventLooksPaid || _approvalRequired) {
          approvalRequired = true;
          canRegisterNow = false;
          requirementsRequired = false;
          registrationMessage = _settlePaymentMessage(event);
        } else {
          // Free event + empty availability = timed out / failed fetch.
          // Keep prior open state if we already know it; never invent Closed.
          canRegisterNow = _canRegisterNow;
          approvalRequired = _approvalRequired;
          requirementsRequired = _requirementsRequired;
          requirementsApproved = _requirementsApproved;
          requirementsStatus = _requirementsStatus;
          registrationMessage = _registrationMessage;
        }
      } else if (isReg) {
        canRegisterNow = false;
        approvalRequired = false;
        paymentCleared = true;
        registrationMessage = '';
        // Paid-event students are already registered after payment —
        // still surface document status when requirements exist.
        if (availability.isNotEmpty) {
          requirementsRequired = availability['requirementsRequired'] == true;
          requirementsApproved = availability['requirementsApproved'] == true;
          requirementsStatus =
              (availability['requirementsStatus'] as String? ?? '').trim();
        }
        // Sticky docs gate: don't drop to See Ticket if rows exist but
        // availability omitted the requirements flags this cycle.
        if (!requirementsApproved &&
            (requirementsRequired ||
                requirementRows.isNotEmpty ||
                _hasStudentRequirements)) {
          requirementsRequired = true;
        }
      }

      final resolvedCount = isReg && count < _participantCount
          ? _participantCount
          : count;
      final isRegistrationClosed = !isReg &&
          (_eventService.isEventAtCapacity(
                event.isNotEmpty ? event : null,
                participantCount: resolvedCount,
              ) ||
              (event.isNotEmpty && isEventRegistrationWindowClosed(event)));

      // Payment must be settled before documents for paid events.
      final paymentPending = !isReg &&
          (approvalRequired ||
              (eventLooksPaid && !paymentCleared && availability.isNotEmpty) ||
              (eventLooksPaid && availability.isEmpty));

      if (!paymentPending && reqInfo['ok'] == true && !isRegistrationClosed) {
        final reqs = List<Map<String, dynamic>>.from(
          reqInfo['requirements'] as List? ?? const [],
        );
        if (reqs.isNotEmpty) {
          final access = reqInfo['access'] is Map
              ? Map<String, dynamic>.from(reqInfo['access'] as Map)
              : <String, dynamic>{};
          requirementsRequired = true;
          requirementsApproved = access['approved'] == true;
          requirementsStatus = (access['status']?.toString() ?? '').trim();
          if (!requirementsApproved) {
            canRegisterNow = false;
            final reqMessage = (access['message']?.toString() ?? '').trim();
            if (!isReg) {
              registrationMessage = reqMessage.isNotEmpty
                  ? reqMessage
                  : 'Upload the required documents before registering.';
            } else if (reqMessage.isNotEmpty) {
              registrationMessage = reqMessage;
            } else {
              registrationMessage =
                  'Upload the required documents for this event.';
            }
          }
        }
      } else if (!paymentPending &&
          !isRegistrationClosed &&
          requirementRows.isNotEmpty) {
        requirementsRequired = true;
        if (!requirementsApproved) {
          canRegisterNow = false;
          requirementsStatus = requirementsStatus.isEmpty
              ? 'incomplete'
              : requirementsStatus;
          if (registrationMessage.isEmpty) {
            registrationMessage = isReg
                ? 'Upload the required documents for this event.'
                : 'Upload the required documents before registering.';
          }
        }
      } else if (paymentPending) {
        // Keep settle-payment state; hide document CTA until payment clears.
        requirementsRequired = false;
        requirementsApproved = false;
        requirementsStatus = '';
        canRegisterNow = false;
        approvalRequired = true;
        // Always prefer priced note when fee is on the event (avoid generic flash).
        registrationMessage = _settlePaymentMessage(event);
      }

      final hasStudentRequirements = requirementRows.isNotEmpty;

      if (isRegistrationClosed) {
        canRegisterNow = false;
        registrationMessage = _eventService.isEventAtCapacity(
              event.isNotEmpty ? event : null,
              participantCount: resolvedCount,
            )
            ? 'Registration is full for this event.'
            : 'Registration is closed for this event.';
      }

      // Free-event availability timed out: do not resolve as "Registration Closed".
      // Capacity / date-window closes are already known via isRegistrationClosed.
      final availabilityUnknown = !isReg &&
          !eventLooksPaid &&
          !approvalRequired &&
          availability.isEmpty &&
          !isRegistrationClosed &&
          !accessDenied &&
          !(requirementsRequired && !requirementsApproved);
      final needsDocStatus = isReg &&
          !isRegistrationClosed &&
          (requirementRows.isNotEmpty ||
              hasStudentRequirements ||
              _requirementsRequired ||
              _hasStudentRequirements ||
              eventLooksPaid);
      final reqInfoOk = reqInfo['ok'] == true;
      final docsGateUnknown = needsDocStatus &&
          !reqInfoOk &&
          !(silent && _isRegistrationResolved);
      final registrationResolved =
          (!availabilityUnknown || canRegisterNow || isReg) && !docsGateUnknown;

      if (mounted && loadToken == _eventLoadToken) {
        final cacheKey = _detailsCacheKey(widget.eventId, userId);
        final previous = cacheKey.isEmpty ? null : _detailsCache[cacheKey];
        final nextEvent = event.isNotEmpty ? event : _event;
        final nextRevision = nextEvent == null
            ? ''
            : _detailsRevision(
                event: nextEvent,
                isRegistered: isReg,
                participantCount: resolvedCount,
                requirementsStatus: requirementsStatus,
                requirementsApproved: requirementsApproved,
                canRegisterNow: canRegisterNow,
                approvalRequired: approvalRequired,
              );
        final unchanged =
            previous != null &&
            previous.revision == nextRevision &&
            (nextEvent?['cover_image_url']?.toString() ?? '')
                .trim()
                .isNotEmpty &&
            DateTime.now().difference(previous.cachedAt) <= _detailsUiTtl;

        setState(() {
          if (!unchanged || _event == null) {
            if (nextEvent != null) {
              _event = {
                ...?_event,
                ...nextEvent,
              };
            }
        _eventSessions = sessions;
            _participantCount = resolvedCount;
            _hasStudentRequirements = hasStudentRequirements;
          }
          // Always apply live registration CTA flags (Allow Registration toggle).
          _isRegistered = isReg;
          _isAccessDenied = accessDenied;
          if (registrationResolved) {
            _canRegisterNow = canRegisterNow;
            _approvalRequired = approvalRequired;
            _requirementsRequired = requirementsRequired;
            _requirementsApproved = requirementsApproved;
            _requirementsStatus = requirementsStatus;
            _registrationMessage = registrationMessage;
            _isRegistrationResolved = true;
          } else {
            // Stay on Checking... / Loading... — retry shortly.
            _isRegistrationResolved = false;
          }
        _isLoading = false;
      });
        if (registrationResolved) {
          _storeDetailsSnapshot();
        }
        _bindCapacityRealtime();
        _scheduleCapacityRefresh();
        _scheduleApprovalRefresh();
        _scheduleRegistrationAccessRefresh();
        if (!registrationResolved && mounted) {
          Future<void>.delayed(const Duration(milliseconds: 900), () {
            if (!mounted || _isRegistrationResolved || _isRefreshingEvent) {
              return;
            }
            unawaited(_loadEvent(silent: true, forceFresh: true));
          });
        }
      }
    } catch (_) {
      if (mounted && loadToken == _eventLoadToken) {
        if (_event == null && widget.initialEvent != null) {
          setState(() {
            _event = Map<String, dynamic>.from(widget.initialEvent!);
          });
        }
        _resolveCtaFailClosed();
      }
    }
  }

  Future<void> _handleRequirementsFlow() async {
    if (_event == null || _isOpeningRequirements) return;
    if (_isRegistrationClosedForEvent()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_registrationClosedMessage())),
        );
      }
      return;
    }

    setState(() => _isOpeningRequirements = true);
    try {
      final result = await Navigator.push<bool>(
        context,
        AppPageRoute(
          builder: (_) => StudentRegistrationRequirementsPage(
            eventId: widget.eventId,
            event: Map<String, dynamic>.from(_event!),
          ),
        ),
      );

      if (!mounted) return;
      if (result == true) {
        setState(() {
          _requirementsRequired = true;
          _requirementsApproved = false;
          _requirementsStatus = 'pending_review';
          if (_registrationMessage.isEmpty) {
            _registrationMessage =
                'Your documents are under review. Wait for teacher approval.';
          }
          _isRegistrationResolved = true;
        });
        _storeDetailsSnapshot();
        _eventService.clearStudentRequirementsCache(widget.eventId);
        StudentRegistrationRequirementsPage.clearPageCache(widget.eventId);
        unawaited(_loadEvent(silent: true, forceFresh: true));
        AppSnackBar.success(
          context,
          'Documents submitted. Wait for teacher approval.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isOpeningRequirements = false);
      } else {
        _isOpeningRequirements = false;
      }
    }
  }

  Future<void> _handlePrimaryAction() async {
    // Hard lock while gates are still loading / refreshing.
    if (!_isRegistrationResolved || _isRefreshingEvent) return;
    if (_isPrimaryActionInProgress) return;
    if (_isDocumentsUnderReview) return;
    _isPrimaryActionInProgress = true;
    if (mounted) setState(() {});

    try {
      // Paid: settle payment before any document / register CTA.
      if (_approvalRequired && !_canRegisterNow && !_isRegistered) {
        if (mounted) {
          AppSnackBar.warning(context, _registrationMessage.isNotEmpty ? _registrationMessage : _settlePaymentMessage());
        }
        return;
      }

      // Already registered (e.g. paid event after staff payment) —
      // documents come first if still pending (including post-payment race).
      if (_docsGateBlocksTicket) {
        if (_requirementsStatus == 'pending_review') return;
        await _handleRequirementsFlow();
        return;
      }

      if (_isRegistered) {
        await _handleViewTicket();
        return;
      }

      if (_isRegistrationClosedForEvent()) {
        if (mounted) {
        AppSnackBar.warning(context, _registrationClosedMessage());
        }
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? '';
      if (userId.isNotEmpty) {
        final requirements = await _eventService.fetchEventStudentRequirementsList(
          widget.eventId,
          studentId: userId,
        );
        if (requirements.isNotEmpty) {
          final reqInfo = await _eventService.getStudentRequirementsInfo(
            widget.eventId,
            userId,
          );
          final access = reqInfo['access'] is Map
              ? Map<String, dynamic>.from(reqInfo['access'] as Map)
              : <String, dynamic>{};
          final approved = access['approved'] == true;
          final status = (access['status']?.toString() ?? '').trim();

          if (mounted) {
            setState(() {
              _requirementsRequired = true;
              _requirementsApproved = approved;
              _requirementsStatus = status;
              if (!approved) {
                _canRegisterNow = false;
                _registrationMessage =
                    (access['message']?.toString() ?? '').trim().isNotEmpty
                    ? access['message'].toString()
                    : 'Upload the required documents before registering.';
              }
            });
          }

          if (!approved) {
            if (status == 'pending_review') {
              if (mounted) {
                AppSnackBar.info(context, 'Your documents are under review. Wait for teacher approval.');
              }
              return;
            }
            await _handleRequirementsFlow();
            return;
          }
        }
      }

      if (_docsGateBlocksTicket) {
        await _handleRequirementsFlow();
        return;
      }

      await _handleRegister();
    } finally {
      _isPrimaryActionInProgress = false;
      if (mounted) setState(() {});
    }
  }

  String _primaryActionLabel() {
    final registrationPaused = _isRegistrationResolved &&
        !_isRegistered &&
        !_canRegisterNow &&
        !_approvalRequired &&
        !_needsRequirementsAction;
    if (!_isRegistrationResolved) return 'Loading...';
    if (_approvalRequired && !_canRegisterNow && !_isRegistered) {
      return 'Settle Payment';
    }
    if ((_isRegistrationClosedForEvent() || registrationPaused) &&
        !_isRegistered) {
      return 'Registration Closed';
    }
    // After payment, registration can flip true before docs flags land.
    // Never flash See Ticket when this event has (or likely has) student docs.
    if (_docsGateBlocksTicket) {
      if (_requirementsStatus == 'pending_review') {
        return 'Under Review';
      }
      if (_requirementsStatus == 'declined') {
        return 'Resubmit Documents';
      }
      return 'Submit Documents';
    }
    if (_isRegistered) return 'See Ticket';
    if (_canRegisterNow) return 'Register';
    return 'Registration Closed';
  }

  /// Gold is reserved for See Ticket only — docs/register stay maroon.
  bool get _isTicketPrimaryAction =>
      _isRegistrationResolved &&
      _isRegistered &&
      !_docsGateBlocksTicket;

  /// True when the student must finish docs before ticket — including the
  /// short window right after payment where `_isRegistered` is already true
  /// but `_requirementsRequired` has not been set yet.
  bool get _docsGateBlocksTicket {
    if (_requirementsApproved) return false;
    if (_requirementsRequired && !_requirementsApproved) return true;
    if (!_isRegistered) return false;
    if (_hasStudentRequirements) return true;
    // Registered but secondary doc fetch still in flight — block ticket flash.
    if (!_isRegistrationResolved) return true;
    return false;
  }

  IconData _primaryActionIcon() {
    if (!_isRegistrationResolved) {
      return Icons.hourglass_top_rounded;
    }
    if ((_isRegistrationClosedForEvent() ||
            (_isRegistrationResolved &&
                !_isRegistered &&
                !_canRegisterNow &&
                !_approvalRequired &&
                !_needsRequirementsAction)) &&
        !_isRegistered) {
      return Icons.lock_outline_rounded;
    }
    if (_approvalRequired && !_canRegisterNow && !_isRegistered) {
      return Icons.payments_outlined;
    }
    if (_docsGateBlocksTicket) {
      if (_requirementsStatus == 'pending_review') {
        return Icons.hourglass_top_rounded;
      }
      return Icons.upload_file_rounded;
    }
    if (_isRegistered) return Icons.confirmation_num_rounded;
    if (_canRegisterNow) return Icons.how_to_reg_rounded;
    return Icons.lock_outline_rounded;
  }

  bool get _needsRequirementsAction =>
      !_isRegistrationClosedForEvent() &&
      !_approvalRequired &&
      _docsGateBlocksTicket &&
      _requirementsStatus != 'pending_review';

  bool _eventLooksFree(Map<String, dynamic> event) {
    final freeRaw =
        (event['is_free_event'] ?? true).toString().trim().toLowerCase();
    return freeRaw == 'true' ||
        freeRaw == '1' ||
        freeRaw == 't' ||
        freeRaw == 'yes' ||
        freeRaw == 'y' ||
        event['is_free_event'] == true;
  }

  double? _parseEventFee(Map<String, dynamic>? event) {
    if (event == null) return null;
    final feeRaw = event['event_fee'];
    if (feeRaw is num) return feeRaw.toDouble();
    return double.tryParse(
      (feeRaw?.toString() ?? '').trim().replaceAll(',', ''),
    );
  }

  /// Prefer the priced settle note (image 2) whenever fee is known — avoid the
  /// generic flash (image 1) while background refresh is still in flight.
  String _settlePaymentMessage([Map<String, dynamic>? event]) {
    final source = event ?? _event ?? widget.initialEvent;
    final fee = _parseEventFee(source);
    if (fee != null && fee > 0) {
      return 'Settle ₱${fee.toStringAsFixed(2)} with the authorized person assigned for this event before you can continue.';
    }
    return 'Settle your payment first with the authorized person assigned for this event.';
  }

  bool get _isDocumentsUnderReview =>
      _docsGateBlocksTicket && _requirementsStatus == 'pending_review';

  Future<void> _handleRegister() async {
    if (_docsGateBlocksTicket) {
      await _handleRequirementsFlow();
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    if (userId.isNotEmpty) {
      final reqInfo = await _eventService.getStudentRequirementsInfo(
        widget.eventId,
        userId,
      );
      if (reqInfo['ok'] == true) {
        final reqs = List<Map<String, dynamic>>.from(
          reqInfo['requirements'] as List? ?? const [],
        );
        final access = reqInfo['access'] is Map
            ? Map<String, dynamic>.from(reqInfo['access'] as Map)
            : <String, dynamic>{};
        if (reqs.isNotEmpty && access['approved'] != true) {
          if (mounted) {
            setState(() {
              _requirementsRequired = true;
              _requirementsApproved = false;
              _requirementsStatus = (access['status']?.toString() ?? '').trim();
              _canRegisterNow = false;
              _registrationMessage =
                  (access['message']?.toString() ?? '').trim().isNotEmpty
                  ? access['message'].toString()
                  : 'Upload the required documents before registering.';
            });
          }
          await _handleRequirementsFlow();
          return;
        }
      }
    }

    if (_approvalRequired && !_canRegisterNow) {
      await _loadEvent(silent: true);
    }

    final snapshot = await _eventService.getRegistrationSnapshot(widget.eventId);
    if (snapshot != null && snapshot['is_full'] == true) {
      await _loadEvent(silent: true);
      if (mounted) {
        AppSnackBar.error(context, 'Registration is full for this event.');
      }
      return;
    }

    if (_isAccessDenied || !_canRegisterNow) {
      if (mounted) {
        AppSnackBar.warning(context, _registrationMessage.isNotEmpty ? _registrationMessage : 'You are not allowed to register for this event.');
      }
      return;
    }

    setState(() => _isRegistering = true);

    final result = await _eventService.registerForEvent(widget.eventId, userId);

    if (result['requirements_required'] == true) {
      if (mounted) {
    setState(() => _isRegistering = false);
        await _handleRequirementsFlow();
      }
      return;
    }

    if (result['ok'] == true) {
      final nextCount = _participantCount + 1;

      if (mounted) {
      setState(() {
          _isRegistering = false;
        _isRegistered = true;
          _canRegisterNow = false;
          _approvalRequired = false;
          _registrationMessage = '';
          _participantCount = nextCount;
          _suppressCapacityRefresh = true;
        });
        _eventService.invalidateEventDetailCache(widget.eventId);
        unawaited(_eventService.invalidateMyTicketsCache(userId));
        _storeDetailsSnapshot();
      }

      // Tickets tab is kept alive in IndexedStack — pulse so it refetches now.
      EventLiveService.instance.pulseTicketsUi();

      _capacityRefreshTimer?.cancel();

      await Future<void>.delayed(const Duration(milliseconds: 450));
      unawaited(_loadEvent(silent: true));

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted) {
        setState(() => _suppressCapacityRefresh = false);
      }
      return;
    }

    if (mounted) {
      setState(() => _isRegistering = false);
      AppSnackBar.error(context, result['error'] as String? ?? 'Registration failed');
    }
  }

  Future<void> _handleViewTicket() async {
    setState(() => _isRegistering = true); // reuse loading state

    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? '';

      final myTicket = await _eventService
          .getTicketForEvent(widget.eventId, userId)
          .timeout(const Duration(seconds: 10));

      if (myTicket.isNotEmpty && mounted) {
        setState(() => _isRegistering = false);
        Navigator.push(
          context,
          AppPageRoute(
            builder: (_) => StudentTicketView(ticket: myTicket),
          ),
        );
      } else {
        if (mounted) {
          setState(() => _isRegistering = false);
          AppSnackBar.error(context, 'Could not load ticket details. Please check your network connection.');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isRegistering = false);
        AppSnackBar.error(context, 'Connection timeout or error. Please try again.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: PulseConnectLoader()),
      );
    }

    if (_event == null) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: _studentPrimary(context),
          title: const Text(
            'Event Details',
            style: TextStyle(color: Colors.white),
          ),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(
          child: Text(
            'Event not found',
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }

    if (_isAccessDenied) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: _studentPrimary(context),
          title: const Text(
            'Event Details',
            style: TextStyle(color: Colors.white),
          ),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 44,
                  color: _studentPrimary(context),
                ),
                const SizedBox(height: 12),
                const Text(
                  'This event is not available for your course/year level.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF374151),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final title = _event!['title'] as String? ?? 'Untitled';
    final description = _event!['description'] as String? ?? '';
    final location = _event!['location'] as String? ?? 'TBA';
    final startAt = _event!['start_at'] as String?;
    final endAt = _event!['end_at'] as String?;
    final eventType = _event!['event_type'] as String? ?? '';
    final coverImageUrl =
        (_event!['cover_image_url'] as String? ?? '').trim();
    final eventFor = (_event!['event_for'] as String?)?.trim() ?? 'all';
    final eventSpan = _event!['event_span'] as String? ?? '';
    final graceTime = _event!['grace_time']?.toString() ?? '';

    final startDate = parseStoredEventDateTime(startAt);
    final endDate = parseStoredEventDateTime(endAt);

    final isRegistrationClosed = _isRegistrationClosedForEvent() ||
        (_isRegistrationResolved &&
            !_isRegistered &&
            !_canRegisterNow &&
            !_approvalRequired &&
            !_needsRequirementsAction);
    final isDeclinedDocs = _requirementsStatus == 'declined';
    final registrationStatusLabel = !_isRegistrationResolved
        ? 'Checking...'
        : ((_approvalRequired && !_isRegistered && !_canRegisterNow)
              ? 'Settle Payment'
              : (_docsGateBlocksTicket
                    ? (_requirementsStatus == 'pending_review'
                          ? 'Under Review'
                          : (_requirementsStatus == 'declined'
                                ? 'Docs Declined'
                                : 'Docs Required'))
                    : (_isRegistered
                          ? 'Registered'
                          : (isRegistrationClosed
                                ? 'Closed'
                                : (_canRegisterNow ? 'Open' : 'Closed')))));
    final usesSessions =
        usesEventSessions(_event!) || _eventSessions.isNotEmpty;
    // Do NOT gate on `_isRefreshingEvent` — silent background refresh must not
    // grey-out a cached See Ticket / Register CTA while network is in flight.
    final canTapAction =
        !_isAccessDenied &&
        !_isRegistering &&
        !_isPrimaryActionInProgress &&
        !_isOpeningRequirements &&
        _isRegistrationResolved &&
        !_isDocumentsUnderReview &&
        (
          // See Ticket — only when docs are approved / not required
          (_isRegistered && !_docsGateBlocksTicket) ||
          // Submit / Resubmit documents (never while payment still required)
          (_needsRequirementsAction && !_approvalRequired) ||
          // Register only (settle payment stays non-tappable info CTA)
          (!_isRegistered &&
              !isRegistrationClosed &&
              _canRegisterNow));
    final isActionDisabled =
        _isDocumentsUnderReview ||
        !_isRegistrationResolved ||
        (!_isRegistered &&
            (isRegistrationClosed ||
                (!_canRegisterNow && !_needsRequirementsAction)));
    // Loader until we know the real per-user CTA.
    final isCtaLoading = _isRegistering ||
        _isPrimaryActionInProgress ||
        _isOpeningRequirements ||
        !_isRegistrationResolved;
    // Keep maroon while loading — gray is only for a truly unavailable action.
    final useDisabledGradient =
        isActionDisabled && !isCtaLoading && !_isTicketPrimaryAction;

    const coverExpandedHeight = 248.0;
    final topInset = MediaQuery.paddingOf(context).top;
    final coverCollapsedHeight = topInset + kToolbarHeight;

    return Scaffold(
      backgroundColor: Colors.white,
      body: ColoredBox(
        color: Colors.white,
        child: CustomScrollView(
          clipBehavior: Clip.hardEdge,
        slivers: [
          SliverAppBar(
              expandedHeight: coverExpandedHeight,
            pinned: true,
              stretch: true,
              elevation: 0,
              scrolledUnderElevation: 0,
              forceElevated: false,
              shadowColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              backgroundColor: Colors.black,
              automaticallyImplyLeading: false,
              leadingWidth: 0,
              titleSpacing: 0,
              flexibleSpace: LayoutBuilder(
                builder: (context, constraints) {
                  final minH = coverCollapsedHeight;
                  final maxH = coverExpandedHeight;
                  final range = (maxH - minH).clamp(1.0, 1000.0);
                  final expandT =
                      ((constraints.maxHeight - minH) / range).clamp(0.0, 1.0);
                  final collapseT = 1.0 - expandT;

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      // Cover always fills the collapsing header (no solid color bar).
                      // While cover URL is still loading, show PulseConnectLoader —
                      // never flash the calendar icon first.
                      if (coverImageUrl.isNotEmpty)
                        RepaintBoundary(
                          child: CachedNetworkImage(
                            imageUrl: coverImageUrl,
                            width: double.infinity,
                            height: double.infinity,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            fadeInDuration: Duration.zero,
                            fadeOutDuration: Duration.zero,
                            filterQuality: FilterQuality.high,
                            memCacheWidth: DevicePerformance.instance
                                .heroImageCacheWidth(context),
                            placeholder: (context, url) =>
                                _coverLoadingPlaceholder(context),
                            errorWidget: (context, url, error) =>
                                _coverFallbackGradient(context),
                          ),
                        )
                      else if (!_eventCoverResolved || _isRefreshingEvent)
                        _coverLoadingPlaceholder(context)
                      else
                        _coverFallbackGradient(context),
                      // Scrim: stronger when collapsed so toolbar icons stay readable
                      DecoratedBox(
                        decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                            colors: [
                              Color.lerp(
                                const Color(0x66000000),
                                const Color(0xB3000000),
                                collapseT,
                              )!,
                              Color.lerp(
                                const Color(0x00000000),
                                const Color(0x66000000),
                                collapseT,
                              )!,
                              Color.lerp(
                                const Color(0xB31A0A0A),
                                const Color(0xCC000000),
                                collapseT,
                              )!,
                            ],
                            stops: const [0.0, 0.45, 1.0],
                          ),
                        ),
                      ),
                      // Expanded title — same shine animation as "Ready to explore?"
                      Positioned(
                        left: 20,
                        right: 20,
                        bottom: 44 + (12 * collapseT),
                        child: Opacity(
                          opacity: (expandT * 1.35).clamp(0.0, 1.0),
                          child: Transform.translate(
                            offset: Offset(0, 10 * collapseT),
                            child: ShinyText(
                              text: title,
                              fontSize: 22,
                              speed: 2.5,
                              fontWeight: FontWeight.w900,
                              color: const Color(0xFFB5B5B5),
                              shineColor: Colors.white,
                              textAlign: TextAlign.left,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              shadows: const [
                                Shadow(
                                  color: Color(0x99000000),
                                  blurRadius: 8,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Compact title in collapsed toolbar
                      Positioned(
                        left: 64,
                        right: 20,
                        top: topInset,
                        height: kToolbarHeight,
                        child: Opacity(
                          opacity: (collapseT * 1.6 - 0.4).clamp(0.0, 1.0),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: ShinyText(
                              text: title,
                              fontSize: 16,
                              speed: 2.5,
                              fontWeight: FontWeight.w800,
                              color: const Color(0xFFB5B5B5),
                              shineColor: Colors.white,
                              textAlign: TextAlign.left,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
                      // Back button
                      Positioned(
                        left: 8,
                        top: topInset + 4,
                        child: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(12),
                ),
                            child: const Icon(
                              Icons.arrow_back_ios_rounded,
                              size: 18,
                              color: Colors.white,
                            ),
              ),
              onPressed: () => Navigator.pop(context),
                        ),
                      ),
                      // White left/right curve cut — painted ON TOP of cover so it's visible
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: Opacity(
                            opacity: expandT.clamp(0.0, 1.0),
                            child: const SizedBox(
                              height: 32,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(32),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            // Flat white sheet — curve lives only on the cover so no black crescent cut
          SliverToBoxAdapter(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Event Type Badge
                  if (eventType.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: _getEventTypeColor(
                          eventType,
                        ).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _getEventTypeIcon(eventType),
                            size: 16,
                            color: _getEventTypeColor(eventType),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            eventType,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _getEventTypeColor(eventType),
                            ),
                          ),
                        ],
                      ),
                    ),

                  _buildTopStatsGrid(
                    registrationStatusLabel: registrationStatusLabel,
                    eventSpan: eventSpan,
                  ),

                  const SizedBox(height: 28),

                  // Event Schedule & Info (aligned with website layout)
                  const Text(
                    'Event Schedule & Info',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F2937),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildScheduleInfoGrid(
                    startDate: startDate,
                    endDate: endDate,
                    location: location,
                    eventType: eventType,
                    eventFor: eventFor,
                    graceTime: graceTime,
                    event: _event!,
                    ),
                  if (usesSessions) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Seminar Sessions',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1F2937),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildSessionScheduleSection(),
                  ],

                  const SizedBox(height: 28),

                  // Description
                  if (description.isNotEmpty) ...[
                    const Text(
                      'Event Description',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1F2937),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade700,
                        height: 1.6,
                      ),
                    ),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
      // Bottom Register/Ticket Button
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isRegistrationResolved &&
                _registrationMessage.isNotEmpty &&
                !_isRegistered &&
                (_approvalRequired ||
                    _requirementsRequired ||
                    isRegistrationClosed ||
                    !_canRegisterNow)) ...[
              Container(
          width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: isDeclinedDocs
                      ? const Color(0xFFFEF2F2)
                      : _approvalRequired
                      ? const Color(0xFFFFF7ED)
                      : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDeclinedDocs
                        ? const Color(0xFFFECACA)
                        : _approvalRequired
                        ? const Color(0xFFFED7AA)
                        : const Color(0xFFE5E7EB),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isDeclinedDocs
                          ? Icons.error_outline_rounded
                          : _approvalRequired
                          ? Icons.verified_user_outlined
                          : Icons.info_outline_rounded,
                      size: 18,
                      color: isDeclinedDocs
                          ? const Color(0xFFDC2626)
                          : _approvalRequired
                          ? const Color(0xFFEA580C)
                          : const Color(0xFF6B7280),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _registrationMessage,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isDeclinedDocs
                              ? const Color(0xFFB91C1C)
                              : _approvalRequired
                              ? const Color(0xFF9A3412)
                              : const Color(0xFF374151),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            SizedBox(
              width: double.infinity,
              height: 60,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                    colors: _isTicketPrimaryAction
                    ? [const Color(0xFFD4A843), const Color(0xFFB8942F)]
                        : (useDisabledGradient
                              ? const [Color(0xFFE5E7EB), Color(0xFFD1D5DB)]
                              : [
                                  _studentDark(context),
                                  _studentPrimary(context),
                                ]),
              ),
              boxShadow: [
                BoxShadow(
                      color:
                          (_isTicketPrimaryAction
                          ? const Color(0xFFD4A843)
                                  : (useDisabledGradient
                                        ? const Color(0xFF9CA3AF)
                                        : _studentPrimary(context)))
                      .withValues(alpha: 0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ElevatedButton(
                  // Avoid Material "disabled" gray styling on the loader —
                  // use a no-op while loading so the maroon CTA stays branded.
                  onPressed: canTapAction
                      ? _handlePrimaryAction
                      : (isCtaLoading ? () {} : null),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                foregroundColor: Colors.white,
                    disabledForegroundColor: const Color(0xFF6B7280),
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
                  child: isCtaLoading
                      ? const PulseConnectLoader(size: 14, color: Colors.white)
                      : AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child: Row(
                            key: ValueKey(
                              _isTicketPrimaryAction
                                  ? 'ticket_action'
                                  : (_needsRequirementsAction ||
                                          (_requirementsRequired &&
                                              !_requirementsApproved)
                                        ? 'requirements_action'
                                        : 'register_action'),
                            ),
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                                _primaryActionIcon(),
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Text(
                                _primaryActionLabel(),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
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
    );
  }

  Widget _coverLoadingPlaceholder(BuildContext context) {
    return ColoredBox(
      color: _studentDark(context),
      child: const Center(
        child: PulseConnectLoader(
          size: 22,
          strokeWidth: 3.5,
          color: Color(0xFFD4A843),
        ),
      ),
    );
  }

  Widget _coverFallbackGradient(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _studentDark(context),
            _studentPrimary(context),
          ],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 48),
      child: Container(
            width: 64,
            height: 64,
        decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.1),
              border: Border.all(
                color: const Color(0xFFD4A843).withValues(alpha: 0.5),
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.event_rounded,
              color: Color(0xFFD4A843),
              size: 32,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopStatsGrid({
    required String registrationStatusLabel,
    required String eventSpan,
  }) {
    final screenWidth = MediaQuery.of(context).size.width;
    final availableWidth = screenWidth - 48;
    final hasSpan = eventSpan.isNotEmpty;
    final spacing = 8.0;
    final itemWidth = hasSpan
        ? ((availableWidth - (spacing * 2)) / 3)
        : ((availableWidth - spacing) / 2);

    final items = <Widget>[
      _buildInfoChip(
        Icons.people_rounded,
        _eventService.formatParticipantTotal(
          _participantCount,
          _event?['registration_limit'],
        ),
        'Participants',
        itemWidth,
      ),
      _buildInfoChip(
        _isRegistered
            ? Icons.confirmation_num_rounded
            : (_canRegisterNow
                  ? Icons.check_circle_rounded
                  : (_approvalRequired
                        ? Icons.lock_clock_rounded
                        : Icons.info_outline_rounded)),
        registrationStatusLabel,
        'Status',
        itemWidth,
      ),
    ];

    if (hasSpan) {
      items.add(
        _buildInfoChip(
          Icons.date_range_rounded,
          eventSpan == 'multi-day' || eventSpan == 'multi_day'
              ? 'Multi-Day'
              : 'Single',
          'Span',
          itemWidth,
      ),
    );
  }

    return Wrap(spacing: spacing, runSpacing: spacing, children: items);
  }

  Widget _buildInfoChip(
    IconData icon,
    String value,
    String label,
    double width,
  ) {
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF1F2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFECDD3)),
            ),
            child: Column(
              children: [
            Icon(icon, color: _studentPrimary(context), size: 22),
            const SizedBox(height: 6),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                value,
                key: ValueKey('$label-$value'),
                textAlign: TextAlign.center,
                  style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: _studentPrimary(context),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                softWrap: true,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
      ),
    );
  }

  Widget _buildSessionScheduleSection() {
    if (_eventSessions.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Text(
          'No seminar schedule found for this event yet.',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade700,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Column(
      children: _eventSessions.asMap().entries.map((entry) {
        final index = entry.key;
        final session = entry.value;
        final sessionStart = parseStoredEventDateTime(session['start_at']);
        final sessionEnd = parseStoredEventDateTime(session['end_at']);
        final rawTitle = (session['title']?.toString() ?? '').trim();
        final sessionTitle = rawTitle.isNotEmpty
            ? rawTitle
            : buildSessionDisplayName(session);

        return Container(
          width: double.infinity,
          margin: EdgeInsets.only(
            bottom: index == _eventSessions.length - 1 ? 0 : 12,
          ),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Seminar ${index + 1}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF6B7280),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                sessionTitle,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827),
                ),
              ),
              const SizedBox(height: 12),
              Column(
                children: [
                  _buildSessionMetaRow(
                    icon: Icons.calendar_today_rounded,
                    label: 'Date',
                    value: formatDateRange(sessionStart, sessionEnd),
                  ),
                  const SizedBox(height: 8),
                  _buildSessionMetaRow(
                    icon: Icons.schedule_rounded,
                    label: 'Time',
                    value: formatTimeRange(sessionStart, sessionEnd),
                  ),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildScheduleInfoGrid({
    required DateTime? startDate,
    required DateTime? endDate,
    required String location,
    required String eventType,
    required String eventFor,
    required String graceTime,
    required Map<String, dynamic> event,
  }) {
    final cards = <Widget>[
      _buildScheduleInfoCard(
        icon: Icons.calendar_month_rounded,
        title: 'Start Date & Time',
        value: startDate != null
            ? DateFormat('MMM d, yyyy, h:mm a').format(startDate)
            : 'TBA',
      ),
      _buildScheduleInfoCard(
        icon: Icons.event_available_rounded,
        title: 'End Date & Time',
        value: endDate != null
            ? DateFormat('MMM d, yyyy, h:mm a').format(endDate)
            : 'TBA',
      ),
    ];

    if (hasRegistrationDeadline(event)) {
      cards.add(
        _buildScheduleInfoCard(
          icon: Icons.event_busy_rounded,
          title: 'Registration Deadline',
          value: formatRegistrationDeadlineLabel(event),
          subtitle: registrationDeadlineSubtitle(event),
        ),
      );
    }

    cards.addAll([
      _buildScheduleInfoCard(
        icon: Icons.location_on_rounded,
        title: 'Location / Venue',
        value: location,
      ),
      _buildScheduleInfoCard(
        icon: _getEventTypeIcon(eventType),
        title: 'Event Type',
        value: eventType.isNotEmpty ? eventType : 'General Event',
      ),
    ]);

    final freeRaw = (event['is_free_event'] ?? true).toString().trim().toLowerCase();
    final isFreeEvent = freeRaw == 'true' ||
        freeRaw == '1' ||
        freeRaw == 't' ||
        freeRaw == 'yes' ||
        freeRaw == 'y' ||
        event['is_free_event'] == true;
    final feeRaw = event['event_fee'];
    double? fee;
    if (feeRaw is num) {
      fee = feeRaw.toDouble();
    } else {
      fee = double.tryParse(
        (feeRaw?.toString() ?? '').trim().replaceAll(',', ''),
      );
    }
    if (!isFreeEvent && fee != null && fee > 0) {
      cards.add(
        _buildScheduleInfoCard(
          icon: Icons.payments_outlined,
          title: 'Settlement Amount',
          value: '₱${fee.toStringAsFixed(2)}',
          subtitle: 'Pay this amount to the authorized person at school',
        ),
      );
    }

    cards.add(
      _buildScheduleInfoCard(
        icon: Icons.groups_rounded,
        title: 'Target Participants',
        value: _targetParticipantsLabel(eventFor),
        fullWidth: true,
      ),
    );

    if (graceTime.isNotEmpty) {
      cards.add(
        _buildScheduleInfoCard(
          icon: Icons.timer_rounded,
          title: 'Grace Time',
          value: '$graceTime min',
        ),
      );
    }

    return Wrap(spacing: 12, runSpacing: 12, children: cards);
  }

  Widget _buildScheduleInfoCard({
    required IconData icon,
    required String title,
    required String value,
    String? subtitle,
    bool fullWidth = false,
  }) {
    final screenWidth = MediaQuery.of(context).size.width;
    final horizontalPadding = 24.0;
    final wrapSpacing = 12.0;
    final availableWidth = screenWidth - (horizontalPadding * 2);
    final useTwoColumns = availableWidth >= 380;
    final cardWidth = (fullWidth || !useTwoColumns)
        ? availableWidth
        : ((availableWidth - wrapSpacing) / 2);

    return Container(
      width: cardWidth,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFFFFF1F2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: _studentPrimary(context), size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                  ),
                ),
                if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionMetaRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: const Color(0xFF6B7280)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F2937),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _targetParticipantsLabel(String value) {
    final normalized = value.toLowerCase();
    if (normalized.isEmpty || normalized == 'all') return 'All Year Levels';
    if (normalized == 'none') return 'No Target';
    final rawUpper = value.trim().toUpperCase();
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
    switch (normalized) {
      case '1':
        return '1st Year Students';
      case '2':
        return '2nd Year Students';
      case '3':
        return '3rd Year Students';
      case '4':
        return '4th Year Students';
      case 'bsit':
        return 'BSIT (All)';
      case 'bsit-sd':
        return 'BSIT-SD';
      case 'bsit-ba':
        return 'BSIT-BA';
      case 'bscs':
        return 'BSCS';
      default:
        return value;
    }
  }

  Color _getEventTypeColor(String type) {
    switch (type.toLowerCase()) {
      case 'seminar':
        return const Color(0xFF1D4ED8);
      case 'off-campus activity':
        return const Color(0xFF059669);
      case 'sports event':
        return const Color(0xFFD97706);
      case 'other':
        return const Color(0xFF7C3AED);
      default:
        return const Color(0xFF6B7280);
    }
  }

  IconData _getEventTypeIcon(String type) {
    switch (type.toLowerCase()) {
      case 'seminar':
        return Icons.school_rounded;
      case 'off-campus activity':
        return Icons.directions_bus_rounded;
      case 'sports event':
        return Icons.sports_basketball_rounded;
      case 'other':
        return Icons.category_rounded;
      default:
        return Icons.event_rounded;
    }
  }
}
