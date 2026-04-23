import 'dart:async';

import 'package:flutter/material.dart';
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
    _initScannerAccess();
  }

  @override
  void dispose() {
    _scanResumeTimer?.cancel();
    _contextRefreshTimer?.cancel();
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

        if (scannerEnabled && !_manualPause) {
          _isScanning = true;
        } else {
          _isScanning = false;
          if (!scannerEnabled) _manualPause = false;
        }

        if (normalizedStatus == 'no_assignment' || normalizedStatus == 'error') {
          _isScanning = false;
          _manualPause = false;
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
      await _refreshScanContext(silent: true);
      if (!mounted || !_scannerEnabled || _manualPause) return;
      setState(() {
        _isScanning = true;
        if (!_hasScanResult) {
          _scanStatus = 'Ready to scan. Point the camera at the ticket QR code.';
          _statusColor = Colors.grey.shade800;
        }
      });
    });
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
        );

        if (mounted) {
          setState(() {
            final status = (res['status']?.toString() ?? '').toLowerCase();
            if (res['ok'] == true) {
              final participantName =
                  (res['participant_name']?.toString() ?? '').trim();
              _scanStatus = participantName.isNotEmpty
                  ? 'Success time in: $participantName'
                  : (res['message']?.toString() ?? 'Check-in successful!');
              _statusColor = const Color(0xFF064E3B);
            } else {
              _scanStatus = _normalizeScannerMessage(
                res['error']?.toString(),
                fallback: 'Check-in failed.',
              );
              _statusColor = status == 'already_checked_in' || status == 'used'
                  ? Colors.orange.shade700
                  : Colors.red.shade700;
            }
            _hasScanResult = true;
          });
        }
        _scheduleScannerResume(
          delay: (res['ok'] == true)
              ? const Duration(milliseconds: 700)
              : const Duration(milliseconds: 900),
        );
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
                    child: _buildCameraSurface(),
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
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: !_scannerEnabled
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
                            : (_isScanning
                                ? 'PAUSE SCANNING'
                                : 'RESUME SCANNING'),
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
