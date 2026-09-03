import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/event_service.dart';
import '../../services/event_live_service.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/animated_ticket_card.dart';
import '../../widgets/circuit_ticket_icon.dart';
import 'student_ticket_view.dart';
import '../../utils/event_time_utils.dart';
import '../../utils/course_theme_utils.dart';

class StudentTickets extends StatefulWidget {
  const StudentTickets({super.key});

  @override
  State<StudentTickets> createState() => _StudentTicketsState();
}

class _StudentTicketsState extends State<StudentTickets>
    with WidgetsBindingObserver {
  final _eventService = EventService();
  List<Map<String, dynamic>> _tickets = [];
  bool _isLoading = true;
  StreamSubscription<String>? _eventLiveSubscription;

  bool _isTicketsLiveReason(String reason) {
    final offlinePulse = reason.startsWith('offline:');
    final core = offlinePulse ? reason.substring('offline:'.length) : reason;
    return core == 'tickets' ||
        core.startsWith('tickets') ||
        core == 'registrations' ||
        core.startsWith('registrations') ||
        core == 'events' ||
        core.startsWith('events') ||
        core == 'sessions' ||
        core.startsWith('sessions') ||
        core.startsWith('push');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _eventLiveSubscription = EventLiveService.instance.changes.listen((reason) {
      if (!mounted) return;
      if (!_isTicketsLiveReason(reason)) return;
      final offlinePulse = reason.startsWith('offline:');
      unawaited(_loadTickets(forceFresh: !offlinePulse));
    });
    unawaited(_bootstrapTickets());
  }

  Future<void> _bootstrapTickets() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = (prefs.getString('user_id') ?? '').trim();
    if (userId.isEmpty) {
      await _loadTickets();
      return;
    }

    final cached = await _eventService.getMyTicketsCached(userId);
    if (cached.isNotEmpty && mounted) {
      final active = _activeTicketsFrom(
        cached,
        offline: true,
        fetchFailed: true,
      );
      if (active.isNotEmpty) {
        setState(() {
          _tickets = active;
          _isLoading = false;
        });
      }
    }
    await _loadTickets();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventLiveSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadTickets(forceFresh: true));
    }
  }

  Future<void> _loadTickets({bool forceFresh = false}) async {
    final hadCachedTickets = _tickets.isNotEmpty;
    if (mounted && !hadCachedTickets) {
      setState(() => _isLoading = true);
    }

    final prefs = await SharedPreferences.getInstance();
    final userId = (prefs.getString('user_id') ?? '').trim();
    final offline = await EventService.isEffectivelyOffline();
    final effectiveForceFresh = forceFresh && !offline;

    List<Map<String, dynamic>> allTickets = <Map<String, dynamic>>[];
    var fetchFailed = false;
    try {
      allTickets = userId.isEmpty
          ? <Map<String, dynamic>>[]
          : await _eventService.getMyTickets(
              userId,
              forceFresh: effectiveForceFresh,
            );
    } catch (e) {
      debugPrint('[tickets] fetch error: $e');
      fetchFailed = true;
      allTickets = <Map<String, dynamic>>[];
    }

    if (allTickets.isEmpty && userId.isNotEmpty && (offline || fetchFailed)) {
      allTickets = await _eventService.getMyTicketsCached(userId);
    }

    debugPrint('[tickets] fetched ${allTickets.length} rows, forceFresh=$effectiveForceFresh');

    final activeTickets = _activeTicketsFrom(
      allTickets,
      offline: offline,
      fetchFailed: fetchFailed,
    );

    // Keep prior list only when offline or the fetch failed — never when online
    // successfully returns/filters to empty (deleted/ended tickets must clear).
    if (activeTickets.isEmpty && hadCachedTickets && (offline || fetchFailed)) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      return;
    }

    if (mounted) {
      setState(() {
        _tickets = activeTickets;
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> _activeTicketsFrom(
    List<Map<String, dynamic>> allTickets, {
    required bool offline,
    required bool fetchFailed,
  }) {
    final localCached = offline || fetchFailed;
    final activeTickets = allTickets
        .where((t) {
          final active = _isTicketActive(t);
          final hasId = _hasTicketId(t);
          if (!active || !hasId) {
            debugPrint('[tickets] filtered out: active=$active hasId=$hasId event=${t['events']?['title'] ?? t['event_id']}');
          }
          return active && hasId;
        })
        .map((ticket) {
          final normalized = Map<String, dynamic>.from(ticket);
          normalized['local_cached'] = localCached;
          return normalized;
        })
        .toList();

    activeTickets.sort(
      (a, b) => _extractSortDate(b).compareTo(_extractSortDate(a)),
    );
    return activeTickets;
  }

  String _ticketTypeLabel(Map<String, dynamic> event) {
    if (usesEventSessions(event)) {
      final embedded = event['sessions'];
      final embeddedCount = embedded is List ? embedded.length : 0;
      final count = int.tryParse(event['session_count']?.toString() ?? '') ??
          embeddedCount;
      if (count == 1) return 'SEMINAR';
      if (count > 1) return '$count SEMINARS';
      return 'SEMINAR-BASED';
    }
    final type = (event['event_type']?.toString() ?? 'Event').trim();
    return type.isEmpty ? 'EVENT' : type.toUpperCase();
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
        // Keep ticket through the normal timeout window (event end + 1h).
        // Cutting at end_at alone hid the pass exactly when students time out.
        final visibleUntil = endDate.add(const Duration(hours: 1));
        return !now.isAfter(visibleUntil);
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

  DateTime _extractSortDate(Map<String, dynamic> ticketMap) {
    final event = ticketMap['events'];
    final startAt = event is Map ? (event['start_at'] ?? '').toString() : '';
    final eventDate = parseStoredEventDateTime(startAt);
    if (eventDate != null) return eventDate;

    try {
      final registeredAt = (ticketMap['registered_at'] ?? '').toString();
      if (registeredAt.isNotEmpty) return DateTime.parse(registeredAt);
    } catch (_) {}

    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  @override
  Widget build(BuildContext context) {
    final chromeColor = CourseThemeUtils.studentChromeFromPrimary(
      Theme.of(context).colorScheme.primary,
    );
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(100.0),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: CourseThemeUtils.studentTicketGradientFromPrimary(
                Theme.of(context).colorScheme.primary,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: chromeColor.withValues(alpha: 0.3),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
            ],
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(32),
              bottomRight: Radius.circular(32),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 24.0,
                vertical: 16.0,
              ),
              child: Row(
                children: [
                  CircuitTicketIcon(
                    child: const Icon(
                      Icons.local_activity_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'My Tickets',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Your digital event passes',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: PulseConnectLoader())
          : _tickets.isEmpty
          ? _buildEmptyState()
          : RefreshIndicator(
              onRefresh: () => _loadTickets(forceFresh: true),
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
          Icon(
            Icons.confirmation_num_outlined,
            size: 64,
            color: Colors.grey.shade300,
          ),
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
    final eventType = _ticketTypeLabel(event);
    final isLocalCached = ticket['local_cached'] == true;
    final ticketData = ticket['tickets'];
    final ticketId = ticketData is List && ticketData.isNotEmpty
        ? ticketData[0]['id']?.toString() ?? ''
        : ticketData is Map
        ? ticketData['id']?.toString() ?? ''
        : '';

    final startDate = parseStoredEventDateTime(startAt);
    final endDate = parseStoredEventDateTime(endAt);

    final ticketIdDisplay = ticketId.length > 8
        ? ticketId.substring(0, 8).toUpperCase()
        : ticketId.toUpperCase();

    final Color themePrimary = Theme.of(context).colorScheme.primary;
    final List<Color> ticketGradient =
        CourseThemeUtils.studentTicketGradientFromPrimary(themePrimary);
    final Color chromeColor = CourseThemeUtils.studentChromeFromPrimary(
      themePrimary,
    );
    final Color accentColor = Theme.of(context).colorScheme.secondary;

    // ── The inner card widget (no tap logic here) ─────────────────────
    final cardWidget = Container(
      height: 188,
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: chromeColor.withValues(alpha: 0.35),
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
                                Shadow(
                                  color: Colors.black26,
                                  offset: Offset(0, 2),
                                  blurRadius: 4,
                                ),
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
                                      Shadow(
                                        color: accentColor.withValues(
                                          alpha: 0.3,
                                        ),
                                        offset: const Offset(0, 1),
                                        blurRadius: 2,
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isLocalCached) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(
                                      alpha: 0.18,
                                    ),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.22,
                                      ),
                                    ),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.offline_pin_rounded,
                                        size: 11,
                                        color: Colors.white,
                                      ),
                                      SizedBox(width: 3),
                                      Text(
                                        'Cached',
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.1),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.calendar_today_rounded,
                                  size: 16,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        formatCompactDateRange(
                                          startDate,
                                          endDate,
                                        ),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                          height: 1.2,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (startDate != null && endDate != null)
                                        Text(
                                          isMultiDayEvent(startDate, endDate)
                                              ? '${DateFormat('hh:mm a').format(startDate)} → ${DateFormat('hh:mm a').format(endDate)}'
                                              : '${DateFormat('hh:mm a').format(startDate)} - ${DateFormat('hh:mm a').format(endDate)}',
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.8,
                                            ),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          // Location
                          Row(
                            children: [
                              Icon(
                                Icons.location_on_rounded,
                                size: 16,
                                color: accentColor,
                              ),
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
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 8,
                      ),
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
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: 0.1,
                                    ),
                                    blurRadius: 8,
                                    offset: const Offset(0, 4),
                                  ),
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
                                color: Colors.white.withValues(alpha: 0.7),
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
    );

    // ── Wrap in the 3-D rocking + shimmer animation ────────────────────
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: GestureDetector(
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => StudentTicketView(ticket: ticket),
            ),
          );
          _loadTickets(forceFresh: true);
        },
        child: AnimatedTicketCard(
          floatDuration: const Duration(milliseconds: 2400),
          shimmerDuration: const Duration(seconds: 3),
          child: cardWidget,
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
            color: index.isEven
                ? Colors.white.withValues(alpha: 0.2)
                : Colors.transparent,
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
    double cutoutPosition =
        size.width * 0.65; // Position of the vertical divider

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
    path.arcToPoint(
      Offset(size.width, radius),
      radius: Radius.circular(radius),
    );
    path.lineTo(size.width, size.height - radius);

    // Bottom-right corner
    path.arcToPoint(
      Offset(size.width - radius, size.height),
      radius: Radius.circular(radius),
    );

    // Bottom border and cutout
    path.lineTo(cutoutPosition + cutoutRadius, size.height);
    path.arcToPoint(
      Offset(cutoutPosition - cutoutRadius, size.height),
      radius: Radius.circular(cutoutRadius),
      clockwise: false,
    );
    path.lineTo(radius, size.height);

    // Bottom-left corner
    path.arcToPoint(
      Offset(0, size.height - radius),
      radius: Radius.circular(radius),
    );
    path.lineTo(0, radius);

    // Top-left corner
    path.arcToPoint(Offset(radius, 0), radius: Radius.circular(radius));

    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
}
