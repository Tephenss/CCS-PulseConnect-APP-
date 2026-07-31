import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:intl/intl.dart';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:gal/gal.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/auth_service.dart';
import '../../services/app_cache_service.dart';
import '../../services/event_service.dart';
import '../../services/mobile_backend_service.dart';
import '../../services/offline_sync_service.dart';
import '../../services/device_performance_service.dart';
import '../../services/scan_ingress_signal_service.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/shiny_text.dart';
import '../../utils/event_time_utils.dart';
import '../../utils/teacher_theme_utils.dart';

class _TeacherManageSnapshot {
  final Map<String, dynamic> event;
  final List<Map<String, dynamic>> participants;
  final List<Map<String, dynamic>> assistants;
  final List<Map<String, dynamic>> sessions;
  final bool canManageAssistants;
  final String currentTeacherId;
  final bool rosterLoaded;
  final DateTime cachedAt;

  const _TeacherManageSnapshot({
    required this.event,
    required this.participants,
    required this.assistants,
    required this.sessions,
    required this.canManageAssistants,
    required this.currentTeacherId,
    required this.rosterLoaded,
    required this.cachedAt,
  });
}

class TeacherEventManage extends StatefulWidget {
  final Map<String, dynamic> event;
  const TeacherEventManage({super.key, required this.event});

  @override
  State<TeacherEventManage> createState() => _TeacherEventManageState();
}

