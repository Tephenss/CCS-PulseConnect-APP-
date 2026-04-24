import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';
import '../../utils/course_theme_utils.dart';

class StudentScanScreen extends StatefulWidget {
  const StudentScanScreen({super.key});

  @override
  State<StudentScanScreen> createState() => _StudentScanScreenState();
}

class _StudentScanScreenState extends State<StudentScanScreen> {
  static const String _scannerClosedLabel = 'Scanning Closed';
  static const Duration _manilaOffset = Duration(hours: 8);
  static const Duration _sameCodeCooldown = Duration(seconds: 10);
  static const Duration _scanSoundCooldown = Duration(milliseconds: 120);
  final AudioPlayer _scanSoundPlayer = AudioPlayer();
  DateTime? _lastScanSoundAt;
  bool _scanSoundConfigured = false;

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

  void _playReviewScanSound() {
    unawaited(
      _playScanSound(
        'sounds/scan_review.wav',
        isSuccess: true,
        bypassCooldown: true,
        backupAssetPath: 'sounds/scan_success.wav',
        alwaysPlaySystemFallback: true,
      ),
    );
  }

  final AuthService _authService = AuthService();
  final EventService _eventService = EventService();

  bool _isLoading = true;
  bool _isScanning = false;
  String _scanStatus = 'Checking scanner assignment...';
  Color _statusColor = Colors.grey.shade600;
  bool _hasScanResult = false;
  bool _isRefreshingContext = false;
  bool _manualPause = false;
  String _studentId = '';
  Map<String, dynamic>? _scanContext;
  String _selectedEventTitle = '';
  String _lastScannedCode = '';
  DateTime? _lastScannedAt;
  bool _isReviewPhase = false;
  bool _isSubmittingReview = false;
  String _pendingTicketPayload = '';
  String _pendingParticipantName = '';
  String _pendingParticipantPhotoUrl = '';
  DateTime? _pendingDetectedAt;
  String _lastVerifiedParticipantName = '';
  String _lastVerifiedParticipantPhotoUrl = '';
  DateTime? _lastVerifiedAt;

  Timer? _scanResumeTimer;
  Timer? _contextRefreshTimer;

