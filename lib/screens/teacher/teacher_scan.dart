import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';

class TeacherScanScreen extends StatefulWidget {
  const TeacherScanScreen({super.key});

  @override
  State<TeacherScanScreen> createState() => _TeacherScanScreenState();
}

class _TeacherScanScreenState extends State<TeacherScanScreen> {
  bool _isLoading = true;
  bool _isScanning = false;
  String _scanStatus = 'Select an event to start scanning.';
  Color _statusColor = Colors.grey.shade600;
  String _teacherId = '';

  List<Map<String, dynamic>> _scanEvents = [];
  String _selectedEventId = '';
  String _selectedEventTitle = '';

  bool _isOffline = false;
  List<String> _offlineQueue = [];
  bool _isSyncing = false;
  Timer? _scanResumeTimer;
  bool _manualPause = false;
  String _lastScannedCode = '';
  DateTime? _lastScannedAt;
  static const Duration _sameCodeCooldown = Duration(seconds: 10);

  late Connectivity _connectivity;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  final AuthService _authService = AuthService();
  final EventService _eventService = EventService();

  bool get _hasPermission => _scanEvents.isNotEmpty;
  bool get _hasSelectedEvent => _selectedEventId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _initScannerAccess();
    _initConnectivity();
  }

  @override
  void dispose() {
    _scanResumeTimer?.cancel();
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
      final events = teacherId.isNotEmpty
          ? await _eventService.getTeacherScanAccessibleEvents(teacherId)
          : <Map<String, dynamic>>[];

      if (mounted) {
        setState(() {
          _teacherId = teacherId;
          _scanEvents = events;
          _selectedEventId = '';
          _selectedEventTitle = '';
          _isScanning = false;
          _scanStatus = events.isEmpty
              ? 'No QR scanner access assigned yet.'
              : 'Select an event to start scanning.';
          _statusColor = events.isEmpty ? Colors.orange.shade700 : Colors.grey.shade700;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _teacherId = '';
          _scanEvents = [];
          _selectedEventId = '';
          _selectedEventTitle = '';
          _isScanning = false;
          _scanStatus = 'Unable to load scanner access right now.';
          _statusColor = Colors.red.shade700;
          _isLoading = false;
        });
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
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    List<String> remainingQueue = List.from(_offlineQueue);
    int syncedCount = 0;

    for (String ticketId in _offlineQueue) {
      final res = await _eventService.checkInParticipantAsTeacher(
        'PULSE-$ticketId',
        _teacherId,
      );
      final status = res['status']?.toString() ?? '';
      final shouldRemove = res['ok'] == true ||
          res['error'] == 'Ticket has already been scanned.' ||
          status == 'forbidden' ||
          status == 'invalid' ||
          status == 'used' ||
          status == 'already_checked_in' ||
          status == 'ended';
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
        SnackBar(content: Text('Auto-synced $syncedCount offline scans to database.')),
      );
    }
  }

  void _openScannerForEvent(Map<String, dynamic> event) {
    _scanResumeTimer?.cancel();
    setState(() {
      _selectedEventId = event['id']?.toString() ?? '';
      _selectedEventTitle = event['title']?.toString() ?? 'Event';
      _lastScannedCode = '';
      _lastScannedAt = null;
      _isScanning = true;
      _manualPause = false;
      _scanStatus = 'Point camera at the QR code.';
      _statusColor = Colors.grey.shade800;
    });
  }

  void _backToEventPicker() {
    _scanResumeTimer?.cancel();
    setState(() {
      _isScanning = false;
      _manualPause = false;
      _lastScannedCode = '';
      _lastScannedAt = null;
      _selectedEventId = '';
      _selectedEventTitle = '';
      _scanStatus = 'Select an event to start scanning.';
      _statusColor = Colors.grey.shade700;
    });
  }

  void _scheduleScannerResume({Duration delay = const Duration(milliseconds: 1400)}) {
    _scanResumeTimer?.cancel();
    _scanResumeTimer = Timer(delay, () {
      if (!mounted) return;
      if (_manualPause || !_hasSelectedEvent) return;
      setState(() {
        _isScanning = true;
        _scanStatus = 'Point camera at the QR code.';
        _statusColor = Colors.grey.shade800;
      });
    });
  }

  void _handleDetect(BarcodeCapture capture) async {
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null && _isScanning && _hasSelectedEvent && _teacherId.isNotEmpty) {
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
          _scanStatus = 'Processing ticket: $normalized...';
          _statusColor = const Color(0xFFD4A843);
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
              _scanStatus = 'Saved offline. Validation will happen when sync resumes.';
              _statusColor = Colors.orange.shade700;
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
                _scanStatus = res['message']?.toString() ?? 'Check-in Successful!';
                _statusColor = const Color(0xFF064E3B);
              } else if (res['status']?.toString() == 'already_checked_in') {
                _scanStatus = res['error']?.toString() ?? 'Already checked in.';
                _statusColor = Colors.orange.shade700;
              } else {
                _scanStatus = res['error'] ?? 'Check-in failed.';
                _statusColor = Colors.red.shade700;
              }
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

    if (!_hasSelectedEvent) {
      return _buildEventPicker();
    }

    return _buildScannerView();
  }

  Widget _buildGradientHeader({
    required String title,
    required String subtitle,
    IconData? actionIcon,
    VoidCallback? onAction,
    bool isBack = false,
  }) {
    return Container(
      padding: EdgeInsets.fromLTRB(24, MediaQuery.of(context).padding.top + 20, 24, 30),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF064E3B), Color(0xFF047857)],
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF064E3B).withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (isBack) ...[
            GestureDetector(
              onTap: onAction,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 20),
              ),
            ),
            const SizedBox(width: 16),
          ],
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
          if (!isBack && actionIcon != null) ...[
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

  Widget _buildEventPicker() {
    final bottomNavClearance = MediaQuery.of(context).padding.bottom + 118;
    return Column(
      children: [
        _buildGradientHeader(
          title: 'QR Scanner Events',
          subtitle: 'Choose the event you are assigned to scan.',
        ),
        const SizedBox(height: 14),
        if (_isOffline || _offlineQueue.isNotEmpty) _buildConnectivityBanner(),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.fromLTRB(20, 10, 20, bottomNavClearance),
              itemCount: _scanEvents.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final event = _scanEvents[index];
                final title = event['title']?.toString() ?? 'Event';
                final location = (event['location']?.toString() ?? '').trim();
                final startAt = DateTime.tryParse(event['start_at']?.toString() ?? '');
                final dateText = startAt != null
                    ? DateFormat('MMM dd, yyyy  -  h:mm a').format(startAt.toLocal())
                    : 'TBA';

                return InkWell(
                  onTap: () => _openScannerForEvent(event),
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.grey.shade100, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 15,
                          offset: const Offset(0, 5),
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF064E3B), Color(0xFF047857)],
                            ),
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF064E3B).withValues(alpha: 0.3),
                                blurRadius: 8,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF1F2937)),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                dateText,
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                              ),
                              if (location.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    Icon(Icons.place_rounded, size: 14, color: Colors.grey.shade500),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        location,
                                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Color(0xFF9CA3AF)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
    );
  }

  Widget _buildScannerView() {
    final media = MediaQuery.of(context);
    final bottomNavClearance = media.padding.bottom + 98;
    return Column(
      children: [
        _buildGradientHeader(
          title: 'Scan QR Code',
          subtitle: _selectedEventTitle,
          isBack: true,
          onAction: _backToEventPicker,
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
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(color: const Color(0xFFD4A843).withValues(alpha: 0.8), width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF064E3B).withValues(alpha: 0.15),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: _isScanning
                          ? MobileScanner(
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
                          : Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.camera_alt_rounded, size: 64, color: Colors.grey.shade300),
                                  const SizedBox(height: 16),
                                  Text('Camera Paused', style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
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
                    onPressed: () {
                      _scanResumeTimer?.cancel();
                      setState(() {
                        if (_isScanning) {
                          _isScanning = false;
                          _manualPause = true;
                          _scanStatus = 'Scan cancelled.';
                          _statusColor = Colors.grey.shade600;
                        } else {
                          _isScanning = true;
                          _manualPause = false;
                          _scanStatus = 'Point camera at the QR code.';
                          _statusColor = Colors.grey.shade800;
                        }
                      });
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isScanning ? Colors.red.shade600 : const Color(0xFF064E3B),
                      foregroundColor: Colors.white,
                      elevation: _isScanning ? 0 : 8,
                      shadowColor: const Color(0xFF064E3B).withValues(alpha: 0.4),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(
                      _isScanning ? 'CANCEL SCANNING' : 'START SCANNING',
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
                color: Color(0xFF064E3B),
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
              'This feature is only used for teachers assigned by the administrator to scan attendance.',
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
