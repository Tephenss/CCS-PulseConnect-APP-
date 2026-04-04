import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:async';
import '../../services/event_service.dart';

class TeacherScanScreen extends StatefulWidget {
  const TeacherScanScreen({super.key});

  @override
  State<TeacherScanScreen> createState() => _TeacherScanScreenState();
}

class _TeacherScanScreenState extends State<TeacherScanScreen> {
  bool _isScanning = false;
  String _scanStatus = 'Click the button to start scanning';
  Color _statusColor = Colors.grey.shade600;

  bool _isOffline = false;
  List<String> _offlineQueue = [];
  bool _isSyncing = false;

  late Connectivity _connectivity;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  final EventService _eventService = EventService();

  @override
  void initState() {
    super.initState();
    _initOfflineQueue();
    _initConnectivity();
  }

  @override
  void dispose() {
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

  void _initConnectivity() {
    _connectivity = Connectivity();
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((List<ConnectivityResult> results) {
      final isOffline = results.every((res) => res == ConnectivityResult.none);
      setState(() => _isOffline = isOffline);
      if (!isOffline && _offlineQueue.isNotEmpty) {
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
      final res = await _eventService.checkInParticipant('PULSE-$ticketId');
      if (res['ok'] == true || res['error'] == 'Ticket has already been scanned.') {
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

  void _handleDetect(BarcodeCapture capture) async {
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null && _isScanning) {
        // Stop scanning to process
        setState(() {
          _isScanning = false;
          _scanStatus = 'Processing ticket: $rawValue...';
          _statusColor = const Color(0xFFD4A843);
        });

        // Offline logic
        if (_isOffline) {
          final strippedId = rawValue.replaceFirst('PULSE-', '').trim();
          if (!_offlineQueue.contains(strippedId)) {
            setState(() {
              _offlineQueue.add(strippedId);
            });
            await _saveOfflineQueue();
          }
          
          if (mounted) {
            setState(() {
              _scanStatus = 'Saved Offline! Will sync later.';
              _statusColor = Colors.orange.shade700;
            });
          }
        } 
        // Online Logic
        else {
          final res = await _eventService.checkInParticipant(rawValue);
          
          if (mounted) {
            setState(() {
              if (res['ok'] == true) {
                 _scanStatus = 'Check-in Successful!';
                 _statusColor = const Color(0xFF064E3B);
              } else {
                 _scanStatus = res['error'] ?? 'Check-in failed.';
                 _statusColor = Colors.red.shade700;
              }
            });
          }
        }
        break; // Process one barcode only
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          // App Bar Area
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Scan QR Code', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF1F2937))),
              ],
            ),
          ),
          
          // Internet status indicator
          if (_isOffline || _offlineQueue.isNotEmpty)
            Container(
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
                     color: _isOffline ? Colors.red.shade700 : Colors.orange.shade700
                   ),
                   const SizedBox(width: 8),
                   Text(
                     _isOffline 
                       ? 'Offline Mode - ${_offlineQueue.length} scans queued'
                       : 'Syncing ${_offlineQueue.length} queued scans...',
                     style: TextStyle(
                       fontSize: 12, 
                       fontWeight: FontWeight.w600, 
                       color: _isOffline ? Colors.red.shade700 : Colors.orange.shade700
                     ),
                   ),
                ],
              ),
            ),
          
          Expanded(
            flex: 5,
            child: Container(
              margin: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFF064E3B), width: 4),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: _isScanning
                    ? MobileScanner(
                        onDetect: _handleDetect,
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
          
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade200),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                      ],
                    ),
                    child: Text(
                      _scanStatus,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _statusColor),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          if (_isScanning) {
                            _isScanning = false;
                            _scanStatus = 'Scan cancelled.';
                            _statusColor = Colors.grey.shade600;
                          } else {
                            _isScanning = true;
                            _scanStatus = 'Point camera at the QR code.';
                            _statusColor = Colors.grey.shade800;
                          }
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isScanning ? Colors.red.shade600 : const Color(0xFFD4A843),
                        foregroundColor: _isScanning ? Colors.white : const Color(0xFF064E3B),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(
                        _isScanning ? 'CANCEL SCANNING' : 'START SCANNING',
                        style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20), // Bottom nav padding
        ],
      ),
    );
  }
}
