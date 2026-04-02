import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/event_service.dart';

class StudentEventDetails extends StatefulWidget {
  final String eventId;
  const StudentEventDetails({super.key, required this.eventId});

  @override
  State<StudentEventDetails> createState() => _StudentEventDetailsState();
}

class _StudentEventDetailsState extends State<StudentEventDetails> {
  final _eventService = EventService();
  Map<String, dynamic>? _event;
  bool _isLoading = true;
  bool _isRegistered = false;
  bool _isRegistering = false;
  int _participantCount = 0;

  @override
  void initState() {
    super.initState();
    _loadEvent();
  }

  Future<void> _loadEvent() async {
    final event = await _eventService.getEventById(widget.eventId);
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    final isReg = await _eventService.isRegistered(widget.eventId, userId);
    final count = await _eventService.getParticipantCount(widget.eventId);

    if (mounted) {
      setState(() {
        _event = event;
        _isRegistered = isReg;
        _participantCount = count;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleRegister() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';

    setState(() => _isRegistering = true);

    final result =
        await _eventService.registerForEvent(widget.eventId, userId);

    setState(() => _isRegistering = false);

    if (result['ok'] == true) {
      setState(() {
        _isRegistered = true;
        _participantCount++;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Successfully registered! Check your tickets.'),
            backgroundColor: Color(0xFF064E3B),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['error'] as String? ?? 'Registration failed'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF064E3B)),
        ),
      );
    }

    if (_event == null) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF064E3B),
          title: const Text('Event Details'),
        ),
        body: const Center(child: Text('Event not found')),
      );
    }

    final title = _event!['title'] as String? ?? 'Untitled';
    final description = _event!['description'] as String? ?? '';
    final location = _event!['location'] as String? ?? 'TBA';
    final startAt = _event!['start_at'] as String?;
    final endAt = _event!['end_at'] as String?;

    DateTime? startDate, endDate;
    if (startAt != null) {
      try {
        startDate = DateTime.parse(startAt);
      } catch (_) {}
    }
    if (endAt != null) {
      try {
        endDate = DateTime.parse(endAt);
      } catch (_) {}
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: CustomScrollView(
        slivers: [
          // App Bar with gradient
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: const Color(0xFF064E3B),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFF064E3B),
                      Color(0xFF047857),
                    ],
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 40),
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.15),
                          border: Border.all(
                            color: const Color(0xFFD4A843).withValues(alpha: 0.5),
                            width: 2,
                          ),
                        ),
                        child: const Icon(Icons.event_rounded,
                            color: Color(0xFFD4A843), size: 32),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 20,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            leading: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.arrow_back_ios_rounded, size: 18),
              ),
              onPressed: () => Navigator.pop(context),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Info Cards Row (Page 48)
                  Row(
                    children: [
                      _buildInfoChip(
                        Icons.people_rounded,
                        '$_participantCount',
                        'Participants',
                      ),
                      const SizedBox(width: 12),
                      _buildInfoChip(
                        Icons.check_circle_rounded,
                        _isRegistered ? 'Registered' : 'Open',
                        'Status',
                      ),
                    ],
                  ),

                  const SizedBox(height: 28),

                  // Event Details Section
                  const Text(
                    'Event Details',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F2937),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Date & Time
                  _buildDetailRow(
                    Icons.calendar_today_rounded,
                    'Date',
                    startDate != null
                        ? DateFormat('MMMM dd, yyyy').format(startDate)
                        : 'TBA',
                  ),
                  _buildDetailRow(
                    Icons.schedule_rounded,
                    'Time',
                    startDate != null
                        ? '${DateFormat('hh:mm a').format(startDate)}${endDate != null ? ' - ${DateFormat('hh:mm a').format(endDate)}' : ''}'
                        : 'TBA',
                  ),
                  _buildDetailRow(
                    Icons.location_on_rounded,
                    'Location',
                    location,
                  ),

                  const SizedBox(height: 28),

                  // Description
                  if (description.isNotEmpty) ...[
                    const Text(
                      'Event Description',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1F2937),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade700,
                        height: 1.6,
                      ),
                    ),
                  ],

                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),

      // Bottom Register/Ticket Button (Page 48)
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _isRegistered
                ? () {
                    // Navigate to tickets
                    Navigator.pop(context);
                  }
                : (_isRegistering ? null : _handleRegister),
            style: ElevatedButton.styleFrom(
              backgroundColor: _isRegistered
                  ? const Color(0xFFD4A843)
                  : const Color(0xFF064E3B),
              foregroundColor:
                  _isRegistered ? const Color(0xFF064E3B) : Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 2,
            ),
            child: _isRegistering
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isRegistered
                            ? Icons.confirmation_num_rounded
                            : Icons.how_to_reg_rounded,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _isRegistered ? 'See Ticket' : 'Register',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF0FDF4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFBBF7D0)),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF064E3B), size: 22),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: Color(0xFF064E3B),
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF064E3B).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFF064E3B), size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade500,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1F2937),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