  Color _studentPrimary(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
  Color _studentDark(BuildContext context) =>
      CourseThemeUtils.studentDarkFromPrimary(_studentPrimary(context));

  bool get _hasPermission =>
      _scanContext != null &&
      _scanContext?['ok'] == true &&
      _studentId.isNotEmpty &&
      (_scanContext?['status']?.toString() ?? '') != 'no_assignment' &&
      (_scanContext?['status']?.toString() ?? '') != 'error';
  bool get _scannerEnabled => _scanContext?['scanner_enabled'] == true;

  @override
  void initState() {
    super.initState();
    unawaited(_configureScanSoundPlayer());
    _initScannerAccess();
  }

  @override
  void dispose() {
    _scanResumeTimer?.cancel();
    _contextRefreshTimer?.cancel();
    _scanSoundPlayer.dispose();
    super.dispose();
  }

  Future<void> _initScannerAccess() async {
    try {
      final user = await _authService.getCurrentUser();
      final studentId = user?['id']?.toString() ?? '';

      if (mounted) {
        setState(() {
          _studentId = studentId;
          _selectedEventTitle = '';
          _isScanning = false;
          _scanStatus = 'Checking scanner assignment...';
          _statusColor = Colors.grey.shade700;
          _hasScanResult = false;
          _scanContext = null;
          _isReviewPhase = false;
          _isSubmittingReview = false;
          _pendingTicketPayload = '';
          _pendingParticipantName = '';
          _pendingParticipantPhotoUrl = '';
          _pendingDetectedAt = null;
          _lastVerifiedParticipantName = '';
          _lastVerifiedParticipantPhotoUrl = '';
          _lastVerifiedAt = null;
          _isLoading = true;
        });
      }

      if (studentId.isNotEmpty) {
        await _refreshScanContext();
        _contextRefreshTimer?.cancel();
        _contextRefreshTimer = Timer.periodic(
          const Duration(seconds: 15),
          (_) => _refreshScanContext(silent: true),
        );
      } else if (mounted) {
        setState(() {
          _scanContext = {
            'status': 'no_assignment',
            'scanner_enabled': false,
            'message': 'Unable to identify your student account.',
            'context': null,
          };
          _scanStatus = 'Unable to identify your student account.';
          _statusColor = Colors.red.shade700;
          _hasScanResult = false;
          _isReviewPhase = false;
          _isSubmittingReview = false;
          _pendingTicketPayload = '';
          _pendingParticipantName = '';
          _pendingParticipantPhotoUrl = '';
          _pendingDetectedAt = null;
          _lastVerifiedParticipantName = '';
          _lastVerifiedParticipantPhotoUrl = '';
          _lastVerifiedAt = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _studentId = '';
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
          _isReviewPhase = false;
          _isSubmittingReview = false;
          _pendingTicketPayload = '';
          _pendingParticipantName = '';
          _pendingParticipantPhotoUrl = '';
          _pendingDetectedAt = null;
          _lastVerifiedParticipantName = '';
          _lastVerifiedParticipantPhotoUrl = '';
          _lastVerifiedAt = null;
          _isLoading = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _refreshScanContext({bool silent = false}) async {
    if (_studentId.isEmpty || _isRefreshingContext) return;
    _isRefreshingContext = true;

    try {
      final result = await _eventService.getStudentScanContext(_studentId);
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
      final availability = _scanAvailabilityNote(
        status: status,
        serviceMessage: message,
        context: contextMap,
      );

      setState(() {
        _scanContext = result;
        _selectedEventTitle =
            (normalizedStatus == 'no_assignment' || normalizedStatus == 'error')
                ? ''
                : eventTitle;

        if (scannerEnabled && !_manualPause && !_isReviewPhase) {
          _isScanning = true;
        } else {
          _isScanning = false;
          if (!scannerEnabled) {
            _manualPause = false;
            _isReviewPhase = false;
            _isSubmittingReview = false;
            _pendingTicketPayload = '';
            _pendingParticipantName = '';
            _pendingParticipantPhotoUrl = '';
            _pendingDetectedAt = null;
          }
        }

        if (normalizedStatus == 'no_assignment' || normalizedStatus == 'error') {
          _isScanning = false;
          _manualPause = false;
          _isReviewPhase = false;
          _isSubmittingReview = false;
          _pendingTicketPayload = '';
          _pendingParticipantName = '';
          _pendingParticipantPhotoUrl = '';
          _pendingDetectedAt = null;
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scanContext = {
          'ok': false,
          'status': 'error',
          'scanner_enabled': false,
          'message': 'Unable to load scanner context right now.',
          'context': null,
        };
        _selectedEventTitle = '';
        if (!_hasScanResult) {
          _scanStatus = _scannerClosedLabel;
          _statusColor = Colors.red.shade700;
        }
        _isScanning = false;
        _manualPause = false;
        _clearPendingReviewState();
      });
    } finally {
      _isRefreshingContext = false;
      if (!silent && mounted) {
        // Reserved for one-shot feedback later.
      }
    }
  }

  void _scheduleScannerResume({
    Duration delay = const Duration(milliseconds: 1200),
  }) {
    _scanResumeTimer?.cancel();
    _scanResumeTimer = Timer(delay, () async {
      if (!mounted || _manualPause) return;
      if (_isReviewPhase || _isSubmittingReview) return;
      await _refreshScanContext(silent: true);
      if (!mounted || !_scannerEnabled || _manualPause || _isReviewPhase) {
        return;
      }
      setState(() {
        _isScanning = true;
        if (!_hasScanResult) {
          _scanStatus = 'Ready to scan. Point the camera at the ticket QR code.';
          _statusColor = Colors.grey.shade800;
        }
      });
    });
  }

  void _clearPendingReviewState() {
    _isReviewPhase = false;
    _isSubmittingReview = false;
    _pendingTicketPayload = '';
    _pendingParticipantName = '';
    _pendingParticipantPhotoUrl = '';
    _pendingDetectedAt = null;
  }

  void _rememberPendingReviewCandidate(
    String ticketPayload,
    Map<String, dynamic> response,
  ) {
    _isReviewPhase = true;
    _isSubmittingReview = false;
    _manualPause = true;
    _isScanning = false;
    _pendingTicketPayload = ticketPayload;
    final participantName =
        (response['participant_name']?.toString() ?? '').trim();
    _pendingParticipantName = participantName.isNotEmpty
        ? participantName
        : 'Student Candidate';
    _pendingParticipantPhotoUrl =
        (response['participant_photo_url']?.toString() ?? '').trim();
    _pendingDetectedAt = DateTime.now();
    _scanStatus = 'Review student identity, then tap Confirm or Reject.';
    _statusColor = const Color(0xFFD4A843);
    _hasScanResult = true;
  }

  void _rememberVerifiedParticipant(Map<String, dynamic> response) {
    final participantName =
        (response['participant_name']?.toString() ?? '').trim();
    final participantPhotoUrl =
        (response['participant_photo_url']?.toString() ?? '').trim();
    if (participantName.isEmpty && participantPhotoUrl.isEmpty) return;

    _lastVerifiedParticipantName = participantName.isNotEmpty
        ? participantName
        : (_lastVerifiedParticipantName.isNotEmpty
              ? _lastVerifiedParticipantName
              : 'Verified Student');
    if (participantPhotoUrl.isNotEmpty) {
      _lastVerifiedParticipantPhotoUrl = participantPhotoUrl;
    }
    _lastVerifiedAt = DateTime.now();
  }

  Future<void> _confirmPendingReview() async {
    if (!_isReviewPhase || _isSubmittingReview) return;
    if (_pendingTicketPayload.trim().isEmpty || _studentId.trim().isEmpty) {
      return;
    }

    final ticketPayload = _pendingTicketPayload.trim();
    setState(() {
      _isSubmittingReview = true;
      _scanStatus = 'Confirming check-in...';
      _statusColor = const Color(0xFFD4A843);
      _hasScanResult = false;
    });

    final res = await _eventService.checkInParticipantAsAssistant(
      ticketPayload,
      _studentId,
    );
    if (!mounted) return;

    setState(() {
      final status = (res['status']?.toString() ?? '').toLowerCase();
      if (res['ok'] == true) {
        final participantName =
            (res['participant_name']?.toString() ?? '').trim();
        _scanStatus = participantName.isNotEmpty
            ? 'Success time in: $participantName'
            : (res['message']?.toString() ?? 'Check-in successful!');
        _statusColor = const Color(0xFF064E3B);
        _rememberVerifiedParticipant(res);
        _playSuccessScanSound();
      } else if (status == 'already_checked_in' || status == 'used') {
        _scanStatus = _normalizeScannerMessage(
          res['error']?.toString(),
          fallback: 'Already checked in.',
        );
        _statusColor = Colors.orange.shade700;
        _rememberVerifiedParticipant(res);
        _playFailedScanSound();
      } else {
        _scanStatus = _normalizeScannerMessage(
          res['error']?.toString(),
          fallback: 'Check-in failed.',
        );
        _statusColor = Colors.red.shade700;
        _playFailedScanSound();
      }
      _hasScanResult = true;
      _manualPause = false;
      _clearPendingReviewState();
    });

    _scheduleScannerResume(
      delay: (res['ok'] == true)
          ? const Duration(milliseconds: 700)
          : const Duration(milliseconds: 900),
    );
  }

  void _rejectPendingReview() {
    if (!_isReviewPhase || _isSubmittingReview) return;
    _scanResumeTimer?.cancel();
    setState(() {
      _scanStatus = 'Scan rejected. No attendance recorded.';
      _statusColor = Colors.orange.shade700;
      _hasScanResult = true;
      _manualPause = false;
      _clearPendingReviewState();
    });
    _playFailedScanSound();
    _scheduleScannerResume(delay: const Duration(milliseconds: 650));
  }

  void _handleDetect(BarcodeCapture capture) async {
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null &&
          _isScanning &&
          _scannerEnabled &&
          _studentId.isNotEmpty) {
        final normalized = rawValue.trim();
        final now = DateTime.now();
        if (_lastScannedCode == normalized &&
            _lastScannedAt != null &&
            now.difference(_lastScannedAt!) < _sameCodeCooldown) {
          return;
        }
        _lastScannedCode = normalized;
        _lastScannedAt = now;

        setState(() {
          _isScanning = false;
          _scanStatus = 'Processing ticket...';
          _statusColor = const Color(0xFFD4A843);
          _hasScanResult = false;
        });

        final res = await _eventService.checkInParticipantAsAssistant(
          normalized,
          _studentId,
          dryRun: true,
        );
        var shouldPlayReviewCue = false;

        if (mounted) {
          setState(() {
            final status = (res['status']?.toString() ?? '').toLowerCase();
            if (res['ok'] == true && status == 'ready_for_confirmation') {
              _rememberPendingReviewCandidate(normalized, res);
              shouldPlayReviewCue = true;
            } else if (status == 'already_checked_in' || status == 'used') {
              _scanStatus = _normalizeScannerMessage(
                res['error']?.toString(),
                fallback: 'Already checked in.',
              );
              _statusColor = Colors.orange.shade700;
              _rememberVerifiedParticipant(res);
              _clearPendingReviewState();
              _playFailedScanSound();
            } else {
              _scanStatus = _normalizeScannerMessage(
                res['error']?.toString(),
                fallback: 'Check-in failed.',
              );
              _statusColor = Colors.red.shade700;
              _clearPendingReviewState();
              _playFailedScanSound();
            }
            _hasScanResult = true;
          });
        }
        if (shouldPlayReviewCue) {
          _playReviewScanSound();
        }
        if ((res['status']?.toString() ?? '').toLowerCase() !=
            'ready_for_confirmation') {
          _scheduleScannerResume(
            delay: (res['ok'] == true)
                ? const Duration(milliseconds: 700)
                : const Duration(milliseconds: 900),
          );
        }
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: PulseConnectLoader());
    }

    if (!_hasPermission) {
      return _buildNoPermission();
    }

    return _buildScannerView();
  }

  Widget _buildGradientHeader({
    required String title,
    required String subtitle,
    IconData? actionIcon,
    VoidCallback? onAction,
  }) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        24,
        MediaQuery.of(context).padding.top + 20,
        24,
        30,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_studentDark(context), _studentPrimary(context)],
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: _studentPrimary(context).withValues(alpha: 0.3),
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
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.8),
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (actionIcon != null) ...[
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
        return const Color(0xFF064E3B);
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

    if (opensAt != null) {
      if (now.isBefore(opensAt)) {
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
    return text;
  }

  String _displayNameInitials(String rawName) {
    final name = rawName.trim();
    if (name.isEmpty) return 'ST';
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
    required String photoUrl,
  }) {
    const avatarSize = 56.0;
    final initials = _displayNameInitials(displayName);
    final hasRemotePhoto =
        photoUrl.trim().isNotEmpty && photoUrl.trim().toLowerCase().startsWith('http');

    Widget initialsAvatar() {
      return Container(
        width: avatarSize,
        height: avatarSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [
              _studentPrimary(context).withValues(alpha: 0.92),
              _studentDark(context).withValues(alpha: 0.95),
            ],
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
      child: hasRemotePhoto
          ? Image.network(
              photoUrl.trim(),
              width: avatarSize,
              height: avatarSize,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => initialsAvatar(),
            )
          : initialsAvatar(),
    );
  }

  Widget _buildLastVerifiedOverlay() {
    final isReviewCandidate = _isReviewPhase;
    final displayName = (isReviewCandidate
            ? _pendingParticipantName
            : _lastVerifiedParticipantName)
        .trim();
    final photoUrl = isReviewCandidate
        ? _pendingParticipantPhotoUrl
        : _lastVerifiedParticipantPhotoUrl;
    final verifiedLabel = isReviewCandidate
        ? (_pendingDetectedAt != null
              ? 'Review ${_formatStartTime(_pendingDetectedAt!)}'
              : 'Review Candidate')
        : (_lastVerifiedAt != null
              ? 'Verified ${_formatStartTime(_lastVerifiedAt!)}'
              : 'Verified Student');

    final hasData = displayName.isNotEmpty;
    final overlayContent = !hasData
        ? const SizedBox.shrink(key: ValueKey('verified-empty'))
        : Container(
            key: ValueKey(
              '${displayName}_${_lastVerifiedAt?.millisecondsSinceEpoch ?? 0}_${_pendingDetectedAt?.millisecondsSinceEpoch ?? 0}',
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
                  displayName: displayName,
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
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  isReviewCandidate
                      ? Icons.visibility_rounded
                      : Icons.verified_rounded,
                  color: isReviewCandidate
                      ? const Color(0xFFFBBF24)
                      : const Color(0xFF34D399),
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

  String _studentScannerFrameAsset(BuildContext context) {
    return CourseThemeUtils.isGreenStudentPrimary(_studentPrimary(context))
        ? 'assets/bscs_student_scanner_trimmed.png'
        : 'assets/bsit_student_scanner_trimmed.png';
  }

  Widget _buildCameraSurface() {
    return (_isScanning && _scannerEnabled)
        ? MobileScanner(
            fit: BoxFit.cover,
            onDetect: _handleDetect,
            errorBuilder: (context, error, child) {
              return Container(
                color: Colors.black,
                alignment: Alignment.center,
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
                        style: TextStyle(
                          color: Colors.grey.shade300,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          )
        : Container(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.camera_alt_rounded,
                    size: 64,
                    color: Colors.grey.shade300,
                  ),
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

  Widget _buildFramedScannerWindow() {
    final frameAsset = _studentScannerFrameAsset(context);

    return AspectRatio(
      // Trimmed frames keep full body visible without edge cutting.
      aspectRatio: 0.74,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          final cameraPadding = EdgeInsets.fromLTRB(
            width * 0.13,
            height * 0.148,
            width * 0.13,
            height * 0.162,
          );

          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: Padding(
                  padding: cameraPadding,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned.fill(child: _buildCameraSurface()),
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
              Positioned.fill(
                child: IgnorePointer(
                  child: Image.asset(
                    frameAsset,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildScannerView() {
    final media = MediaQuery.of(context);
    final bottomNavClearance = media.padding.bottom + 98;
    final eventTitle =
        _selectedEventTitle.trim().isNotEmpty ? _selectedEventTitle : 'Assigned Event';

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: Column(
        children: [
          _buildGradientHeader(
            title: 'Scan QR Code',
            subtitle: eventTitle,
            actionIcon: Icons.refresh_rounded,
            onAction: () => _refreshScanContext(),
          ),
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(24, 14, 24, bottomNavClearance),
              child: Column(
                children: [
                  _buildFramedScannerWindow(),
                  const SizedBox(height: 20),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: _isScanning
                          ? Colors.white
                          : (_statusColor == Colors.red.shade700
                              ? Colors.red.shade50
                              : (_statusColor == const Color(0xFFD4A843)
                                  ? Colors.orange.shade50
                                  : const Color(0xFFECFDF5))),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _isScanning
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
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _statusColor == Colors.red.shade700
                              ? Icons.error_rounded
                              : (_statusColor == const Color(0xFFD4A843)
                                  ? Icons.hourglass_top_rounded
                                  : Icons.check_circle_rounded),
                          color: _statusColor,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _scanStatus,
                            textAlign: TextAlign.left,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: _statusColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_isReviewPhase) ...[
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 50,
                            child: OutlinedButton.icon(
                              onPressed: _isSubmittingReview
                                  ? null
                                  : _rejectPendingReview,
                              icon: const Icon(Icons.close_rounded, size: 18),
                              label: const Text(
                                'REJECT',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.9,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red.shade700,
                                side: BorderSide(color: Colors.red.shade300),
                                backgroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: _isSubmittingReview
                                  ? null
                                  : _confirmPendingReview,
                              icon: _isSubmittingReview
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.check_rounded, size: 18),
                              label: Text(
                                _isSubmittingReview ? 'CONFIRMING' : 'CONFIRM',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.0,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF059669),
                                foregroundColor: Colors.white,
                                elevation: 3,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: (!_scannerEnabled || _isReviewPhase || _isSubmittingReview)
                          ? null
                          : () {
                              _scanResumeTimer?.cancel();
                              setState(() {
                                if (_isScanning) {
                                  _isScanning = false;
                                  _manualPause = true;
                                  if (!_hasScanResult) {
                                    _scanStatus = 'Scanner paused.';
                                    _statusColor = Colors.grey.shade600;
                                  }
                                } else {
                                  _isScanning = true;
                                  _manualPause = false;
                                  if (!_hasScanResult) {
                                    _scanStatus =
                                        'Ready to scan. Point the camera at the ticket QR code.';
                                    _statusColor = Colors.grey.shade800;
                                  }
                                }
                              });
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: !_scannerEnabled
                            ? Colors.grey.shade400
                            : (_isScanning
                                ? Colors.red.shade600
                                : _studentPrimary(context)),
                        foregroundColor: Colors.white,
                        elevation: _isScanning ? 0 : 8,
                        shadowColor: _studentPrimary(context).withValues(
                          alpha: 0.4,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text(
                        !_scannerEnabled
                            ? 'WAIT FOR SCAN WINDOW'
                            : (_isReviewPhase
                                ? 'REVIEW IN PROGRESS'
                                : (_isScanning
                                    ? 'PAUSE SCANNING'
                                    : 'RESUME SCANNING')),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoPermission() {
    final status = (_scanContext?['status']?.toString() ?? '').toLowerCase();
    final serviceMessage = (_scanContext?['message']?.toString() ?? '').trim();
    final message = status == 'error'
        ? (serviceMessage.isNotEmpty
            ? serviceMessage
            : 'Unable to load scanner access right now. Please refresh.')
        : 'You can\'t access this feature. Only students assigned by teacher can use the QR scanner.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                color: Color(0xFFFFF7ED),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.qr_code_scanner_rounded,
                size: 64,
                color: _studentPrimary(context),
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
