import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';
import 'student_event_evaluation.dart';

class StudentCertificates extends StatefulWidget {
  const StudentCertificates({super.key});

  @override
  State<StudentCertificates> createState() => _StudentCertificatesState();
}

class _StudentCertificatesState extends State<StudentCertificates> {
  final _eventService = EventService();
  List<Map<String, dynamic>> _certificates = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCertificates();
  }

  Future<void> _loadCertificates() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    final certs = await _eventService.getMyCertificates(userId);
    if (mounted) {
      setState(() {
        _certificates = certs;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: const Color(0xFF7F1D1D),
        title: const Text(
          'Certificates',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, color: Colors.white),
        ),
      ),
      body: _isLoading
          ? const Center(child: PulseConnectLoader())
          : _certificates.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _loadCertificates,
                  color: const Color(0xFF7F1D1D),
                  child: GridView.builder(
                    padding: const EdgeInsets.all(20),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: 0.75,
                    ),
                    itemCount: _certificates.length,
                    itemBuilder: (context, index) {
                      return _buildCertificateCard(_certificates[index]);
                    },
                  ),
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.workspace_premium_outlined,
              size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            'No certificates yet',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Complete events to earn certificates!',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildCertificateCard(Map<String, dynamic> cert) {
    final event = cert['events'] as Map<String, dynamic>? ?? {};
    final title = event['title'] as String? ?? 'Event';
    final startAt = event['start_at'] as String?;

    DateTime? startDate;
    if (startAt != null) {
      try { startDate = DateTime.parse(startAt); } catch (_) {}
    }

    return GestureDetector(
      onTap: () => _showCertificatePreview(cert),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFFF9FAFB),
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(15),
                  ),
                ),
                child: Center(
                  child: Icon(
                    Icons.workspace_premium_rounded,
                    size: 48,
                    color: const Color(0xFFD4A843), // Gold
                  ),
                ),
              ),
            ),
            // Info
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: Color(0xFF1F2937),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    startDate != null
                        ? DateFormat('MMM dd, yyyy').format(startDate)
                        : '--',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade500,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCertificatePreview(Map<String, dynamic> cert) async {
    final event = cert['events'] as Map<String, dynamic>? ?? {};
    final eventId = cert['event_id']?.toString() ?? '';
    final title = event['title'] as String? ?? 'Event';

    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: PulseConnectLoader())
    );

    final prefs = await SharedPreferences.getInstance();
    final studentId = prefs.getString('user_id') ?? '';

    // Check evaluation status
    final isEvalDone = await _eventService.isEvaluationSubmitted(eventId, studentId);
    if (!mounted) return;
    Navigator.pop(context); // Close loading dialog

    if (!isEvalDone) {
      // Must evaluate first
      final success = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => StudentEventEvaluationScreen(eventId: eventId, studentId: studentId),
        ),
      );

      // If they skipped or submitted, success will be true
      if (success != true) {
        return; // Did not finish evaluation
      }
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Color(0xFF1F2937),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: Colors.grey.shade500),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              
              // Certificate Preview
              Container(
                height: 300,
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF9FAFB),
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'CERTIFICATE OF PARTICIPATION',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.5,
                            color: Color(0xFFD4A843),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'PROUDLY PRESENTED TO',
                          style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Student Name',
                          style: TextStyle(
                            fontFamily: 'serif',
                            fontSize: 24,
                            fontStyle: FontStyle.italic,
                            color: Color(0xFF1F2937),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            'For successful completion and participation in\n$title',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 10, height: 1.5, color: Colors.grey.shade600),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Download Button
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF450A0A), Color(0xFF7F1D1D)],
                      ),
                    ),
                    child: ElevatedButton.icon(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Download feature coming soon')),
                        );
                      },
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('DOWNLOAD PDF'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
