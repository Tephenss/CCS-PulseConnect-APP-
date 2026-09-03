import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import '../../widgets/app_snackbar.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/auth_service.dart';
import '../../services/event_live_service.dart';
import '../../services/event_service.dart';
import '../../services/offline_sync_service.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/scan_attendance_live_indicator.dart';
import '../../utils/teacher_theme_utils.dart';

class TeacherScanScreen extends StatefulWidget {
  /// When false (another home tab selected), pause camera + polling but
  /// keep State alive so returning does not full-reload.
  final bool isActive;

  const TeacherScanScreen({super.key, this.isActive = true});

  @override
  State<TeacherScanScreen> createState() => _TeacherScanScreenState();
}

class _TeacherScanScreenState extends State<TeacherScanScreen>
    with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _isScanning = false;
  /// Blocks new detects without tearing down the camera (avoids white flash).
  bool _isProcessingScan = false;
  String _scanStatus = 'Checking scanner assignment...';
  Color _statusColor = Colors.grey.shade600;
  bool _hasScanResult = false;
  String _teacherId = '';

  Map<String, dynamic>? _scanContext;
  String _selectedEventTitle = '';
  double? _attendancePercent;
  int? _attendancePresent;
  int? _attendanceTotal;
  bool _attendanceStatsLoading = false;

  bool _isOffline = false;
  int _pendingSyncCount = 0;
  bool _isSyncing = false;
  bool _offlineSnapshotReady = false;
  bool _offlineSnapshotStale = false;
  bool _offlineWarmFailed = false;
  DateTime? _offlineLastSyncedAt;
  Map<String, dynamic>? _offlinePinnedOpenContext;
  bool _isRefreshingContext = false;
  Timer? _scanResumeTimer;
  Timer? _contextRefreshTimer;
  Timer? _windowCloseTimer;
  bool _manualPause = false;
  String _lastScannedCode = '';
  DateTime? _lastScannedAt;
  String _lastVerifiedParticipantName = '';
  String _lastVerifiedParticipantStudentNo = '';
  String _lastVerifiedParticipantPhotoUrl = '';
  String _lastVerifiedParticipantPhotoLocalPath = '';
  String _lastVerifiedStatusLabel = 'Present';
  DateTime? _lastVerifiedAt;
  /// Bumped whenever overlay identity changes so late avatar hydrates cannot
  /// re-apply a previous student's photo onto the next scan.
  int _verifiedOverlayEpoch = 0;
  static const Duration _sameCodeCooldown = Duration(seconds: 5);
  static const Duration _scanSoundCooldown = Duration(milliseconds: 120);
  static const Duration _resumeAfterSuccess = Duration(milliseconds: 2200);
  static const Duration _resumeAfterFailure = Duration(milliseconds: 1800);
  static const String _scannerClosedLabel = 'Scanning Closed';
  static const Duration _manilaOffset = Duration(hours: 8);
  final AudioPlayer _scanSoundPlayer = AudioPlayer();
  DateTime? _lastScanSoundAt;
  bool _scanSoundConfigured = false;

  /// Explicit controller: QR-only + unrestricted detection (screen-of-screen
  /// tickets need more frames than DetectionSpeed.normal's 250ms gate).
  /// autoZoom (Android): zooms when a small/far QR is detected — Lens-like assist.
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.unrestricted,
    facing: CameraFacing.back,
    formats: const [BarcodeFormat.qrCode],
    returnImage: false,
    cameraResolution: const Size(1280, 720),
    autoZoom: true,
  );

  Future<void> _configureScanSoundPlayer() async {
    if (_scanSoundConfigured) return;
    _scanSoundConfigured = true;
    try {
      await _scanSoundPlayer.setPlayerMode(PlayerMode.lowLatency);
    } catch (_) {}
    try {
      await _scanSoundPlayer.setReleaseMode(ReleaseMode.stop);
    } catch (_) {}
    try {
      await _scanSoundPlayer.setVolume(1.0);
    } catch (_) {}
  }

  Future<void> _playFallbackFeedback({required bool isSuccess}) async {
    try {
      await SystemSound.play(
        isSuccess ? SystemSoundType.click : SystemSoundType.alert,
      );
    } catch (_) {}

    try {
      if (isSuccess) {
        await HapticFeedback.lightImpact();
      } else {
        await HapticFeedback.heavyImpact();
      }
    } catch (_) {}
  }

  Future<bool> _tryPlayAssetSound(String assetPath, {PlayerMode? mode}) async {
    try {
      await _scanSoundPlayer.play(AssetSource(assetPath), mode: mode);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _playScanSound(
    String assetPath, {
    required bool isSuccess,
    bool bypassCooldown = false,
    String? backupAssetPath,
    bool alwaysPlaySystemFallback = false,
  }) async {
    final now = DateTime.now();
    if (!bypassCooldown &&
        _lastScanSoundAt != null &&
        now.difference(_lastScanSoundAt!) < _scanSoundCooldown) {
      return;
    }
    _lastScanSoundAt = now;

    await _configureScanSoundPlayer();
    var playedAsset = false;
    try {
      await _scanSoundPlayer.stop();
    } catch (_) {}

    playedAsset = await _tryPlayAssetSound(
      assetPath,
      mode: PlayerMode.lowLatency,
    );
    if (!playedAsset) {
      playedAsset = await _tryPlayAssetSound(assetPath);
    }

    if (!playedAsset &&
        backupAssetPath != null &&
        backupAssetPath.trim().isNotEmpty) {
      playedAsset = await _tryPlayAssetSound(
        backupAssetPath.trim(),
        mode: PlayerMode.lowLatency,
      );
      if (!playedAsset) {
        playedAsset = await _tryPlayAssetSound(backupAssetPath.trim());
      }
    }

    if (!playedAsset || alwaysPlaySystemFallback) {
      await _playFallbackFeedback(isSuccess: isSuccess);
    }
  }

  void _playSuccessScanSound() {
    unawaited(_playScanSound('sounds/scan_success.wav', isSuccess: true));
  }

  void _playFailedScanSound() {
    unawaited(_playScanSound('sounds/scan_error.wav', isSuccess: false));
  }

  Future<void> _applyInstantCheckInResult(
    Map<String, dynamic> res, {
    required bool fromOfflineQueue,
  }) async {
    if (!mounted) return;

    setState(() {
      final status = (res['status']?.toString() ?? '').toLowerCase();
      if (res['ok'] == true &&
          (status == 'queued_offline' || fromOfflineQueue)) {
        final participantName =
            (res['participant_name']?.toString() ?? '').trim();
        final action = (res['action']?.toString() ?? '').toLowerCase();
        final queuedLabel =
            action == 'check_out' ? 'Timed Out' : 'Present';
        _scanStatus = participantName.isNotEmpty
            ? 'Queued offline: $participantName — $queuedLabel'
            : (res['message']?.toString() ??
                'Offline check-in saved. Syncing when online.');
        _statusColor = Colors.orange.shade700;
        _rememberVerifiedParticipant(res, statusLabel: 'Queued');
        _playSuccessScanSound();
      } else if (res['ok'] == true) {
        final participantName =
            (res['participant_name']?.toString() ?? '').trim();
        final action = (res['action']?.toString() ?? '').toLowerCase();
        final timedOut = status == 'checked_out' || action == 'check_out';
        final rawMessage = (res['message']?.toString() ?? '').trim();
        final looksLikeSyncMessage = rawMessage.toLowerCase().contains('synchron') ||
            rawMessage.toLowerCase().contains('earliest recorded');
        _scanStatus = participantName.isNotEmpty
            ? (timedOut
                ? '$participantName — Timed out'
                : (looksLikeSyncMessage
                    ? '$participantName — Already checked in'
                    : '$participantName — Present'))
            : (looksLikeSyncMessage
                ? 'Already checked in.'
                : (rawMessage.isNotEmpty
                    ? rawMessage
                    : (timedOut
                        ? 'Timed out successfully!'
                        : 'Check-in successful!')));
        _statusColor = looksLikeSyncMessage && !timedOut
            ? Colors.orange.shade700
            : TeacherThemeUtils.primary;
        _rememberVerifiedParticipant(
          res,
          statusLabel: timedOut
              ? 'Timed out'
              : (looksLikeSyncMessage ? 'Already in' : 'Present'),
        );
        _playSuccessScanSound();
      } else if (status == 'already_checked_in' || status == 'used') {
        final participantName =
            (res['participant_name']?.toString() ?? '').trim();
        _scanStatus = participantName.isNotEmpty
            ? '$participantName — Already checked in'
            : _normalizeScannerMessage(
                res['error']?.toString(),
                fallback: 'Already checked in.',
              );
        _statusColor = Colors.orange.shade700;
        _rememberVerifiedParticipant(res, statusLabel: 'Already in');
        _playFailedScanSound();
      } else if (status == 'absent_no_time_in' ||
          (res['error']?.toString() ?? '')
              .toLowerCase()
              .contains('no time-in')) {
        final participantName =
            (res['participant_name']?.toString() ?? '').trim();
        _scanStatus = participantName.isNotEmpty
            ? '$participantName — Absent (no time-in)'
            : _normalizeScannerMessage(
                res['error']?.toString(),
                fallback:
                    'Cannot time out — this student has no time-in (marked absent).',
              );
        _statusColor = Colors.red.shade700;
        _rememberVerifiedParticipant(res, statusLabel: 'Absent');
        _playFailedScanSound();
      } else if (status == 'wrong_event' || status == 'forbidden') {
        _scanStatus = _normalizeScannerMessage(
          res['error']?.toString(),
          fallback: status == 'wrong_event'
              ? 'Wrong event ticket. Scan a ticket for this event only.'
              : 'You are not assigned to scan this event.',
        );
        _statusColor = Colors.red.shade700;
        _clearVerifiedParticipantOverlay();
        _playFailedScanSound();
      } else if (status == 'checked_out' || status == 'already_checked_out') {
        final participantName =
            (res['participant_name']?.toString() ?? '').trim();
        final timedOut = status == 'checked_out' || res['ok'] == true;
        _scanStatus = participantName.isNotEmpty
            ? (timedOut
                ? '$participantName — Timed out'
                : '$participantName — Already timed out')
            : _normalizeScannerMessage(
                res['error']?.toString() ?? res['message']?.toString(),
                fallback: timedOut ? 'Timed out successfully!' : 'Already timed out.',
              );
        _statusColor = timedOut ? TeacherThemeUtils.primary : Colors.orange.shade700;
        if (timedOut) {
          _rememberVerifiedParticipant(res, statusLabel: 'Timed out');
          _playSuccessScanSound();
        } else {
          // Warning state — never keep a green "Present" card here.
          _rememberVerifiedParticipant(res, statusLabel: 'Already out');
          _playFailedScanSound();
        }
      } else if ((res['error']?.toString() ?? '')
          .toLowerCase()
          .contains('already timed out')) {
        final participantName =
            (res['participant_name']?.toString() ?? '').trim();
        _scanStatus = participantName.isNotEmpty
            ? '$participantName — Already timed out'
            : 'Already timed out.';
        _statusColor = Colors.orange.shade700;
        _rememberVerifiedParticipant(res, statusLabel: 'Already out');
        _playFailedScanSound();
      } else {
        _scanStatus = _normalizeScannerMessage(
          res['error']?.toString(),
          fallback: _isOffline
              ? 'Offline check-in failed. Refresh cache online first.'
              : 'Check-in failed.',
        );
        _statusColor = Colors.red.shade700;
        // Don't keep a stale "Present" card when the scan failed.
        _clearVerifiedParticipantOverlay();
        _playFailedScanSound();
      }
      _hasScanResult = true;
      _manualPause = false;
      _bumpAttendanceAfterSuccessfulScan(res);
    });

    if (!_isOffline) {
      unawaited(_refreshAttendanceStats());
      // Snapshot refresh only — do not drain the offline queue here.
      // Syncing after every online scan flashes the Sync banner even when
      // the check-in already succeeded online.
      unawaited(
        _offlineSyncService.refreshSnapshotForCurrentScanner(
          actorId: _teacherId,
          isTeacher: true,
          force: true,
        ),
      );
    } else {
      unawaited(_refreshPendingSyncCount());
    }

    // Re-arm quickly so the next ticket can be scanned without a long dead zone.
    // Same-QR double-fires are still blocked by _sameCodeCooldown.
    _scheduleScannerResume(
      delay: (res['ok'] == true) ? _resumeAfterSuccess : _resumeAfterFailure,
    );
  }

  late Connectivity _connectivity;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  final AuthService _authService = AuthService();
  final EventService _eventService = EventService();
  final OfflineSyncService _offlineSyncService = OfflineSyncService();
  final _supabase = Supabase.instance.client;
  RealtimeChannel? _assignmentChannel;
  RealtimeChannel? _eventChannel;
  StreamSubscription<String>? _eventLiveSubscription;
  String _boundLiveEventId = '';

  bool get _hasAssignedEventContext {
    final rawContext = _scanContext?['context'];
    final context = rawContext is Map<String, dynamic>
        ? rawContext
        : (rawContext is Map ? Map<String, dynamic>.from(rawContext) : null);
    final eventRaw = context?['event'];
    final event = eventRaw is Map<String, dynamic>
        ? eventRaw
        : (eventRaw is Map ? Map<String, dynamic>.from(eventRaw) : null);
    final eventId = (event?['id']?.toString() ?? '').trim();
    final assignments =
        int.tryParse(_scanContext?['assignments']?.toString() ?? '') ?? 0;
    return eventId.isNotEmpty || assignments > 0;
  }

  bool get _hasPermission =>
      _scanContext != null &&
      _scanContext?['ok'] == true &&
      _teacherId.isNotEmpty &&
      (_scanContext?['status']?.toString() ?? '') != 'no_assignment' &&
      (_scanContext?['status']?.toString() ?? '') != 'error' &&
      _hasAssignedEventContext;
  bool get _shouldShowAccessGate {
    if (_isLoading) return false;
    if (_hasPermission) return false;
    final status = (_scanContext?['status']?.toString() ?? '').toLowerCase();
    if (status == 'checking') return false;
    if (_payloadHasAssignedContext(_scanContext)) return false;
    return _teacherId.isEmpty || status == 'no_assignment';
  }
  bool get _scannerEnabled => _scanContext?['scanner_enabled'] == true;
  bool get _showOfflineReadinessIndicator =>
      _isOffline &&
      !_hasScanResult &&
      !_payloadHasAssignedContext(_scanContext) &&
      !_shouldShowAccessGate &&
      (!_offlineSnapshotReady || _offlineSnapshotStale);

  bool _payloadHasAssignedContext(Map<String, dynamic>? payload) {
    if (payload == null || payload.isEmpty) return false;
    final status = (payload['status']?.toString() ?? '').trim().toLowerCase();
    if (status == 'no_assignment' || status == 'error' || status == 'checking') {
      return false;
    }
    final context = payload['context'];
    final contextMap = context is Map<String, dynamic>
        ? context
        : (context is Map ? Map<String, dynamic>.from(context) : null);
    final eventRaw = contextMap?['event'];
    final eventMap = eventRaw is Map<String, dynamic>
        ? eventRaw
        : (eventRaw is Map ? Map<String, dynamic>.from(eventRaw) : null);
    final eventId = (eventMap?['id']?.toString() ?? '').trim();
    final assignments =
        int.tryParse(payload['assignments']?.toString() ?? '') ?? 0;
    return eventId.isNotEmpty || assignments > 0;
  }

  Future<void> _sealCurrentContextForOfflineTransition() async {
    final current = _scanContext;
    if (_teacherId.trim().isEmpty || !_payloadHasAssignedContext(current)) {
      return;
    }

    final snapshot = Map<String, dynamic>.from(current!);
    try {
      await _offlineSyncService.cacheLiveScannerContext(
        actorId: _teacherId,
        isTeacher: true,
        contextPayload: snapshot,
      );
    } catch (_) {
      // Keep current in-memory state even if cache write fails.
    }

    _rememberOfflinePinnedContext(snapshot);
  }

  bool _applyCurrentContextOfflineTransition() {
    final current = _scanContext;
    if (!_payloadHasAssignedContext(current)) return false;

    final snapshot = _resolveOfflineWindowLocally(
      Map<String, dynamic>.from(current!),
    );
    final context = snapshot['context'];
    final contextMap = context is Map<String, dynamic>
        ? context
        : (context is Map ? Map<String, dynamic>.from(context) : null);
    final status = (snapshot['status']?.toString() ?? 'closed').trim();
    final scannerEnabled = snapshot['scanner_enabled'] == true;

    if (!mounted) return false;
    setState(() {
      _scanContext = snapshot;
      _selectedEventTitle = _currentEventTitle(contextMap);
      _isScanning = _cameraShouldRun(scannerEnabled: scannerEnabled);
      if (!_hasScanResult) {
        _scanStatus = scannerEnabled
            ? 'Offline mode active. Ready to scan from cache.'
            : _scanAvailabilityNote(
                status: status,
                serviceMessage: (snapshot['message']?.toString() ?? '').trim(),
                context: contextMap,
              );
        _statusColor = scannerEnabled
            ? Colors.orange.shade700
            : _contextColor(status);
      }
    });
    if (scannerEnabled) {
      _rememberOfflinePinnedContext(snapshot);
    }
    _scheduleWindowCloseTimer(_scanContext);
    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_configureScanSoundPlayer());
    _initConnectivity();
    _initScannerAccess();
    if (!widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyTabVisibility(active: false);
      });
    }
  }

  @override
  void didUpdateWidget(TeacherScanScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) return;
    _applyTabVisibility(active: widget.isActive);
  }

  void _applyTabVisibility({required bool active}) {
    if (!active) {
      _scanResumeTimer?.cancel();
      _contextRefreshTimer?.cancel();
      _contextRefreshTimer = null;
      _windowCloseTimer?.cancel();
      _windowCloseTimer = null;
      if (mounted) {
        setState(() {
          _isScanning = false;
          _isProcessingScan = false;
        });
      } else {
        _isScanning = false;
        _isProcessingScan = false;
      }
      return;
    }

    if (_teacherId.isNotEmpty) {
      _startContextRefreshTimer();
      unawaited(_refreshScanContext(silent: true));
    }
    final scannerEnabled = _scanContext?['scanner_enabled'] == true;
    if (_cameraShouldRun(scannerEnabled: scannerEnabled) && mounted) {
      setState(() {
        _isScanning = true;
        _isProcessingScan = false;
      });
    }
    _scheduleWindowCloseTimer(_scanContext);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanResumeTimer?.cancel();
    _contextRefreshTimer?.cancel();
    _windowCloseTimer?.cancel();
    _eventLiveSubscription?.cancel();
    _assignmentChannel?.unsubscribe();
    _eventChannel?.unsubscribe();
    _scanSoundPlayer.dispose();
    _connectivitySubscription.cancel();
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  bool _shouldRefreshScanContextForLiveReason(String reason) {
    final core = reason.startsWith('offline:')
        ? reason.substring('offline:'.length)
        : reason;
    return core == 'events' ||
        core.startsWith('events') ||
        core == 'teacher_assignments' ||
        core.startsWith('teacher_assignments') ||
        core == 'assistants' ||
        core.startsWith('assistants') ||
        core == 'sessions' ||
        core.startsWith('sessions');
  }

  void _startContextRefreshTimer() {
    _contextRefreshTimer?.cancel();
    if (_teacherId.isEmpty || !widget.isActive) return;
    _contextRefreshTimer = Timer.periodic(
      // Realtime is primary. This is only a quiet backup for window/access.
      const Duration(seconds: 45),
      (_) {
        if (!widget.isActive) return;
        _enforceLocalOfflineWindowGuard();
        unawaited(_refreshScanContext(silent: true));
        unawaited(_syncQueueWhenOnline(showSnack: false));
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _contextRefreshTimer?.cancel();
      _contextRefreshTimer = null;
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (!widget.isActive) return;
      _startContextRefreshTimer();
      unawaited(_refreshScanContext(silent: true));
      unawaited(_syncQueueWhenOnline(showSnack: false));
      if (!_isOffline && _teacherId.trim().isNotEmpty) {
        unawaited(
          _offlineSyncService.refreshSnapshotForCurrentScanner(
            actorId: _teacherId,
            isTeacher: true,
            force: true,
          ),
        );
      }
    }
  }

  bool _resultsAreOffline(List<ConnectivityResult> results) {
    return results.isEmpty ||
        results.every((result) => result == ConnectivityResult.none);
  }

  Future<bool> _resolveIsOffline({
    List<ConnectivityResult>? linkResults,
  }) async {
    // Offline scanner mode follows the radio link only.
    final results = linkResults ?? await Connectivity().checkConnectivity();
    return _resultsAreOffline(results);
  }

  /// Camera only runs while this tab is visible (keep-alive when inactive).
  bool _cameraShouldRun({bool? scannerEnabled}) {
    final enabled =
        scannerEnabled ?? (_scanContext?['scanner_enabled'] == true);
    return widget.isActive && enabled && !_manualPause;
  }

  /// Keep the platform camera view mounted during check-in (no remount flash).
  bool get _shouldMountCamera => _cameraShouldRun();

  bool get _acceptingScans =>
      _shouldMountCamera && _isScanning && !_isProcessingScan;

  /// Parse event/attendance ISO like EventService (UTC; naive = Manila wall time).
  DateTime? _parseIsoToUtc(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null;
    final dt = DateTime.tryParse(text);
    if (dt == null) return null;
    final hasExplicitOffset = RegExp(
      r'(z|[+-]\d{2}:\d{2}|[+-]\d{4})$',
      caseSensitive: false,
    ).hasMatch(text);
    if (hasExplicitOffset) return dt.toUtc();
    return DateTime.utc(
      dt.year,
      dt.month,
      dt.day,
      dt.hour,
      dt.minute,
      dt.second,
      dt.millisecond,
      dt.microsecond,
    ).subtract(_manilaOffset);
  }

  DateTime? _contextClosesAtUtc(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final rawContext = payload['context'];
    final context = rawContext is Map<String, dynamic>
        ? rawContext
        : (rawContext is Map ? Map<String, dynamic>.from(rawContext) : null);
    return _parseIsoToUtc(context?['closes_at']?.toString());
  }

  /// True only while local closes_at is still in the future (no enabled sticky).
  bool _localClosesAtStillInFuture(Map<String, dynamic>? payload) {
    final closesAt = _contextClosesAtUtc(payload);
    if (closesAt == null) return false;
    return !DateTime.now().toUtc().isAfter(closesAt);
  }

  void _scheduleWindowCloseTimer(Map<String, dynamic>? payload) {
    _windowCloseTimer?.cancel();
    _windowCloseTimer = null;
    if (!widget.isActive || payload == null) return;

    final rawContext = payload['context'];
    final contextMap = rawContext is Map<String, dynamic>
        ? rawContext
        : (rawContext is Map ? Map<String, dynamic>.from(rawContext) : null);
    if (contextMap == null) return;

    final now = DateTime.now().toUtc();
    final opensAt = _parseIsoToUtc(contextMap['opens_at']?.toString());
    final closesAt = _parseIsoToUtc(contextMap['closes_at']?.toString());
    final enabled = payload['scanner_enabled'] == true;

    // Schedule BOTH open and close boundaries (online + offline).
    // Previously online only scheduled close while enabled — so after end_at
    // the check-out window stayed closed until a manual refresh/touch.
    Duration? delay;
    if (!enabled && opensAt != null && now.isBefore(opensAt)) {
      delay = opensAt.difference(now);
    } else if (enabled && closesAt != null && !now.isAfter(closesAt)) {
      delay = closesAt.difference(now);
    } else if (!enabled && opensAt != null && !now.isBefore(opensAt)) {
      // opens_at already reached but UI still closed — apply now.
      _applyWindowBoundaryNow();
      return;
    } else {
      return;
    }

    if (delay <= Duration.zero) {
      _applyWindowBoundaryNow();
      return;
    }

    _windowCloseTimer = Timer(delay + const Duration(milliseconds: 250), () {
      if (!mounted || !widget.isActive) return;
      _applyWindowBoundaryNow();
    });
  }

  void _applyWindowBoundaryNow() {
    if (_isOffline) {
      _enforceLocalOfflineWindowGuard();
      return;
    }
    _enforceLocalWindowBoundaryOnline();
  }

  /// Online: flip open/close from local schedule immediately, then confirm with BFF.
  void _enforceLocalWindowBoundaryOnline() {
    final active = _scanContext;
    if (active == null || active.isEmpty || !_payloadHasAssignedContext(active)) {
      unawaited(_refreshScanContext(silent: true));
      return;
    }

    final resolved = _resolveOfflineWindowLocally(
      Map<String, dynamic>.from(active),
    );
    final rawContext = resolved['context'];
    final contextMap = rawContext is Map<String, dynamic>
        ? rawContext
        : (rawContext is Map ? Map<String, dynamic>.from(rawContext) : null);
    final nextStatus =
        (resolved['status']?.toString() ?? 'closed').trim().toLowerCase();
    final nextEnabled = resolved['scanner_enabled'] == true;
    final prevStatus =
        (active['status']?.toString() ?? '').trim().toLowerCase();
    final prevEnabled = active['scanner_enabled'] == true;

    if (nextEnabled != prevEnabled || nextStatus != prevStatus) {
      if (!mounted) return;
    setState(() {
        _scanContext = resolved;
        _selectedEventTitle = _currentEventTitle(contextMap);
        _isScanning = _cameraShouldRun(scannerEnabled: nextEnabled);
        _manualPause = false;
        if (!_hasScanResult) {
          _scanStatus = nextEnabled
              ? 'Ready to scan.'
              : _scanAvailabilityNote(
                  status: nextStatus,
                  serviceMessage: (resolved['message']?.toString() ?? '').trim(),
                  context: contextMap,
                );
          _statusColor = nextEnabled
              ? TeacherThemeUtils.primary
              : _contextColor(nextStatus);
        }
      });
    }

    _scheduleWindowCloseTimer(_scanContext);
    unawaited(_refreshScanContext(silent: true));
  }

  Map<String, dynamic> _resolveOfflineWindowLocally(
    Map<String, dynamic> payload,
  ) {
    // Use shared schedule resolver so offline flips check_in → check_out
    // at event end / Early Out (same rules as BFF + ticket validation).
    return _offlineSyncService.resolveScannerContextLocally(payload);
  }

  Future<void> _initScannerAccess() async {
    try {
      final user = await _authService.getCurrentUser();
      final teacherId = user?['id']?.toString() ?? '';
      final initialConnectivity = await Connectivity().checkConnectivity();
      final startOffline = await _resolveIsOffline(
        linkResults: initialConnectivity,
      );

      if (mounted) {
        setState(() {
          _teacherId = teacherId;
          _isOffline = startOffline;
          _selectedEventTitle = '';
          _isScanning = false;
          _offlineSnapshotReady = false;
          _offlineSnapshotStale = false;
          _offlineWarmFailed = false;
          _offlineLastSyncedAt = null;
          _offlinePinnedOpenContext = null;
          _scanStatus = 'Checking scanner assignment...';
          _statusColor = Colors.grey.shade700;
          _hasScanResult = false;
          _scanContext = null;
          _clearVerifiedParticipantOverlay();
          _isLoading = true;
        });
      }

      if (teacherId.isNotEmpty) {
        _bindAssignmentRealtime(teacherId);
        await _refreshPendingSyncCount();
        await _refreshOfflineReadiness();
        var bootstrappedFromCache = false;
        if (startOffline) {
          bootstrappedFromCache = await _applyCachedScanContextFallback();
          if (mounted) {
            setState(() => _isLoading = false);
          }
        }
        if (!startOffline || !bootstrappedFromCache) {
        await _refreshScanContext();
        }
        if (!_isOffline && _pendingSyncCount > 0) {
          unawaited(_syncQueueIfNeeded(showSnack: false));
        }
        _startContextRefreshTimer();
      } else if (mounted) {
        _assignmentChannel?.unsubscribe();
        _assignmentChannel = null;
        setState(() {
          _scanContext = {
            'status': 'no_assignment',
            'scanner_enabled': false,
            'message': 'Unable to identify your teacher account.',
            'context': null,
          };
          _scanStatus = 'Unable to identify your teacher account.';
          _statusColor = Colors.red.shade700;
          _hasScanResult = false;
          _clearVerifiedParticipantOverlay();
        });
      }
    } catch (_) {
      _assignmentChannel?.unsubscribe();
      _assignmentChannel = null;
      if (mounted) {
        setState(() {
          _teacherId = '';
          _offlineSnapshotReady = false;
          _offlineSnapshotStale = false;
          _offlineWarmFailed = false;
          _offlineLastSyncedAt = null;
          _offlinePinnedOpenContext = null;
          _scanContext = {
            'status': 'closed',
            'scanner_enabled': false,
            'message': _scannerClosedLabel,
            'context': null,
          };
          _selectedEventTitle = '';
          _isScanning = false;
          _scanStatus = _scannerClosedLabel;
          _statusColor = Colors.red.shade700;
          _hasScanResult = false;
          _clearVerifiedParticipantOverlay();
          _isLoading = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _refreshScanContext({
    bool silent = false,
    bool forceFresh = false,
  }) async {
    if (_teacherId.isEmpty || _isRefreshingContext) return;
    _isRefreshingContext = true;

    if (!silent && mounted) {
      setState(() {
        _clearVerifiedParticipantOverlay();
        _hasScanResult = false;
      });
    }

    try {
      if (_isOffline) {
        if (_applyCurrentContextOfflineTransition()) {
          if (mounted) {
            setState(() => _isLoading = false);
          }
          return;
        }
        final usedCached = await _applyCachedScanContextFallback();
        if (usedCached) {
          if (mounted) {
            setState(() => _isLoading = false);
          }
          return;
        }
      }

      final result = await _eventService.getTeacherScanContext(
        _teacherId,
        forceFresh: forceFresh || !silent,
      );
      if (!mounted) return;

      final context = result['context'];
      final contextMap = context is Map<String, dynamic>
          ? context
          : (context is Map ? Map<String, dynamic>.from(context) : null);
      final eventTitle = _currentEventTitle(
        context is Map<String, dynamic> ? context : null,
      );
      final status = result['status']?.toString() ?? 'closed';
      final normalizedStatus = status.toLowerCase();
      final scannerEnabled = result['scanner_enabled'] == true;
      final message = (result['message']?.toString() ?? '').trim();
      final eventId =
          (contextMap?['event'] is Map
                  ? (contextMap?['event'] as Map)['id']
                  : null)
              ?.toString()
              .trim() ??
          '';
      final availability = _scanAvailabilityNote(
        status: status,
        serviceMessage: message,
        context: contextMap,
      );
      if (result['ok'] != true || normalizedStatus == 'error') {
        // Ignore only transient blips while the current window deadline remains open.
        if (silent && _localClosesAtStillInFuture(_scanContext)) {
          return;
        }
        if (!_isOffline) {
          setState(() {
            _scanContext = {
              'ok': true,
              'status': 'no_assignment',
              'scanner_enabled': false,
              'message': 'Unable to verify scanner access right now.',
              'context': null,
              'assignments': 0,
            };
            _selectedEventTitle = '';
            _isScanning = false;
            _manualPause = false;
            if (!_hasScanResult) {
              _scanStatus = 'Unable to verify scanner access right now.';
              _statusColor = Colors.red.shade700;
            }
          });
          _scheduleWindowCloseTimer(null);
          if (silent) {
            unawaited(_refreshOfflineReadiness());
          } else {
            await _refreshOfflineReadiness();
          }
          return;
        }
        final usedCached = await _applyCachedScanContextFallback();
        if (usedCached) {
          unawaited(_refreshOfflineReadiness());
          return;
        }
      }

      if (!silent &&
          !_isOffline &&
          result['ok'] == true &&
          normalizedStatus != 'no_assignment' &&
          normalizedStatus != 'error' &&
          eventId.isNotEmpty) {
        final verified = await _eventService.verifyTeacherScanEventAccess(
          eventId,
          _teacherId,
        );
        if (!mounted) return;
        if (verified == false) {
          await _offlineSyncService.clearCachedScannerAccess(
            actorId: _teacherId,
            isTeacher: true,
          );
          setState(() {
            _scanContext = {
              'ok': true,
              'status': 'no_assignment',
              'scanner_enabled': false,
              'message':
                  'QR scanner access for this event was removed by admin.',
              'context': null,
              'assignments': 0,
            };
            _selectedEventTitle = '';
            _isScanning = false;
            _manualPause = false;
            if (!_hasScanResult) {
              _scanStatus = 'QR scanner access was removed by admin.';
              _statusColor = Colors.red.shade700;
            }
          });
          if (silent) {
            unawaited(_refreshOfflineReadiness());
          } else {
            await _refreshOfflineReadiness();
          }
          return;
        }
      }

      if (result['ok'] == true) {
        await _offlineSyncService.cacheLiveScannerContext(
          actorId: _teacherId,
          isTeacher: true,
          contextPayload: Map<String, dynamic>.from(result),
        );
        _rememberOfflinePinnedContext(result);
      }

      setState(() {
        _scanContext = result;
        _selectedEventTitle =
            (normalizedStatus == 'no_assignment' || normalizedStatus == 'error')
                ? ''
                : eventTitle;

        if (normalizedStatus == 'no_assignment' || normalizedStatus == 'error') {
          _isScanning = false;
          _manualPause = false;
        } else if (silent) {
          // Silent polls update access state but must not fight the post-scan
          // resume timer (which owns turning the camera back on).
          if (!scannerEnabled) {
            _isScanning = false;
            _manualPause = false;
            _isProcessingScan = false;
          } else if (!_manualPause && widget.isActive && !_isProcessingScan) {
            // Keep accepts armed — otherwise UI can say "Ready" while
            // _isScanning stayed false and onDetect is ignored.
          _isScanning = true;
          }
        } else if (scannerEnabled && !_manualPause) {
          _isScanning = _cameraShouldRun(scannerEnabled: true);
        } else {
          _isScanning = false;
          if (!scannerEnabled) {
            _manualPause = false;
            _isProcessingScan = false;
          }
        }

        if (!_hasScanResult) {
          _scanStatus = scannerEnabled
              ? 'Ready to scan. Point the camera at the ticket QR code.'
              : availability;
          _statusColor = scannerEnabled
              ? Colors.grey.shade800
              : _contextColor(status);
        }
      });
      _scheduleWindowCloseTimer(result);

      if (eventId.isNotEmpty &&
          result['ok'] == true &&
          normalizedStatus != 'no_assignment' &&
          normalizedStatus != 'error') {
        _bindEventRealtime(eventId);
      } else {
        _bindEventRealtime('');
      }

      if (result['ok'] == true &&
          normalizedStatus != 'no_assignment' &&
          normalizedStatus != 'error') {
        if (!silent) {
          unawaited(_refreshAttendanceStats());
          await _refreshOfflineReadiness(refreshSnapshot: true);
        } else {
          unawaited(_refreshOfflineReadiness());
        }
      } else {
        if (silent) {
          unawaited(_refreshOfflineReadiness());
        } else {
          await _refreshOfflineReadiness();
        }
      }
    } catch (_) {
      final usedCached = _isOffline
          ? await _applyCachedScanContextFallback()
          : false;
      if (!mounted) return;
      if (!usedCached) {
      setState(() {
          _scanContext = {
            'ok': true,
            'status': 'no_assignment',
            'scanner_enabled': false,
            'message':
                _isOffline
                    ? 'Offline mode detected, but this device has no saved scanner data yet.'
                    : 'Unable to verify scanner access right now.',
            'context': null,
            'assignments': 0,
          };
          _selectedEventTitle = '';
        if (!_hasScanResult) {
            _scanStatus =
                _isOffline
                    ? 'Offline scanner data is not ready yet on this device.'
                    : 'Unable to verify scanner access right now.';
          _statusColor = Colors.red.shade700;
        }
        _isScanning = false;
          _manualPause = false;
      });
      }
      unawaited(_refreshOfflineReadiness());
    } finally {
      _isRefreshingContext = false;
      if (!silent && mounted) {
        // reserved for future one-shot feedback
      }
    }
  }

  Future<bool> _applyCachedScanContextFallback() async {
    if (_applyPinnedOpenContextFallback()) {
      return true;
    }

    final cached = await _offlineSyncService.getCachedScannerContext(
      actorId: _teacherId,
      isTeacher: true,
    );
    if (!mounted || cached == null) return false;

    final context = cached['context'];
    final contextMap = context is Map<String, dynamic>
        ? context
        : (context is Map ? Map<String, dynamic>.from(context) : null);
    final status = (cached['status']?.toString() ?? 'closed').trim();
    final scannerEnabled = cached['scanner_enabled'] == true;
    final stale = cached['offline_cache_stale'] == true;
    final shouldDropAccess =
        status.toLowerCase() == 'closed' &&
        _shouldDropOfflineAccessAfterDeadline(contextMap);

    setState(() {
      if (shouldDropAccess) {
        _scanContext = {
          'ok': true,
          'status': 'no_assignment',
          'scanner_enabled': false,
          'message': 'Assigned scanner event has already ended.',
          'context': null,
          'assignments': 0,
        };
        _selectedEventTitle = '';
        _isScanning = false;
        if (!_hasScanResult) {
          _scanStatus = 'Assigned scanner event has already ended.';
          _statusColor = Colors.red.shade700;
        }
      } else {
        _scanContext = cached;
        _selectedEventTitle = _currentEventTitle(contextMap);
        _isScanning = _cameraShouldRun(scannerEnabled: scannerEnabled);
        if (!_hasScanResult) {
          _scanStatus = stale
              ? 'Offline cache expired. Reconnect to refresh scanner data.'
              : (scannerEnabled
                    ? 'Offline mode active. Ready to scan from cache.'
                    : _scanAvailabilityNote(
                        status: status,
                        serviceMessage:
                            (cached['message']?.toString() ?? '').trim(),
                        context: contextMap,
                      ));
          _statusColor = stale
              ? Colors.red.shade700
              : (scannerEnabled
                    ? Colors.orange.shade700
                    : _contextColor(status));
        }
      }
    });
    _scheduleWindowCloseTimer(_scanContext);

    return true;
  }

  void _rememberOfflinePinnedContext(Map<String, dynamic> result) {
    final context = result['context'];
    final contextMap = context is Map<String, dynamic>
        ? context
        : (context is Map ? Map<String, dynamic>.from(context) : null);
    final status = (result['status']?.toString() ?? '').trim().toLowerCase();
    final scannerEnabled = result['scanner_enabled'] == true;

    if (status == 'error') {
      return;
    }
    if (contextMap == null) {
      _offlinePinnedOpenContext = null;
      return;
    }
    if (!scannerEnabled || status != 'open') {
      _offlinePinnedOpenContext = null;
      return;
    }

    _offlinePinnedOpenContext = Map<String, dynamic>.from(result);
  }

  void _bindAssignmentRealtime(String teacherId) {
    final id = teacherId.trim();
    if (id.isEmpty) return;

    _assignmentChannel?.unsubscribe();
    _assignmentChannel = _supabase.channel('public:teacher_scan_access:$id');
    _assignmentChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_teacher_assignments',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'teacher_id',
        value: id,
      ),
      callback: (_) {
        unawaited(_refreshScanContext(silent: true, forceFresh: true));
      },
    );
    _assignmentChannel!.subscribe();

    _eventLiveSubscription?.cancel();
    _eventLiveSubscription = EventLiveService.instance.changes.listen((reason) {
      if (!mounted || _isOffline) return;
      if (!_shouldRefreshScanContextForLiveReason(reason)) return;
      unawaited(_refreshScanContext(silent: true, forceFresh: true));
    });
  }

  void _bindEventRealtime(String eventId) {
    final id = eventId.trim();
    if (id.isEmpty) {
      _eventChannel?.unsubscribe();
      _eventChannel = null;
      _boundLiveEventId = '';
      return;
    }
    if (id == _boundLiveEventId && _eventChannel != null) return;

    _boundLiveEventId = id;
    _eventChannel?.unsubscribe();
    _eventChannel = _supabase.channel('public:teacher_scan_event:$id');
    _eventChannel!
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'events',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: id,
        ),
        callback: (_) {
          unawaited(_refreshScanContext(silent: true, forceFresh: true));
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'event_sessions',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'event_id',
          value: id,
        ),
        callback: (_) {
          unawaited(_refreshScanContext(silent: true, forceFresh: true));
        },
      )
      ..subscribe();
  }

  DateTime? _offlinePinnedDeadline(Map<String, dynamic>? context) {
    if (context == null) return null;

    final explicitClose = _parseScheduleDate(context['closes_at']?.toString());
    if (explicitClose != null) return explicitClose;

    final scanMode =
        (context['scan_mode']?.toString() ?? 'check_in').toLowerCase().trim();

    final session = context['session'];
    final event = context['event'];

    if (scanMode == 'check_out') {
      if (session is Map) {
        final sessionEnd = _parseScheduleDate(session['end_at']?.toString());
        if (sessionEnd != null) {
          return sessionEnd.add(const Duration(hours: 1));
        }
      }
      if (event is Map) {
        final eventEnd = _parseScheduleDate(event['end_at']?.toString());
        if (eventEnd != null) {
          return eventEnd.add(const Duration(hours: 1));
        }
      }
    }

    if (session is Map) {
      final sessionStart = _parseScheduleDate(session['start_at']?.toString());
      final sessionWindow =
          int.tryParse(session['scan_window_minutes']?.toString() ?? '') ?? 30;
      if (sessionStart != null) {
        return sessionStart.add(Duration(minutes: sessionWindow));
      }
    }

    if (event is Map) {
      final eventStart = _parseScheduleDate(event['start_at']?.toString());
      final graceMinutes =
          int.tryParse(event['grace_time']?.toString() ?? '') ?? 30;
      if (eventStart != null) {
        return eventStart.add(Duration(minutes: graceMinutes));
      }
    }

    return null;
  }

  bool _shouldDropOfflineAccessAfterDeadline(Map<String, dynamic>? context) {
    if (context == null) return false;

    // Keep assignment through the post-event time-out window (end_at → +1h),
    // matching student_scan / check-out scan context.
    final event = context['event'];
    if (event is! Map) return false;
    final eventEndAt = _parseScheduleDate(event['end_at']?.toString());
    if (eventEndAt == null) return false;
    final now = DateTime.now().toUtc().add(_manilaOffset);
    return now.isAfter(eventEndAt.add(const Duration(hours: 1)));
  }

  bool _applyPinnedOpenContextFallback() {
    final pinned = _offlinePinnedOpenContext;
    if (pinned == null) return false;

    final context = pinned['context'];
    final contextMap = context is Map<String, dynamic>
        ? context
        : (context is Map ? Map<String, dynamic>.from(context) : null);
    final status = (pinned['status']?.toString() ?? '').trim().toLowerCase();
    final scannerEnabled = pinned['scanner_enabled'] == true;
    final deadline = _offlinePinnedDeadline(contextMap);
    final now = DateTime.now().toUtc().add(_manilaOffset);

    if (contextMap == null ||
        !scannerEnabled ||
        status != 'open' ||
        (deadline != null && now.isAfter(deadline))) {
      _offlinePinnedOpenContext = null;
      return false;
    }

    setState(() {
      _scanContext = pinned;
      _selectedEventTitle = _currentEventTitle(contextMap);
      _isScanning = _cameraShouldRun();
      if (!_hasScanResult) {
        _scanStatus =
            'Offline mode active. Ready to scan from last live event state.';
        _statusColor = Colors.orange.shade700;
      }
    });
    _scheduleWindowCloseTimer(_scanContext);

    return true;
  }

  void _enforceLocalOfflineWindowGuard() {
    if (!_isOffline) return;
    final active = _activeOfflineValidationContext();
    if (active == null || active.isEmpty) return;
    if (!_payloadHasAssignedContext(active)) return;

    final resolved = _resolveOfflineWindowLocally(
      Map<String, dynamic>.from(active),
    );
    final rawContext = resolved['context'];
    final contextMap = rawContext is Map<String, dynamic>
        ? rawContext
        : (rawContext is Map ? Map<String, dynamic>.from(rawContext) : null);
    final nextStatus =
        (resolved['status']?.toString() ?? 'closed').trim().toLowerCase();
    final nextEnabled = resolved['scanner_enabled'] == true;
    final prevStatus =
        (active['status']?.toString() ?? '').trim().toLowerCase();
    final prevEnabled = active['scanner_enabled'] == true;

    if (nextStatus == 'closed' && contextMap != null) {
      final dropAccess = _shouldDropOfflineAccessAfterDeadline(contextMap);
      if (dropAccess && prevStatus != 'no_assignment') {
        _offlinePinnedOpenContext = null;
        if (!mounted) return;
        setState(() {
          _scanContext = {
            'ok': true,
            'status': 'no_assignment',
            'scanner_enabled': false,
            'message': 'Assigned scanner event has already ended.',
            'context': null,
            'assignments': 0,
          };
          _selectedEventTitle = '';
          _isScanning = false;
          _manualPause = false;
          if (!_hasScanResult) {
            _scanStatus = 'Assigned scanner event has already ended.';
            _statusColor = Colors.red.shade700;
          }
        });
        _scheduleWindowCloseTimer(_scanContext);
        unawaited(
          _offlineSyncService.clearCachedScannerAccess(
            actorId: _teacherId,
            isTeacher: true,
          ),
        );
        return;
      }
    }

    if (nextEnabled == prevEnabled && nextStatus == prevStatus) {
      _scheduleWindowCloseTimer(resolved);
      return;
    }

    if (!mounted) return;
    setState(() {
      _scanContext = resolved;
      _selectedEventTitle = _currentEventTitle(contextMap);
      _isScanning = _cameraShouldRun(scannerEnabled: nextEnabled);
      _manualPause = false;
      if (!_hasScanResult) {
        if (nextEnabled) {
          _scanStatus = 'Offline mode active. Ready to scan from cache.';
          _statusColor = Colors.orange.shade700;
        } else {
          _scanStatus = _scanAvailabilityNote(
            status: nextStatus,
            serviceMessage: (resolved['message']?.toString() ?? '').trim(),
            context: contextMap,
          );
          _statusColor = _contextColor(nextStatus);
        }
      }
    });

    if (nextEnabled) {
      _rememberOfflinePinnedContext(resolved);
    } else if (nextStatus == 'closed') {
      _offlinePinnedOpenContext = null;
    }
    _scheduleWindowCloseTimer(_scanContext);
  }

  Map<String, dynamic>? _activeOfflineValidationContext() {
    final pinned = _offlinePinnedOpenContext;
    if (pinned != null && pinned.isNotEmpty) {
      return Map<String, dynamic>.from(pinned);
    }

    final current = _scanContext;
    if (current != null && current.isNotEmpty) {
      return Map<String, dynamic>.from(current);
    }
    return null;
  }

  String? _activeScannerEventId() {
    final payload = _activeOfflineValidationContext();
    if (payload == null) return null;
    final context = payload['context'];
    final contextMap = context is Map<String, dynamic>
        ? context
        : (context is Map ? Map<String, dynamic>.from(context) : null);
    final eventRaw = contextMap?['event'];
    final eventMap = eventRaw is Map<String, dynamic>
        ? eventRaw
        : (eventRaw is Map ? Map<String, dynamic>.from(eventRaw) : null);
    final eventId = (eventMap?['id']?.toString() ?? '').trim();
    return eventId.isEmpty ? null : eventId;
  }

  String? _activeScannerSessionId() {
    final payload = _activeOfflineValidationContext();
    if (payload == null) return null;
    final context = payload['context'];
    final contextMap = context is Map<String, dynamic>
        ? context
        : (context is Map ? Map<String, dynamic>.from(context) : null);
    final sessionRaw = contextMap?['session'];
    final sessionMap = sessionRaw is Map<String, dynamic>
        ? sessionRaw
        : (sessionRaw is Map ? Map<String, dynamic>.from(sessionRaw) : null);
    final sessionId = (sessionMap?['id']?.toString() ?? '').trim();
    return sessionId.isEmpty ? null : sessionId;
  }

  String _activeScannerScanMode() {
    final payload = _activeOfflineValidationContext();
    final context = payload?['context'];
    final contextMap = context is Map<String, dynamic>
        ? context
        : (context is Map ? Map<String, dynamic>.from(context) : null);
    final mode = (contextMap?['scan_mode']?.toString() ?? '')
        .trim()
        .toLowerCase();
    return mode == 'check_out' ? 'check_out' : 'check_in';
  }

  void _clearAttendanceStats() {
    _attendancePercent = null;
    _attendancePresent = null;
    _attendanceTotal = null;
  }

  void _bumpAttendanceAfterSuccessfulScan(Map<String, dynamic> res) {
    if (_isOffline) return;
      final status = (res['status']?.toString() ?? '').toLowerCase();
    final action = (res['action']?.toString() ?? '').toLowerCase();
    if (res['ok'] != true) return;
    if (status == 'queued_offline') {
      return;
    }
    final isCheckOutMode = _activeScannerScanMode() == 'check_out';
    final isCheckOutSuccess = status == 'checked_out' || action == 'check_out';
    if (isCheckOutMode != isCheckOutSuccess) return;
    if (!isCheckOutMode &&
        (status == 'already_checked_in' || status == 'used')) {
      return;
    }
    final total = _attendanceTotal;
    final present = _attendancePresent;
    if (total == null || present == null || total <= 0 || present >= total) {
      return;
    }
    final next = present + 1;
    _attendancePresent = next;
    _attendancePercent = (next / total) * 100;
  }

  Future<void> _refreshAttendanceStats() async {
    if (!mounted || _isOffline) {
      if (mounted && _attendancePercent != null) {
        setState(_clearAttendanceStats);
      }
      return;
    }
    final eventId = (_activeScannerEventId() ?? '').trim();
    if (eventId.isEmpty) {
      if (_attendancePercent != null && mounted) {
        setState(_clearAttendanceStats);
      }
      return;
    }
    if (_attendanceStatsLoading) return;
    _attendanceStatsLoading = true;
    final requestedMode = _activeScannerScanMode();
    try {
      final res = await _eventService.getScanAttendanceStats(
        eventId: eventId,
        sessionId: _activeScannerSessionId(),
        mode: requestedMode,
      );
      if (!mounted || _isOffline) return;
      if (_activeScannerScanMode() != requestedMode) {
        setState(_clearAttendanceStats);
        return;
      }
      if (res == null) return;
      final present = int.tryParse(res['present']?.toString() ?? '') ?? 0;
      final total = int.tryParse(res['total']?.toString() ?? '') ?? 0;
      final percent = double.tryParse(res['percent']?.toString() ?? '') ??
          (total > 0 ? (present / total) * 100 : 0);
    setState(() {
        _attendancePresent = present;
        _attendanceTotal = total;
        _attendancePercent = percent;
      });
    } finally {
      _attendanceStatsLoading = false;
    }
  }

  Future<void> _refreshPendingSyncCount() async {
    if (_teacherId.trim().isEmpty) return;
    final count = await _offlineSyncService.pendingQueueCount(
      actorId: _teacherId,
      isTeacher: true,
    );
    if (!mounted) return;
    setState(() => _pendingSyncCount = count);
  }

  /// When any network link is present, leave offline mode and drain the queue.
  Future<void> _syncQueueWhenOnline({bool showSnack = false}) async {
    final results = await Connectivity().checkConnectivity();
    if (_resultsAreOffline(results)) return;

    if (_isOffline && mounted) {
      setState(() => _isOffline = false);
    }
    await _refreshPendingSyncCount();
    if (!mounted || _pendingSyncCount <= 0) return;
    await _performQueueSync(showSnack: showSnack);
  }

  /// Drain offline queue only when there is work — no "Syncing 0…" flash.
  Future<void> _syncQueueIfNeeded({bool showSnack = false}) async {
    if (_isSyncing || _teacherId.trim().isEmpty) return;
    await _syncQueueWhenOnline(showSnack: showSnack);
  }

  Future<void> _performQueueSync({bool showSnack = false}) async {
    if (_isSyncing || _teacherId.trim().isEmpty) return;

    final pendingBefore = await _offlineSyncService.pendingQueueCount(
      actorId: _teacherId,
      isTeacher: true,
    );
      if (!mounted) return;
    if (pendingBefore <= 0) {
      setState(() => _pendingSyncCount = 0);
      return;
    }

    setState(() {
      _isSyncing = true;
      _pendingSyncCount = pendingBefore;
    });
    final result = await _offlineSyncService.syncPendingQueue(
      actorId: _teacherId,
      isTeacher: true,
    );
    final synced = int.tryParse(result['synced']?.toString() ?? '') ?? 0;
    final rejected = int.tryParse(result['rejected']?.toString() ?? '') ?? 0;
    final conflictResolved =
        int.tryParse(result['conflict_resolved']?.toString() ?? '') ?? 0;
    await _refreshPendingSyncCount();
    unawaited(_refreshOfflineReadiness());
    if (!mounted) return;
    setState(() => _isSyncing = false);
    if (showSnack && (synced > 0 || rejected > 0 || conflictResolved > 0)) {
      final details = <String>[
        if (synced > 0) '$synced synced',
        if (conflictResolved > 0) '$conflictResolved conflict-resolved',
        if (rejected > 0) '$rejected rejected',
      ].join(', ');
      AppSnackBar.info(context, 'Offline sync update: $details.');
    }
  }

  void _initConnectivity() {
    _connectivity = Connectivity();
    _connectivity.checkConnectivity().then((results) async {
      final isOffline = await _resolveIsOffline(linkResults: results);
      if (!mounted) return;
      final wasOffline = _isOffline;
      if (wasOffline != isOffline) {
        setState(() {
          _isOffline = isOffline;
          if (isOffline) _clearAttendanceStats();
        });
      }
      if (!isOffline) {
        unawaited(_syncQueueWhenOnline(showSnack: false));
      }
    });
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) async {
      final isOffline = await _resolveIsOffline(linkResults: results);
      if (!mounted) return;
      final wasOffline = _isOffline;
      if (wasOffline != isOffline) {
        setState(() {
          _isOffline = isOffline;
          if (isOffline) _clearAttendanceStats();
        });
      }
      if (isOffline) {
        if (!wasOffline) {
          await _sealCurrentContextForOfflineTransition();
          if (_applyCurrentContextOfflineTransition()) {
            unawaited(_refreshOfflineReadiness());
            return;
          }
          if (_applyPinnedOpenContextFallback()) {
            unawaited(_refreshOfflineReadiness());
            return;
          }
      await _refreshScanContext(silent: true);
          unawaited(_refreshOfflineReadiness());
        }
        return;
      }

      // Link is up → always try to drain queue (Wi‑Fi reconnect / mobile data).
      await _syncQueueWhenOnline(showSnack: true);
      await _refreshScanContext(silent: true);
      unawaited(_refreshAttendanceStats());
      unawaited(_refreshOfflineReadiness(refreshSnapshot: true));
    });
  }

  DateTime? _parseOfflineSyncDate(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  Future<void> _refreshOfflineReadiness({
    bool refreshSnapshot = false,
  }) async {
    final actorId = _teacherId.trim();
    if (actorId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _offlineSnapshotReady = false;
        _offlineSnapshotStale = false;
        _offlineWarmFailed = false;
        _offlineLastSyncedAt = null;
      });
      return;
    }

    final monitor = await _offlineSyncService.getOfflineMonitorStatus(
      actorId: actorId,
      isTeacher: true,
      refreshSnapshot: refreshSnapshot && !_isOffline,
      isOffline: _isOffline,
    );
    if (!mounted) return;
    setState(() {
      _offlineSnapshotReady = monitor['offline_ready'] == true;
      _offlineSnapshotStale = monitor['snapshot_stale'] == true;
      _offlineWarmFailed = monitor['warm_failed'] == true;
      _offlineLastSyncedAt = _parseOfflineSyncDate(
        monitor['last_synced_at']?.toString(),
      );
    });
  }

  void _scheduleScannerResume({Duration delay = const Duration(milliseconds: 1800)}) {
    _scanResumeTimer?.cancel();
    _scanResumeTimer = Timer(delay, () {
      if (!mounted || _manualPause || !widget.isActive) return;

      // Re-check deadline at resume time so grace end is not undone.
      final canResume =
          _scannerEnabled || _localClosesAtStillInFuture(_scanContext);
      if (!canResume) {
        setState(() => _isProcessingScan = false);
        unawaited(_refreshScanContext(silent: true));
        return;
      }

      setState(() {
        _isScanning = true;
        _isProcessingScan = false;
      });
    });
  }

  String? _barcodePayload(Barcode barcode) {
    final raw = barcode.rawValue?.trim();
    if (raw != null && raw.isNotEmpty) return raw;

    final display = barcode.displayValue?.trim();
    if (display != null && display.isNotEmpty) return display;

    final bytes = switch (barcode.rawDecodedBytes) {
      DecodedBarcodeBytes(:final bytes) => bytes,
      DecodedVisionBarcodeBytes(:final bytes, :final rawBytes) =>
        bytes ?? rawBytes,
      null => null,
    };
    if (bytes != null && bytes.isNotEmpty) {
      try {
        final decoded = String.fromCharCodes(bytes).trim();
        if (decoded.isNotEmpty) return decoded;
      } catch (_) {}
    }
    return null;
  }

  void _handleDetect(BarcodeCapture capture) async {
    if (!_acceptingScans || _teacherId.isEmpty) return;

    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final normalized = _barcodePayload(barcode);
      if (normalized == null || normalized.isEmpty) continue;

      if (normalized.toUpperCase().startsWith('PULSE-EVENT-')) {
        setState(() {
          _isProcessingScan = true;
          _scanStatus = 'Scan a student ticket QR, not the event QR.';
          _statusColor = Colors.red.shade700;
          _hasScanResult = true;
        });
        _playFailedScanSound();
        _scheduleScannerResume(delay: _resumeAfterFailure);
        return;
      }

        final now = DateTime.now();
        if (_lastScannedCode == normalized &&
            _lastScannedAt != null &&
            now.difference(_lastScannedAt!) < _sameCodeCooldown) {
          return;
        }

        _lastScannedCode = normalized;
        _lastScannedAt = now;

        setState(() {
        _isProcessingScan = true;
        _scanStatus = 'Checking in...';
          _statusColor = const Color(0xFFD4A843);
          _hasScanResult = false;
          _clearVerifiedParticipantOverlay();
        });

      try {
        final res = _isOffline
            ? await _offlineSyncService.enqueueOfflineCheckIn(
                actorId: _teacherId,
                isTeacher: true,
                ticketPayload: normalized,
                activeContextOverride: _activeOfflineValidationContext(),
              )
            : await _eventService.checkInParticipantAsTeacher(
            normalized,
            _teacherId,
                expectedEventId: _activeScannerEventId(),
              );

        await _applyInstantCheckInResult(
          Map<String, dynamic>.from(res),
          fromOfflineQueue: _isOffline,
        );
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _scanStatus = 'Scan failed. Try again.';
                _statusColor = Colors.red.shade700;
              _hasScanResult = true;
          _isProcessingScan = false;
        });
        _playFailedScanSound();
        _scheduleScannerResume(delay: _resumeAfterFailure);
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: PulseConnectLoader());
    }

    if (_shouldShowAccessGate) {
      return _buildNoPermission();
    }

    return _buildScannerView();
  }

  Widget _buildOfflinePreparedHeaderChip() {
    final ready = _offlineSnapshotReady && !_offlineSnapshotStale;
    final stale = (_offlineSnapshotStale || _offlineWarmFailed) && !ready;
    final String label;
    final IconData icon;
    if (_isOffline && ready) {
      label = 'Offline';
      icon = Icons.inventory_2_rounded;
    } else if (ready) {
      label = 'Prepared';
      icon = Icons.cloud_done_rounded;
    } else if (stale) {
      label = 'Refresh';
      icon = Icons.sync_problem_rounded;
    } else if (_isOffline) {
      label = 'No pack';
      icon = Icons.cloud_off_rounded;
    } else {
      label = 'Warming…';
      icon = Icons.cloud_sync_rounded;
    }

    final Color accent = ready && !_isOffline
        ? const Color(0xFFBBF7D0)
        : (ready
            ? const Color(0xFFFDE68A)
            : Colors.white.withValues(alpha: 0.85));
    final Color fill = ready && !_isOffline
        ? const Color(0xFF166534).withValues(alpha: 0.35)
        : (ready
            ? const Color(0xFF92400E).withValues(alpha: 0.35)
            : Colors.white.withValues(alpha: 0.12));

    return Tooltip(
      message: ready
          ? (_isOffline
              ? 'Offline pack is active on this device.'
              : 'Offline pack saved. You can scan without internet later.')
          : (_isOffline
              ? 'No offline pack yet. Connect once while assigned to prepare.'
              : (_offlineWarmFailed
                  ? 'Could not save offline pack. Tap to retry.'
                  : 'Saving offline pack… keep this screen open with internet.')),
      child: GestureDetector(
        onTap: (!_isOffline && (stale || !ready))
            ? () {
                unawaited(_refreshOfflineReadiness(refreshSnapshot: true));
              }
            : null,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 118),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: accent.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: accent),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: accent,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGradientHeader({
    required String title,
    required String subtitle,
    IconData? actionIcon,
    VoidCallback? onAction,
  }) {
    return Container(
      padding: EdgeInsets.fromLTRB(24, MediaQuery.of(context).padding.top + 20, 24, 30),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: TeacherThemeUtils.chromeGradient,
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: TeacherThemeUtils.dark.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.8), fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _buildOfflinePreparedHeaderChip(),
          if (actionIcon != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onAction,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(actionIcon, color: Colors.white, size: 22),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _contextColor(String status) {
    switch (status) {
      case 'open':
        return TeacherThemeUtils.primary;
      case 'waiting':
        return const Color(0xFFD97706);
      case 'closed':
        return Colors.grey.shade700;
      case 'no_assignment':
      case 'conflict':
      case 'missing_schedule':
        return Colors.red.shade700;
      default:
        return Colors.grey.shade700;
    }
  }

  String _defaultStatusMessage(String status) {
    switch (status) {
      case 'open':
        return 'Scanning Open';
      case 'waiting':
        return 'Waiting for event start';
      case 'closed':
        return _scannerClosedLabel;
      case 'no_assignment':
        return 'No QR scanner access assigned yet.';
      case 'conflict':
        return 'Multiple active assignments detected. Contact admin.';
      case 'missing_schedule':
        return 'Assigned event has no valid scan schedule.';
      default:
        return _scannerClosedLabel;
    }
  }

  DateTime? _parseScheduleDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return parsed.toUtc().add(_manilaOffset);
  }

  bool _isSameDate(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _formatStartTime(DateTime dateTime) {
    final hour = dateTime.hour % 12 == 0 ? 12 : dateTime.hour % 12;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final period = dateTime.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  String _formatScheduleDate(DateTime dateTime) {
    const monthNames = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${monthNames[dateTime.month - 1]} ${dateTime.day}, ${dateTime.year}';
  }

  String _formatScheduleDateTime(DateTime dateTime) {
    return '${_formatScheduleDate(dateTime)} • ${_formatStartTime(dateTime)}';
  }

  String _formatOfflineSyncLabel(DateTime? dateTime) {
    if (dateTime == null) return 'No saved snapshot yet';
    final now = DateTime.now();
    if (_isSameDate(now, dateTime)) {
      return 'Today, ${_formatStartTime(dateTime)}';
    }
    return '${_formatScheduleDate(dateTime)}, ${_formatStartTime(dateTime)}';
  }

  String _currentEventTitle(Map<String, dynamic>? context) {
    if (context == null) return 'Assigned Event';

    final event = context['event'];
    if (event is Map) {
      final title = event['title']?.toString().trim() ?? '';
      if (title.isNotEmpty) return title;
    }
    return 'Assigned Event';
  }

  String _currentSessionTitle(Map<String, dynamic>? context) {
    if (context == null) return 'Assigned Event';

    final session = context['session'];
    if (session is Map) {
      final display = session['display_name']?.toString().trim() ?? '';
      final title = session['title']?.toString().trim() ?? '';
      if (display.isNotEmpty) return display;
      if (title.isNotEmpty) return title;
    }

    return '';
  }

  String _scanAvailabilityNote({
    required String status,
    required String serviceMessage,
    required Map<String, dynamic>? context,
  }) {
    final now = DateTime.now().toUtc().add(_manilaOffset);
    final opensAt = _parseScheduleDate(context?['opens_at']?.toString());
    final closesAt = _parseScheduleDate(context?['closes_at']?.toString());
    final sessionTitle = _currentSessionTitle(context);
    final contextTitle =
        sessionTitle.isNotEmpty ? sessionTitle : _currentEventTitle(context);
    final scanMode = (context?['scan_mode']?.toString() ?? '').toLowerCase();
    final isCheckOutMode = scanMode == 'check_out' ||
        serviceMessage.toLowerCase().contains('time-out') ||
        serviceMessage.toLowerCase().contains('early time-out');

    if (status.toLowerCase() == 'open' && isCheckOutMode) {
      final earlyOut = context?['early_out'] == true;
      if (closesAt != null && !now.isAfter(closesAt)) {
        return earlyOut
            ? 'Early Time-Out Open (until ${_formatStartTime(closesAt)})'
            : 'Time-Out Open (until ${_formatStartTime(closesAt)})';
      }
      return earlyOut ? 'Early Time-Out Open' : 'Time-Out Open';
    }

    if (opensAt != null) {
      if (now.isBefore(opensAt)) {
        // After time-in grace, opens_at is the event end (time-out window) —
        // do not label that as "event start".
        if (isCheckOutMode) {
          if (_isSameDate(now, opensAt)) {
            return 'Waiting for time-out (Opens at ${_formatStartTime(opensAt)})';
          }
          return 'Time-out opens ${_formatScheduleDateTime(opensAt)}';
        }
        if (_isSameDate(now, opensAt)) {
          return 'Waiting for event start (Starts at ${_formatStartTime(opensAt)})';
        }
        return 'Upcoming Event: $contextTitle - ${_formatScheduleDateTime(opensAt)}';
      }

      if (closesAt == null || !now.isAfter(closesAt)) {
        return 'Scanning Open';
      }

      return _scannerClosedLabel;
    }

    final normalized = serviceMessage.toLowerCase();
    if (normalized.contains('unable to load scanner context') ||
        normalized.contains('failed to refresh scanner context') ||
        normalized.contains('scanner unavailable')) {
      return _scannerClosedLabel;
    }

    return _defaultStatusMessage(status);
  }

  String _normalizeScannerMessage(String? raw, {required String fallback}) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return fallback;

    final normalized = text.toLowerCase();
    if (normalized.contains('unable to load scanner context') ||
        normalized.contains('failed to refresh scanner context') ||
        normalized.contains('scanner unavailable')) {
      return _scannerClosedLabel;
    }
    if (normalized.contains('synchronized') ||
        normalized.contains('earliest recorded scan')) {
      return 'Already checked in.';
    }
    return text;
  }

  void _clearVerifiedParticipantOverlay() {
    _verifiedOverlayEpoch++;
    _lastVerifiedParticipantName = '';
    _lastVerifiedParticipantStudentNo = '';
    _lastVerifiedParticipantPhotoUrl = '';
    _lastVerifiedParticipantPhotoLocalPath = '';
    _lastVerifiedStatusLabel = 'Present';
    _lastVerifiedAt = null;
  }

  DateTime? _parseAttendanceDisplayTime(String? rawIso) {
    final utc = _parseIsoToUtc(rawIso);
    if (utc == null) return null;
    // Same Manila wall-clock representation used by schedule labels.
    return utc.add(_manilaOffset);
  }

  DateTime? _attendanceTimeFromResponse(
    Map<String, dynamic> response, {
    required String statusLabel,
  }) {
    final label = statusLabel.toLowerCase();
    final prefersOut = label.contains('timed out') ||
        label.contains('already out') ||
        label == 'timed out';
    if (prefersOut) {
      final out = _parseAttendanceDisplayTime(
        response['check_out_at']?.toString(),
      );
      if (out != null) return out;
    }
    return _parseAttendanceDisplayTime(response['check_in_at']?.toString()) ??
        _parseAttendanceDisplayTime(
          response['recorded_check_in_at']?.toString(),
        );
  }

  List<String> get _scanStatusLines {
    final raw = _scanStatus.trim();
    if (raw.isEmpty) return const [];
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  Widget _buildScanStatusText() {
    final lines = _scanStatusLines;
    if (lines.isEmpty) {
      return Text(
        _scanStatus,
        textAlign: TextAlign.left,
        softWrap: true,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: _statusColor,
          height: 1.35,
        ),
      );
    }

    final raw = lines.first;
    final sepIndex = raw.lastIndexOf(' — ');
    if (sepIndex > 0) {
      final namePart = raw.substring(0, sepIndex).trim();
      var actionPart = raw.substring(sepIndex + 3).trim();
      if (actionPart.toLowerCase() == 'present') {
        actionPart = 'Timed in';
      }
      if (namePart.isNotEmpty && actionPart.isNotEmpty) {
    return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
      children: [
            Text(
              namePart,
              softWrap: true,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: _statusColor,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              actionPart,
              softWrap: true,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _statusColor.withValues(alpha: 0.92),
                height: 1.3,
              ),
            ),
          ],
        );
      }
    }

    return Text(
      raw,
      textAlign: TextAlign.left,
      softWrap: true,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: _statusColor,
        height: 1.35,
      ),
    );
  }

  Future<void> _hydrateVerifiedParticipantPhoto(
    String rawPhotoUrl, {
    required int epoch,
  }) async {
    final raw = rawPhotoUrl.trim();
    if (raw.isEmpty) return;
    final signed = await _eventService.resolveAvatarDisplayUrl(raw);
    if (!mounted || signed.isEmpty) return;
    // Drop late hydrates from a previous scan / cleared overlay.
    if (epoch != _verifiedOverlayEpoch) return;
    if (_lastVerifiedParticipantPhotoUrl == signed) return;
    setState(() => _lastVerifiedParticipantPhotoUrl = signed);
  }

  void _rememberVerifiedParticipant(
    Map<String, dynamic> response, {
    String statusLabel = 'Present',
  }) {
    final participantName =
        (response['participant_name']?.toString() ?? '').trim();
    final participantStudentNo = _resolveParticipantStudentNo(response);
    final participantPhotoUrl =
        (response['participant_photo_url']?.toString() ?? '').trim();
    final participantPhotoLocalPath =
        (response['participant_photo_local_path']?.toString() ?? '').trim();

    if (participantName.isEmpty &&
        participantStudentNo.isEmpty &&
        participantPhotoUrl.isEmpty &&
        participantPhotoLocalPath.isEmpty) {
      return;
    }

    // New participant identity — bump epoch so in-flight avatar resolves for
    // the previous student cannot paint onto this card.
    _verifiedOverlayEpoch++;
    _lastVerifiedParticipantName =
        participantName.isNotEmpty ? participantName : 'Verified Student';
    _lastVerifiedParticipantStudentNo = participantStudentNo;
    // Always replace photo sources (never keep the previous student's avatar).
    _lastVerifiedParticipantPhotoUrl = participantPhotoUrl;
    _lastVerifiedParticipantPhotoLocalPath = participantPhotoLocalPath;
    if (participantPhotoUrl.isNotEmpty) {
      unawaited(
        _hydrateVerifiedParticipantPhoto(
          participantPhotoUrl,
          epoch: _verifiedOverlayEpoch,
        ),
      );
    }
    _lastVerifiedStatusLabel =
        statusLabel.trim().isEmpty ? 'Present' : statusLabel.trim();
    _lastVerifiedAt = _attendanceTimeFromResponse(
          response,
          statusLabel: _lastVerifiedStatusLabel,
        ) ??
        DateTime.now();
  }

  String _resolveParticipantStudentNo(Map<String, dynamic> response) {
    final fromNo =
        (response['participant_student_no']?.toString() ?? '').trim();
    if (fromNo.isNotEmpty) return fromNo;
    final fromId =
        (response['participant_student_id']?.toString() ?? '').trim();
    if (fromId.isEmpty) return '';
    final uuidLike = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    if (uuidLike.hasMatch(fromId)) return '';
    return fromId;
  }

  String _displayNameInitials(String rawName) {
    final name = rawName.trim();
    if (name.isEmpty) return 'ST';
    if (name.contains(',')) {
      final bits = name.split(',');
      final last = bits.first.trim();
      final given = bits.length > 1 ? bits.sublist(1).join(' ').trim() : '';
      final a = last.isNotEmpty ? last[0] : '';
      final givenParts =
          given.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
      final b = givenParts.isNotEmpty ? givenParts.first[0] : '';
      final initials = '$a$b'.toUpperCase();
      return initials.isEmpty ? 'ST' : initials;
    }
    final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'ST';
    if (parts.length == 1) {
      return parts.first.substring(0, min(2, parts.first.length)).toUpperCase();
    }
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  Widget _buildVerifiedParticipantAvatar({
    required String displayName,
    required String localPhotoPath,
    required String photoUrl,
  }) {
    const avatarSize = 56.0;
    final initials = _displayNameInitials(displayName);
    final hasLocalPhoto = localPhotoPath.trim().isNotEmpty;
    final trimmedUrl = photoUrl.trim();
    final hasRemotePhoto = trimmedUrl.isNotEmpty &&
        (trimmedUrl.toLowerCase().startsWith('http') ||
            trimmedUrl.toLowerCase().startsWith('data:'));

    Widget initialsAvatar() {
      return Container(
        width: avatarSize,
        height: avatarSize,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Color(0xFF0EA5E9), Color(0xFF0284C7)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          initials,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 16,
            letterSpacing: 0.8,
          ),
        ),
      );
    }

    return Container(
      width: avatarSize,
      height: avatarSize,
                  decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black.withValues(alpha: 0.22), width: 1.2),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasLocalPhoto
          ? Image.file(
              File(localPhotoPath.trim()),
              width: avatarSize,
              height: avatarSize,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                if (!hasRemotePhoto) return initialsAvatar();
                return Image.network(
                  photoUrl.trim(),
                  width: avatarSize,
                  height: avatarSize,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      initialsAvatar(),
                );
              },
            )
          : (hasRemotePhoto
                ? Image.network(
                    photoUrl.trim(),
                    width: avatarSize,
                    height: avatarSize,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        initialsAvatar(),
                  )
                : initialsAvatar()),
    );
  }

  Widget _buildLastVerifiedOverlay() {
    final displayName = _lastVerifiedParticipantName.trim();
    final studentNo = _lastVerifiedParticipantStudentNo.trim();
    final overlayLabel = studentNo.isNotEmpty ? studentNo : displayName;
    final photoUrl = _lastVerifiedParticipantPhotoUrl;
    final photoLocalPath = _lastVerifiedParticipantPhotoLocalPath;
    final statusLabel = _lastVerifiedStatusLabel.trim().isEmpty
        ? 'Present'
        : _lastVerifiedStatusLabel.trim();
    final isWarning = statusLabel.toLowerCase().contains('already') ||
        statusLabel.toLowerCase().contains('queued');
    final isTimedOut = statusLabel.toLowerCase().contains('timed out') ||
        statusLabel.toLowerCase() == 'timed out';
    final verifiedLabel = _lastVerifiedAt != null
        ? '$statusLabel · ${_formatStartTime(_lastVerifiedAt!)}'
        : statusLabel;

    final hasData = overlayLabel.isNotEmpty;
    final overlayContent = !hasData
        ? const SizedBox.shrink(key: ValueKey('verified-empty'))
        : Container(
            key: ValueKey(
              '${overlayLabel}_${statusLabel}_${_lastVerifiedAt?.millisecondsSinceEpoch ?? 0}_${photoLocalPath}_$photoUrl',
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                    boxShadow: [
                      BoxShadow(
                  color: Colors.black.withValues(alpha: 0.26),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                      ),
                    ],
                  ),
            child: Row(
              children: [
                _buildVerifiedParticipantAvatar(
                  displayName: displayName.isNotEmpty ? displayName : overlayLabel,
                  localPhotoPath: photoLocalPath,
                  photoUrl: photoUrl,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        verifiedLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.74),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 1),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text(
                          overlayLabel,
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  isWarning
                      ? Icons.warning_amber_rounded
                      : (isTimedOut
                          ? Icons.logout_rounded
                          : Icons.verified_rounded),
                  color: isWarning
                      ? const Color(0xFFFBBF24)
                      : (isTimedOut
                          ? const Color(0xFF93C5FD)
                          : const Color(0xFF34D399)),
                  size: 18,
                ),
              ],
            ),
          );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final slide = Tween<Offset>(
          begin: const Offset(0, -0.2),
          end: Offset.zero,
        ).animate(animation);
        final scale = Tween<double>(begin: 0.97, end: 1).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: slide,
            child: ScaleTransition(scale: scale, child: child),
          ),
        );
      },
      child: overlayContent,
    );
  }

  Widget _buildCameraSurface() {
    if (!_shouldMountCamera) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.camera_alt_rounded, size: 64, color: Colors.grey.shade300),
              const SizedBox(height: 16),
              Text(
                _scannerEnabled ? 'Camera Paused' : 'Scanner Closed',
                style: TextStyle(
                  color: Colors.grey.shade500,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          key: const ValueKey('teacher_live_scanner'),
          controller: _scannerController,
          fit: BoxFit.cover,
                              onDetect: _handleDetect,
                              errorBuilder: (context, error) {
            return ColoredBox(
                                  color: Colors.black,
                                  child: Padding(
                                    padding: const EdgeInsets.all(20),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                                        const SizedBox(height: 10),
                                        const Text(
                                          'Camera unavailable',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          'Allow camera permission in app settings, then try again.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(color: Colors.grey.shade300, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
        ),
        IgnorePointer(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 160),
            opacity: _isProcessingScan && !_hasScanResult ? 1 : 0,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.28),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFramedScannerWindow() {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: AspectRatio(
          // Match teacher_scanner_trimmed.png (406×546).
          aspectRatio: 406 / 546,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final height = constraints.maxHeight;
              // Keep preview under the PNG bezel without extra zoom (scale
              // made the live feed look bent / fisheye).
              final cameraPadding = EdgeInsets.fromLTRB(
                width * 0.11,
                height * 0.155,
                width * 0.11,
                height * 0.13,
              );

              return Stack(
                fit: StackFit.expand,
                                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: cameraPadding,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: ColoredBox(
                          color: Colors.black,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Positioned.fill(
                                child: _buildCameraSurface(),
                              ),
                              Positioned(
                                top: 8,
                                left: 8,
                                right: 8,
                                child: IgnorePointer(
                                  child: _buildLastVerifiedOverlay(),
                                ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Image.asset(
                        'assets/teacher_scanner_trimmed.png',
                        fit: BoxFit.fill,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildScannerView() {
    final media = MediaQuery.of(context);
    final bottomNavClearance = media.padding.bottom + 98;
    final eventTitle = _selectedEventTitle.trim().isNotEmpty
        ? _selectedEventTitle
        : (_shouldShowAccessGate ? 'Scanner Access' : 'Assigned Event');

    return Column(
      children: [
        _buildGradientHeader(
          title: 'QR Scanner',
          subtitle: eventTitle,
        ),
        if (!_isOffline && _attendancePercent != null) ...[
          const SizedBox(height: 10),
          ScanAttendanceLiveIndicator(
            percent: _attendancePercent!,
            accent: TeacherThemeUtils.primary,
            present: _attendancePresent,
            total: _attendanceTotal,
            label: _activeScannerScanMode() == 'check_out'
                ? 'Timed Out'
                : 'Attendance',
          ),
        ],
        if (_showOfflineReadinessIndicator) ...[
          const SizedBox(height: 10),
          _buildOfflineReadinessCard(),
        ],
        if (_isOffline || _pendingSyncCount > 0) ...[
          const SizedBox(height: 10),
          _buildConnectivityBanner(),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(24, 14, 24, bottomNavClearance),
            child: Column(
              children: [
                _buildFramedScannerWindow(),
                const SizedBox(height: 20),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: (!_isProcessingScan && !_hasScanResult)
                        ? Colors.white
                        : (_statusColor == Colors.red.shade700
                            ? Colors.red.shade50
                            : (_statusColor == const Color(0xFFD4A843)
                                ? Colors.orange.shade50
                                : (_statusColor == Colors.orange.shade700
                                    ? Colors.orange.shade50
                                    : const Color(0xFFECFDF5)))),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: (!_isProcessingScan && !_hasScanResult)
                          ? Colors.grey.shade200
                          : _statusColor.withValues(alpha: 0.3),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(
                        _statusColor == Colors.red.shade700
                            ? Icons.error_rounded
                            : (_statusColor == const Color(0xFFD4A843)
                                ? Icons.hourglass_top_rounded
                                : (_statusColor == Colors.orange.shade700
                                    ? Icons.info_rounded
                                    : Icons.check_circle_rounded)),
                        color: _statusColor,
                        size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildScanStatusText(),
                      ),
                    ],
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        ],
    );
  }

  Widget _buildConnectivityBanner() {
    final accent = Colors.orange.shade700;
    final background = Colors.orange.shade50;
    final border = Colors.orange.shade200;
    final String label;
    if (_isOffline && _pendingSyncCount > 0) {
      label = 'Offline mode — $_pendingSyncCount scan(s) queued';
    } else if (_isOffline) {
      label = 'Offline mode active — using saved pack';
    } else if (_isSyncing) {
      label = 'Syncing $_pendingSyncCount queued scan(s)…';
                        } else {
      label = 'Online — $_pendingSyncCount queued scan(s) pending';
    }
    return GestureDetector(
      onTap: () {
        unawaited(_syncQueueWhenOnline(showSnack: true));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        margin: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isOffline ? Icons.wifi_off_rounded : Icons.sync_rounded,
              size: 16,
              color: accent,
            ),
            const SizedBox(width: 8),
            Flexible(
                    child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  Widget _buildOfflineReadinessCard() {
    final ready = _offlineSnapshotReady;
    final stale = _offlineSnapshotStale;
    final accent = !ready
        ? Colors.orange.shade700
        : (stale
              ? Colors.orange.shade700
              : (_isOffline ? Colors.orange.shade700 : TeacherThemeUtils.primary));
    final background = !ready
        ? Colors.orange.shade50
        : (stale ? Colors.orange.shade50 : const Color(0xFFF0FDF4));
    final title = !ready
        ? 'Offline unavailable'
        : (stale
              ? 'Offline data needs refresh'
              : (_isOffline ? 'Offline mode active' : 'Offline ready'));
    final detail = !ready
        ? 'Reconnect once to prepare scanner backup data.'
        : 'Last synced ${_formatOfflineSyncLabel(_offlineLastSyncedAt)}';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.16)),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 4,
        children: [
          Icon(
            !ready
                ? Icons.cloud_off_rounded
                : (_isOffline ? Icons.inventory_2_rounded : Icons.cloud_done_rounded),
            color: accent,
            size: 16,
          ),
          Text(
            title,
            style: TextStyle(
              fontSize: 12.6,
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          Text(
            detail,
            style: TextStyle(
              fontSize: 11.7,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoPermission() {
    final status = (_scanContext?['status']?.toString() ?? '').toLowerCase();
    final serviceMessage = (_scanContext?['message']?.toString() ?? '').trim();
    final message = (status == 'no_assignment' || status == 'error')
        ? 'You can\'t access this feature. Only teachers assigned by admin can use the QR scanner.'
        : (serviceMessage.isNotEmpty
            ? serviceMessage
            : 'You can\'t access this feature. Only teachers assigned by admin can use the QR scanner.');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                color: Color(0xFFECFDF5),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.admin_panel_settings_rounded,
                size: 64,
                color: TeacherThemeUtils.primary,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Scanner Access Required',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey.shade600,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
