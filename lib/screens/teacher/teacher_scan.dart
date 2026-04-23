import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';
import '../../utils/teacher_theme_utils.dart';

class TeacherScanScreen extends StatefulWidget {
  const TeacherScanScreen({super.key});

  @override
  State<TeacherScanScreen> createState() => _TeacherScanScreenState();
}

class _TeacherScanScreenState extends State<TeacherScanScreen> {
  bool _isLoading = true;
  bool _isScanning = false;
  String _scanStatus = 'Checking scanner assignment...';
  Color _statusColor = Colors.grey.shade600;
  bool _hasScanResult = false;
  String _teacherId = '';

  Map<String, dynamic>? _scanContext;
  String _selectedEventTitle = '';

  bool _isOffline = false;
  List<String> _offlineQueue = [];
  bool _isSyncing = false;
  bool _isRefreshingContext = false;
  Timer? _scanResumeTimer;
  Timer? _contextRefreshTimer;
  bool _manualPause = false;
  String _lastScannedCode = '';
  DateTime? _lastScannedAt;
  static const Duration _sameCodeCooldown = Duration(seconds: 10);
  static const String _scannerClosedLabel = 'Scanning Closed';
  static const Duration _manilaOffset = Duration(hours: 8);

  late Connectivity _connectivity;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  final AuthService _authService = AuthService();
  final EventService _eventService = EventService();

  bool get _hasPermission =>
      _scanContext != null &&
      _scanContext?['ok'] == true &&
      _teacherId.isNotEmpty &&
      (_scanContext?['status']?.toString() ?? '') != 'no_assignment' &&
      (_scanContext?['status']?.toString() ?? '') != 'error';
  bool get _scannerEnabled => _scanContext?['scanner_enabled'] == true;

  @override
  void initState() {
    super.initState();
    _initScannerAccess();
    _initConnectivity();
  }

  @override
  void dispose() {
    _scanResumeTimer?.cancel();
    _contextRefreshTimer?.cancel();
    _connectivitySubscription.cancel();
    super.dispose();
  }

