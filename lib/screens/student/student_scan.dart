import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_service.dart';

class StudentScanScreen extends StatefulWidget {
  const StudentScanScreen({super.key});

  @override
  State<StudentScanScreen> createState() => _StudentScanScreenState();
}

class _StudentScanScreenState extends State<StudentScanScreen> {
  final _supabase = Supabase.instance.client;
  final _authService = AuthService();
  bool _isLoading = true;
  bool _hasPermission = false;
  bool _isScanning = false;
  String _scanStatus = 'Click the button to start scanning';
  Color _statusColor = Colors.grey.shade600;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    try {
      final user = await _authService.getCurrentUser();
      if (user != null) {
        // Query if the student is an assistant for any active event with scanning allowed
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
        // Stop scanning to process
        setState(() {
          _isScanning = false;
          _scanStatus = 'Processing ticket: $rawValue...';
          _statusColor = const Color(0xFFD4A843);
        });

        // In a real app we would call an API here to record attendance
        await Future.delayed(const Duration(seconds: 1));

        if (mounted) {
          setState(() {
            _scanStatus = 'Check-in Successful!';
            _statusColor = const Color(0xFF064E3B);
          });
        }
        break; // Process one barcode only
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR Code', style: TextStyle(fontWeight: FontWeight.w700)),
        elevation: 0,
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF064E3B)))
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
                color: Colors.red.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.qr_code_scanner_rounded, size: 64, color: Colors.red.shade400),
            ),
            const SizedBox(height: 24),
            Text(
              'No Permission',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.red.shade800),
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
    return Column(
      children: [
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
                      // fit: BoxFit.contain,
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
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10, offset: const Offset(0, 4)
                      ),
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
      ],
    );
  }
}
