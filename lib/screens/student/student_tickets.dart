import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';
import 'student_ticket_view.dart';
import '../../utils/event_time_utils.dart';
import '../../utils/course_theme_utils.dart';

class StudentTickets extends StatefulWidget {
  const StudentTickets({super.key});

  @override
  State<StudentTickets> createState() => _StudentTicketsState();
}

class _StudentTicketsState extends State<StudentTickets> {
  final _eventService = EventService();
  static const String _downloadedTicketKeyPrefix = 'downloaded_tickets_';
  List<Map<String, dynamic>> _tickets = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTickets();
  }

  Future<void> _loadTickets() async {
    if (mounted) {
      setState(() => _isLoading = true);
    }

    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    final allTickets = userId.isEmpty
        ? <Map<String, dynamic>>[]
        : await _eventService.getMyTickets(userId);

    // Keep online list behavior: show active events only.
    // Also require an actual ticket id from Supabase; registration rows without
    // a ticket should not appear here (prevents "ghost" tickets).
    final activeOnlineTickets = allTickets
        .where((t) => _isTicketActive(t) && _hasTicketId(t))
        .map((ticket) {
      final normalized = Map<String, dynamic>.from(ticket);
      normalized['local_cached'] = false;
      return normalized;
    }).toList();

    // Downloaded tickets are kept in app storage and shown even offline.
    final offlineTickets = _readOfflineTickets(prefs, userId);
    final mergedTickets = _mergeTickets(activeOnlineTickets, offlineTickets);

    if (mounted) {
      setState(() {
        _tickets = mergedTickets;
        _isLoading = false;
      });
    }
  }

  bool _isTicketActive(Map<String, dynamic> ticket) {
    final now = DateTime.now().toUtc().add(kManilaOffset);
    final event = ticket['events'] as Map<String, dynamic>? ?? {};

    final status = event['status'] as String? ?? '';
    if (status != 'published') return false;

    final endAt = event['end_at'] as String?;
    if (endAt != null && endAt.isNotEmpty) {
      final endDate = parseStoredEventDateTime(endAt);
      if (endDate != null) {
        return endDate.isAfter(now) || endDate.isAtSameMomentAs(now);
      }
    }
    return true;
  }

  bool _hasTicketId(Map<String, dynamic> ticketMap) {
    final ticketData = ticketMap['tickets'];
    final ticketId = ticketData is List && ticketData.isNotEmpty
        ? (ticketData[0]['id'] ?? '').toString()
        : ticketData is Map
            ? (ticketData['id'] ?? '').toString()
            : '';
    return ticketId.trim().isNotEmpty;
  }

  String _ticketUniqueKey(Map<String, dynamic> ticketMap) {
    final ticketData = ticketMap['tickets'];
    final ticketId = ticketData is List && ticketData.isNotEmpty
        ? (ticketData[0]['id'] ?? '').toString()
        : ticketData is Map
            ? (ticketData['id'] ?? '').toString()
            : '';
    if (ticketId.isNotEmpty) return 'ticket:$ticketId';

    final event = ticketMap['events'];
    final eventId = event is Map ? (event['id'] ?? '').toString() : '';
    if (eventId.isNotEmpty) return 'event:$eventId';

    final registeredAt = (ticketMap['registered_at'] ?? '').toString();
    if (registeredAt.isNotEmpty) return 'registered:$registeredAt';
    return '';
  }

  DateTime _extractSortDate(Map<String, dynamic> ticketMap) {
    try {
      final registeredAt = (ticketMap['registered_at'] ?? '').toString();
      if (registeredAt.isNotEmpty) return DateTime.parse(registeredAt);
    } catch (_) {}

    try {
      final downloadedAt = (ticketMap['downloaded_at_local'] ?? '').toString();
      if (downloadedAt.isNotEmpty) return DateTime.parse(downloadedAt);
    } catch (_) {}

    final event = ticketMap['events'];
    final startAt = event is Map ? (event['start_at'] ?? '').toString() : '';
    final eventDate = parseStoredEventDateTime(startAt);
    if (eventDate != null) return eventDate;

    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  List<Map<String, dynamic>> _readOfflineTickets(
    SharedPreferences prefs,
    String userId,
  ) {
    if (userId.isEmpty) return <Map<String, dynamic>>[];

    final rows = prefs.getStringList('$_downloadedTicketKeyPrefix$userId') ?? <String>[];
    final parsed = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        final decoded = jsonDecode(row);
        if (decoded is! Map) continue;
        final ticket = Map<String, dynamic>.from(decoded);
        // Only treat tickets as offline-saved when user explicitly tapped
        // the Download Ticket button. This prevents legacy/accidental cache
        // entries from making the download feature pointless.
        if (ticket['downloaded_explicit'] != true) continue;
        ticket['local_cached'] = true;
        parsed.add(ticket);
      } catch (_) {
        // Skip malformed cached tickets safely.
      }
    }
    return parsed;
  }

  List<Map<String, dynamic>> _mergeTickets(
    List<Map<String, dynamic>> online,
    List<Map<String, dynamic>> offline,
  ) {
    final merged = <String, Map<String, dynamic>>{};
    int fallback = 0;

    for (final ticket in offline) {
      final normalized = Map<String, dynamic>.from(ticket);
      final key = _ticketUniqueKey(normalized).isNotEmpty
          ? _ticketUniqueKey(normalized)
          : 'offline_${fallback++}';
      normalized['local_cached'] = true;
      merged[key] = normalized;
    }

    for (final ticket in online) {
      final normalized = Map<String, dynamic>.from(ticket);
      final key = _ticketUniqueKey(normalized).isNotEmpty
          ? _ticketUniqueKey(normalized)
          : 'online_${fallback++}';
      final alreadyOffline = merged.containsKey(key);
      normalized['local_cached'] = alreadyOffline || normalized['local_cached'] == true;
      merged[key] = normalized;
    }

    final list = merged.values.toList();
    list.sort((a, b) => _extractSortDate(b).compareTo(_extractSortDate(a)));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final chromeColor = CourseThemeUtils.studentChromeFromPrimary(
      Theme.of(context).colorScheme.primary,
    );
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: chromeColor,
        title: const Text(
          'My Tickets',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, color: Colors.white),
        ),
      ),
      body: _isLoading
          ? const Center(child: PulseConnectLoader())
          : _tickets.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _loadTickets,
                  color: chromeColor,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    itemCount: _tickets.length,
                    itemBuilder: (context, index) {
                      return _buildTicketCard(_tickets[index]);
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
          Icon(Icons.confirmation_num_outlined,
              size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            'No tickets yet',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Register for events to get tickets!',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildTicketCard(Map<String, dynamic> ticket) {
    final event = ticket['events'] as Map<String, dynamic>? ?? {};
    final title = event['title'] as String? ?? 'Event';
    final startAt = event['start_at'] as String?;
    final endAt = event['end_at'] as String?;
    final location = event['location'] as String? ?? 'No Venue';
    final eventType = event['event_type'] as String? ?? 'Event';
    final isLocalCached = ticket['local_cached'] == true;
    final ticketData = ticket['tickets'];
    final ticketId = ticketData is List && ticketData.isNotEmpty
        ? ticketData[0]['id']?.toString() ?? ''
        : ticketData is Map ? ticketData['id']?.toString() ?? '' : '';

    final startDate = parseStoredEventDateTime(startAt);
    final endDate = parseStoredEventDateTime(endAt);

    final ticketIdDisplay = ticketId.length > 8
        ? ticketId.substring(0, 8).toUpperCase()
        : ticketId.toUpperCase();

    final Color themePrimary = Theme.of(context).colorScheme.primary;
    final List<Color> ticketGradient =
        CourseThemeUtils.studentTicketGradientFromPrimary(themePrimary);
    final Color chromeColor =
        CourseThemeUtils.studentChromeFromPrimary(themePrimary);
    final Color accentColor = Theme.of(context).colorScheme.secondary;

    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StudentTicketView(ticket: ticket),
          ),
        );
        _loadTickets();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 20),
        height: 188,
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: chromeColor.withOpacity(0.35),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipPath(
          clipper: TicketClipper(),
          child: Stack(
            children: [
              // Shiny Glossy Background
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: ticketGradient,
                    stops: const [0.0, 0.4, 0.6, 1.0],
                  ),
                ),
              ),

              // Diagonal Shine Overlay
              Positioned.fill(
                child: Opacity(
                  opacity: 0.1,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment(-1.0, -1.0),
                        end: Alignment(1.0, 1.0),
                        colors: [
                          Colors.transparent,
                          Colors.white,
                          Colors.transparent,
                        ],
                        stops: [0.45, 0.5, 0.55],
                      ),
                    ),
                  ),
                ),
              ),

              // Content Row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 0),
                child: Row(
                  children: [
                    // Left Side: Event Info
                    Expanded(
                      flex: 65,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 20,
                                letterSpacing: -0.5,
                                shadows: [
                                  Shadow(color: Colors.black26, offset: Offset(0, 2), blurRadius: 4),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    eventType.toUpperCase(),
                                    style: TextStyle(
                                      color: accentColor,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 12,
                                      letterSpacing: 1.2,
                                      shadows: [
                                        Shadow(color: accentColor.withOpacity(0.3), offset: const Offset(0, 1), blurRadius: 2),
                                      ],
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (isLocalCached) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.download_done_rounded, size: 11, color: Colors.white),
                                        SizedBox(width: 3),
                                        Text(
                                          'Offline',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.3,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const Spacer(),
                            // Date/Time
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.white.withOpacity(0.1)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.calendar_today_rounded, size: 16, color: Colors.white),
                                  const SizedBox(width: 8),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        startDate != null ? DateFormat('MMM dd, yyyy').format(startDate) : 'TBA',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      if (startDate != null && endDate != null)
                                        Text(
                                          '${DateFormat('hh:mm a').format(startDate)} - ${DateFormat('hh:mm a').format(endDate)}',
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(0.8),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            // Location
                            Row(
                              children: [
                                Icon(Icons.location_on_rounded, size: 16, color: accentColor),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    location,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Vertical Divider
                    _buildDashedDivider(),

                    // Right Side: QR Code
                    Expanded(
                      flex: 35,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 4)),
                                  ],
                                ),
                                child: QrImageView(
                                  data: 'PULSE-$ticketId',
                                  version: QrVersions.auto,
                                  size: 75,
                                  eyeStyle: QrEyeStyle(
                                    eyeShape: QrEyeShape.square,
                                    color: chromeColor,
                                  ),
                                  dataModuleStyle: QrDataModuleStyle(
                                    dataModuleShape: QrDataModuleShape.square,
                                    color: chromeColor,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'TICKET ID',
                                style: TextStyle(
                                  fontSize: 10, 
                                  color: Colors.white.withOpacity(0.7),
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              SizedBox(
                                width: 100,
                                child: Text(
                                  ticketIdDisplay,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.5,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDashedDivider() {
    return Column(
      children: List.generate(
        15,
        (index) => Expanded(
          child: Container(
            width: 1.5,
            margin: const EdgeInsets.symmetric(vertical: 3),
            color: index.isEven ? Colors.white.withOpacity(0.2) : Colors.transparent,
          ),
        ),
      ),
    );
  }

}

class TicketClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    Path path = Path();
    double radius = 16.0;
    double cutoutRadius = 12.0;
    double cutoutPosition = size.width * 0.65; // Position of the vertical divider

    // Main Ticket Path
    path.moveTo(radius, 0);
    
    // Top border and cutout
    path.lineTo(cutoutPosition - cutoutRadius, 0);
    path.arcToPoint(
      Offset(cutoutPosition + cutoutRadius, 0),
      radius: Radius.circular(cutoutRadius),
      clockwise: false,
    );
    path.lineTo(size.width - radius, 0);
    
    // Top-right corner
    path.arcToPoint(Offset(size.width, radius), radius: Radius.circular(radius));
    path.lineTo(size.width, size.height - radius);
    
    // Bottom-right corner
    path.arcToPoint(Offset(size.width - radius, size.height), radius: Radius.circular(radius));
    
    // Bottom border and cutout
    path.lineTo(cutoutPosition + cutoutRadius, size.height);
    path.arcToPoint(
      Offset(cutoutPosition - cutoutRadius, size.height),
      radius: Radius.circular(cutoutRadius),
      clockwise: false,
    );
    path.lineTo(radius, size.height);
    
    // Bottom-left corner
    path.arcToPoint(Offset(0, size.height - radius), radius: Radius.circular(radius));
    path.lineTo(0, radius);
    
    // Top-left corner
    path.arcToPoint(Offset(radius, 0), radius: Radius.circular(radius));
    
    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
}