  Future<void> _initOfflineQueue() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _offlineQueue = prefs.getStringList('offline_scans') ?? [];
    });
  }

  Future<void> _saveOfflineQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('offline_scans', _offlineQueue);
  }

  Future<void> _initScannerAccess() async {
    await _initOfflineQueue();

    try {
      final user = await _authService.getCurrentUser();
      final teacherId = user?['id']?.toString() ?? '';

      if (mounted) {
        setState(() {
          _teacherId = teacherId;
          _selectedEventTitle = '';
          _isScanning = false;
          _scanStatus = 'Checking scanner assignment...';
          _statusColor = Colors.grey.shade700;
          _hasScanResult = false;
          _scanContext = null;
          _isLoading = true;
        });
      }

      if (teacherId.isNotEmpty) {
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
            'message': 'Unable to identify your teacher account.',
            'context': null,
          };
          _scanStatus = 'Unable to identify your teacher account.';
          _statusColor = Colors.red.shade700;
          _hasScanResult = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _teacherId = '';
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
    if (_teacherId.isEmpty || _isRefreshingContext) return;
    _isRefreshingContext = true;

    try {
      final result = await _eventService.getTeacherScanContext(_teacherId);
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
        // reserved for future one-shot feedback
      }
    }
  }

  void _initConnectivity() {
    _connectivity = Connectivity();
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((List<ConnectivityResult> results) {
      final isOffline = results.every((res) => res == ConnectivityResult.none);
      setState(() => _isOffline = isOffline);
      if (!isOffline && _offlineQueue.isNotEmpty && _teacherId.isNotEmpty) {
        _syncOfflineQueue();
      }
    });
  }

  Future<void> _syncOfflineQueue() async {
    if (_isSyncing || _teacherId.isEmpty) return;
    setState(() => _isSyncing = true);

    List<String> remainingQueue = List.from(_offlineQueue);
    int syncedCount = 0;

    for (String ticketId in _offlineQueue) {
      final res = await _eventService.checkInParticipantAsTeacher(
        'PULSE-$ticketId',
        _teacherId,
      );
      final status = (res['status']?.toString() ?? '').toLowerCase();
      final shouldRemove = res['ok'] == true ||
          status == 'forbidden' ||
          status == 'invalid' ||
          status == 'used' ||
          status == 'already_checked_in' ||
          status == 'closed' ||
          status == 'wrong_event' ||
          status == 'no_assignment' ||
          status == 'conflict';
      if (shouldRemove) {
        remainingQueue.remove(ticketId);
        syncedCount++;
      }
    }

    setState(() {
      _offlineQueue = remainingQueue;
      _isSyncing = false;
    });
    _saveOfflineQueue();

    if (syncedCount > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Auto-synced $syncedCount offline scans.')),
      );
    }
  }

  void _scheduleScannerResume({Duration delay = const Duration(milliseconds: 1400)}) {
    _scanResumeTimer?.cancel();
    _scanResumeTimer = Timer(delay, () async {
      if (!mounted) return;
      if (_manualPause) return;
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
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null && _isScanning && _scannerEnabled && _teacherId.isNotEmpty) {
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

        if (_isOffline) {
          final strippedId = normalized.replaceFirst('PULSE-', '').trim();
          if (!_offlineQueue.contains(strippedId)) {
            setState(() {
              _offlineQueue.add(strippedId);
            });
            await _saveOfflineQueue();
          }

          if (mounted) {
            setState(() {
              _scanStatus = 'Saved offline. Validation will happen once online.';
              _statusColor = Colors.orange.shade700;
              _hasScanResult = true;
            });
          }
          _scheduleScannerResume();
        } else {
          final res = await _eventService.checkInParticipantAsTeacher(
            normalized,
            _teacherId,
          );

          if (mounted) {
            setState(() {
              if (res['ok'] == true) {
                final participantName =
                    (res['participant_name']?.toString() ?? '').trim();
                _scanStatus = participantName.isNotEmpty
                    ? 'Success time in: $participantName'
                    : (res['message']?.toString() ?? 'Check-in successful!');
                _statusColor = TeacherThemeUtils.primary;
              } else if ((res['status']?.toString() ?? '').toLowerCase() == 'already_checked_in' ||
                  (res['status']?.toString() ?? '').toLowerCase() == 'used') {
                _scanStatus = _normalizeScannerMessage(
                  res['error']?.toString(),
                  fallback: 'Already checked in.',
                );
                _statusColor = Colors.orange.shade700;
              } else {
                _scanStatus = _normalizeScannerMessage(
                  res['error']?.toString(),
                  fallback: 'Check-in failed.',
                );
                _statusColor = Colors.red.shade700;
              }
              _hasScanResult = true;
            });
          }
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
                      const Icon(Icons.error_outline_rounded, color: Colors.white, size: 30),
                      const SizedBox(height: 10),
                      const Text(
                        'Camera unavailable',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
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
          )
        : Container(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.camera_alt_rounded, size: 64, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text(
                    _scannerEnabled ? 'Camera Paused' : 'Scanner Closed',
                    style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          );
  }

  Widget _buildFramedScannerWindow() {
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
                    'assets/teacher_scanner_trimmed.png',
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
    final eventTitle = _selectedEventTitle.trim().isNotEmpty ? _selectedEventTitle : 'Assigned Event';

    return Column(
      children: [
        _buildGradientHeader(
          title: 'QR Scanner',
          subtitle: eventTitle,
          actionIcon: Icons.refresh_rounded,
          onAction: () => _refreshScanContext(),
        ),
        if (_isOffline || _offlineQueue.isNotEmpty) ...[
          const SizedBox(height: 12),
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
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
                    border: Border.all(color: _isScanning ? Colors.grey.shade200 : _statusColor.withValues(alpha: 0.3)),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _statusColor == Colors.red.shade700
                            ? Icons.error_rounded
                            : (_statusColor == const Color(0xFFD4A843) ? Icons.hourglass_top_rounded : Icons.check_circle_rounded),
                        color: _statusColor,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _scanStatus,
                          textAlign: TextAlign.left,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _statusColor),
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
                            _scanStatus = 'Ready to scan. Point the camera at the ticket QR code.';
                            _statusColor = Colors.grey.shade800;
                          }
                        }
                      });
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: !_scannerEnabled
                          ? Colors.grey.shade400
                          : (_isScanning ? Colors.red.shade600 : TeacherThemeUtils.primary),
                      foregroundColor: Colors.white,
                      elevation: _isScanning ? 0 : 8,
                      shadowColor: TeacherThemeUtils.dark.withValues(alpha: 0.4),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(
                      !_scannerEnabled
                          ? 'WAIT FOR SCAN WINDOW'
                          : (_isScanning ? 'PAUSE SCANNING' : 'RESUME SCANNING'),
                      style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2, fontSize: 15),
                    ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      margin: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: _isOffline ? Colors.red.shade50 : Colors.orange.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _isOffline ? Colors.red.shade200 : Colors.orange.shade200),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _isOffline ? Icons.wifi_off_rounded : Icons.sync_rounded,
            size: 16,
            color: _isOffline ? Colors.red.shade700 : Colors.orange.shade700,
          ),
          const SizedBox(width: 8),
          Text(
            _isOffline
                ? 'Offline Mode - ${_offlineQueue.length} scans queued'
                : 'Syncing ${_offlineQueue.length} queued scans...',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _isOffline ? Colors.red.shade700 : Colors.orange.shade700,
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
