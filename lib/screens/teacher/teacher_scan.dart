import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../services/auth_service.dart';

class TeacherScanScreen extends StatefulWidget {
  const TeacherScanScreen({super.key});

  @override
  State<TeacherScanScreen> createState() => _TeacherScanScreenState();
}

class _TeacherScanScreenState extends State<TeacherScanScreen> {
  final _authService = AuthService();
  bool _isScanning = false;
  String _scanStatus = 'Click the button to start scanning';
  Color _statusColor = Colors.grey.shade600;

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

        // Simulating API call
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
