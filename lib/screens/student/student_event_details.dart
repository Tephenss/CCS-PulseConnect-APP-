import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';
import 'student_ticket_view.dart';
import 'student_registration_requirements_page.dart';
import '../../utils/event_time_utils.dart';
import '../../utils/course_theme_utils.dart';

class StudentEventDetails extends StatefulWidget {
  final String eventId;
  final Map<String, dynamic>? initialEvent;

  const StudentEventDetails({
    super.key,
    required this.eventId,
    this.initialEvent,
  });

  @override
  State<StudentEventDetails> createState() => _StudentEventDetailsState();
}

class _StudentEventDetailsState extends State<StudentEventDetails>
    with WidgetsBindingObserver {
  final _eventService = EventService();
  final _supabase = Supabase.instance.client;
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
  bool _suppressCapacityRefresh = false;
  Timer? _approvalRefreshTimer;
  Timer? _capacityRefreshTimer;
  RealtimeChannel? _approvalChannel;
  RealtimeChannel? _capacityChannel;
  String _approvalChannelUserId = '';

  Color _studentPrimary(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
  Color _studentDark(BuildContext context) =>
      CourseThemeUtils.studentDarkFromPrimary(_studentPrimary(context));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialEvent != null) {
      _event = Map<String, dynamic>.from(widget.initialEvent!);
      _isLoading = false;
      _isRegistrationResolved = false;
    }
    _loadEvent();
  }

  @override
  void dispose() {
    _approvalRefreshTimer?.cancel();
    _capacityRefreshTimer?.cancel();
    _approvalChannel?.unsubscribe();
    _capacityChannel?.unsubscribe();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadEvent(silent: true);
    }
  }

  void _scheduleApprovalRefresh() {
    _approvalRefreshTimer?.cancel();
    if (_isRegistered || _canRegisterNow || _isAccessDenied) {
      return;
    }

    _approvalRefreshTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted) return;
      if (_isRegistered || _canRegisterNow || _isAccessDenied) {
        _approvalRefreshTimer?.cancel();
        return;
      }
      unawaited(_loadEvent(silent: true));
    });
  }

  void _scheduleCapacityRefresh() {
    _capacityRefreshTimer?.cancel();

    final limit = _eventService.registrationLimitFromEvent(_event);
    if (limit == null || _isRegistered) {
      return;
    }

    _capacityRefreshTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _isRegistered || _suppressCapacityRefresh) {
        _capacityRefreshTimer?.cancel();
        return;
      }
      unawaited(_loadEvent(silent: true));
    });
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

    final signalId = 'reg_access_approved_${widget.eventId}';
    _approvalChannel = _supabase.channel(
      'public:student_registration_access:$trimmedUserId:${widget.eventId}',
    );

    _approvalChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'user_notification_reads',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: trimmedUserId,
      ),
      callback: (payload) {
        final record = payload.newRecord.isNotEmpty
            ? payload.newRecord
            : payload.oldRecord;
        final notificationId = (record['notification_id']?.toString() ?? '')
            .trim();
        if (notificationId == signalId) {
          _applyApprovedRegistrationState(trimmedUserId);
        }
      },
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

  Future<void> _loadEvent({bool silent = false}) async {
    if (_isRefreshingEvent) return;
    _isRefreshingEvent = true;

    if (!silent && mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      await _loadEventData(silent: silent).timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          if (!mounted) return;
          setState(() {
            if (_event == null && widget.initialEvent != null) {
              _event = Map<String, dynamic>.from(widget.initialEvent!);
            }
            _isLoading = false;
          });
          unawaited(_recoverEventRegistrationState());
        },
      );
    } catch (_) {
      if (mounted && !silent) {
        setState(() {
          if (_event == null && widget.initialEvent != null) {
            _event = Map<String, dynamic>.from(widget.initialEvent!);
          }
          _isLoading = false;
        });
        if (!_isRegistrationResolved) {
          unawaited(_recoverEventRegistrationState());
        }
      }
    } finally {
      _isRefreshingEvent = false;
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

  Future<void> _loadEventData({required bool silent}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? '';
      _bindApprovalRealtime(userId);
      final results = await Future.wait([
        _eventService.getEventById(widget.eventId),
        _eventService.isRegistered(widget.eventId, userId),
        _eventService.getEventRegistrationSettings(widget.eventId),
        _eventService.getEventSessions(widget.eventId),
      ]).timeout(const Duration(seconds: 12));

      final baseEvent = results[0] as Map<String, dynamic>?;
      var isReg = results[1] as bool || _isRegistered;
      final registrationSettings = results[2] as Map<String, dynamic>?;
      final sessions = results[3] as List<Map<String, dynamic>>;
      final event = _eventService.mergeEventRegistrationSettings(
        baseEvent,
        registrationSettings,
      );

      final secondary = await Future.wait([
        _eventService.getRegistrationSnapshot(widget.eventId),
        _eventService.getParticipantCount(
          widget.eventId,
          eventHint: event.isNotEmpty ? event : null,
        ),
        if (!isReg && userId.isNotEmpty)
          _eventService.getTicketForEvent(widget.eventId, userId)
        else
          Future<Map<String, dynamic>>.value({}),
        if (event.isNotEmpty && !isReg && userId.isNotEmpty)
          _eventService.getStudentRegistrationAvailability(
            widget.eventId,
            userId,
            preloadedEvent: Map<String, dynamic>.from(event),
          )
        else
          Future<Map<String, dynamic>>.value({}),
        if (userId.isNotEmpty)
          _eventService
              .getStudentRequirementsInfo(widget.eventId, userId)
              .timeout(
                const Duration(seconds: 5),
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
                const Duration(seconds: 6),
                onTimeout: () => <Map<String, dynamic>>[],
              )
        else
          Future<List<Map<String, dynamic>>>.value([]),
      ]);

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

      if (event.isNotEmpty && !isReg && availability.isNotEmpty) {
        accessDenied = availability['targetAllowed'] == false;
        canRegisterNow = availability['allowed'] == true;
        approvalRequired = availability['approvalRequired'] == true;
        requirementsRequired = availability['requirementsRequired'] == true;
        requirementsApproved = availability['requirementsApproved'] == true;
        requirementsStatus =
            (availability['requirementsStatus'] as String? ?? '').trim();
        registrationMessage = (availability['message'] as String? ?? '').trim();
      } else if (isReg) {
        canRegisterNow = false;
        approvalRequired = false;
        registrationMessage = '';
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

      if (reqInfo['ok'] == true && !isRegistrationClosed) {
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
            registrationMessage = reqMessage.isNotEmpty
                ? reqMessage
                : 'Upload the required documents before registering.';
          }
        }
      } else if (!isRegistrationClosed && requirementRows.isNotEmpty) {
        requirementsRequired = true;
        if (!requirementsApproved) {
          canRegisterNow = false;
          requirementsStatus = requirementsStatus.isEmpty
              ? 'incomplete'
              : requirementsStatus;
          if (registrationMessage.isEmpty) {
            registrationMessage =
                'Upload the required documents before registering.';
          }
        }
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

      if (mounted) {
        setState(() {
          _event = event.isNotEmpty ? event : _event;
          _isRegistered = isReg;
          _isAccessDenied = accessDenied;
          _canRegisterNow = canRegisterNow;
          _approvalRequired = approvalRequired;
          _requirementsRequired = requirementsRequired;
          _requirementsApproved = requirementsApproved;
          _requirementsStatus = requirementsStatus;
          _registrationMessage = registrationMessage;
          _hasStudentRequirements = hasStudentRequirements;
          _participantCount = resolvedCount;
          _eventSessions = sessions;
          _isRegistrationResolved = true;
          _isLoading = false;
        });
        _bindCapacityRealtime();
        _scheduleCapacityRefresh();
        _scheduleApprovalRefresh();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          if (_event == null && widget.initialEvent != null) {
            _event = Map<String, dynamic>.from(widget.initialEvent!);
          }
          _isLoading = false;
        });
        if (!_isRegistrationResolved) {
          unawaited(_recoverEventRegistrationState());
        }
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
        MaterialPageRoute(
          builder: (_) => StudentRegistrationRequirementsPage(
            eventId: widget.eventId,
            event: Map<String, dynamic>.from(_event!),
          ),
        ),
      );

      if (!mounted) return;
      await _loadEvent(silent: true);
      if (result == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Documents submitted. Wait for teacher approval.'),
          ),
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
    if (_isPrimaryActionInProgress) return;
    _isPrimaryActionInProgress = true;
    if (mounted) setState(() {});

    try {
      if (_isRegistered) {
        await _handleViewTicket();
        return;
      }

      if (_isRegistrationClosedForEvent()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_registrationClosedMessage())),
          );
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Your documents are under review. Wait for teacher approval.',
                    ),
                  ),
                );
              }
              return;
            }
            await _handleRequirementsFlow();
            return;
          }
        }
      }

      if (_requirementsRequired && !_requirementsApproved) {
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
    if (_isRegistered) return 'See Ticket';
    if (_isRegistrationClosedForEvent()) return 'Registration Closed';
    if (_requirementsRequired && !_requirementsApproved) {
      if (_requirementsStatus == 'pending_review') {
        return 'Under Review';
      }
      if (_requirementsStatus == 'declined') {
        return 'Resubmit Documents';
      }
      return 'Submit Documents';
    }
    if (_canRegisterNow) return 'Register';
    if (_approvalRequired) return 'Approval Required';
    if (_hasStudentRequirements && _requirementsRequired && !_requirementsApproved) {
      return 'Submit Documents';
    }
    if (!_isRegistrationResolved) return 'Loading...';
    return 'Register';
  }

  IconData _primaryActionIcon() {
    if (_isRegistered) return Icons.confirmation_num_rounded;
    if (_isRegistrationClosedForEvent()) return Icons.lock_outline_rounded;
    if (_requirementsRequired && !_requirementsApproved) {
      if (_requirementsStatus == 'pending_review') {
        return Icons.hourglass_top_rounded;
      }
      return Icons.upload_file_rounded;
    }
    if (_approvalRequired) return Icons.lock_clock_rounded;
    return Icons.how_to_reg_rounded;
  }

  bool get _needsRequirementsAction =>
      !_isRegistrationClosedForEvent() &&
      _requirementsRequired &&
      !_requirementsApproved &&
      _requirementsStatus != 'pending_review';

  Future<void> _handleRegister() async {
    if (_requirementsRequired && !_requirementsApproved) {
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Registration is full for this event.'),
          ),
        );
      }
      return;
    }

    if (_isAccessDenied || !_canRegisterNow) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _registrationMessage.isNotEmpty
                  ? _registrationMessage
                  : 'You are not allowed to register for this event.',
            ),
          ),
        );
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
      }

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['error'] as String? ?? 'Registration failed'),
          backgroundColor: _studentPrimary(context),
        ),
      );
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
          MaterialPageRoute(
            builder: (_) => StudentTicketView(ticket: myTicket),
          ),
        );
      } else {
        if (mounted) {
          setState(() => _isRegistering = false);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not load ticket details. Please check your network connection.',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isRegistering = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection timeout or error. Please try again.'),
          ),
        );
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
    final eventFor = (_event!['event_for'] as String?)?.trim() ?? 'all';
    final eventSpan = _event!['event_span'] as String? ?? '';
    final graceTime = _event!['grace_time']?.toString() ?? '';

    final startDate = parseStoredEventDateTime(startAt);
    final endDate = parseStoredEventDateTime(endAt);

    final isRegistrationClosed = _isRegistrationClosedForEvent();
    final isDeclinedDocs = _requirementsStatus == 'declined';
    final registrationStatusLabel = _isRegistered
        ? 'Registered'
        : (isRegistrationClosed
              ? 'Closed'
              : (_requirementsRequired && !_requirementsApproved
                    ? (_requirementsStatus == 'pending_review'
                          ? 'Under Review'
                          : (_requirementsStatus == 'declined'
                                ? 'Docs Declined'
                                : 'Docs Required'))
                    : (_canRegisterNow
                          ? 'Open'
                          : (_approvalRequired
                                ? 'Approval Required'
                                : (_hasStudentRequirements &&
                                        _requirementsRequired &&
                                        !_requirementsApproved
                                    ? 'Docs Required'
                                    : (!_isRegistrationResolved
                                          ? 'Checking...'
                                          : 'Open'))))));
    final usesSessions =
        usesEventSessions(_event!) || _eventSessions.isNotEmpty;
    final canTapAction =
        !_isAccessDenied &&
        !_isRegistering &&
        !_isPrimaryActionInProgress &&
        !_isOpeningRequirements &&
        (_isRegistered ||
            (!isRegistrationClosed &&
                (_needsRequirementsAction ||
                    (_isRegistrationResolved && _canRegisterNow) ||
                    (_isRegistrationResolved &&
                        _hasStudentRequirements &&
                        _requirementsRequired &&
                        !_requirementsApproved &&
                        _requirementsStatus != 'pending_review'))));
    final isActionDisabled =
        !_isRegistered &&
        (isRegistrationClosed || (!_canRegisterNow && !_needsRequirementsAction));

    return Scaffold(
      backgroundColor: Colors.white,
      body: CustomScrollView(
        slivers: [
          // App Bar — Dark Maroon
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: _studentDark(context),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_studentDark(context), _studentPrimary(context)],
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 40),
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.1),
                          border: Border.all(
                            color: const Color(
                              0xFFD4A843,
                            ).withValues(alpha: 0.5),
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.event_rounded,
                          color: Color(0xFFD4A843),
                          size: 32,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 20,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            leading: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
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

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
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
            if (_registrationMessage.isNotEmpty &&
                !_isRegistered &&
                (!_approvalRequired ||
                    _requirementsRequired ||
                    isRegistrationClosed)) ...[
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
                    colors: _isRegistered
                        ? [const Color(0xFFD4A843), const Color(0xFFB8942F)]
                        : (isActionDisabled
                              ? const [Color(0xFFE5E7EB), Color(0xFFD1D5DB)]
                              : [
                                  _studentDark(context),
                                  _studentPrimary(context),
                                ]),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          (_isRegistered
                                  ? const Color(0xFFD4A843)
                                  : (isActionDisabled
                                        ? const Color(0xFF9CA3AF)
                                        : _studentPrimary(context)))
                              .withValues(alpha: 0.3),
                      blurRadius: 15,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: canTapAction ? _handlePrimaryAction : null,
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
                  child: (_isRegistering ||
                          _isPrimaryActionInProgress ||
                          _isOpeningRequirements ||
                          (!_isRegistrationResolved && !_isRegistered))
                      ? const PulseConnectLoader(size: 14, color: Colors.white)
                      : AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child: Row(
                            key: ValueKey(
                              _isRegistered
                                  ? 'ticket_action'
                                  : (_needsRequirementsAction
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
      _buildScheduleInfoCard(
        icon: Icons.groups_rounded,
        title: 'Target Participants',
        value: _targetParticipantsLabel(eventFor),
        fullWidth: true,
      ),
    ]);

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
      r'^COURSE\s*=\s*(ALL|BSIT|BSCS)\s*;\s*YEARS\s*=\s*([0-9,\sA-Z]+)$',
    ).firstMatch(rawUpper);
    if (multi != null) {
      final course = multi.group(1) == 'ALL'
          ? 'All Courses'
          : (multi.group(1) ?? 'All Courses');
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
