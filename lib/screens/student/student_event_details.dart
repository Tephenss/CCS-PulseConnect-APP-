import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';
import 'student_event_evaluation.dart';
import 'student_response_view.dart';
import 'student_ticket_view.dart';

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
  bool _hasEvaluated = false;
  String _userId = '';

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
    final evalDone = isReg ? await _eventService.isEvaluationSubmitted(widget.eventId, userId) : false;

    if (mounted) {
      setState(() {
        _event = event;
        _isRegistered = isReg;
        _participantCount = count;
        _hasEvaluated = evalDone;
        _userId = userId;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleRegister() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';

    setState(() => _isRegistering = true);

    final result = await _eventService.registerForEvent(widget.eventId, userId);

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
            backgroundColor: Color(0xFF15803D),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['error'] as String? ?? 'Registration failed'),
            backgroundColor: const Color(0xFF7F1D1D),
          ),
        );
      }
    }
  }

  Future<void> _handleViewTicket() async {
    setState(() => _isRegistering = true); // reuse loading state

    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? '';
      
      // Fetch tickets with a 10-second timeout to prevent infinite loading if network hangs
      final tickets = await _eventService.getMyTickets(userId).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      setState(() => _isRegistering = false);

      final myTicket = tickets.firstWhere(
        (t) => t['event_id']?.toString() == widget.eventId.toString(),
        orElse: () => <String, dynamic>{},
      );

      if (myTicket.isNotEmpty && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StudentTicketView(ticket: myTicket),
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not load ticket details. Please check your network connection.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isRegistering = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection timeout or error. Please try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: PulseConnectLoader(),
        ),
      );
    }

    if (_event == null) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: const Color(0xFF7F1D1D),
          title: const Text('Event Details', style: TextStyle(color: Colors.white)),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(child: Text('Event not found', style: TextStyle(color: Colors.grey.shade600))),
      );
    }

    final title = _event!['title'] as String? ?? 'Untitled';
    final description = _event!['description'] as String? ?? '';
    final location = _event!['location'] as String? ?? 'TBA';
    final startAt = _event!['start_at'] as String?;
    final endAt = _event!['end_at'] as String?;
    final eventType = _event!['event_type'] as String? ?? '';
    final eventFor = _event!['event_for'] as String? ?? '';
    final eventSpan = _event!['event_span'] as String? ?? '';
    final graceTime = _event!['grace_time'] as String? ?? '';

    DateTime? startDate, endDate;
    if (startAt != null) {
      try { startDate = DateTime.parse(startAt).toLocal(); } catch (_) {}
    }
    if (endAt != null) {
      try { endDate = DateTime.parse(endAt).toLocal(); } catch (_) {}
    }

    bool isMultiDay = false;
    if (startDate != null && endDate != null) {
      isMultiDay = startDate.day != endDate.day ||
          startDate.month != endDate.month ||
          startDate.year != endDate.year;
    }

    bool isRegistrationOpen = _event!['status'] == 'published';

    return Scaffold(
      backgroundColor: Colors.white,
      body: CustomScrollView(
        slivers: [
          // App Bar — Dark Maroon
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: const Color(0xFF450A0A),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF450A0A), Color(0xFF7F1D1D)],
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
                          color: Colors.white.withValues(alpha: 0.1),
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
                child: const Icon(Icons.arrow_back_ios_rounded, size: 18, color: Colors.white),
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
                  // Event Type Badge
                  if (eventType.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: _getEventTypeColor(eventType).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_getEventTypeIcon(eventType), size: 16, color: _getEventTypeColor(eventType)),
                          const SizedBox(width: 6),
                          Text(eventType, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _getEventTypeColor(eventType))),
                        ],
                      ),
                    ),

                  // Info Cards Row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInfoChip(
                        Icons.people_rounded,
                        '$_participantCount',
                        'Participants',
                      ),
                      const SizedBox(width: 8),
                      _buildInfoChip(
                        isRegistrationOpen ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                        _isRegistered ? 'Registered' : (isRegistrationOpen ? 'Open' : 'Closed'),
                        'Status',
                      ),
                      if (eventSpan.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        _buildInfoChip(
                          Icons.date_range_rounded,
                          eventSpan == 'multi-day' ? 'Multi-Day' : 'Single',
                          'Span',
                        ),
                      ],
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

                  _buildDetailRow(
                    Icons.calendar_today_rounded,
                    'Date',
                    startDate != null
                        ? isMultiDay && endDate != null
                            ? '${DateFormat('MMMM dd, yyyy').format(startDate)} - ${DateFormat('MMMM dd, yyyy').format(endDate)}'
                            : DateFormat('MMMM dd, yyyy').format(startDate)
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
                  if (eventFor.isNotEmpty)
                    _buildDetailRow(
                      Icons.school_rounded,
                      'Event For',
                      eventFor,
                    ),
                  if (graceTime.isNotEmpty)
                    _buildDetailRow(
                      Icons.timer_rounded,
                      'Grace Time',
                      '$graceTime min',
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

                  // ── Evaluation Section ──
                  if (_isRegistered) ...[
                    const SizedBox(height: 12),
                    if (_hasEvaluated)
                      GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => StudentResponseView(
                                eventId: widget.eventId,
                                studentId: _userId,
                              ),
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFECFDF5),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFF064E3B).withValues(alpha: 0.2)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.fact_check_rounded, color: Color(0xFF064E3B), size: 22),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Evaluation Submitted', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF064E3B))),
                                    Text('Tap to view your feedback', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right, color: Color(0xFF064E3B)),
                            ],
                          ),
                        ),
                      )
                    else
                      GestureDetector(
                        onTap: () async {
                          final success = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => StudentEventEvaluationScreen(
                                eventId: widget.eventId,
                                studentId: _userId,
                              ),
                            ),
                          );
                          if (success == true && mounted) {
                            setState(() => _hasEvaluated = true);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF7ED),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFD4A843).withValues(alpha: 0.3)),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.rate_review_rounded, color: Color(0xFFD4A843), size: 22),
                              SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Submit Evaluation', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF92400E))),
                                    Text('Rate this event to get your certificate', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right, color: Color(0xFFD4A843)),
                            ],
                          ),
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

      // Bottom Register/Ticket Button
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SizedBox(
          width: double.infinity,
          height: 60, // Prevents the loader's Center from expanding to fill the screen
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: _isRegistered
                    ? [const Color(0xFFD4A843), const Color(0xFFB8942F)]
                    : [const Color(0xFF450A0A), const Color(0xFF7F1D1D)],
              ),
              boxShadow: [
                BoxShadow(
                  color: (_isRegistered
                          ? const Color(0xFFD4A843)
                          : const Color(0xFF7F1D1D))
                      .withValues(alpha: 0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ElevatedButton(
              onPressed: _isRegistering || (!isRegistrationOpen && !_isRegistered)
                  ? null 
                  : (_isRegistered ? _handleViewTicket : _handleRegister),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _isRegistering
                  ? const PulseConnectLoader(size: 14)
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
                          _isRegistered 
                            ? 'See Ticket' 
                            : (isRegistrationOpen ? 'Register' : 'Registration Closed'),
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
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF1F2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFECDD3)), // Rose 200 border
        ),
        child: Column(
          children: [
            Icon(icon, color: const Color(0xFF7F1D1D), size: 22),
            const SizedBox(height: 6),
            Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: Color(0xFF7F1D1D),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey.shade600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
              color: const Color(0xFFFFF1F2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFF7F1D1D), size: 20),
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
                    color: Colors.grey.shade600,
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

  Color _getEventTypeColor(String type) {
    switch (type.toLowerCase()) {
      case 'seminar': return const Color(0xFF1D4ED8);
      case 'off-campus activity': return const Color(0xFF059669);
      case 'sports event': return const Color(0xFFD97706);
      case 'other': return const Color(0xFF7C3AED);
      default: return const Color(0xFF6B7280);
    }
  }

  IconData _getEventTypeIcon(String type) {
    switch (type.toLowerCase()) {
      case 'seminar': return Icons.school_rounded;
      case 'off-campus activity': return Icons.directions_bus_rounded;
      case 'sports event': return Icons.sports_basketball_rounded;
      case 'other': return Icons.category_rounded;
      default: return Icons.event_rounded;
    }
  }
}
