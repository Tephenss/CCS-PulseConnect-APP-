import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';

class StudentScanScreen extends StatefulWidget {
  const StudentScanScreen({super.key});

  @override
  State<StudentScanScreen> createState() => _StudentScanScreenState();
}

class _StudentScanScreenState extends State<StudentScanScreen> {
  final _supabase = Supabase.instance.client;
  final _authService = AuthService();
  final _eventService = EventService();
  bool _isLoading = true;
  bool _hasPermission = false;
  bool _isScanning = false;
  String _scanStatus = 'Click the button to start scanning';
  Color _statusColor = Colors.grey.shade600;
  IconData _statusIcon = Icons.qr_code_scanner_rounded;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    try {
      final user = await _authService.getCurrentUser();
      if (user != null) {
         final response = await _supabase
            .from('event_assistants')
            .select('''
              id,
              allow_scan,
              events!inner(status)
            ''')
            .eq('student_id', user['id'])
            .eq('allow_scan', true)
            .inFilter('events.status', ['published', 'active'])
            .limit(1);

        if (response.isNotEmpty) {
          setState(() {
            _hasPermission = true;
          });
        }
      }
    } catch (e) {
      // Ignored: No permission by default
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _handleDetect(BarcodeCapture capture) async {
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null && _hasPermission && _isScanning) {
        setState(() {
          _isScanning = false;
          _scanStatus = 'Processing ticket...';
          _statusColor = const Color(0xFFD4A843);
          _statusIcon = Icons.hourglass_top_rounded;
        });

        final res = await _eventService.checkInParticipant(rawValue);

        if (mounted) {
          setState(() {
            final status = res['status'] ?? '';
            if (res['ok'] == true) {
              final message = res['message'] ?? 'Check-in Successful!';
              _scanStatus = message;

              if (status == 'late') {
                _statusColor = const Color(0xFFD97706); // Orange for late
                _statusIcon = Icons.warning_amber_rounded;
              } else if (status == 'checked_out') {
                _statusColor = const Color(0xFF1D4ED8); // Blue for check-out
                _statusIcon = Icons.logout_rounded;
              } else {
                _statusColor = const Color(0xFF064E3B); // Green for on-time
                _statusIcon = Icons.check_circle_rounded;
              }
            } else {
              _scanStatus = res['error'] ?? 'Check-in failed.';

              if (status == 'too_early') {
                _statusColor = const Color(0xFF1D4ED8);
                _statusIcon = Icons.access_time_rounded;
              } else if (status == 'ended') {
                _statusColor = Colors.grey.shade700;
                _statusIcon = Icons.event_busy_rounded;
              } else if (status == 'used') {
                _statusColor = const Color(0xFFD97706);
                _statusIcon = Icons.replay_rounded;
              } else {
                _statusColor = Colors.red.shade700;
                _statusIcon = Icons.cancel_rounded;
              }
            }
          });
        }
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: const Text('Scan QR Code', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white)),
        backgroundColor: const Color(0xFF064E3B), // changed to green
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: PulseConnectLoader())
          : !_hasPermission
              ? _buildNoPermission()
              : _buildScanner(),
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
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5), // changed to light green
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.qr_code_scanner_rounded, size: 64, color: Color(0xFF064E3B)), // changed to green
            ),
            const SizedBox(height: 24),
            const Text(
              'No Permission',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF1F2937)),
            ),
            const SizedBox(height: 12),
            Text(
              'You have no permission to scan tickets. Only assigned student assistants can use this feature.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: Colors.grey.shade600, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanner() {
    final media = MediaQuery.of(context);
    final bottomNavClearance = media.padding.bottom + 98;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(24, 14, 24, bottomNavClearance),
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFF064E3B), width: 4),
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 20, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
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
                Container(
                  padding: const EdgeInsets.all(16),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey.shade200),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 3)),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(_statusIcon, size: 20, color: _statusColor),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _scanStatus,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _statusColor),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        colors: _isScanning
                            ? [const Color(0xFFDC2626), const Color(0xFF991B1B)]
                            : [const Color(0xFF450A0A), const Color(0xFF7F1D1D)],
                      ),
                      boxShadow: [
                        BoxShadow(
                           color: (_isScanning ? const Color(0xFFDC2626) : const Color(0xFF7F1D1D)).withValues(alpha: 0.3),
                           blurRadius: 10,
                           offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          if (_isScanning) {
                            _isScanning = false;
                            _scanStatus = 'Scan cancelled.';
                            _statusColor = Colors.grey.shade600;
                            _statusIcon = Icons.qr_code_scanner_rounded;
                          } else {
                            _isScanning = true;
                            _scanStatus = 'Point camera at the QR code.';
                            _statusColor = Colors.grey.shade800;
                            _statusIcon = Icons.center_focus_strong_rounded;
                          }
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(
                        _isScanning ? 'CANCEL SCANNING' : 'START SCANNING',
                        style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2),
                      ),
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
}
