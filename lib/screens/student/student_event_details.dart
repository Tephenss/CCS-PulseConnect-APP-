import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';
import 'student_ticket_view.dart';
import '../../utils/event_time_utils.dart';
import '../../utils/course_theme_utils.dart';

class StudentEventDetails extends StatefulWidget {
  final String eventId;
  final Map<String, dynamic>? initialEvent;

  const StudentEventDetails({
    super.key,
    required this.eventId,
    this.initialEvent,
  });

  @override
  State<StudentEventDetails> createState() => _StudentEventDetailsState();
}

class _StudentEventDetailsState extends State<StudentEventDetails> {
  final _eventService = EventService();
  Map<String, dynamic>? _event;
  bool _isLoading = true;
  bool _isRegistered = false;
  bool _isRegistrationResolved = false;
  bool _isRegistering = false;
  int _participantCount = 0;
  List<Map<String, dynamic>> _eventSessions = [];

  Color _studentPrimary(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
  Color _studentDark(BuildContext context) =>
      CourseThemeUtils.studentDarkFromPrimary(_studentPrimary(context));

  @override
  void initState() {
    super.initState();
    if (widget.initialEvent != null) {
      _event = Map<String, dynamic>.from(widget.initialEvent!);
      _isLoading = false;
      _isRegistrationResolved = false;
    }
    _loadEvent();
  }

  Future<void> _loadEvent() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    final results = await Future.wait([
      _eventService.getEventById(widget.eventId),
      _eventService.isRegistered(widget.eventId, userId),
      _eventService.getParticipantCount(widget.eventId),
      _eventService.getEventSessions(widget.eventId),
    ]);

    final event = results[0] as Map<String, dynamic>?;
    var isReg = results[1] as bool;
    final count = results[2] as int;
    final sessions = results[3] as List<Map<String, dynamic>>;

    if (!isReg) {
      // Fallback: if registration row check misses, verify by ticket existence.
      final ticket = await _eventService.getTicketForEvent(widget.eventId, userId);
      if (ticket.isNotEmpty) {
        isReg = true;
      }
    }

    if (mounted) {
      setState(() {
        _event = event ?? _event;
        _isRegistered = isReg;
        _participantCount = count;
        _eventSessions = sessions;
        _isRegistrationResolved = true;
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
            backgroundColor: _studentPrimary(context),
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

      final myTicket = await _eventService
          .getTicketForEvent(widget.eventId, userId)
          .timeout(const Duration(seconds: 10));

      if (myTicket.isNotEmpty && mounted) {
        setState(() => _isRegistering = false);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StudentTicketView(ticket: myTicket),
          ),
        );
      } else {
        if (mounted) {
          setState(() => _isRegistering = false);
        }
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
          backgroundColor: _studentPrimary(context),
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
    final eventFor = (_event!['event_for'] as String?)?.trim() ?? 'all';
    final eventSpan = _event!['event_span'] as String? ?? '';
    final graceTime = _event!['grace_time']?.toString() ?? '';

    final startDate = parseStoredEventDateTime(startAt);
    final endDate = parseStoredEventDateTime(endAt);

    bool isRegistrationOpen = _event!['status'] == 'published';
    final usesSessions = usesEventSessions(_event!) || _eventSessions.isNotEmpty;
    final canTapAction =
        _isRegistrationResolved &&
        !_isRegistering &&
        !(!isRegistrationOpen && !_isRegistered);

    return Scaffold(
      backgroundColor: Colors.white,
      body: CustomScrollView(
        slivers: [
          // App Bar — Dark Maroon
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: _studentDark(context),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_studentDark(context), _studentPrimary(context)],
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

                  _buildTopStatsGrid(
                    isRegistrationOpen: isRegistrationOpen,
                    eventSpan: eventSpan,
                  ),

                  const SizedBox(height: 28),

                  // Event Schedule & Info (aligned with website layout)
                  const Text(
                    'Event Schedule & Info',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F2937),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildScheduleInfoGrid(
                    startDate: startDate,
                    endDate: endDate,
                    location: location,
                    eventType: eventType,
                    eventFor: eventFor,
                    graceTime: graceTime,
                  ),
                  if (usesSessions) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Seminar Sessions',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1F2937),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildSessionScheduleSection(),
                  ],

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
                    : [_studentDark(context), _studentPrimary(context)],
              ),
              boxShadow: [
                BoxShadow(
                  color: (_isRegistered
                          ? const Color(0xFFD4A843)
                              : _studentPrimary(context))
                      .withValues(alpha: 0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ElevatedButton(
              onPressed: canTapAction
                  ? (_isRegistered ? _handleViewTicket : _handleRegister)
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: (_isRegistering || !_isRegistrationResolved)
                  ? const PulseConnectLoader(
                      size: 14,
                      color: Colors.white,
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

  Widget _buildTopStatsGrid({
    required bool isRegistrationOpen,
    required String eventSpan,
  }) {
    final screenWidth = MediaQuery.of(context).size.width;
    final availableWidth = screenWidth - 48;
    final hasSpan = eventSpan.isNotEmpty;
    final spacing = 8.0;
    final itemWidth = hasSpan
        ? ((availableWidth - (spacing * 2)) / 3)
        : ((availableWidth - spacing) / 2);

    final items = <Widget>[
      _buildInfoChip(
        Icons.people_rounded,
        '$_participantCount',
        'Participants',
        itemWidth,
      ),
      _buildInfoChip(
        isRegistrationOpen ? Icons.check_circle_rounded : Icons.info_outline_rounded,
        _isRegistered ? 'Registered' : (isRegistrationOpen ? 'Open' : 'Closed'),
        'Status',
        itemWidth,
      ),
    ];

    if (hasSpan) {
      items.add(
        _buildInfoChip(
          Icons.date_range_rounded,
          eventSpan == 'multi-day' || eventSpan == 'multi_day'
              ? 'Multi-Day'
              : 'Single',
          'Span',
          itemWidth,
        ),
      );
    }

    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: items,
    );
  }

  Widget _buildInfoChip(
    IconData icon,
    String value,
    String label,
    double width,
  ) {
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF1F2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFECDD3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: _studentPrimary(context), size: 22),
            const SizedBox(height: 6),
            Text(
              value,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: _studentPrimary(context),
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

  Widget _buildSessionScheduleSection() {
    if (_eventSessions.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Text(
          'No seminar schedule found for this event yet.',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade700,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Column(
      children: _eventSessions.asMap().entries.map((entry) {
        final index = entry.key;
        final session = entry.value;
        final sessionStart = parseStoredEventDateTime(session['start_at']);
        final sessionEnd = parseStoredEventDateTime(session['end_at']);
        final rawTitle = (session['title']?.toString() ?? '').trim();
        final sessionTitle = rawTitle.isNotEmpty
            ? rawTitle
            : buildSessionDisplayName(session);

        return Container(
          width: double.infinity,
          margin: EdgeInsets.only(bottom: index == _eventSessions.length - 1 ? 0 : 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Seminar ${index + 1}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF6B7280),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                sessionTitle,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827),
                ),
              ),
              const SizedBox(height: 12),
              Column(
                children: [
                  _buildSessionMetaRow(
                    icon: Icons.calendar_today_rounded,
                    label: 'Date',
                    value: formatDateRange(sessionStart, sessionEnd),
                  ),
                  const SizedBox(height: 8),
                  _buildSessionMetaRow(
                    icon: Icons.schedule_rounded,
                    label: 'Time',
                    value: formatTimeRange(sessionStart, sessionEnd),
                  ),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildScheduleInfoGrid({
    required DateTime? startDate,
    required DateTime? endDate,
    required String location,
    required String eventType,
    required String eventFor,
    required String graceTime,
  }) {
    final cards = <Widget>[
      _buildScheduleInfoCard(
        icon: Icons.calendar_month_rounded,
        title: 'Start Date & Time',
        value: startDate != null
            ? DateFormat('MMM d, yyyy, h:mm a').format(startDate)
            : 'TBA',
      ),
      _buildScheduleInfoCard(
        icon: Icons.event_available_rounded,
        title: 'End Date & Time',
        value: endDate != null
            ? DateFormat('MMM d, yyyy, h:mm a').format(endDate)
            : 'TBA',
      ),
      _buildScheduleInfoCard(
        icon: Icons.location_on_rounded,
        title: 'Location / Venue',
        value: location,
      ),
      _buildScheduleInfoCard(
        icon: _getEventTypeIcon(eventType),
        title: 'Event Type',
        value: eventType.isNotEmpty ? eventType : 'General Event',
      ),
      _buildScheduleInfoCard(
        icon: Icons.groups_rounded,
        title: 'Target Participants',
        value: _targetParticipantsLabel(eventFor),
        fullWidth: true,
      ),
    ];

    if (graceTime.isNotEmpty) {
      cards.add(
        _buildScheduleInfoCard(
          icon: Icons.timer_rounded,
          title: 'Grace Time',
          value: '$graceTime min',
        ),
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: cards,
    );
  }

  Widget _buildScheduleInfoCard({
    required IconData icon,
    required String title,
    required String value,
    bool fullWidth = false,
  }) {
    final screenWidth = MediaQuery.of(context).size.width;
    final horizontalPadding = 24.0;
    final wrapSpacing = 12.0;
    final availableWidth = screenWidth - (horizontalPadding * 2);
    final useTwoColumns = availableWidth >= 380;
    final cardWidth = (fullWidth || !useTwoColumns)
        ? availableWidth
        : ((availableWidth - wrapSpacing) / 2);

    return Container(
      width: cardWidth,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFFFFF1F2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: _studentPrimary(context), size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionMetaRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: const Color(0xFF6B7280)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F2937),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _targetParticipantsLabel(String value) {
    final normalized = value.toLowerCase();
    if (normalized.isEmpty || normalized == 'all') return 'All Year Levels';
    if (normalized == 'none') return 'No Target';
    switch (normalized) {
      case '1':
        return '1st Year Students';
      case '2':
        return '2nd Year Students';
      case '3':
        return '3rd Year Students';
      case '4':
        return '4th Year Students';
      default:
        return value;
    }
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
