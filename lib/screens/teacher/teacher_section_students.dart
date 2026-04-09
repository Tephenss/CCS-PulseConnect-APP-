import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../widgets/custom_loader.dart';

class TeacherSectionStudents extends StatefulWidget {
  final String sectionId;
  final String sectionName;

  const TeacherSectionStudents({
    super.key,
    required this.sectionId,
    required this.sectionName,
  });

  @override
  State<TeacherSectionStudents> createState() => _TeacherSectionStudentsState();
}

class _TeacherSectionStudentsState extends State<TeacherSectionStudents> {
  final _supabase = Supabase.instance.client;
  bool _isLoading = true;
  List<Map<String, dynamic>> _scannedStudents = [];

  @override
  void initState() {
    super.initState();
    _fetchScannedStudents();
  }

  Future<void> _fetchScannedStudents() async {
    try {
      // Query students in this section, fetching their events, tickets, and attendance in one go
      final response = await _supabase
          .from('users')
          .select('''
            id, first_name, last_name, email,
            event_registrations (
              events ( title ),
              tickets (
                attendance ( check_in_at )
              )
            )
          ''')
          .eq('section_id', widget.sectionId)
          .eq('role', 'student');

      final List<Map<String, dynamic>> scannedList = [];

      for (var u in response) {
        bool hasScan = false;
        String latestEvent = '';
        DateTime? latestScan;

        final regs = u['event_registrations'] as List<dynamic>? ?? [];
        for (var reg in regs) {
          final tickets = reg['tickets'] as List<dynamic>? ?? [];
          final eventMap = reg['events'] as Map<String, dynamic>?;
          final eventTitle = eventMap?['title']?.toString() ?? 'Event';

          for (var t in tickets) {
            final atts = t['attendance'] as List<dynamic>? ?? [];
            for (var a in atts) {
              if (a['check_in_at'] != null) {
                hasScan = true;
                final checkIn = DateTime.parse(a['check_in_at'].toString());
                if (latestScan == null || checkIn.isAfter(latestScan)) {
                  latestScan = checkIn;
                  latestEvent = eventTitle;
                }
              }
            }
          }
        }

        // Only include those who have been scanned
        if (hasScan) {
          scannedList.add({
            'id': u['id'],
            'name': '${u['first_name']} ${u['last_name']}',
            'email': u['email'],
            'latest_event': latestEvent,
            'check_in_at': latestScan,
          });
        }
      }

      // Sort by latest scan descending
      scannedList.sort((a, b) {
        final aDate = a['check_in_at'] as DateTime;
        final bDate = b['check_in_at'] as DateTime;
        return bDate.compareTo(aDate);
      });

      if (mounted) {
        setState(() {
          _scannedStudents = scannedList;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load students: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: Text(widget.sectionName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Colors.white)),
        backgroundColor: const Color(0xFF064E3B),
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: const Color(0xFF064E3B),
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 4)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Scanned Students',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  'Showing students in ${widget.sectionName} who have been scanned.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 14),
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: PulseConnectLoader())
                : _scannedStudents.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.qr_code_scanner_rounded, size: 64, color: Colors.grey.shade300),
                            const SizedBox(height: 16),
                            const Text(
                              'No one scanned yet',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1F2937)),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Students from this section will appear here\nafter using the scanner.',
                              style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(24),
                        itemCount: _scannedStudents.length,
                        itemBuilder: (context, index) {
                          final student = _scannedStudents[index];
                          final checkInStr = DateFormat('MMM dd, yyyy - hh:mm a').format(student['check_in_at']);

                          return Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.grey.shade200),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.04),
                                  blurRadius: 10, offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF064E3B).withValues(alpha: 0.1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Center(
                                    child: Text(
                                      student['name'][0].toUpperCase(),
                                      style: const TextStyle(
                                        color: Color(0xFF064E3B),
                                        fontWeight: FontWeight.w800,
                                        fontSize: 20,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        student['name'],
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 16,
                                          color: Color(0xFF1F2937),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        student['latest_event'],
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12,
                                          color: Color(0xFFD4A843),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Icon(Icons.check_circle_rounded, size: 12, color: Colors.green.shade600),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Scanned: $checkInStr',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Colors.grey.shade600,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
