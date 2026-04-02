import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

class StudentTicketView extends StatelessWidget {
  final Map<String, dynamic> ticket;

  const StudentTicketView({super.key, required this.ticket});

  @override
  Widget build(BuildContext context) {
    final event = ticket['events'] as Map<String, dynamic>? ?? {};
    final title = event['title'] as String? ?? 'Event';
    final startAt = event['start_at'] as String?;
    final endAt = event['end_at'] as String?;
    final location = event['location'] as String? ?? 'TBA';
    final ticketId = ticket['id']?.toString() ?? '';

    DateTime? startDate;
    if (startAt != null) {
      try {
        startDate = DateTime.parse(startAt);
      } catch (_) {}
    }
    
    String timeString = 'TBA';
    if (startAt != null) {
      final start = DateFormat('hh:mm a').format(DateTime.parse(startAt));
      if (endAt != null) {
        final end = DateFormat('hh:mm a').format(DateTime.parse(endAt));
        timeString = '$start - $end';
      } else {
        timeString = start;
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text('Event Ticket', style: TextStyle(fontWeight: FontWeight.w700)),
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1F2937),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: Center(
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxWidth: 400),
                    decoration: BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 30,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Top Part (Main Ticket Info)
                        Container(
                          padding: const EdgeInsets.all(28),
                          decoration: const BoxDecoration(
                            color: Color(0xFF4A0404), // Dark Maroon
                            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Header (Logo and Type)
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.confirmation_num, color: Color(0xFFD4A843), size: 20),
                                      const SizedBox(width: 8),
                                      const Text(
                                        'PULSECONNECT',
                                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: -0.5),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: const Color(0xFFD4A843), width: 1.5),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Text('EVENT PASS', style: TextStyle(color: Color(0xFFD4A843), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 36),
                              
                              // Title
                              Text(
                                title.toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 26,
                                  height: 1.1,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'CCS Exclusive Event',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              
                              const SizedBox(height: 36),
                              
                              Row(
                                children: [
                                  Expanded(child: _buildTicketField('DATE', startDate != null ? DateFormat('MMM dd, yyyy').format(startDate) : 'TBA')),
                                  Expanded(child: _buildTicketField('TIME', timeString)),
                                ],
                              ),
                              const SizedBox(height: 24),
                              _buildTicketField('VENUE', location),
                            ],
                          ),
                        ),
                        
                        // Perforation Line
                        Container(
                          color: const Color(0xFF4A0404),
                          child: Row(
                            children: [
                              Container(
                                width: 14, height: 28,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFF8F9FA), // match scaffold background
                                  borderRadius: BorderRadius.horizontal(right: Radius.circular(14)),
                                ),
                              ),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      return Flex(
                                        direction: Axis.horizontal,
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: List.generate((constraints.constrainWidth() / 12).floor(), (index) {
                                          return Container(width: 6, height: 2, color: Colors.white.withValues(alpha: 0.15));
                                        }),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              Container(
                                width: 14, height: 28,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFF8F9FA), // match scaffold background
                                  borderRadius: BorderRadius.horizontal(left: Radius.circular(14)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        
                        // Bottom Part (Stub + QR)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(28),
                          decoration: const BoxDecoration(
                            color: Color(0xFF7F1D1D), // Slightly lighter maroon for the bottom stub
                            borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
                          ),
                          child: Column(
                            children: [
                              // QR Code
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                                child: QrImageView(
                                  data: 'PULSE-$ticketId',
                                  version: QrVersions.auto,
                                  size: 140,
                                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF7F1D1D)),
                                  dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF7F1D1D)),
                                ),
                              ),
                              const SizedBox(height: 24),
                              // Ticket ID Placeholder
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Text(
                                    'TICKET ID',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.5),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 1.5,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    ticketId.length > 8 ? ticketId.substring(0, 8).toUpperCase() : ticketId.toUpperCase(),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontFamily: 'monospace',
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 2,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Fixed Download Button at bottom
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Download feature coming soon')),
                      );
                    },
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('DOWNLOAD TICKET', style: TextStyle(fontWeight: FontWeight.w700)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7F1D1D),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTicketField(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