class _TeacherEventManageState extends State<TeacherEventManage>
    with SingleTickerProviderStateMixin {
  static final Map<String, _TeacherManageSnapshot> _manageCache = {};
  static const Duration _manageUiTtl = Duration(minutes: 3);

  late TabController _tabController;
  final _eventService = EventService();
  final _authService = AuthService();
  final _appCacheService = AppCacheService();
  final _offlineSyncService = OfflineSyncService();
  final _scanIngressSignalService = ScanIngressSignalService();
  final _mobileBackend = MobileBackendService();

  List<Map<String, dynamic>> _participants = [];
  List<Map<String, dynamic>> _assistants = [];
  List<Map<String, dynamic>> _eventSessions = [];
  bool _isLoading = false;
  String _searchQuery = '';
  String _currentTeacherId = '';
  bool _canManageAssistants = false;
  bool _isApprovalPhase = false;
  RealtimeChannel? _attendanceChannel;
  Timer? _participantsRefreshDebounce;
  Set<String> _eventSessionIds = <String>{};
  bool _usingCachedParticipants = false;
  int _pendingOfflineParticipantCount = 0;
  bool _earlyOutEnabled = false;
  String? _earlyOutExpiresAt;
  bool? _earlyOutCanEnable;
  String? _earlyOutGraceEndsAt;
  bool _earlyOutBusy = false;
  final Map<String, Map<String, dynamic>> _sessionEarlyOut = {};
  Timer? _earlyOutTick;
  bool _isOfflineMode = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  late Map<String, dynamic> _event;
  bool _isRefreshingEvent = false;
  bool _isLoadingRoster = false;
  bool _rosterLoaded = false;
  int? _lastScanIngressRevision;
  bool _scanIngressListenerBound = false;
  final GlobalKey _eventQrKey = GlobalKey();
  bool _isSavingEventQr = false;

  @override
  void initState() {
    super.initState();
    _event = Map<String, dynamic>.from(widget.event);
    final status = (_event['status']?.toString() ?? 'pending')
        .toLowerCase();
    // Only show Participants and Assistants tabs for Published or Expired events
    _isApprovalPhase = status != 'published' && status != 'expired';
    _tabController = TabController(
      length: _isApprovalPhase ? 1 : 3,
      vsync: this,
    );
    unawaited(_initConnectivityMonitoring());
    _hydrateFromMemoryCache();
    if (!_isApprovalPhase && !_rosterLoaded) {
      _isLoadingRoster = true;
    }
    _loadData();
    if (!_isApprovalPhase) {
      _bindScanIngressListener();
    }
    unawaited(_refreshEarlyOutStatus());
    _earlyOutTick = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_refreshEarlyOutStatus(silent: true));
    });
  }

  bool _participantHasProfile(Map<String, dynamic> participant) {
    final users = participant['users'];
    if (users is! Map) return false;
    return _eventService
        .composeParticipantDisplayName(Map<String, dynamic>.from(users))
        .isNotEmpty;
  }

  bool _assistantHasProfile(Map<String, dynamic> assistant) {
    final users = assistant['users'];
    if (users is! Map) return false;
    return _eventService
        .composeParticipantDisplayName(Map<String, dynamic>.from(users))
        .isNotEmpty;
  }

  bool _rosterRowsAreComplete(
    List<Map<String, dynamic>> participants,
    List<Map<String, dynamic>> assistants,
  ) {
    if (participants.any((row) => !_participantHasProfile(row))) {
      return false;
    }
    if (assistants.any((row) => !_assistantHasProfile(row))) {
      return false;
    }
    return true;
  }

  void _hydrateFromMemoryCache() {
    final eventId = widget.event['id']?.toString() ?? '';
    if (eventId.isEmpty) return;

    final cached = _manageCache[eventId];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) <= _manageUiTtl) {
      _event = Map<String, dynamic>.from(cached.event);
      _eventSessions = List<Map<String, dynamic>>.from(cached.sessions);
      _eventSessionIds = _eventSessions
          .map((s) => s['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      _canManageAssistants = cached.canManageAssistants;
      _currentTeacherId = cached.currentTeacherId;

      if (cached.rosterLoaded &&
          _rosterRowsAreComplete(cached.participants, cached.assistants)) {
        _participants = List<Map<String, dynamic>>.from(cached.participants);
        _assistants = List<Map<String, dynamic>>.from(cached.assistants);
        _rosterLoaded = true;
        _isLoadingRoster = false;
        _pendingOfflineParticipantCount = _participants
            .where(_participantHasPendingSync)
            .length;
      }

      _isLoading = false;
    }
  }

  void _storeManageSnapshot() {
    final eventId = _event['id']?.toString() ?? '';
    if (eventId.isEmpty) return;

    _manageCache[eventId] = _TeacherManageSnapshot(
      event: Map<String, dynamic>.from(_event),
      participants: _participants
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false),
      assistants: _assistants
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false),
      sessions: _eventSessions
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false),
      canManageAssistants: _canManageAssistants,
      currentTeacherId: _currentTeacherId,
      rosterLoaded: _rosterLoaded,
      cachedAt: DateTime.now(),
    );
  }

  bool _resultsAreOffline(List<ConnectivityResult> results) {
    if (results.isEmpty) return true;
    return !results.any((result) => result != ConnectivityResult.none);
  }

  Future<void> _initConnectivityMonitoring() async {
    try {
      final initial = await Connectivity().checkConnectivity();
      if (!mounted) return;
      setState(() => _isOfflineMode = _resultsAreOffline(initial));
    } catch (_) {
      if (!mounted) return;
      setState(() => _isOfflineMode = false);
    }

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      if (!mounted) return;
      final nextOffline = _resultsAreOffline(results);
      if (nextOffline == _isOfflineMode) return;
      setState(() {
        _isOfflineMode = nextOffline;
        if (nextOffline && _participants.isNotEmpty) {
          _usingCachedParticipants = true;
        }
      });
      if (nextOffline) {
        unawaited(_persistCurrentSnapshotToCache());
      } else {
        unawaited(_loadData());
      }
    });
  }

  Future<void> _persistCurrentSnapshotToCache() async {
    final eventId = widget.event['id']?.toString() ?? '';
    if (eventId.isEmpty) return;
    try {
      if (_participants.isNotEmpty) {
        await _appCacheService.saveJsonList(
          _participantsCacheKey(eventId),
          _participants,
        );
      }
      if (_assistants.isNotEmpty) {
        await _appCacheService.saveJsonList(
          _assistantsCacheKey(eventId),
          _assistants,
        );
      }
      if (_eventSessions.isNotEmpty) {
        await _appCacheService.saveJsonList(
          _sessionsCacheKey(eventId),
          _eventSessions,
        );
      }
    } catch (_) {
      // Ignore cache persistence failures; current in-memory view remains usable.
    }
  }

  String _participantsCacheKey(String eventId) =>
      'teacher_event_manage_participants_$eventId';

  String _assistantsCacheKey(String eventId) =>
      'teacher_event_manage_assistants_$eventId';

  String _sessionsCacheKey(String eventId) =>
      'teacher_event_manage_sessions_$eventId';

  String _participantKey(Map<String, dynamic> participant) {
    final registrationId = (participant['id']?.toString() ?? '').trim();
    if (registrationId.isNotEmpty) return 'registration:$registrationId';

    final studentId =
        (participant['student_id']?.toString() ??
                ((participant['users'] is Map)
                    ? (participant['users']['student_id']?.toString() ?? '')
                    : ''))
            .trim();
    if (studentId.isNotEmpty) return 'student:$studentId';

    final fallbackName = _getName(participant).trim().toLowerCase();
    return fallbackName.isNotEmpty
        ? 'name:$fallbackName'
        : 'participant:unknown';
  }

  bool _participantHasPendingSync(Map<String, dynamic> participant) {
    if (participant['offline_pending'] == true) return true;

    final sessionAttendance = _getSessionAttendance(participant);
    if (sessionAttendance.any((row) => row['offline_pending'] == true)) {
      return true;
    }

    final tickets = participant['tickets'];
    if (tickets is List) {
      for (final rawTicket in tickets) {
        if (rawTicket is! Map) continue;
        final attendance = rawTicket['attendance'];
        if (attendance is! List) continue;
        for (final rawRow in attendance) {
          if (rawRow is! Map) continue;
          if (rawRow['offline_pending'] == true) return true;
        }
      }
    }
    return false;
  }

  List<Map<String, dynamic>> _mergeParticipantSources({
    required List<Map<String, dynamic>> baseParticipants,
    required List<Map<String, dynamic>> offlineParticipants,
  }) {
    final merged = <String, Map<String, dynamic>>{};

    for (final participant in baseParticipants) {
      merged[_participantKey(participant)] = Map<String, dynamic>.from(
        participant,
      );
    }

    for (final offline in offlineParticipants) {
      final key = _participantKey(offline);
      final existing = merged[key];
      if (existing == null) {
        merged[key] = Map<String, dynamic>.from(offline);
        continue;
      }

      final next = Map<String, dynamic>.from(existing);
      final offlineCopy = Map<String, dynamic>.from(offline);

      final offlineId = (offlineCopy['id']?.toString() ?? '').trim();
      if (offlineId.isNotEmpty) {
        next['id'] = offlineId;
      }

      final offlineStudentId = (offlineCopy['student_id']?.toString() ?? '')
          .trim();
      if (offlineStudentId.isNotEmpty) {
        next['student_id'] = offlineStudentId;
      }

      final offlineDisplayName = (offlineCopy['display_name']?.toString() ?? '')
          .trim();
      if (offlineDisplayName.isNotEmpty) {
        next['display_name'] = offlineDisplayName;
      }

      final baseUsers = next['users'] is Map
          ? Map<String, dynamic>.from(next['users'] as Map)
          : <String, dynamic>{};
      final offlineUsers = offlineCopy['users'] is Map
          ? Map<String, dynamic>.from(offlineCopy['users'] as Map)
          : <String, dynamic>{};
      for (final entry in offlineUsers.entries) {
        final value = entry.value?.toString().trim() ?? '';
        if (value.isNotEmpty) {
          baseUsers[entry.key] = entry.value;
        }
      }
      next['users'] = baseUsers;

      // Only override attendance payloads when offline rows are pending sync.
      // This keeps website-accurate fetched status/time while still surfacing
      // local unsynced updates.
      if (offlineCopy['session_attendance'] is List) {
        final offlineSessionRows = List<Map<String, dynamic>>.from(
          (offlineCopy['session_attendance'] as List).map(
            (row) => Map<String, dynamic>.from(row as Map),
          ),
        );
        final hasPendingSessionRows = offlineSessionRows.any(
          (row) => row['offline_pending'] == true,
        );
        if (hasPendingSessionRows) {
          next['session_attendance'] = offlineSessionRows;
        }
      }

      if (offlineCopy['tickets'] is List) {
        final offlineTickets = List<Map<String, dynamic>>.from(
          (offlineCopy['tickets'] as List).map(
            (row) => Map<String, dynamic>.from(row as Map),
          ),
        );
        final hasPendingTicketRows = offlineTickets.any((ticket) {
          if (ticket['offline_pending'] == true) return true;
          final attendance = ticket['attendance'];
          if (attendance is! List) return false;
          for (final row in attendance) {
            if (row is Map && row['offline_pending'] == true) return true;
          }
          return false;
        });
        if (hasPendingTicketRows) {
          next['tickets'] = offlineTickets;
        }
      }

      if (offlineCopy['offline_pending'] == true) {
        next['offline_pending'] = true;
      }
      if ((offlineCopy['offline_updated_at']?.toString() ?? '')
          .trim()
          .isNotEmpty) {
        next['offline_updated_at'] = offlineCopy['offline_updated_at'];
      }
      if (offlineCopy['offline_cached'] == true) {
        next['offline_cached'] = true;
      }

      merged[key] = next;
    }

    final rows = merged.values.toList()
      ..sort(
        (a, b) =>
            _getName(a).toLowerCase().compareTo(_getName(b).toLowerCase()),
      );
    return rows;
  }

  Future<Map<String, dynamic>> _loadCachedEventData({
    required String eventId,
    required String teacherId,
  }) async {
    final cachedParticipants = await _appCacheService.loadJsonList(
      _participantsCacheKey(eventId),
    );
    final cachedAssistants = await _appCacheService.loadJsonList(
      _assistantsCacheKey(eventId),
    );
    final cachedSessions = await _appCacheService.loadJsonList(
      _sessionsCacheKey(eventId),
    );
    final offlineParticipants = teacherId.trim().isEmpty
        ? <Map<String, dynamic>>[]
        : await _offlineSyncService.getOfflineParticipantRoster(
            actorId: teacherId,
            isTeacher: true,
            eventId: eventId,
          );

    final mergedParticipants = _mergeParticipantSources(
      baseParticipants: cachedParticipants,
      offlineParticipants: offlineParticipants,
    );

    return {
      'participants': mergedParticipants,
      'assistants': cachedAssistants,
      'sessions': cachedSessions,
      'offline_participants': offlineParticipants,
      'has_any':
          mergedParticipants.isNotEmpty ||
          cachedAssistants.isNotEmpty ||
          cachedSessions.isNotEmpty,
    };
  }

  Future<void> _loadData([bool showLoader = false]) async {
    final eventId = widget.event['id']?.toString() ?? '';
    if (eventId.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    final hasVisibleData = _participants.isNotEmpty ||
        _assistants.isNotEmpty ||
        _eventSessions.isNotEmpty ||
        (_event['title']?.toString() ?? '').trim().isNotEmpty;

    if (showLoader && !hasVisibleData && mounted) {
      setState(() => _isLoading = true);
    }
    if (!_isApprovalPhase && (!_rosterLoaded || showLoader) && mounted) {
      setState(() => _isLoadingRoster = true);
    }

    final user = await _authService.getCurrentUser();
    final teacherId = user?['id']?.toString() ?? '';
    final cachedData = await _loadCachedEventData(
      eventId: eventId,
      teacherId: teacherId,
    );

    if (mounted && cachedData['has_any'] == true) {
      final cachedParticipants = List<Map<String, dynamic>>.from(
        cachedData['participants'] as List,
      );
      final cachedAssistants = List<Map<String, dynamic>>.from(
        cachedData['assistants'] as List,
      );
      final cachedSessions = List<Map<String, dynamic>>.from(
        cachedData['sessions'] as List,
      );
      final cachedEventSessionIds = cachedSessions
          .map((s) => s['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      setState(() {
        _eventSessions = cachedSessions;
        _eventSessionIds = cachedEventSessionIds;
        _currentTeacherId = teacherId;
        if (_rosterRowsAreComplete(cachedParticipants, cachedAssistants)) {
          _participants = cachedParticipants;
          _assistants = cachedAssistants;
          _rosterLoaded = true;
          _isLoadingRoster = false;
          _pendingOfflineParticipantCount = cachedParticipants
              .where(_participantHasPendingSync)
              .length;
        }
        _usingCachedParticipants = true;
        if (!showLoader) {
          _isLoading = false;
        }
      });
      if (_rosterLoaded) {
        _storeManageSnapshot();
      }
    }

    unawaited(_refreshEventDetails(eventId, forceFresh: showLoader));

    try {
      final results = await Future.wait([
        _eventService.getEventParticipants(eventId),
        _eventService.getEventAssistants(eventId),
        teacherId.isEmpty
            ? Future<bool>.value(false)
            : _eventService.canTeacherManageAssistants(eventId, teacherId),
        _eventService.getEventSessions(eventId),
      ]);

      final participants = results[0] as List<Map<String, dynamic>>;
      final assistants = results[1] as List<Map<String, dynamic>>;
      final canManageAssistants = results[2] as bool;
      final eventSessions = results[3] as List<Map<String, dynamic>>;
      final offlineParticipants = List<Map<String, dynamic>>.from(
        cachedData['offline_participants'] as List,
      );
      final mergedParticipants = _mergeParticipantSources(
        baseParticipants: participants,
        offlineParticipants: offlineParticipants,
      );
      final eventSessionIds = eventSessions
          .map((s) => s['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();

      await _appCacheService.saveJsonList(
        _participantsCacheKey(eventId),
        mergedParticipants,
      );
      await _appCacheService.saveJsonList(
        _assistantsCacheKey(eventId),
        assistants,
      );
      await _appCacheService.saveJsonList(
        _sessionsCacheKey(eventId),
        eventSessions,
      );

      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingRoster = false;
          _rosterLoaded = true;
          _participants = mergedParticipants;
          _assistants = assistants;
          _eventSessions = eventSessions;
          _eventSessionIds = eventSessionIds;
          _currentTeacherId = teacherId;
          _canManageAssistants = canManageAssistants;
          _pendingOfflineParticipantCount = mergedParticipants
              .where(_participantHasPendingSync)
              .length;
          _usingCachedParticipants = offlineParticipants.isNotEmpty;
        });
        _storeManageSnapshot();
        unawaited(_refreshEarlyOutStatus());
      }
      _bindAttendanceRealtime();
    } catch (_) {
      if (mounted) {
        final fallbackParticipants = List<Map<String, dynamic>>.from(
          cachedData['participants'] as List,
        );
        final fallbackAssistants = List<Map<String, dynamic>>.from(
          cachedData['assistants'] as List,
        );
        final fallbackSessions = List<Map<String, dynamic>>.from(
          cachedData['sessions'] as List,
        );
        final fallbackEventSessionIds = fallbackSessions
            .map((s) => s['id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();
        final keepCurrentParticipants =
            _participants.isNotEmpty &&
            fallbackParticipants.length <= _participants.length;
        final keepCurrentAssistants =
            _assistants.isNotEmpty &&
            fallbackAssistants.length <= _assistants.length;
        final keepCurrentSessions =
            _eventSessions.isNotEmpty &&
            fallbackSessions.length <= _eventSessions.length;
        setState(() {
          _isLoading = false;
          _isLoadingRoster = false;
          _rosterLoaded = _rosterRowsAreComplete(
            keepCurrentParticipants ? _participants : fallbackParticipants,
            keepCurrentAssistants ? _assistants : fallbackAssistants,
          );
          _participants = keepCurrentParticipants
              ? _participants
              : (_rosterRowsAreComplete(fallbackParticipants, fallbackAssistants)
                    ? fallbackParticipants
                    : _participants);
          _assistants = keepCurrentAssistants
              ? _assistants
              : (_rosterRowsAreComplete(fallbackParticipants, fallbackAssistants)
                    ? fallbackAssistants
                    : _assistants);
          _eventSessions = keepCurrentSessions
              ? _eventSessions
              : fallbackSessions;
          _eventSessionIds = keepCurrentSessions
              ? _eventSessionIds
              : fallbackEventSessionIds;
          _currentTeacherId = teacherId;
          _canManageAssistants = false;
          _pendingOfflineParticipantCount = _participants
              .where(_participantHasPendingSync)
              .length;
          _usingCachedParticipants =
              _isOfflineMode ||
              cachedData['has_any'] == true ||
              _usingCachedParticipants;
        });
      }
    }
  }

  void _scheduleParticipantsRefresh() {
    _participantsRefreshDebounce?.cancel();
    _participantsRefreshDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_refreshParticipantsOnly());
    });
  }

  String _payloadSessionId(PostgresChangePayload payload) {
    final newRecord = payload.newRecord;
    if (newRecord['session_id'] != null) {
      final sid = newRecord['session_id'].toString().trim();
      if (sid.isNotEmpty) return sid;
    }
    final oldRecord = payload.oldRecord;
    if (oldRecord['session_id'] != null) {
      final sid = oldRecord['session_id'].toString().trim();
      if (sid.isNotEmpty) return sid;
    }
    return '';
  }

  Future<void> _refreshParticipantsOnly() async {
    if (!mounted) return;
    final eventId = widget.event['id']?.toString() ?? '';
    if (eventId.isEmpty) return;
    try {
      final participants = await _eventService.getEventParticipants(eventId);
      final offlineParticipants = _currentTeacherId.trim().isEmpty
          ? <Map<String, dynamic>>[]
          : await _offlineSyncService.getOfflineParticipantRoster(
              actorId: _currentTeacherId,
              isTeacher: true,
              eventId: eventId,
            );
      final mergedParticipants = _mergeParticipantSources(
        baseParticipants: participants,
        offlineParticipants: offlineParticipants,
      );
      await _appCacheService.saveJsonList(
        _participantsCacheKey(eventId),
        mergedParticipants,
      );
      if (!mounted) return;
      setState(() {
        _participants = mergedParticipants;
        _pendingOfflineParticipantCount = mergedParticipants
            .where(_participantHasPendingSync)
            .length;
        _usingCachedParticipants = offlineParticipants.isNotEmpty;
      });
    } catch (_) {
      final cachedData = await _loadCachedEventData(
        eventId: eventId,
        teacherId: _currentTeacherId,
      );
      if (!mounted) return;
      final fallbackParticipants = List<Map<String, dynamic>>.from(
        cachedData['participants'] as List,
      );
      final keepCurrentParticipants =
          _participants.isNotEmpty &&
          fallbackParticipants.length <= _participants.length;
      setState(() {
        _participants = keepCurrentParticipants
            ? _participants
            : fallbackParticipants;
        _pendingOfflineParticipantCount = _participants
            .where(_participantHasPendingSync)
            .length;
        _usingCachedParticipants =
            _isOfflineMode ||
            cachedData['has_any'] == true ||
            _usingCachedParticipants;
      });
    }
  }

  void _bindScanIngressListener() {
    if (_scanIngressListenerBound || _isApprovalPhase) return;
    final eventId = widget.event['id']?.toString() ?? '';
    if (eventId.isEmpty) return;

    _scanIngressListenerBound = true;
    _scanIngressSignalService.listenToEvent(
      eventId: eventId,
      onRevision: (revision) {
        if (!mounted) return;
        final previous = _lastScanIngressRevision;
        _lastScanIngressRevision = revision;
        if (previous == null || revision <= previous) return;
        _scheduleParticipantsRefresh();
      },
    );
  }

  void _bindAttendanceRealtime() {
    final eventId = widget.event['id']?.toString() ?? '';
    if (eventId.isEmpty) return;
    if (_attendanceChannel != null) return;

    final supabase = Supabase.instance.client;
    final channelName = 'public:event_manage_attendance:$eventId';
    _attendanceChannel = supabase.channel(channelName);

    void handlePayload(PostgresChangePayload payload) {
      if (_eventSessionIds.isNotEmpty) {
        final sid = _payloadSessionId(payload);
        if (sid.isEmpty) return;
        if (!_eventSessionIds.contains(sid)) return;
      }
      _scheduleParticipantsRefresh();
    }

    _attendanceChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_session_attendance',
      callback: handlePayload,
    );

    _attendanceChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'attendance',
      callback: handlePayload,
    );

    _attendanceChannel!.subscribe();
  }

  @override
  void dispose() {
    _participantsRefreshDebounce?.cancel();
    _earlyOutTick?.cancel();
    _connectivitySubscription?.cancel();
    _attendanceChannel?.unsubscribe();
    final eventId = widget.event['id']?.toString() ?? '';
    if (eventId.isNotEmpty) {
      unawaited(_scanIngressSignalService.cancelEvent(eventId));
    } else {
      unawaited(_scanIngressSignalService.cancelAll());
    }
    _tabController.dispose();
    super.dispose();
  }

  // â”€â”€â”€ Helper: extract student name â”€â”€â”€
  String _getName(Map<String, dynamic> p) {
    final displayName = (p['display_name']?.toString() ?? '').trim();
    if (displayName.isNotEmpty) return displayName;
    final u = p['users'];
    if (u is Map) {
      final user = Map<String, dynamic>.from(u);
      final composed = _eventService.composeParticipantDisplayName(user);
      if (composed.isNotEmpty) return composed;
      final fullName = (user['full_name']?.toString() ?? '').trim();
      if (fullName.isNotEmpty) return fullName;
      final mappedDisplay = (user['display_name']?.toString() ?? '').trim();
      if (mappedDisplay.isNotEmpty) return mappedDisplay;
    }
    return 'Unknown Student';
  }

  // â”€â”€â”€ Helper: initials (max 2 chars) â”€â”€â”€
  String _getInitials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[parts.length - 1][0]}'.toUpperCase();
  }

  String _getAssistantName(Map<String, dynamic> assistant) {
    final u = assistant['users'];
    if (u is Map) {
      final composed = _eventService.composeParticipantDisplayName(
        Map<String, dynamic>.from(u),
      );
      if (composed.isNotEmpty) return composed;
    }
    final legacy = (assistant['name'] ?? '').toString().trim();
    if (legacy.isNotEmpty) return legacy;
    return 'Unknown Student';
  }

  String _getAssistantStudentNumber(Map<String, dynamic> assistant) {
    final u = assistant['users'];
    if (u is Map) {
      final idNum = (u['id_number'] ?? '').toString().trim();
      if (idNum.isNotEmpty && idNum != 'null') return idNum;
      final studentId = (u['student_id'] ?? '').toString().trim();
      if (studentId.isNotEmpty && studentId != 'null') return studentId;
    }
    final legacy = (assistant['id_number'] ?? '').toString().trim();
    return legacy.isNotEmpty && legacy != 'null' ? legacy : 'N/A';
  }

  List<Map<String, String>> _buildAssistantCandidates() {
    final assignedIds = _assistants
        .map((a) => a['student_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    final candidates = <Map<String, String>>[];
    for (final p in _participants) {
      final sid = p['student_id']?.toString() ?? '';
      if (sid.isEmpty || assignedIds.contains(sid)) continue;

      final name = _getName(p);
      final u = p['users'];
      String idNum = 'N/A';
      if (u is Map) {
        final id = (u['id_number'] ?? '').toString().trim();
        final sc = (u['student_id'] ?? '').toString().trim();
        if (id.isNotEmpty && id != 'null') {
          idNum = id;
        } else if (sc.isNotEmpty && sc != 'null') {
          idNum = sc;
        }
      }

      candidates.add({'student_id': sid, 'name': name, 'id_number': idNum});
    }

    candidates.sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
    return candidates;
  }

  // â”€â”€â”€ Helper: attendance status â”€â”€â”€
  bool _isSeminarBasedEvent() {
    if (_eventSessions.isNotEmpty) return true;
    return usesEventSessions(_event);
  }

  Future<void> _refreshEventDetails(
    String eventId, {
    bool forceFresh = false,
  }) async {
    if (eventId.trim().isEmpty) return;

    final hasCover = (_event['cover_image_url']?.toString() ?? '').trim().isNotEmpty;
    if (!hasCover && mounted) {
      setState(() => _isRefreshingEvent = true);
    }

    try {
      final results = await Future.wait([
        _eventService.getEventById(eventId, forceFresh: forceFresh),
        _eventService.getEventRegistrationSettings(
          eventId,
          forceFresh: forceFresh,
        ),
      ]);
      if (!mounted) return;

      final fresh = results[0];
      final regSettings = results[1];
      if (fresh == null) return;

      final merged = _eventService.mergeEventRegistrationSettings(
        fresh,
        regSettings,
      );
      final knownCover = (_event['cover_image_url'] ?? '').toString().trim();
      if ((merged['cover_image_url'] ?? '').toString().trim().isEmpty &&
          knownCover.isNotEmpty) {
        merged['cover_image_url'] = knownCover;
      }

      setState(() => _event = merged);
      _storeManageSnapshot();
    } catch (_) {
      // Keep list-passed event data when refresh fails (offline / RLS).
    } finally {
      if (mounted) setState(() => _isRefreshingEvent = false);
    }
  }

  String _eventStatusLabel(String? status) {
    switch ((status ?? '').toLowerCase()) {
      case 'published':
        return 'Published';
      case 'pending':
        return 'Pending Approval';
      case 'approved':
        return 'Approved';
      case 'rejected':
        return 'Rejected';
      case 'expired':
        return 'Expired';
      default:
        final raw = (status ?? 'Unknown').toString().trim();
        return raw.isEmpty ? 'Unknown' : raw;
    }
  }

  List<Map<String, dynamic>> _getSessionAttendance(Map<String, dynamic> p) {
    final raw = p['session_attendance'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    return const <Map<String, dynamic>>[];
  }

  bool _sessionRowIsPresent(Map<String, dynamic> row) {
    final status = (row['status']?.toString() ?? '').trim().toLowerCase();
    final checkIn = (row['check_in_at']?.toString() ?? '').trim();
    if (checkIn.isNotEmpty) return true;
    return status == 'present' ||
        status == 'scanned' ||
        status == 'late' ||
        status == 'early';
  }

  bool _sessionRowIsAbsent(Map<String, dynamic> row) {
    final status = (row['status']?.toString() ?? '').trim().toLowerCase();
    return status == 'absent';
  }

  DateTime? _parseUtcTimestamp(dynamic raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return null;
    return parsed.toUtc();
  }

  int _sessionWindowMinutes(Map<String, dynamic> session) {
    final raw =
        (session['scan_window_minutes'] ??
                session['attendance_window_minutes'] ??
                30)
            .toString();
    final parsed = int.tryParse(raw) ?? 30;
    return parsed < 1 ? 30 : parsed;
  }

  bool _sessionWindowClosed(Map<String, dynamic> session) {
    final startUtc = _parseUtcTimestamp(session['start_at']);
    if (startUtc == null) return false;
    final explicitEndUtc = _parseUtcTimestamp(session['end_at']);
    final closesAtUtc =
        explicitEndUtc ??
        startUtc.add(Duration(minutes: _sessionWindowMinutes(session)));
    return DateTime.now().toUtc().isAfter(closesAtUtc);
  }

  List<Map<String, dynamic>> _synthesizedClosedMissedSessions(
    Map<String, dynamic> p,
  ) {
    if (!_isSeminarBasedEvent() || _eventSessions.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    final rows = _getSessionAttendance(p);
    final missed = <Map<String, dynamic>>[];

    for (final session in _eventSessions) {
      final sessionId = (session['id']?.toString() ?? '').trim();
      if (sessionId.isEmpty) continue;
      if (!_sessionWindowClosed(session)) continue;

      final sessionRows = rows
          .where((r) => (r['session_id']?.toString() ?? '') == sessionId)
          .toList();

      if (sessionRows.any(_sessionRowIsPresent)) {
        continue;
      }

      final explicitAbsent = sessionRows.where(_sessionRowIsAbsent).toList();
      if (explicitAbsent.isNotEmpty) {
        missed.add(explicitAbsent.first);
        continue;
      }

      missed.add({
        'session_id': sessionId,
        'status': 'absent',
        'check_in_at': null,
        'last_scanned_at': null,
        'session_no': session['session_no'],
        'title': session['title'],
        'display_name': session['display_name'],
        'start_at': session['start_at'],
      });
    }

    return missed;
  }

  List<Map<String, dynamic>> _getPresentSessionAttendance(
    Map<String, dynamic> p,
  ) {
    return _getSessionAttendance(p).where(_sessionRowIsPresent).toList();
  }

  List<Map<String, dynamic>> _visibleSessionIndicators(Map<String, dynamic> p) {
    final present = _getPresentSessionAttendance(p);
    if (present.isNotEmpty) return present;
    final absent = _getSessionAttendance(p).where(_sessionRowIsAbsent).toList();
    if (absent.isNotEmpty) return absent;
    final synthesized = _synthesizedClosedMissedSessions(p);
    if (synthesized.isNotEmpty) return synthesized;
    return const <Map<String, dynamic>>[];
  }

  String _getLegacyAttStatus(Map<String, dynamic> p) {
    try {
      final att = _canonicalTicketAttendance(p);
      if (att == null) return 'unscanned';
      final raw = (att['status']?.toString() ?? '').trim().toLowerCase();
      return raw.isEmpty ? 'unscanned' : raw;
    } catch (_) {
      return 'unscanned';
    }
  }

  String _getAttStatus(Map<String, dynamic> p) {
    if (_isSeminarBasedEvent()) {
      final sessionAttendance = _getSessionAttendance(p);
      if (sessionAttendance.any(_sessionRowIsPresent)) {
        return 'present';
      }
      if (sessionAttendance.any(_sessionRowIsAbsent)) {
        return 'absent';
      }
      if (_synthesizedClosedMissedSessions(p).isNotEmpty) {
        return 'absent';
      }
      final legacy = _getLegacyAttStatus(p);
      if (legacy == 'absent') {
        return 'absent';
      }
      return 'unscanned';
    }

    final status = _getLegacyAttStatus(p);
    if (status == 'absent') {
      return 'absent';
    }
    if (status == 'present' ||
        status == 'late' ||
        status == 'early' ||
        status == 'scanned') {
      return 'present';
    }
    return 'unscanned';
  }

  DateTime? _parseBackendTimestampToLocal(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final parsed = DateTime.tryParse(text);
    if (parsed == null) return null;

    final hasTimezone = RegExp(r'(z|Z|[+\-]\d{2}:\d{2})$').hasMatch(text);
    if (hasTimezone) {
      return parsed.toLocal();
    }

    // Legacy fallback:
    // if timezone is missing in stored timestamp, treat it as UTC
    // so app and web display the same local time.
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    ).toLocal();
  }

  String _formatStoredTime(dynamic raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return '-';
    final local = _parseBackendTimestampToLocal(text);
    if (local == null) return '-';
    return DateFormat('hh:mm a').format(local);
  }

  Map<String, dynamic>? _canonicalTicketAttendance(
    Map<String, dynamic> participant,
  ) {
    try {
      final tickets = participant['tickets'];
      if (tickets == null || (tickets is List && tickets.isEmpty)) return null;
      final ticket = (tickets is List) ? tickets[0] : null;
      if (ticket is! Map) return null;

      final attendanceRaw = ticket['attendance'];
      final attendance = attendanceRaw is List
          ? attendanceRaw
                .whereType<Map>()
                .map(Map<String, dynamic>.from)
                .toList()
          : (attendanceRaw is Map
                ? <Map<String, dynamic>>[
                    Map<String, dynamic>.from(attendanceRaw),
                  ]
                : <Map<String, dynamic>>[]);
      if (attendance.isEmpty) return null;

      int rank(Map<String, dynamic> row) {
        final checkIn = (row['check_in_at']?.toString() ?? '').trim();
        final status = (row['status']?.toString() ?? '').trim().toLowerCase();
        if (checkIn.isNotEmpty) return 0;
        if (status == 'present' ||
            status == 'late' ||
            status == 'early' ||
            status == 'scanned') {
          return 1;
        }
        if (status == 'absent') return 3;
        return 2;
      }

      attendance.sort((a, b) {
        final rankCompare = rank(a).compareTo(rank(b));
        if (rankCompare != 0) return rankCompare;

        final aCheckIn = (a['check_in_at']?.toString() ?? '').trim();
        final bCheckIn = (b['check_in_at']?.toString() ?? '').trim();
        if (aCheckIn.isNotEmpty && bCheckIn.isNotEmpty) {
          return aCheckIn.compareTo(bCheckIn);
        }
        if (aCheckIn.isNotEmpty) return -1;
        if (bCheckIn.isNotEmpty) return 1;

        final aLast = (a['last_scanned_at']?.toString() ?? '').trim();
        final bLast = (b['last_scanned_at']?.toString() ?? '').trim();
        if (aLast.isNotEmpty && bLast.isNotEmpty) {
          return aLast.compareTo(bLast);
        }
        if (aLast.isNotEmpty) return -1;
        if (bLast.isNotEmpty) return 1;
        return 0;
      });

      return attendance.first;
    } catch (_) {
      return null;
    }
  }

  String _getCheckIn(Map<String, dynamic> p) {
    if (_isSeminarBasedEvent()) {
      final presentRows = _getPresentSessionAttendance(p);
      if (presentRows.isEmpty) return '-';

      presentRows.sort((a, b) {
        final aSessionNo =
            int.tryParse(a['session_no']?.toString() ?? '') ?? 999;
        final bSessionNo =
            int.tryParse(b['session_no']?.toString() ?? '') ?? 999;
        final bySessionNo = aSessionNo.compareTo(bSessionNo);
        if (bySessionNo != 0) return bySessionNo;

        final aStart = _parseUtcTimestamp(a['start_at']);
        final bStart = _parseUtcTimestamp(b['start_at']);
        if (aStart != null && bStart != null) {
          final byStart = aStart.compareTo(bStart);
          if (byStart != 0) return byStart;
        } else if (aStart != null) {
          return -1;
        } else if (bStart != null) {
          return 1;
        }

        final aCheck = (a['check_in_at']?.toString() ?? '').trim();
        final bCheck = (b['check_in_at']?.toString() ?? '').trim();
        return aCheck.compareTo(bCheck);
      });

      final primary = presentRows.first;
      return _formatStoredTime(
        primary['check_in_at'] ?? primary['last_scanned_at'],
      );
    }

    try {
      final att = _canonicalTicketAttendance(p);
      return att != null
          ? _formatStoredTime(att['check_in_at'] ?? att['last_scanned_at'])
          : '-';
    } catch (_) {
      return '-';
    }
  }

  int _getSessionCount(Map<String, dynamic> p) {
    return _getPresentSessionAttendance(p).length;
  }

  bool _hasSessionScan(Map<String, dynamic> p, String sessionId) {
    if (sessionId.trim().isEmpty) return false;
    return _getSessionAttendance(p).any(
      (item) =>
          (item['session_id']?.toString() ?? '') == sessionId &&
          _sessionRowIsPresent(item),
    );
  }

  String _sessionIndicatorLabel(Map<String, dynamic> scan) {
    final sessionNo = int.tryParse(scan['session_no']?.toString() ?? '');
    if (sessionNo != null && sessionNo > 0) {
      return 'Seminar $sessionNo';
    }
    final display = (scan['display_name']?.toString() ?? '').trim();
    if (display.isNotEmpty) return display;
    final title = (scan['title']?.toString() ?? '').trim();
    if (title.isNotEmpty) return title;
    return 'Seminar';
  }

  String _sessionStatusForParticipant(
    Map<String, dynamic> participant,
    Map<String, dynamic> session,
  ) {
    final sessionId = (session['id']?.toString() ?? '').trim();
    if (sessionId.isEmpty) return 'unscanned';

    final sessionRows = _getSessionAttendance(participant)
        .where((row) => (row['session_id']?.toString() ?? '') == sessionId)
        .toList();

    if (sessionRows.any(_sessionRowIsPresent)) return 'present';
    if (sessionRows.any(_sessionRowIsAbsent)) return 'absent';
    if (_sessionWindowClosed(session)) return 'absent';
    return 'unscanned';
  }

  String _sessionStatusLabel(String status) {
    switch (status) {
      case 'present':
        return 'Present';
      case 'absent':
        return 'Absent';
      default:
        return 'No record';
    }
  }

  Color _sessionStatusTextColor(String status) {
    switch (status) {
      case 'present':
        return const Color(0xFF065F46);
      case 'absent':
        return const Color(0xFF92400E);
      default:
        return const Color(0xFF4B5563);
    }
  }

  Color _sessionStatusBgColor(String status) {
    switch (status) {
      case 'present':
        return const Color(0xFFD1FAE5);
      case 'absent':
        return const Color(0xFFFEF3C7);
      default:
        return const Color(0xFFF3F4F6);
    }
  }

  Future<void> _toggleAssistant(
    Map<String, dynamic> assistant,
    bool val,
  ) async {
    if (!_canManageAssistants || _currentTeacherId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Only assigned teachers can manage assistants for this event.',
            ),
          ),
        );
      }
      return;
    }

    final oldVal = assistant['allow_scan'] == true;
    setState(() => assistant['allow_scan'] = val);

    final result = await _eventService.updateAssistantAccess(
      assistantId: assistant['id']?.toString(),
      eventId: widget.event['id']?.toString(),
      studentId: assistant['student_id']?.toString(),
      teacherId: _currentTeacherId,
      allowScan: val,
    );

    if (result['ok'] != true) {
      setState(() => assistant['allow_scan'] = oldVal);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result['error'] ?? 'Failed to update assistant access.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _showAssignAssistantSheet() async {
    final eventId = widget.event['id']?.toString() ?? '';
    if (eventId.isEmpty) return;
    if (!_canManageAssistants || _currentTeacherId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Only assigned teachers can add assistants for this event.',
          ),
        ),
      );
      return;
    }

    final baseCandidates = _buildAssistantCandidates();
    if (baseCandidates.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No eligible participants available for assistant assignment.',
          ),
        ),
      );
      return;
    }

    final candidates = List<Map<String, String>>.from(baseCandidates);
    String query = '';
    bool isSubmitting = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final filtered = candidates.where((c) {
              if (query.trim().isEmpty) return true;
              final q = query.toLowerCase();
              return (c['name'] ?? '').toLowerCase().contains(q) ||
                  (c['id_number'] ?? '').toLowerCase().contains(q);
            }).toList();

            return Container(
              height: MediaQuery.of(context).size.height * 0.72,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD1D5DB),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const Text(
                    'Assign Assistant',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Select registered participants who can scan tickets for this event.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: TextField(
                      onChanged: (v) => setSheetState(() => query = v),
                      decoration: const InputDecoration(
                        hintText: 'Search name or ID number...',
                        border: InputBorder.none,
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: 20,
                          color: Color(0xFF9CA3AF),
                        ),
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(
                            child: Text(
                              'No matching students.',
                              style: TextStyle(
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (listContext, index) {
                              final c = filtered[index];
                              final name = c['name'] ?? 'Student';
                              final idNum = c['id_number'] ?? 'N/A';
                              final sid = c['student_id'] ?? '';
                              final initials = _getInitials(name);

                              const avatarColors = [
                                TeacherThemeUtils.primary,
                                Color(0xFF1D4ED8),
                                Color(0xFF7C3AED),
                                Color(0xFF1E40AF),
                                Color(0xFFB45309),
                              ];
                              final avatarColor =
                                  avatarColors[index % avatarColors.length];

                              return InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: isSubmitting
                                    ? null
                                    : () async {
                                        if (sid.isEmpty) return;
                                        final messenger = ScaffoldMessenger.of(
                                          context,
                                        );
                                        final navigator = Navigator.of(
                                          listContext,
                                        );

                                        setSheetState(
                                          () => isSubmitting = true,
                                        );

                                        final res = await _eventService
                                            .assignEventAssistant(
                                              eventId: eventId,
                                              studentId: sid,
                                              teacherId: _currentTeacherId,
                                              allowScan: true,
                                            );

                                        if (!mounted) return;
                                        setSheetState(
                                          () => isSubmitting = false,
                                        );

                                        if (res['ok'] == true) {
                                          if (navigator.canPop()) {
                                            navigator.pop();
                                          }
                                          await _loadData(true);
                                          if (!mounted) return;
                                          messenger.showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                '$name assigned as assistant.',
                                              ),
                                            ),
                                          );
                                        } else {
                                          messenger.showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                res['error'] ??
                                                    'Failed to assign assistant.',
                                              ),
                                            ),
                                          );
                                        }
                                      },
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.04,
                                        ),
                                        blurRadius: 12,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                    border: Border.all(
                                      color: const Color(0xFFF3F4F6),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 46,
                                        height: 46,
                                        decoration: BoxDecoration(
                                          color: avatarColor,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Center(
                                          child: Text(
                                            initials,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              name,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 15,
                                                color: Color(0xFF111827),
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              'Student ID: $idNum',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: Color(0xFF6B7280),
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: TeacherThemeUtils.primary
                                              .withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.add_rounded,
                                              color: TeacherThemeUtils.primary,
                                              size: 16,
                                            ),
                                            SizedBox(width: 6),
                                            Text(
                                              'Assign',
                                              style: TextStyle(
                                                color:
                                                    TeacherThemeUtils.primary,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _exportCsv(List<Map<String, dynamic>> participants) async {
    if (participants.isEmpty) return;

    final rows = <List<dynamic>>[];
    rows.add([
      'Name',
      'Email',
      'ID Number',
      'Course',
      'Year Level',
      'Status',
      'Check-in Time',
    ]);

    for (final p in participants) {
      final name = _getName(p);
      final u = p['users'];
      final email = (u is Map ? u['email'] : null)?.toString() ?? '';
      final idNum =
          (u is Map ? (u['id_number'] ?? u['student_id']) : null)?.toString() ??
          '';
      final course = (u is Map ? u['course'] : null)?.toString() ?? '';
      final yearLevel = (u is Map ? u['year_level'] : null)?.toString() ?? '';
      final attStatus = _getAttStatus(p);
      final checkIn = _getCheckIn(p);

      rows.add([name, email, idNum, course, yearLevel, attStatus, checkIn]);
    }

    final csvData = rows
        .map((row) {
          return row
              .map((cell) {
                final s = cell.toString().replaceAll('"', '""');
                return '"$s"';
              })
              .join(',');
        })
        .join('\n');

    final directory = await getTemporaryDirectory();
    final path =
        '${directory.path}/PulseConnect_Participants_${DateTime.now().millisecondsSinceEpoch}.csv';
    final file = File(path);
    await file.writeAsString(csvData);

    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: 'Exported Event Participants'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPending = _event['status'] == 'pending';
    final isApproved = _event['status'] == 'approved';
    final isRejected = _event['status'] == 'rejected';

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          _buildHeroHeader(),
          if (isPending || isRejected || isApproved)
            Container(
              color: isApproved
                  ? Colors.blue.shade50
                  : (isPending ? Colors.orange.shade50 : Colors.red.shade50),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    isApproved
                        ? Icons.check_circle_outline_rounded
                        : (isPending
                              ? Icons.hourglass_top_rounded
                              : Icons.cancel_rounded),
                    color: isApproved
                        ? Colors.blue.shade700
                        : (isPending
                              ? Colors.orange.shade700
                              : Colors.red.shade700),
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isApproved
                          ? 'Event is approved! It will be visible to students once published.'
                          : (isPending
                                ? 'This event is pending admin approval.'
                                : 'This event was rejected. Reason: Conflict with schedule.'),
                      style: TextStyle(
                        color: isApproved
                            ? Colors.blue.shade900
                            : (isPending
                                  ? Colors.orange.shade900
                                  : Colors.red.shade900),
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (!_isApprovalPhase)
            Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(
                  bottom: BorderSide(color: Color(0xFFF3F4F6)),
                ),
              ),
              child: TabBar(
                controller: _tabController,
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                splashFactory: NoSplash.splashFactory,
                dividerHeight: 0,
                indicatorSize: TabBarIndicatorSize.label,
                indicator: const UnderlineTabIndicator(
                  borderSide: BorderSide(
                    width: 3,
                    color: TeacherThemeUtils.primary,
                  ),
                ),
                labelColor: TeacherThemeUtils.primary,
                unselectedLabelColor: Colors.grey.shade500,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                tabs: const [
                  Tab(text: 'Details'),
                  Tab(text: 'Participants'),
                  Tab(text: 'Assistants'),
                ],
              ),
            ),
          Expanded(
            child: _isLoading
                ? const Center(child: PulseConnectLoader())
                : TabBarView(
                    controller: _tabController,
                    // Avoid clipping the first Details widgets (event-type chip)
                    // under the tab bar during the initial layout pass.
                    clipBehavior: Clip.none,
                    children: [
                      ColoredBox(
                        color: Colors.white,
                        child: _buildDetailsTab(),
                      ),
                      if (!_isApprovalPhase) _buildParticipantsTab(),
                      if (!_isApprovalPhase) _buildAssistantsTab(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroHeader() {
    final title = (_event['title'] ?? 'Manage Event').toString();
    final coverImageUrl = (_event['cover_image_url']?.toString() ?? '').trim();
    final topInset = MediaQuery.paddingOf(context).top;
    const heroHeight = 232.0;

    return SizedBox(
      height: heroHeight + topInset,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (coverImageUrl.isNotEmpty)
            RepaintBoundary(
              child: CachedNetworkImage(
                imageUrl: coverImageUrl,
                fit: BoxFit.cover,
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                memCacheWidth: DevicePerformance.instance.imageCacheWidth,
                placeholder: (context, url) => _coverLoadingPlaceholder(),
                errorWidget: (context, url, error) => _coverFallback(),
              ),
            )
          else if (_isRefreshingEvent)
            _coverLoadingPlaceholder()
          else
            _coverFallback(),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.35),
                  Colors.black.withValues(alpha: 0.1),
                  Colors.black.withValues(alpha: 0.72),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 36,
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
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: const SizedBox(
              height: 28,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                ),
              ),
            ),
          ),
        ],
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
    if (rawUpper == 'BSIT-SD' || rawUpper == 'BSIT-BA' || rawUpper == 'BSCS') {
      return rawUpper;
    }
    final map = {
      '1': '1st Year',
      '2': '2nd Year',
      '3': '3rd Year',
      '4': '4th Year',
    };
    return map[val] ?? val;
  }

  Future<void> _refreshEarlyOutStatus({bool silent = false}) async {
    if (!MobileBackendService.isConfigured) return;
    final eventId = (_event['id']?.toString() ?? '').trim();
    if (eventId.isEmpty) return;

    try {
      if (!_isSeminarBasedEvent()) {
        final res = await _mobileBackend.getEventEarlyOutStatus(eventId: eventId);
        if (!mounted) return;
        final eo = res['early_out'];
        final map = eo is Map ? Map<String, dynamic>.from(eo) : <String, dynamic>{};
        setState(() {
          _earlyOutEnabled = map['enabled'] == true;
          _earlyOutExpiresAt = map['expires_at']?.toString();
          _earlyOutCanEnable = map.containsKey('can_enable')
              ? map['can_enable'] == true
              : null;
          _earlyOutGraceEndsAt = map['grace_ends_at']?.toString();
        });
      } else {
        final next = <String, Map<String, dynamic>>{};
        for (final session in _eventSessions) {
          final sid = (session['id']?.toString() ?? '').trim();
          if (sid.isEmpty) continue;
          final res = await _mobileBackend.getEventEarlyOutStatus(
            eventId: eventId,
            sessionId: sid,
          );
          final eo = res['early_out'];
          next[sid] = eo is Map
              ? Map<String, dynamic>.from(eo)
              : <String, dynamic>{'enabled': false};
        }
        if (!mounted) return;
        setState(() => _sessionEarlyOut
          ..clear()
          ..addAll(next));
      }
    } catch (_) {
      if (!silent && mounted) {
        // Keep quiet on poll failures.
      }
    }
  }

  bool _isWithinEarlyOutSchedule({String? sessionId}) {
    // Prefer server flag when status was fetched.
    if (sessionId != null && sessionId.isNotEmpty) {
      final status = _sessionEarlyOut[sessionId];
      if (status != null && status.containsKey('can_enable')) {
        return status['can_enable'] == true;
      }
    } else if (_earlyOutCanEnable != null) {
      return _earlyOutCanEnable!;
    }

    DateTime? start;
    DateTime? end;
    int graceMinutes = 30;
    if (sessionId != null && sessionId.isNotEmpty) {
      Map<String, dynamic>? session;
      for (final s in _eventSessions) {
        if ((s['id']?.toString() ?? '') == sessionId) {
          session = s;
          break;
        }
      }
      start = parseStoredEventDateTime(session?['start_at']);
      end = parseStoredEventDateTime(session?['end_at']);
      graceMinutes = int.tryParse(
            session?['scan_window_minutes']?.toString() ?? '',
          ) ??
          30;
    } else {
      start = parseStoredEventDateTime(_event['start_at']);
      end = parseStoredEventDateTime(_event['end_at']);
      graceMinutes = int.tryParse(_event['grace_time']?.toString() ?? '') ?? 30;
    }
    if (start == null || end == null) return false;
    graceMinutes = graceMinutes < 0 ? 0 : graceMinutes;
    final graceEnds = start.add(Duration(minutes: graceMinutes));
    final now = DateTime.now();
    // Clickable only after grace ends, until event/seminar end.
    return !now.isBefore(graceEnds) && !now.isAfter(end);
  }

  Future<void> _setEarlyOut({
    required bool enabled,
    String? sessionId,
  }) async {
    if (!MobileBackendService.isConfigured) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mobile backend is not configured.')),
      );
      return;
    }
    final eventId = (_event['id']?.toString() ?? '').trim();
    if (eventId.isEmpty || _earlyOutBusy) return;

    if (enabled && !_isWithinEarlyOutSchedule(sessionId: sessionId)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Early Out is available only after the grace period ends.',
          ),
        ),
      );
      return;
    }

    setState(() => _earlyOutBusy = true);
    try {
      final res = await _mobileBackend.setEventEarlyOut(
        eventId: eventId,
        sessionId: sessionId,
        enabled: enabled,
      );
      if (!mounted) return;
      if (res['ok'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              (res['error']?.toString().trim().isNotEmpty ?? false)
                  ? res['error'].toString()
                  : 'Failed to update Early Out.',
            ),
          ),
        );
        return;
      }
      final eo = res['early_out'];
      final map = eo is Map ? Map<String, dynamic>.from(eo) : <String, dynamic>{};
      setState(() {
        if (sessionId != null && sessionId.isNotEmpty) {
          _sessionEarlyOut[sessionId] = map;
        } else {
          _earlyOutEnabled = map['enabled'] == true;
          _earlyOutExpiresAt = map['expires_at']?.toString();
          _earlyOutCanEnable = map.containsKey('can_enable')
              ? map['can_enable'] == true
              : null;
          _earlyOutGraceEndsAt = map['grace_ends_at']?.toString();
        }
      });
    } finally {
      if (mounted) setState(() => _earlyOutBusy = false);
    }
  }

  String _earlyOutSubtitle(Map<String, dynamic>? status, {String? sessionId}) {
    final isOn = status != null && status['enabled'] == true;
    if (!isOn && !_isWithinEarlyOutSchedule(sessionId: sessionId)) {
      final graceRaw = (status?['grace_ends_at']?.toString() ??
              _earlyOutGraceEndsAt ??
              '')
          .trim();
      if (graceRaw.isNotEmpty) {
        final graceEnds = parseStoredEventDateTime(graceRaw);
        if (graceEnds != null) {
          final hour = graceEnds.hour % 12 == 0 ? 12 : graceEnds.hour % 12;
          final minute = graceEnds.minute.toString().padLeft(2, '0');
          final period = graceEnds.hour >= 12 ? 'PM' : 'AM';
          return 'Available after grace ends ($hour:$minute $period).';
        }
      }
      return 'Available only after the grace period ends.';
    }
    if (!isOn) {
      return 'Opens time-out for 1 hour, then auto-off.';
    }
    final expires = (status['expires_at']?.toString() ?? '').trim();
    if (expires.isEmpty) {
      return 'Early Out is ON for 1 hour.';
    }
    final parsed = DateTime.tryParse(expires);
    if (parsed == null) {
      return 'Early Out is ON for 1 hour.';
    }
    final local = parsed.toLocal();
    return 'Auto-off at ${DateFormat('h:mm a').format(local)}';
  }

  Widget _buildEarlyOutToggleCard({
    required bool enabled,
    required String subtitle,
    required ValueChanged<bool> onChanged,
    String title = 'Early Out',
    bool interactable = true,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ],
            ),
          ),
          if (_earlyOutBusy)
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          else
            Switch.adaptive(
              value: enabled,
              onChanged: (!interactable || _earlyOutBusy) ? null : onChanged,
              activeTrackColor: TeacherThemeUtils.primary.withValues(alpha: 0.5),
              activeThumbColor: TeacherThemeUtils.primary,
            ),
        ],
      ),
    );
  }

  Widget _buildDetailsTab() {
    final startDate = parseStoredEventDateTime(_event['start_at']);
    final endDate = parseStoredEventDateTime(_event['end_at']);
    final location = (_event['location'] ?? 'TBA').toString();
    final eventType = (_event['event_type'] ?? '').toString().trim();
    final graceTime = (_event['grace_time']?.toString() ?? '').trim();
    final eventFor = (_event['event_for']?.toString() ?? 'all').trim();
    final description = (_event['description'] ?? '').toString().trim();
    final eventSpan = (_event['event_span']?.toString() ?? '').trim();
    final isSeminarBased = _isSeminarBasedEvent();

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        if (eventType.isNotEmpty) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _getEventTypeColor(eventType).withValues(alpha: 0.12),
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
          ),
          const SizedBox(height: 16),
        ],
        _buildTeacherTopStatsGrid(eventSpan: eventSpan),
        if (_shouldShowEventQr) ...[
          const SizedBox(height: 24),
          _buildEventQrSection(),
        ],
        const SizedBox(height: 28),
        const Text(
          'Event Schedule & Info',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Color(0xFF1F2937),
          ),
        ),
        const SizedBox(height: 16),
        _buildTeacherScheduleInfoGrid(
          startDate: startDate,
          endDate: endDate,
          location: location,
          eventType: eventType,
          target: _getTargetLabel(eventFor),
          graceTime: graceTime,
        ),
        if (!isSeminarBased) ...[
          const SizedBox(height: 12),
          _buildEarlyOutToggleCard(
            enabled: _earlyOutEnabled,
            subtitle: _earlyOutSubtitle({
              'enabled': _earlyOutEnabled,
              'expires_at': _earlyOutExpiresAt,
            }),
            interactable: _earlyOutEnabled || _isWithinEarlyOutSchedule(),
            onChanged: (v) => _setEarlyOut(enabled: v),
          ),
        ],
        if (isSeminarBased) ...[
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
        if (description.isNotEmpty) ...[
          const SizedBox(height: 28),
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
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildSessionScheduleSection() {
    if (_eventSessions.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFF3F4F6)),
        ),
        child: const Text(
          'No seminar schedule found for this event yet.',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6B7280),
          ),
        ),
      );
    }

    return Column(
      children: _eventSessions.asMap().entries.map((entry) {
        final index = entry.key;
        final session = entry.value;
        final rawTitle = (session['title']?.toString() ?? '').trim();
        final title = rawTitle.isNotEmpty
            ? rawTitle
            : buildSessionDisplayName(session);
        final start = parseStoredEventDateTime(session['start_at']);
        final end = parseStoredEventDateTime(session['end_at']);
        final topic = (session['topic']?.toString() ?? '').trim();
        final showTopic =
            topic.isNotEmpty &&
            !title.toLowerCase().contains(topic.toLowerCase());

        return Container(
          width: double.infinity,
          margin: EdgeInsets.only(
            bottom: index == _eventSessions.length - 1 ? 0 : 12,
          ),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF9FAFB),
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
                  letterSpacing: 1.1,
                  color: Color(0xFF6B7280),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827),
                ),
              ),
              if (showTopic) ...[
                const SizedBox(height: 6),
                Text(
                  topic,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF374151),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _buildTeacherSessionMetaRow(
                Icons.calendar_today_rounded,
                'Date',
                formatDateRange(start, end),
              ),
              const SizedBox(height: 8),
              _buildTeacherSessionMetaRow(
                Icons.schedule_rounded,
                'Time',
                formatTimeRange(start, end),
              ),
              const SizedBox(height: 12),
              _buildEarlyOutToggleCard(
                title: 'Early Out (this seminar)',
                enabled: _sessionEarlyOut[session['id']?.toString() ?? '']
                        ?['enabled'] ==
                    true,
                subtitle: _earlyOutSubtitle(
                  _sessionEarlyOut[session['id']?.toString() ?? ''],
                  sessionId: session['id']?.toString(),
                ),
                interactable: (_sessionEarlyOut[session['id']?.toString() ?? '']
                            ?['enabled'] ==
                        true) ||
                    _isWithinEarlyOutSchedule(
                      sessionId: session['id']?.toString(),
                    ),
                onChanged: (v) => _setEarlyOut(
                  enabled: v,
                  sessionId: session['id']?.toString(),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _coverLoadingPlaceholder() {
    return ColoredBox(
      color: TeacherThemeUtils.dark,
      child: const Center(
        child: PulseConnectLoader(
          size: 22,
          strokeWidth: 3.5,
          color: Color(0xFFD4A843),
        ),
      ),
    );
  }

  Widget _coverFallback() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: TeacherThemeUtils.chromeGradient,
        ),
      ),
      child: Center(
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
    );
  }

  Widget _buildTeacherTopStatsGrid({required String eventSpan}) {
    final hasSpan = eventSpan.isNotEmpty;

    return Row(
      children: [
        Expanded(
          child: _buildTeacherStatChip(
            Icons.people_rounded,
            _eventService.formatParticipantTotal(
              _participants.length,
              _event['registration_limit'],
            ),
            'Participants',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildTeacherStatChip(
            Icons.info_outline_rounded,
            _eventStatusLabel(_event['status']?.toString()),
            'Status',
          ),
        ),
        if (hasSpan) ...[
          const SizedBox(width: 8),
          Expanded(
            child: _buildTeacherStatChip(
              Icons.date_range_rounded,
              eventSpan == 'multi-day' || eventSpan == 'multi_day'
                  ? 'Multi-Day'
                  : 'Single',
              'Span',
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTeacherStatChip(
    IconData icon,
    String value,
    String label,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE0F2FE), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: TeacherThemeUtils.primary.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFF0F9FF),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFE0F2FE)),
            ),
            child: Icon(icon, color: TeacherThemeUtils.primary, size: 18),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 14,
              color: TeacherThemeUtils.dark,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade500,
              letterSpacing: 0.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildTeacherScheduleInfoGrid({
    required DateTime? startDate,
    required DateTime? endDate,
    required String location,
    required String eventType,
    required String target,
    required String graceTime,
  }) {
    final cards = <Widget>[
      _buildTeacherScheduleInfoCard(
        icon: Icons.calendar_month_rounded,
        title: 'Start Date & Time',
        value: startDate != null
            ? DateFormat('MMM d, yyyy, h:mm a').format(startDate)
            : 'TBA',
      ),
      _buildTeacherScheduleInfoCard(
        icon: Icons.event_available_rounded,
        title: 'End Date & Time',
        value: endDate != null
            ? DateFormat('MMM d, yyyy, h:mm a').format(endDate)
            : 'TBA',
      ),
      _buildTeacherScheduleInfoCard(
        icon: Icons.location_on_rounded,
        title: 'Location / Venue',
        value: location,
      ),
      _buildTeacherScheduleInfoCard(
        icon: _getEventTypeIcon(eventType),
        title: 'Event Type',
        value: eventType.isNotEmpty ? eventType : 'General Event',
      ),
      _buildTeacherScheduleInfoCard(
        icon: Icons.groups_rounded,
        title: 'Target Participants',
        value: target,
        fullWidth: true,
      ),
    ];

    if (graceTime.isNotEmpty) {
      cards.add(
        _buildTeacherScheduleInfoCard(
          icon: Icons.timer_rounded,
          title: 'Grace Time',
          value: '$graceTime min',
        ),
      );
    }

    return Wrap(spacing: 12, runSpacing: 12, children: cards);
  }

  Widget _buildTeacherScheduleInfoCard({
    required IconData icon,
    required String title,
    required String value,
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF3F4F6), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFFF0F9FF),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE0F2FE)),
            ),
            child: Icon(icon, color: TeacherThemeUtils.primary, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Colors.grey.shade500,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1F2937),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
        return Icons.landscape_rounded;
      case 'sports event':
        return Icons.sports_soccer_rounded;
      case 'other':
        return Icons.category_rounded;
      default:
        return Icons.style_rounded;
    }
  }

  Widget _buildTeacherSessionMetaRow(
    IconData icon,
    String label,
    String value,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
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
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF6B7280),
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
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â• PARTICIPANTS TAB â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildParticipantsDataBanner() {
    final hasPending = _pendingOfflineParticipantCount > 0;
    final showCachedBanner = _isOfflineMode && _usingCachedParticipants;
    if (!hasPending && !showCachedBanner) {
      return const SizedBox.shrink();
    }

    final backgroundColor = hasPending
        ? const Color(0xFFFFF7ED)
        : const Color(0xFFEFF6FF);
    final borderColor = hasPending
        ? const Color(0xFFF59E0B).withValues(alpha: 0.3)
        : const Color(0xFF3B82F6).withValues(alpha: 0.22);
    final iconColor = hasPending
        ? const Color(0xFFD97706)
        : const Color(0xFF2563EB);
    final title = hasPending
        ? (_isOfflineMode
              ? 'Offline monitoring active'
              : 'Pending offline sync')
        : 'Showing saved participant data';
    final message = hasPending
        ? '$_pendingOfflineParticipantCount participant check-in${_pendingOfflineParticipantCount == 1 ? '' : 's'} still pending sync.'
        : 'This roster is using the latest cached participant data on this device.';

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            hasPending ? Icons.sync_problem_rounded : Icons.cloud_off_rounded,
            size: 18,
            color: iconColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: iconColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: iconColor.withValues(alpha: 0.82),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParticipantsTab() {
    final filtered = _searchQuery.isEmpty
        ? _participants
        : _participants.where((p) {
            final name = _getName(p).toLowerCase();
            final email =
                ((p['users'] is Map ? p['users']['email'] : null) ?? '')
                    .toString()
                    .toLowerCase();
            return name.contains(_searchQuery.toLowerCase()) ||
                email.contains(_searchQuery.toLowerCase());
          }).toList();

    final isSeminarBased = _isSeminarBasedEvent();
    final presentCount = _participants
        .where((p) => _getAttStatus(p) == 'present')
        .length;
    final absentCount = _participants
        .where((p) => _getAttStatus(p) == 'absent')
        .length;
    final seminarOneCount = _eventSessions.isNotEmpty
        ? _participants
              .where(
                (p) => _hasSessionScan(
                  p,
                  _eventSessions.first['id']?.toString() ?? '',
                ),
              )
              .length
        : 0;
    final seminarTwoCount = _eventSessions.length > 1
        ? _participants
              .where(
                (p) => _hasSessionScan(
                  p,
                  _eventSessions[1]['id']?.toString() ?? '',
                ),
              )
              .length
        : 0;

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: _buildStatChip(
                  'Joined',
                  _eventService.formatParticipantTotal(
                    _participants.length,
                    _event['registration_limit'],
                  ),
                  TeacherThemeUtils.primary,
                  Icons.people_rounded,
                ),
              ),
              if (isSeminarBased) ...[
                if (_eventSessions.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildStatChip(
                      'Seminar 1',
                      '$seminarOneCount',
                      const Color(0xFF60A5FA),
                      Icons.looks_one_rounded,
                    ),
                  ),
                ],
                if (_eventSessions.length > 1) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildStatChip(
                      'Seminar 2',
                      '$seminarTwoCount',
                      const Color(0xFF1D4ED8),
                      Icons.looks_two_rounded,
                    ),
                  ),
                ],
              ] else ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatChip(
                    'Present',
                    '$presentCount',
                    const Color(0xFF10B981),
                    Icons.check_circle_rounded,
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: _buildStatChip(
                  'Absent',
                  '$absentCount',
                  const Color(0xFFF59E0B),
                  Icons.pending_actions_rounded,
                ),
              ),
            ],
          ),
        ),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 46,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: TextField(
                    onChanged: (v) => setState(() => _searchQuery = v),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    decoration: const InputDecoration(
                      hintText: 'Search students...',
                      hintStyle: TextStyle(
                        color: Color(0xFF9CA3AF),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        color: Color(0xFF9CA3AF),
                        size: 20,
                      ),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                height: 46,
                width: 46,
                decoration: BoxDecoration(
                  color: TeacherThemeUtils.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: TeacherThemeUtils.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: IconButton(
                  icon: const Icon(
                    Icons.download_rounded,
                    color: TeacherThemeUtils.primary,
                    size: 20,
                  ),
                  onPressed: () => _exportCsv(filtered),
                  tooltip: 'Export CSV',
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
        _buildParticipantsDataBanner(),
        const Divider(height: 1, color: Color(0xFFF3F4F6)),
        Expanded(
          child: _isLoadingRoster
              ? const Center(child: PulseConnectLoader())
              : filtered.isEmpty
              ? _buildEmptyState(
                  _searchQuery.isNotEmpty
                      ? 'No students match your search.'
                      : 'No students have registered yet.',
                  _searchQuery.isNotEmpty
                      ? Icons.search_off_rounded
                      : Icons.group_off_rounded,
                )
              : RefreshIndicator(
                  color: TeacherThemeUtils.primary,
                  onRefresh: () => _loadData(true),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, i) =>
                        _buildParticipantCard(filtered[i], i),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildStatChip(
    String label,
    String value,
    Color color,
    IconData icon,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.16), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 18,
              height: 1.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w800,
              fontSize: 9,
              letterSpacing: 0.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildParticipantCard(Map<String, dynamic> p, int index) {
    final name = _getName(p);
    final initials = _getInitials(name);
    final isSeminarBased = _isSeminarBasedEvent();
    final attStatus = _getAttStatus(p);
    final checkIn = _getCheckIn(p);
    final sessionAttendance = _visibleSessionIndicators(p);
    final sessionCount = _getSessionCount(p);
    final hasPendingSync = _participantHasPendingSync(p);

    final u = p['users'];
    final email = (u is Map ? u['email'] : null)?.toString() ?? '';
    final course = (u is Map ? u['course'] : null)?.toString() ?? '';
    final yearLevel = (u is Map ? u['year_level'] : null)?.toString() ?? '';
    final levelText = [
      if (yearLevel.isNotEmpty) yearLevel,
      if (course.isNotEmpty) course,
    ].join(' | ');

    Color statusColor;
    Color statusBg;
    String statusLabel;
    IconData statusIcon;

    switch (attStatus) {
      case 'present':
        statusColor = const Color(0xFF10B981); // beautiful emerald-500
        statusBg = const Color(0xFFECFDF5);
        statusLabel = isSeminarBased && sessionCount > 0
            ? '$sessionCount Present'
            : 'Present';
        statusIcon = Icons.check_circle_rounded;
        break;
      case 'absent':
        statusColor = const Color(0xFFF59E0B); // beautiful amber-500
        statusBg = const Color(0xFFFEF3C7);
        statusLabel = 'Absent';
        statusIcon = Icons.warning_amber_rounded;
        break;
      default:
        statusColor = Colors.grey.shade600;
        statusBg = const Color(0xFFF3F4F6);
        statusLabel = 'Registered';
        statusIcon = Icons.confirmation_num_rounded;
    }

    const avatarColors = [
      TeacherThemeUtils.primary,
      Color(0xFF1D4ED8),
      Color(0xFF7C3AED),
      Color(0xFF1E40AF),
      Color(0xFFB45309),
    ];
    final avatarColor = avatarColors[index % avatarColors.length];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: const Color(0xFFF3F4F6), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    avatarColor,
                    avatarColor.withValues(alpha: 0.8),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: avatarColor.withValues(alpha: 0.25),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  initials,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: Color(0xFF111827),
                    ),
                  ),
                  if (email.isNotEmpty)
                    Text(
                      email,
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  if (levelText.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      levelText,
                      style: const TextStyle(
                        color: Color(0xFF9CA3AF),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (checkIn != '-')
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.login_rounded,
                              size: 12,
                              color: Color(0xFF60A5FA),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              checkIn,
                              style: const TextStyle(
                                color: Color(0xFF60A5FA),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      if (isSeminarBased)
                        ..._eventSessions.map((session) {
                          final status = _sessionStatusForParticipant(
                            p,
                            session,
                          );
                          final label = _sessionIndicatorLabel(session);
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _sessionStatusBgColor(status),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '$label: ${_sessionStatusLabel(status)}',
                              style: TextStyle(
                                color: _sessionStatusTextColor(status),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          );
                        }),
                      if (isSeminarBased &&
                          _eventSessions.isEmpty &&
                          sessionAttendance.isNotEmpty)
                        ...sessionAttendance.map((scan) {
                          final status = _sessionRowIsPresent(scan)
                              ? 'present'
                              : (_sessionRowIsAbsent(scan)
                                    ? 'absent'
                                    : 'unscanned');
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _sessionStatusBgColor(status),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '${_sessionIndicatorLabel(scan)}: ${_sessionStatusLabel(status)}',
                              style: TextStyle(
                                color: _sessionStatusTextColor(status),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          );
                        }),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: statusBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, size: 12, color: statusColor),
                      const SizedBox(width: 4),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasPendingSync) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFFED7AA)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.cloud_upload_rounded,
                          size: 12,
                          color: Color(0xFFD97706),
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Pending Sync',
                          style: TextStyle(
                            color: Color(0xFFD97706),
                            fontWeight: FontWeight.w700,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(String message, IconData icon) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F9FF),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFE0F2FE), width: 2),
              ),
              child: Icon(icon, size: 48, color: TeacherThemeUtils.primary),
            ),
            const SizedBox(height: 20),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF1F2937),
                fontWeight: FontWeight.w800,
                fontSize: 15,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Pull down to refresh',
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===================== ASSISTANTS TAB =====================
  Widget _buildAssistantsTab() {
    final isExpired = _event['status'] == 'expired';

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Authorized Scanners',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isExpired
                          ? 'This event is completed. Assistant management is disabled.'
                          : _canManageAssistants
                          ? 'These students can scan tickets on your behalf.'
                          : 'Assistant management is limited to teachers assigned by admin.',
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: (_canManageAssistants && !isExpired)
                    ? _showAssignAssistantSheet
                    : null,
                icon: const Icon(Icons.person_add_rounded, size: 16),
                label: const Text('Assign'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: TeacherThemeUtils.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF3F4F6)),
        Expanded(
          child: _isLoadingRoster
              ? const Center(child: PulseConnectLoader())
              : _assistants.isEmpty
              ? RefreshIndicator(
                  color: TeacherThemeUtils.primary,
                  onRefresh: () => _loadData(true),
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Container(
                      height: MediaQuery.of(context).size.height * 0.5,
                      alignment: Alignment.center,
                      child: _buildEmptyState(
                        isExpired
                            ? 'No assistants were assigned to this event.'
                            : _canManageAssistants
                            ? 'No assistants assigned yet.'
                            : 'Only assigned teachers can manage assistants.',
                        isExpired
                            ? Icons.person_off_rounded
                            : _canManageAssistants
                            ? Icons.person_off_rounded
                            : Icons.lock_outline_rounded,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  itemCount: _assistants.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final a = _assistants[i];
                    final assistantName = _getAssistantName(a);
                    final assistantIdNumber = _getAssistantStudentNumber(a);
                    final initials = _getInitials(assistantName);

                    const avatarColors = [
                      TeacherThemeUtils.primary,
                      Color(0xFF1D4ED8),
                      Color(0xFF7C3AED),
                      Color(0xFF1E40AF),
                      Color(0xFFB45309),
                    ];
                    final avatarColor = avatarColors[i % avatarColors.length];

                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                        border: Border.all(color: const Color(0xFFF3F4F6), width: 1.5),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  avatarColor,
                                  avatarColor.withValues(alpha: 0.8),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: avatarColor.withValues(alpha: 0.25),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                initials,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  assistantName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                    color: Color(0xFF111827),
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'Student ID: $assistantIdNumber',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF6B7280),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Transform.scale(
                            scale: 0.8,
                            child: Switch(
                              value: a['allow_scan'] == true,
                              activeThumbColor: Colors.white,
                              activeTrackColor: TeacherThemeUtils.primary,
                              inactiveThumbColor: Colors.grey.shade400,
                              inactiveTrackColor: Colors.grey.shade200,
                              onChanged: (_canManageAssistants && !isExpired)
                                  ? (v) => _toggleAssistant(a, v)
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  bool get _shouldShowEventQr {
    final status = (_event['status']?.toString() ?? '').toLowerCase();
    return status == 'published' ||
        status == 'expired' ||
        status == 'finished';
  }

  // ===================== EVENT QR (inline in Details) =====================
  Widget _buildEventQrSection() {
    final eventId = (_event['id']?.toString() ?? '').trim();
    final qrPayload = EventService.buildEventQrPayload(eventId);
    if (qrPayload.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: TeacherThemeUtils.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.qr_code_2_rounded,
                  color: TeacherThemeUtils.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Event QR Code',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: Color(0xFF111827),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Students scan this during the scan window',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Center(
            child: RepaintBoundary(
              key: _eventQrKey,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: QrImageView(
                  data: qrPayload,
                  version: QrVersions.auto,
                  size: 168,
                  errorCorrectionLevel: QrErrorCorrectLevel.H,
                  embeddedImage: const AssetImage('assets/CCS.png'),
                  embeddedImageStyle: const QrEmbeddedImageStyle(
                    size: Size(38, 38),
                  ),
                  eyeStyle: QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: TeacherThemeUtils.primary,
                  ),
                  dataModuleStyle: QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: TeacherThemeUtils.primary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton.icon(
              onPressed: _isSavingEventQr ? null : _downloadEventQr,
              icon: _isSavingEventQr
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: TeacherThemeUtils.primary,
                      ),
                    )
                  : Icon(
                      Icons.download_rounded,
                      size: 18,
                      color: TeacherThemeUtils.primary,
                    ),
              label: Text(
                _isSavingEventQr ? 'Saving...' : 'Download QR',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: TeacherThemeUtils.primary,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: TeacherThemeUtils.primary,
                side: BorderSide(color: TeacherThemeUtils.primary.withValues(alpha: 0.35)),
                backgroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadEventQr() async {
    final eventId = (_event['id']?.toString() ?? '').trim();
    if (eventId.isEmpty) return;

    setState(() => _isSavingEventQr = true);
    try {
      final boundary = _eventQrKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        throw Exception('QR preview is not ready yet.');
      }

      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw Exception('Could not capture QR image.');
      }

      final bytes = byteData.buffer.asUint8List();
      final rawTitle = (_event['title']?.toString() ?? 'event')
          .replaceAll(RegExp(r'[^\w\s-]+'), '')
          .trim()
          .replaceAll(RegExp(r'\s+'), '_');
      final safeTitle = rawTitle.isEmpty ? 'event' : rawTitle;
      final fileName = 'event_qr_${safeTitle}_$eventId.png';

      try {
        final hasAccess = await Gal.hasAccess(toAlbum: true);
        if (!hasAccess) {
          final granted = await Gal.requestAccess(toAlbum: true);
          if (!granted) {
            throw Exception('Gallery access was denied.');
          }
        }

        await Gal.putImageBytes(bytes, name: fileName);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('QR code saved to gallery.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      } on MissingPluginException {
        // New native plugin needs a full app restart (hot reload is not enough).
        final tempDir = await getTemporaryDirectory();
        final file = File('${tempDir.path}/$fileName');
        await file.writeAsBytes(bytes);
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            text: 'Event QR for ${(_event['title']?.toString() ?? 'Event').trim()}',
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Gallery plugin needs a full app restart. Shared QR instead — stop the app and rebuild to save directly to gallery.',
              ),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 5),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save QR: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSavingEventQr = false);
      }
    }
  }
}
