import 'dart:async';
import 'package:flutter/material.dart';
import '../../widgets/app_snackbar.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/event_time_utils.dart';
import '../../services/event_service.dart';
import '../../utils/course_theme_utils.dart';

class StudentTicketView extends StatefulWidget {
  final Map<String, dynamic> ticket;

  const StudentTicketView({super.key, required this.ticket});

  @override
  State<StudentTicketView> createState() => _StudentTicketViewState();
}

class _StudentTicketViewState extends State<StudentTicketView>
    with WidgetsBindingObserver {
  static const String _downloadedTicketKeyPrefix = 'downloaded_tickets_';
  final EventService _eventService = EventService();
  bool _isDownloading = false;
  bool _isAlreadyDownloaded = false;
  bool _isLoadingSeminarAttendance = false;
  List<Map<String, dynamic>> _seminarAttendance = [];
  /// Live simple-event attendance (refreshed while this screen is open).
  Map<String, dynamic>? _liveAttendance;
  Timer? _attendancePollTimer;
  RealtimeChannel? _attendanceChannel;
  bool _attendanceRefreshInFlight = false;
  DateTime? _lastAttendanceRefreshAt;

  Color _studentPrimary(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  String get _ticketId {
    final ticketData = widget.ticket['tickets'];
    if (ticketData is List && ticketData.isNotEmpty) {
      return (ticketData[0]['id'] ?? '').toString().trim();
    }
    if (ticketData is Map) {
      return (ticketData['id'] ?? '').toString().trim();
    }
    return '';
  }

  String get _registrationId =>
      (widget.ticket['id'] ?? '').toString().trim();

  String get _eventId {
    final event = widget.ticket['events'];
    if (event is Map) {
      final id = (event['id'] ?? '').toString().trim();
      if (id.isNotEmpty) return id;
    }
    return (widget.ticket['event_id'] ?? '').toString().trim();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _liveAttendance = _attendanceFromTicket(widget.ticket);
    _seminarAttendance = _seedSeminarRows(widget.ticket);
    _loadDownloadedState();
    _loadSeminarAttendance();
    unawaited(_refreshAttendanceLive(force: true));
    _bindAttendanceRealtime();
    // Realtime is primary; poll quietly as backup (was 4s — burned Free egress).
    _attendancePollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      unawaited(_refreshAttendanceLive());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _attendancePollTimer?.cancel();
    _attendanceChannel?.unsubscribe();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _attendancePollTimer?.cancel();
      _attendancePollTimer = null;
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _attendancePollTimer?.cancel();
      _attendancePollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (!mounted) return;
        unawaited(_refreshAttendanceLive());
      });
      unawaited(_refreshAttendanceLive(force: true));
    }
  }

  Map<String, dynamic>? _attendanceFromTicket(Map<String, dynamic> ticket) {
    final ticketData = ticket['tickets'];
    dynamic att;
    if (ticketData is List && ticketData.isNotEmpty) {
      att = ticketData[0]['attendance'];
    } else if (ticketData is Map) {
      att = ticketData['attendance'];
    }
    if (att is List && att.isNotEmpty && att[0] is Map) {
      return Map<String, dynamic>.from(att[0] as Map);
    }
    if (att is Map) {
      return Map<String, dynamic>.from(att);
    }
    return null;
  }

  void _patchTicketAttendance(Map<String, dynamic> attendance) {
    final ticketData = widget.ticket['tickets'];
    if (ticketData is List && ticketData.isNotEmpty && ticketData[0] is Map) {
      final row = Map<String, dynamic>.from(ticketData[0] as Map);
      row['attendance'] = [attendance];
      ticketData[0] = row;
    } else if (ticketData is Map) {
      ticketData['attendance'] = [attendance];
    }
  }

  Future<void> _refreshAttendanceLive({bool force = false}) async {
    if (!mounted || _attendanceRefreshInFlight) return;
    final now = DateTime.now();
    if (!force &&
        _lastAttendanceRefreshAt != null &&
        now.difference(_lastAttendanceRefreshAt!) < const Duration(seconds: 8)) {
      return;
    }
    _attendanceRefreshInFlight = true;
    _lastAttendanceRefreshAt = now;
    try {
      final ticketId = _ticketId;
      final eventId = _eventId;
      final registrationId = _registrationId;

      Map<String, dynamic>? nextAttendance = _liveAttendance;
      if (ticketId.isNotEmpty) {
        final fresh = await _eventService.getTicketAttendance(ticketId);
        if (fresh != null) {
          nextAttendance = Map<String, dynamic>.from(fresh);
          _patchTicketAttendance(nextAttendance);
        }
      }

      List<Map<String, dynamic>>? seminarRows;
      if (eventId.isNotEmpty && registrationId.isNotEmpty) {
        seminarRows = await _eventService.getTicketSeminarAttendance(
          eventId: eventId,
          registrationId: registrationId,
          ticketId: ticketId,
        );
      }

      if (!mounted) return;
      setState(() {
        if (nextAttendance != null) {
          _liveAttendance = nextAttendance;
        }
        if (seminarRows != null) {
          _seminarAttendance = seminarRows;
          _isLoadingSeminarAttendance = false;
          if (seminarRows.isNotEmpty && widget.ticket['events'] is Map) {
            final patched =
                Map<String, dynamic>.from(widget.ticket['events'] as Map);
            patched['event_mode'] = 'seminar_based';
            patched['uses_sessions'] = true;
            widget.ticket['events'] = patched;
          }
        }
      });
    } catch (_) {
      // Keep last known attendance on transient errors.
    } finally {
      _attendanceRefreshInFlight = false;
    }
  }

  void _bindAttendanceRealtime() {
    final ticketId = _ticketId;
    final registrationId = _registrationId;
    if (ticketId.isEmpty && registrationId.isEmpty) return;

    final supabase = Supabase.instance.client;
    final channelName =
        'public:student_ticket_attendance:${ticketId.isNotEmpty ? ticketId : registrationId}';
    _attendanceChannel = supabase.channel(channelName);

    void onChange(PostgresChangePayload _) {
      unawaited(_refreshAttendanceLive(force: true));
    }

    if (ticketId.isNotEmpty) {
      _attendanceChannel!.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'attendance',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'ticket_id',
          value: ticketId,
        ),
        callback: onChange,
      );
    }

    if (registrationId.isNotEmpty) {
      _attendanceChannel!.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'event_session_attendance',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'registration_id',
          value: registrationId,
        ),
        callback: onChange,
      );
    }

    _attendanceChannel!.subscribe();
  }

  List<Map<String, dynamic>> _seedSeminarRows(Map<String, dynamic> ticket) {
    final cached = ticket['seminar_attendance'];
    if (cached is List && cached.isNotEmpty) {
      return cached
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    }
    final event = ticket['events'];
    if (event is Map) {
      final sessions = event['sessions'];
      if (sessions is List && sessions.isNotEmpty) {
        return sessions
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
      }
    }
    return [];
  }

  Future<void> _loadSeminarAttendance() async {
    final eventId = _eventId;
    final registrationId = _registrationId;
    final ticketId = _ticketId;

    // Always try loading sessions — do not trust event_mode alone (BFF used to omit it).
    if (eventId.isEmpty || registrationId.isEmpty) {
      if (mounted) {
        setState(() {
          _isLoadingSeminarAttendance = false;
        });
      }
      return;
    }

    if (mounted && _seminarAttendance.isEmpty) {
      setState(() => _isLoadingSeminarAttendance = true);
    }
    final rows = await _eventService.getTicketSeminarAttendance(
      eventId: eventId,
      registrationId: registrationId,
      ticketId: ticketId,
    );
    if (!mounted) return;

    // Patch nested event flags when seminars exist so UI stays consistent.
    if (rows.isNotEmpty && widget.ticket['events'] is Map) {
      final patched = Map<String, dynamic>.from(widget.ticket['events'] as Map);
      patched['event_mode'] = 'seminar_based';
      patched['uses_sessions'] = true;
      if ((patched['event_structure']?.toString() ?? '').trim().isEmpty) {
        patched['event_structure'] =
            rows.length > 1 ? 'two_seminars' : 'one_seminar';
      }
      widget.ticket['events'] = patched;
    }

    setState(() {
      _seminarAttendance = rows;
      _isLoadingSeminarAttendance = false;
    });
  }

  Future<void> _loadDownloadedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? 'guest';
      final storageKey = '$_downloadedTicketKeyPrefix$userId';
      final currentKey = _ticketUniqueKey(widget.ticket);

      if (currentKey.isEmpty) {
        if (mounted) setState(() => _isAlreadyDownloaded = false);
        return;
      }

      final rows = prefs.getStringList(storageKey) ?? <String>[];
      bool found = false;
      for (final row in rows) {
        try {
          final decoded = jsonDecode(row);
          if (decoded is! Map) continue;
          final map = Map<String, dynamic>.from(decoded);
          if (_ticketUniqueKey(map) == currentKey) {
            found = true;
            break;
          }
        } catch (_) {
          // Ignore malformed rows.
        }
      }

      if (mounted) {
        setState(() => _isAlreadyDownloaded = found);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isAlreadyDownloaded = false);
      }
    }
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
    return '';
  }

  Future<void> _downloadTicket(String ticketIdDisplay) async {
    if (_isDownloading) return;
    if (_isAlreadyDownloaded) {
      AppSnackBar.info(context, 'Ticket already saved offline.');
      return;
    }
    if (ticketIdDisplay.trim().isEmpty) {
      AppSnackBar.warning(context, 'Ticket is not available yet.');
      return;
    }

    setState(() => _isDownloading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? 'guest';
      final storageKey = '$_downloadedTicketKeyPrefix$userId';

      final currentTicket = Map<String, dynamic>.from(widget.ticket);
      currentTicket['local_cached'] = true;
      currentTicket['downloaded_at_local'] = DateTime.now().toIso8601String();
      currentTicket['downloaded_explicit'] = true;
      if (_seminarAttendance.isNotEmpty) {
        currentTicket['seminar_attendance'] = _seminarAttendance;
        final eventMap = currentTicket['events'];
        if (eventMap is Map) {
          final patched = Map<String, dynamic>.from(eventMap);
          patched['sessions'] = _seminarAttendance;
          patched['event_mode'] = 'seminar_based';
          patched['uses_sessions'] = true;
          patched['session_count'] = _seminarAttendance.length;
          currentTicket['events'] = patched;
        }
      }
      final currentKey = _ticketUniqueKey(currentTicket);

      final existingRows = prefs.getStringList(storageKey) ?? <String>[];
      final updatedRows = <String>[];
      bool replaced = false;

      for (final row in existingRows) {
        try {
          final decoded = jsonDecode(row);
          if (decoded is! Map) {
            continue;
          }
          final decodedMap = Map<String, dynamic>.from(decoded);
          final decodedKey = _ticketUniqueKey(decodedMap);
          if (!replaced && currentKey.isNotEmpty && decodedKey == currentKey) {
            updatedRows.add(jsonEncode(currentTicket));
            replaced = true;
          } else {
            updatedRows.add(jsonEncode(decodedMap));
          }
        } catch (_) {
          // Skip malformed cached rows safely.
        }
      }

      if (!replaced) {
        updatedRows.insert(0, jsonEncode(currentTicket));
      }

      await prefs.setStringList(storageKey, updatedRows.take(150).toList());

      if (!mounted) return;
      AppSnackBar.success(context, 'Ticket saved in app. You can open it offline in My Tickets.');
      setState(() => _isAlreadyDownloaded = true);
    } catch (e) {
      if (!mounted) return;
      AppSnackBar.error(context, 'Failed to save ticket offline: $e');
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  Widget _buildDownloadActionIcon() {
    if (_isDownloading) {
      return const SizedBox(
        key: ValueKey('loading-icon'),
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2.2,
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFD4A843)),
        ),
      );
    }

    if (_isAlreadyDownloaded) {
      return const Icon(
        Icons.download_done_rounded,
        key: ValueKey('saved-icon'),
        size: 18,
        color: Color(0xFFD4A843),
      );
    }

    return const Icon(
      Icons.download_rounded,
      key: ValueKey('default-icon'),
      size: 18,
    );
  }

  Widget _buildDownloadActionLabel() {
    if (_isAlreadyDownloaded) {
      return const Text(
        'SAVED OFFLINE',
        key: ValueKey('saved-label'),
        style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.4),
      );
    }

    if (_isDownloading) {
      return const Text(
        'SAVING OFFLINE...',
        key: ValueKey('loading-label'),
        style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.4),
      );
    }

    return const Text(
      'DOWNLOAD TICKET',
      key: ValueKey('default-label'),
      style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.35),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ticket = widget.ticket;
    final event = ticket['events'] as Map<String, dynamic>? ?? {};
    final title = event['title'] as String? ?? 'Event';
    final startAt = event['start_at'] as String?;
    final endAt = event['end_at'] as String?;
    final location = event['location'] as String? ?? 'TBA';
    final eventType = event['event_type'] as String? ?? '';
    final graceTime = event['grace_time']?.toString() ?? '';
    final isSeminarBased = _isSeminarBasedEvent(event);
    final seminarRows = _seminarRowsForDisplay(event);
    final ticketData = ticket['tickets'];
    final ticketId = ticketData is List && ticketData.isNotEmpty
        ? ticketData[0]['id']?.toString() ?? ''
        : ticketData is Map ? ticketData['id']?.toString() ?? '' : '';

    // Prefer live attendance (polled / realtime) over the stale nav payload.
    final attendance = _liveAttendance ?? () {
      Map<String, dynamic>? nested;
      if (ticketData is List && ticketData.isNotEmpty) {
        final att = ticketData[0]['attendance'];
        if (att is List && att.isNotEmpty) {
          nested = Map<String, dynamic>.from(att[0] as Map);
        } else if (att is Map) {
          nested = Map<String, dynamic>.from(att);
        }
      } else if (ticketData is Map) {
        final att = ticketData['attendance'];
        if (att is List && att.isNotEmpty) {
          nested = Map<String, dynamic>.from(att[0] as Map);
        } else if (att is Map) {
          nested = Map<String, dynamic>.from(att);
        }
      }
      return nested;
    }();

    final scanStatus = attendance?['status'] as String? ?? 'unscanned';
    final checkInAt = attendance?['check_in_at'] as String?;
    final checkOutAt = attendance?['check_out_at'] as String?;
    final displayStatus = _resolveTicketDisplayStatus(
      isSeminarBased: isSeminarBased,
      scanStatus: scanStatus,
      checkInAt: checkInAt,
      checkOutAt: checkOutAt,
    );
    final ticketIdDisplay = ticketId.length > 8 ? ticketId.substring(0, 8).toUpperCase() : ticketId.toUpperCase();

    final startDate = parseStoredEventDateTime(startAt);
    final endDate = parseStoredEventDateTime(endAt);
    
    String timeString = 'TBA';
    if (startDate != null) {
      final start = DateFormat('hh:mm a').format(startDate);
      if (endDate != null) {
        final end = DateFormat('hh:mm a').format(endDate);
        timeString = '$start - $end';
      } else {
        timeString = start;
      }
    }

    final themePrimary = _studentPrimary(context);
    final chromeColor = CourseThemeUtils.studentChromeFromPrimary(themePrimary);
    final ticketGradient =
        CourseThemeUtils.studentTicketGradientFromPrimary(themePrimary);

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
                        ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Stack(
                            children: [
                          // Shiny Background Layer (Full Height)
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: ticketGradient,
                                  stops: const [0.0, 0.4, 0.6, 1.0],
                                ),
                              ),
                            ),
                          ),

                          // Diagonal Shine Overlay
                          Positioned.fill(
                            child: Opacity(
                              opacity: 0.12,
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

                          // Main Content
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Top Part (Main Ticket Info)
                              Container(
                                padding: const EdgeInsets.all(28),
                                decoration: BoxDecoration(
                                  border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05))),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Header
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
                                          child: Text(
                                            isSeminarBased ? 'SEMINAR PASS' : 'EVENT PASS',
                                            style: const TextStyle(color: Color(0xFFD4A843), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2),
                                          ),
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
                                        fontSize: 28,
                                        height: 1.1,
                                        letterSpacing: -0.5,
                                        shadows: [Shadow(color: Colors.black38, offset: Offset(0, 2), blurRadius: 4)],
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      _ticketSubtitle(
                                        isSeminarBased: isSeminarBased,
                                        seminarCount: seminarRows.length,
                                      ),
                                      style: TextStyle(
                                        color: const Color(0xFFD4A843).withValues(alpha: 0.8),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 1.0,
                                      ),
                                    ),
                                    
                                    const SizedBox(height: 36),
                                    
                                    if (isMultiDayEvent(startDate, endDate)) ...[
                                      _buildTicketField(
                                        'START',
                                        '${DateFormat('MMM dd, yyyy').format(startDate!)} · ${DateFormat('hh:mm a').format(startDate)}',
                                      ),
                                      const SizedBox(height: 16),
                                      _buildTicketField(
                                        'END',
                                        '${DateFormat('MMM dd, yyyy').format(endDate!)} · ${DateFormat('hh:mm a').format(endDate)}',
                                      ),
                                    ] else ...[
                                      Row(
                                        children: [
                                          Expanded(
                                            child: _buildTicketField(
                                              'DATE',
                                              startDate != null
                                                  ? DateFormat('MMM dd, yyyy').format(startDate)
                                                  : 'TBA',
                                            ),
                                          ),
                                          Expanded(
                                            child: _buildTicketField('TIME', timeString),
                                          ),
                                        ],
                                      ),
                                    ],
                                    const SizedBox(height: 24),
                                    _buildTicketField('VENUE', location),
                                    if (isSeminarBased && seminarRows.isNotEmpty) ...[
                                      const SizedBox(height: 24),
                                      Text(
                                        'SEMINARS',
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.5),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: 1.5,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      ...seminarRows.asMap().entries.map((entry) {
                                        final row = entry.value;
                                        final seminarTitle =
                                            (row['title']?.toString() ?? '').trim().isNotEmpty
                                                ? row['title'].toString().trim()
                                                : 'Seminar ${entry.key + 1}';
                                        final topic = (row['topic']?.toString() ?? '').trim();
                                        final showTopic = topic.isNotEmpty &&
                                            topic.toLowerCase() != seminarTitle.toLowerCase();
                                        final room = (row['location']?.toString() ?? '').trim();
                                        final showRoom = room.isNotEmpty &&
                                            room.toLowerCase() != location.trim().toLowerCase();
                                        return Padding(
                                          padding: EdgeInsets.only(
                                            bottom: entry.key == seminarRows.length - 1 ? 0 : 12,
                                          ),
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Container(
                                                width: 22,
                                                height: 22,
                                                alignment: Alignment.center,
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFD4A843).withValues(alpha: 0.18),
                                                  borderRadius: BorderRadius.circular(6),
                                                  border: Border.all(
                                                    color: const Color(0xFFD4A843).withValues(alpha: 0.55),
                                                  ),
                                                ),
                                                child: Text(
                                                  '${entry.key + 1}',
                                                  style: const TextStyle(
                                                    color: Color(0xFFD4A843),
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      seminarTitle,
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 14,
                                                        fontWeight: FontWeight.w800,
                                                        height: 1.25,
                                                      ),
                                                    ),
                                                    if (showTopic) ...[
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        topic,
                                                        style: TextStyle(
                                                          color: Colors.white.withValues(alpha: 0.72),
                                                          fontSize: 12,
                                                          fontWeight: FontWeight.w600,
                                                        ),
                                                      ),
                                                    ],
                                                    const SizedBox(height: 3),
                                                    Text(
                                                      _formatSeminarWindow(
                                                        row['start_at']?.toString(),
                                                        row['end_at']?.toString(),
                                                      ),
                                                      style: TextStyle(
                                                        color: const Color(0xFFD4A843).withValues(alpha: 0.9),
                                                        fontSize: 12,
                                                        fontWeight: FontWeight.w700,
                                                      ),
                                                    ),
                                                    if (showRoom) ...[
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        room,
                                                        style: TextStyle(
                                                          color: Colors.white.withValues(alpha: 0.7),
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.w600,
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }),
                                    ],
                                  ],
                                ),
                              ),

                              // Perforation Line
                              Row(
                                children: [
                                  Container(
                                    width: 14, height: 28,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFF8F9FA), 
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
                                              return Container(width: 6, height: 2, color: Colors.white.withValues(alpha: 0.2));
                                            }),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  Container(
                                    width: 14, height: 28,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFF8F9FA), 
                                      borderRadius: BorderRadius.horizontal(left: Radius.circular(14)),
                                    ),
                                  ),
                                ],
                              ),

                              // Bottom Part (Stub + QR)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.fromLTRB(28, 14, 28, 28),
                                child: Column(
                                  children: [
                                    // QR Code
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Colors.white, 
                                        borderRadius: BorderRadius.circular(16),
                                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 5))],
                                      ),
                                      child: QrImageView(
                                        data: 'PULSE-$ticketId',
                                        version: QrVersions.auto,
                                        size: 140,
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
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 2.0,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          ticketIdDisplay,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontFamily: 'monospace',
                                            fontSize: 18,
                                            fontWeight: FontWeight.w900,
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
                        ],
                      ),
                    ),
                        
                        // ── Attendance History Section ──
                        const SizedBox(height: 20),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey.shade200),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4)),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Attendance Status',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF1F2937)),
                              ),
                              const SizedBox(height: 16),

                              // Status Badge
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: _getAttendanceColor(displayStatus).withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(_getAttendanceIcon(displayStatus), size: 16, color: _getAttendanceColor(displayStatus)),
                                        const SizedBox(width: 6),
                                        Text(
                                          _getAttendanceLabel(displayStatus),
                                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _getAttendanceColor(displayStatus)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),

                              if (isSeminarBased) ...[
                                _buildSeminarAttendanceRows(),
                              ] else ...[
                                _buildAttendanceRow(
                                  'Check-In',
                                  _formatAttendanceTime(checkInAt),
                                  (checkInAt ?? '').trim().isNotEmpty,
                                ),
                                const SizedBox(height: 10),
                                _buildAttendanceRow(
                                  'Time-Out',
                                  _formatAttendanceTime(checkOutAt),
                                  (checkOutAt ?? '').trim().isNotEmpty,
                                ),
                                const SizedBox(height: 10),
                                _buildAttendanceRow('Flow', 'Simple event', true),
                              ],

                              // Event Type & Grace Time
                              if (eventType.isNotEmpty || graceTime.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                const Divider(height: 1),
                                const SizedBox(height: 12),
                                if (eventType.isNotEmpty)
                                  _buildAttendanceRow('Event Type', eventType, true),
                                if (graceTime.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  _buildAttendanceRow('Grace Time', '$graceTime min', true),
                                ],
                              ],
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
                    onPressed: (_isDownloading || _isAlreadyDownloaded)
                        ? null
                        : () => _downloadTicket(ticketIdDisplay),
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _buildDownloadActionIcon(),
                    ),
                    label: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _buildDownloadActionLabel(),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: chromeColor,
                      disabledBackgroundColor: chromeColor,
                      foregroundColor: Colors.white,
                      disabledForegroundColor: _isAlreadyDownloaded
                          ? const Color(0xFFD4A843)
                          : Colors.white,
                      elevation: _isDownloading ? 0 : 2,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      side: BorderSide(
                        color: _isAlreadyDownloaded
                            ? const Color(0xFFD4A843).withValues(alpha: 0.55)
                            : Colors.transparent,
                        width: 1.0,
                      ),
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

  List<Map<String, dynamic>> _seminarRowsForDisplay(Map<String, dynamic> event) {
    if (_seminarAttendance.isNotEmpty) return _seminarAttendance;
    final embedded = event['sessions'];
    if (embedded is List && embedded.isNotEmpty) {
      return embedded
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    }
    return const [];
  }

  String _ticketSubtitle({
    required bool isSeminarBased,
    required int seminarCount,
  }) {
    if (!isSeminarBased) return 'CCS EXCLUSIVE EVENT';
    if (seminarCount <= 0) return 'SEMINAR-BASED EVENT';
    if (seminarCount == 1) return 'SEMINAR-BASED · 1 SEMINAR';
    return 'SEMINAR-BASED · $seminarCount SEMINARS';
  }

  String _formatSeminarWindow(String? startRaw, String? endRaw) {
    final start = parseStoredEventDateTime(startRaw);
    final end = parseStoredEventDateTime(endRaw);
    if (start == null) return 'Schedule TBA';
    final date = DateFormat('MMM dd, yyyy').format(start);
    final startTime = DateFormat('hh:mm a').format(start);
    if (end == null) return '$date · $startTime';
    final sameDay = start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    final endTime = DateFormat('hh:mm a').format(end);
    if (sameDay) return '$date · $startTime – $endTime';
    return '$date $startTime – ${DateFormat('MMM dd, yyyy hh:mm a').format(end)}';
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

  bool _isSeminarBasedEvent(Map<String, dynamic> event) {
    final mode = (event['event_mode']?.toString() ?? '').trim().toLowerCase();
    final structure = (event['event_structure']?.toString() ?? '').trim().toLowerCase();
    final usesSessionsRaw = event['uses_sessions'];
    final usesSessions = usesSessionsRaw == true ||
        (usesSessionsRaw is num && usesSessionsRaw > 0) ||
        (usesSessionsRaw is String && usesSessionsRaw.toLowerCase() == 'true');
    final sessionCount = int.tryParse(event['session_count']?.toString() ?? '') ?? 0;
    return mode == 'seminar_based' ||
        structure == 'seminar_based' ||
        structure == 'one_seminar' ||
        structure == 'two_seminars' ||
        structure.contains('seminar') ||
        usesSessions ||
        sessionCount > 0 ||
        _seminarAttendance.isNotEmpty;
  }

  /// Seminar check-ins live in event_session_attendance; simple events use
  /// tickets.attendance. Prefer seminar rows so the badge matches the list.
  String _resolveTicketDisplayStatus({
    required bool isSeminarBased,
    required String scanStatus,
    String? checkInAt,
    String? checkOutAt,
  }) {
    if (isSeminarBased && _seminarAttendance.isNotEmpty) {
      var anyCheckIn = false;
      var anyCheckOut = false;
      var checkedInCount = 0;
      var checkedOutCount = 0;
      for (final row in _seminarAttendance) {
        final cin = (row['check_in_at']?.toString() ?? '').trim();
        final cout = (row['check_out_at']?.toString() ?? '').trim();
        if (cin.isNotEmpty) {
          anyCheckIn = true;
          checkedInCount++;
        }
        if (cout.isNotEmpty) {
          anyCheckOut = true;
          checkedOutCount++;
        }
      }
      if (anyCheckOut &&
          checkedOutCount >= _seminarAttendance.length &&
          checkedInCount >= _seminarAttendance.length) {
        return 'timed_out';
      }
      if (anyCheckIn) return 'present';
      return 'unscanned';
    }

    final hasCheckOut = (checkOutAt ?? '').trim().isNotEmpty;
    if (hasCheckOut) return 'timed_out';
    final hasCheckIn = (checkInAt ?? '').trim().isNotEmpty;
    if (hasCheckIn &&
        (scanStatus == 'unscanned' || scanStatus.trim().isEmpty)) {
      return 'present';
    }
    return scanStatus.trim().isEmpty ? 'unscanned' : scanStatus;
  }

  Widget _buildSeminarAttendanceRows() {
    if (_isLoadingSeminarAttendance) {
      return const Padding(
        padding: EdgeInsets.only(top: 6),
        child: SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_seminarAttendance.isEmpty) {
      return _buildAttendanceRow('Seminars', 'No seminar schedule found', false);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildAttendanceRow(
          'Seminars',
          _seminarAttendance.length == 1 ? '1 Seminar' : '${_seminarAttendance.length} Seminars',
          true,
        ),
        const SizedBox(height: 10),
        ..._seminarAttendance.asMap().entries.map((entry) {
          final row = entry.value;
          final title = (row['title']?.toString() ?? '').trim().isNotEmpty
              ? row['title'].toString().trim()
              : 'Seminar ${entry.key + 1}';
          final rawCheckIn = (row['check_in_at']?.toString() ?? '').trim();
          final rawCheckOut = (row['check_out_at']?.toString() ?? '').trim();
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildAttendanceRow('Title', title, true),
                const SizedBox(height: 6),
                _buildAttendanceRow(
                  'Check-In',
                  _formatAttendanceTime(rawCheckIn),
                  rawCheckIn.isNotEmpty,
                ),
                const SizedBox(height: 6),
                _buildAttendanceRow(
                  'Time-Out',
                  _formatAttendanceTime(rawCheckOut),
                  rawCheckOut.isNotEmpty,
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  String _formatAttendanceTime(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return 'Not yet';
    final parsed = parseStoredEventDateTime(value);
    if (parsed == null) return 'Not yet';
    return DateFormat('MMM dd, yyyy — hh:mm a').format(parsed);
  }

  Color _getAttendanceColor(String status) {
    switch (status) {
      case 'timed_out':
      case 'checked_out':
        return const Color(0xFF047857);
      case 'present': return const Color(0xFF059669);
      case 'late': return const Color(0xFFD97706);
      case 'early': return const Color(0xFF2563EB);
      case 'scanned': return const Color(0xFF059669);
      case 'absent': return const Color(0xFFDC2626);
      case 'unscanned': return const Color(0xFF6B7280);
      default: return const Color(0xFF6B7280);
    }
  }

  IconData _getAttendanceIcon(String status) {
    switch (status) {
      case 'timed_out':
      case 'checked_out':
        return Icons.logout_rounded;
      case 'present': return Icons.check_circle_rounded;
      case 'late': return Icons.watch_later_rounded;
      case 'early': return Icons.bolt_rounded;
      case 'scanned': return Icons.check_circle_rounded;
      case 'absent': return Icons.cancel_rounded;
      case 'unscanned': return Icons.radio_button_unchecked_rounded;
      default: return Icons.help_outline_rounded;
    }
  }

  String _getAttendanceLabel(String status) {
    switch (status) {
      case 'timed_out':
      case 'checked_out':
        return 'Timed Out';
      case 'present': return 'Checked In';
      case 'late': return 'Checked In (Late)';
      case 'early': return 'Checked In (Early)';
      case 'scanned': return 'Checked In';
      case 'absent': return 'Absent';
      case 'unscanned': return 'Not Yet Scanned';
      default: return status.toUpperCase();
    }
  }

  Widget _buildAttendanceRow(String label, String value, bool active) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade600,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            softWrap: true,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: active ? const Color(0xFF1F2937) : Colors.grey.shade400,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}
