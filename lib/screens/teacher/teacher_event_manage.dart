import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';
import '../../utils/event_time_utils.dart';

class TeacherEventManage extends StatefulWidget {
  final Map<String, dynamic> event;
  const TeacherEventManage({super.key, required this.event});

  @override
  State<TeacherEventManage> createState() => _TeacherEventManageState();
}

class _TeacherEventManageState extends State<TeacherEventManage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _eventService = EventService();
  final _authService = AuthService();

  List<Map<String, dynamic>> _participants = [];
  List<Map<String, dynamic>> _assistants = [];
  List<Map<String, dynamic>> _eventSessions = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String _currentTeacherId = '';
  bool _canManageAssistants = false;
  bool _isApprovalPhase = false;

  @override
  void initState() {
    super.initState();
    final status = (widget.event['status']?.toString() ?? 'pending').toLowerCase();
    // Only show Participants and Assistants tabs for Published or Expired events
    _isApprovalPhase = status != 'published' && status != 'expired';
    _tabController = TabController(length: _isApprovalPhase ? 1 : 3, vsync: this);
    _loadData();
  }

  Future<void> _loadData([bool showLoader = false]) async {
    if (showLoader && mounted) {
      setState(() => _isLoading = true);
    }
    
    final eventId = widget.event['id']?.toString() ?? '';
    if (eventId.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final user = await _authService.getCurrentUser();
      final teacherId = user?['id']?.toString() ?? '';
      final results = await Future.wait([
        _eventService.getEventParticipants(eventId),
        _eventService.getEventAssistants(eventId),
        teacherId.isEmpty
            ? Future<bool>.value(false)
            : _eventService.canTeacherManageAssistants(eventId, teacherId),
        _eventService.getEventSessions(eventId),
      ]);

      final participants = results[0] as List<Map<String, dynamic>>;
      final assistants = results[1] as List<Map<String, dynamic>>;
      final canManageAssistants = results[2] as bool;
      final eventSessions = results[3] as List<Map<String, dynamic>>;

      if (mounted) {
        setState(() {
          _isLoading = false;
          _participants = participants;
          _assistants = assistants;
          _eventSessions = eventSessions;
          _currentTeacherId = teacherId;
          _canManageAssistants = canManageAssistants;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _participants = [];
          _assistants = [];
          _eventSessions = [];
          _currentTeacherId = '';
          _canManageAssistants = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // â”€â”€â”€ Helper: extract student name â”€â”€â”€
  String _getName(Map<String, dynamic> p) {
    final u = p['users'];
    if (u == null) return 'Unknown Student';
    if (u is Map) {
      final first = (u['first_name'] ?? '').toString().trim();
      final last = (u['last_name'] ?? '').toString().trim();
      final name = '$first $last'.trim();
      return name.isEmpty ? 'Unknown Student' : name;
    }
    return 'Unknown Student';
  }

  // â”€â”€â”€ Helper: initials (max 2 chars) â”€â”€â”€
  String _getInitials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[parts.length - 1][0]}'.toUpperCase();
  }

  String _getAssistantName(Map<String, dynamic> assistant) {
    final u = assistant['users'];
    if (u is Map) {
      final first = (u['first_name'] ?? '').toString().trim();
      final last = (u['last_name'] ?? '').toString().trim();
      final full = '$first $last'.trim();
      if (full.isNotEmpty) return full;
    }
    final legacy = (assistant['name'] ?? '').toString().trim();
    if (legacy.isNotEmpty) return legacy;
    return 'Unknown Student';
  }

  String _getAssistantStudentNumber(Map<String, dynamic> assistant) {
    final u = assistant['users'];
    if (u is Map) {
      final idNum = (u['id_number'] ?? '').toString().trim();
      if (idNum.isNotEmpty && idNum != 'null') return idNum;
      final studentId = (u['student_id'] ?? '').toString().trim();
      if (studentId.isNotEmpty && studentId != 'null') return studentId;
    }
    final legacy = (assistant['id_number'] ?? '').toString().trim();
    return legacy.isNotEmpty && legacy != 'null' ? legacy : 'N/A';
  }

  List<Map<String, String>> _buildAssistantCandidates() {
    final assignedIds = _assistants
        .map((a) => a['student_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    final candidates = <Map<String, String>>[];
    for (final p in _participants) {
      final sid = p['student_id']?.toString() ?? '';
      if (sid.isEmpty || assignedIds.contains(sid)) continue;

      final name = _getName(p);
      final u = p['users'];
      String idNum = 'N/A';
      if (u is Map) {
        final id = (u['id_number'] ?? '').toString().trim();
        final sc = (u['student_id'] ?? '').toString().trim();
        if (id.isNotEmpty && id != 'null') idNum = id;
        else if (sc.isNotEmpty && sc != 'null') idNum = sc;
      }

      candidates.add({
        'student_id': sid,
        'name': name,
        'id_number': idNum,
      });
    }

    candidates.sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
    return candidates;
  }

  // â”€â”€â”€ Helper: attendance status â”€â”€â”€
  bool _isSeminarBasedEvent() {
    if (_eventSessions.isNotEmpty) return true;
    final usesSessionsRaw = widget.event['uses_sessions'];
    if (usesSessionsRaw == true ||
        (usesSessionsRaw?.toString().toLowerCase().trim() == 'true')) {
      return true;
    }
    final eventMode =
        (widget.event['event_mode']?.toString() ?? '').toLowerCase().trim();
    if (eventMode == 'seminar_based') return true;
    final eventStructure =
        (widget.event['event_structure']?.toString() ?? '').toLowerCase().trim();
    return eventStructure == 'one_seminar' || eventStructure == 'two_seminars';
  }

  List<Map<String, dynamic>> _getSessionAttendance(Map<String, dynamic> p) {
    final raw = p['session_attendance'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    return const <Map<String, dynamic>>[];
  }

  String _getLegacyAttStatus(Map<String, dynamic> p) {
    try {
      final tickets = p['tickets'];
      if (tickets == null) return 'unscanned';
      final ticket = (tickets is List && tickets.isNotEmpty) ? tickets[0] : null;
      if (ticket == null) return 'unscanned';
      final attendance = ticket['attendance'];
      if (attendance == null) return 'unscanned';
      final att = (attendance is List && attendance.isNotEmpty) ? attendance[0] : null;
      if (att == null) return 'unscanned';
      return att['status']?.toString() ?? 'unscanned';
    } catch (_) {
      return 'unscanned';
    }
  }
  String _getAttStatus(Map<String, dynamic> p) {
    if (_isSeminarBasedEvent()) {
      return _getSessionAttendance(p).isNotEmpty ? 'present' : 'unscanned';
    }

    final status = _getLegacyAttStatus(p);
    if (status == 'present' ||
        status == 'late' ||
        status == 'early' ||
        status == 'scanned') {
      return 'present';
    }
    return 'unscanned';
  }

  DateTime? _parseBackendTimestampToLocal(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final parsed = DateTime.tryParse(text);
    if (parsed == null) return null;

    final hasTimezone = RegExp(r'(z|Z|[+\-]\d{2}:\d{2})$').hasMatch(text);
    if (hasTimezone) {
      return parsed.toLocal();
    }

    // Legacy fallback:
    // if timezone is missing in stored timestamp, treat it as UTC
    // so app and web display the same local time.
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    ).toLocal();
  }

  String _formatStoredTime(dynamic raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return '—';
    final local = _parseBackendTimestampToLocal(text);
    if (local == null) return '—';
    return DateFormat('hh:mm a').format(local);
  }
  String _getCheckIn(Map<String, dynamic> p) {
    if (_isSeminarBasedEvent()) {
      final sessionAttendance = _getSessionAttendance(p);
      if (sessionAttendance.isEmpty) return 'â€”';
      for (final scan in sessionAttendance) {
        final formatted =
            _formatStoredTime(scan['check_in_at'] ?? scan['last_scanned_at']);
        if (formatted != 'â€”') return formatted;
      }
      return 'â€”';
    }

    try {
      final tickets = p['tickets'];
      if (tickets == null || (tickets is List && tickets.isEmpty)) return 'â€”';
      final ticket = (tickets is List) ? tickets[0] : null;
      if (ticket == null) return 'â€”';
      final attendance = ticket['attendance'];
      final att = (attendance is List && attendance.isNotEmpty) ? attendance[0] : null;
      return att != null ? _formatStoredTime(att['check_in_at']) : 'â€”';
    } catch (_) {
      return 'â€”';
    }
  }

  int _getSessionCount(Map<String, dynamic> p) {
    return _getSessionAttendance(p).length;
  }

  bool _hasSessionScan(Map<String, dynamic> p, String sessionId) {
    if (sessionId.trim().isEmpty) return false;
    return _getSessionAttendance(p).any(
      (item) => (item['session_id']?.toString() ?? '') == sessionId,
    );
  }

  String _sessionIndicatorLabel(Map<String, dynamic> scan) {
    final sessionNo = int.tryParse(scan['session_no']?.toString() ?? '');
    if (sessionNo != null && sessionNo > 0) {
      return 'Seminar $sessionNo';
    }
    final display = (scan['display_name']?.toString() ?? '').trim();
    if (display.isNotEmpty) return display;
    final title = (scan['title']?.toString() ?? '').trim();
    if (title.isNotEmpty) return title;
    return 'Seminar';
  }


  Future<void> _toggleAssistant(Map<String, dynamic> assistant, bool val) async {
    if (!_canManageAssistants || _currentTeacherId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Only assigned teachers can manage assistants for this event.')),
        );
      }
      return;
    }

    final oldVal = assistant['allow_scan'] == true;
    setState(() => assistant['allow_scan'] = val);

    final result = await _eventService.updateAssistantAccess(
      assistantId: assistant['id']?.toString(),
      eventId: widget.event['id']?.toString(),
      studentId: assistant['student_id']?.toString(),
      teacherId: _currentTeacherId,
      allowScan: val,
    );

    if (result['ok'] != true) {
      setState(() => assistant['allow_scan'] = oldVal);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['error'] ?? 'Failed to update assistant access.')),
        );
      }
    }
  }

  Future<void> _showAssignAssistantSheet() async {
    final eventId = widget.event['id']?.toString() ?? '';
    if (eventId.isEmpty) return;
    if (!_canManageAssistants || _currentTeacherId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only assigned teachers can add assistants for this event.')),
      );
      return;
    }

    final baseCandidates = _buildAssistantCandidates();
    if (baseCandidates.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No eligible participants available for assistant assignment.')),
      );
      return;
    }

    final candidates = List<Map<String, String>>.from(baseCandidates);
    String query = '';
    bool isSubmitting = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final filtered = candidates.where((c) {
              if (query.trim().isEmpty) return true;
              final q = query.toLowerCase();
              return (c['name'] ?? '').toLowerCase().contains(q) ||
                  (c['id_number'] ?? '').toLowerCase().contains(q);
            }).toList();

            return Container(
              height: MediaQuery.of(context).size.height * 0.72,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD1D5DB),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const Text(
                    'Assign Assistant',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Color(0xFF111827)),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Select registered participants who can scan tickets for this event.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: TextField(
                      onChanged: (v) => setSheetState(() => query = v),
                      decoration: const InputDecoration(
                        hintText: 'Search name or ID number...',
                        border: InputBorder.none,
                        prefixIcon: Icon(Icons.search_rounded, size: 20, color: Color(0xFF9CA3AF)),
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(
                            child: Text(
                              'No matching students.',
                              style: TextStyle(color: Color(0xFF6B7280), fontWeight: FontWeight.w600),
                            ),
                          )
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (listContext, index) {
                              final c = filtered[index];
                              final name = c['name'] ?? 'Student';
                              final idNum = c['id_number'] ?? 'N/A';
                              final sid = c['student_id'] ?? '';
                              final initials = _getInitials(name);

                              const avatarColors = [
                                Color(0xFF064E3B),
                                Color(0xFF1D4ED8),
                                Color(0xFF7C3AED),
                                Color(0xFF0F766E),
                                Color(0xFFB45309),
                              ];
                              final avatarColor = avatarColors[index % avatarColors.length];

                              return InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: isSubmitting
                                    ? null
                                    : () async {
                                        if (sid.isEmpty) return;
                                        final messenger = ScaffoldMessenger.of(context);
                                        final navigator = Navigator.of(listContext);

                                        setSheetState(() => isSubmitting = true);

                                        final res = await _eventService.assignEventAssistant(
                                          eventId: eventId,
                                          studentId: sid,
                                          teacherId: _currentTeacherId,
                                          allowScan: true,
                                        );

                                        if (!mounted) return;
                                        setSheetState(() => isSubmitting = false);

                                        if (res['ok'] == true) {
                                          if (navigator.canPop()) {
                                            navigator.pop();
                                          }
                                          await _loadData(true);
                                          if (!mounted) return;
                                          messenger.showSnackBar(
                                            SnackBar(content: Text('$name assigned as assistant.')),
                                          );
                                        } else {
                                          messenger.showSnackBar(
                                            SnackBar(content: Text(res['error'] ?? 'Failed to assign assistant.')),
                                          );
                                        }
                                      },
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.04),
                                        blurRadius: 12,
                                        offset: const Offset(0, 2),
                                      )
                                    ],
                                    border: Border.all(color: const Color(0xFFF3F4F6)),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 46,
                                        height: 46,
                                        decoration: BoxDecoration(color: avatarColor, shape: BoxShape.circle),
                                        child: Center(
                                          child: Text(
                                            initials,
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              name,
                                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFF111827)),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              'Student ID: $idNum',
                                              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280), fontWeight: FontWeight.w500),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF064E3B).withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.add_rounded, color: Color(0xFF064E3B), size: 16),
                                            SizedBox(width: 6),
                                            Text('Assign', style: TextStyle(color: Color(0xFF064E3B), fontWeight: FontWeight.w700, fontSize: 13)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _exportCsv(List<Map<String, dynamic>> participants) async {
    if (participants.isEmpty) return;

    final rows = <List<dynamic>>[];
    rows.add(['Name', 'Email', 'ID Number', 'Course', 'Year Level', 'Status', 'Check-in Time']);

    for (final p in participants) {
      final name = _getName(p);
      final u = p['users'];
      final email = (u is Map ? u['email'] : null)?.toString() ?? '';
      final idNum = (u is Map ? (u['id_number'] ?? u['student_id']) : null)?.toString() ?? '';
      final course = (u is Map ? u['course'] : null)?.toString() ?? '';
      final yearLevel = (u is Map ? u['year_level'] : null)?.toString() ?? '';
      final attStatus = _getAttStatus(p);
      final checkIn = _getCheckIn(p);

      rows.add([name, email, idNum, course, yearLevel, attStatus, checkIn]);
    }

    final csvData = rows.map((row) {
      return row.map((cell) {
        final s = cell.toString().replaceAll('"', '""');
        return '"$s"';
      }).join(',');
    }).join('\n');

    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/PulseConnect_Participants_${DateTime.now().millisecondsSinceEpoch}.csv';
    final file = File(path);
    await file.writeAsString(csvData);

    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: 'Exported Event Participants'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPending = widget.event['status'] == 'pending';
    final isApproved = widget.event['status'] == 'approved';
    final isRejected = widget.event['status'] == 'rejected';

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        backgroundColor: const Color(0xFF064E3B),
        foregroundColor: Colors.white,
        title: Text(
          widget.event['title'] ?? 'Manage Event',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: true,
        elevation: 0,
      ),
      body: Column(
        children: [
          if (isPending || isRejected || isApproved)
            Container(
              color: isApproved
                  ? Colors.blue.shade50
                  : (isPending ? Colors.orange.shade50 : Colors.red.shade50),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    isApproved
                        ? Icons.check_circle_outline_rounded
                        : (isPending ? Icons.hourglass_top_rounded : Icons.cancel_rounded),
                    color: isApproved
                        ? Colors.blue.shade700
                        : (isPending ? Colors.orange.shade700 : Colors.red.shade700),
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isApproved
                          ? 'Event is approved! It will be visible to students once published.'
                          : (isPending
                              ? 'This event is pending admin approval.'
                              : 'This event was rejected. Reason: Conflict with schedule.'),
                      style: TextStyle(
                        color: isApproved
                            ? Colors.blue.shade900
                            : (isPending ? Colors.orange.shade900 : Colors.red.shade900),
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (!_isApprovalPhase)
            Container(
              color: Colors.white,
              child: TabBar(
                controller: _tabController,
                indicatorColor: const Color(0xFF064E3B),
                indicatorWeight: 3,
                labelColor: const Color(0xFF064E3B),
                unselectedLabelColor: Colors.grey.shade500,
                labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                tabs: const [
                  Tab(text: 'Details'),
                  Tab(text: 'Participants'),
                  Tab(text: 'Assistants'),
                ],
              ),
            ),
          Expanded(
            child: _isLoading
                ? const Center(child: PulseConnectLoader())
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildDetailsTab(),
                      if (!_isApprovalPhase) _buildParticipantsTab(),
                      if (!_isApprovalPhase) _buildAssistantsTab(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  String _getTargetLabel(String? val) {
    if (val == null || val.toLowerCase() == 'all') return 'All Year Levels';
    if (val.toLowerCase() == 'none') return 'No Target';
    final map = {
      '1': '1st Year',
      '2': '2nd Year',
      '3': '3rd Year',
      '4': '4th Year',
    };
    return map[val] ?? val;
  }

  Widget _buildDetailsTab() {
    final startDate = parseStoredEventDateTime(widget.event['start_at']);
    final endDate = parseStoredEventDateTime(widget.event['end_at']);
    final dateStr = formatDateRange(startDate, endDate);
    final timeStr = formatTimeRange(startDate, endDate);
    final location = (widget.event['location'] ?? 'TBA').toString();
    final target = _getTargetLabel(widget.event['event_for']?.toString());
    final description = (widget.event['description'] ?? 'No description provided.').toString();
    final isSeminarBased = _isSeminarBasedEvent();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      children: [
        const Text(
          'EVENT INFORMATION',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: Color(0xFF6B7280),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 15,
                offset: const Offset(0, 4),
              )
            ],
            border: Border.all(color: const Color(0xFFF3F4F6)),
          ),
          child: Column(
            children: [
              _buildPremiumDetailRow(Icons.group_rounded, 'Target Participants', target),
              const Divider(height: 1, color: Color(0xFFF3F4F6), indent: 64),
              _buildPremiumDetailRow(Icons.calendar_today_rounded, 'Date', dateStr),
              const Divider(height: 1, color: Color(0xFFF3F4F6), indent: 64),
              _buildPremiumDetailRow(Icons.schedule_rounded, 'Time', timeStr),
              const Divider(height: 1, color: Color(0xFFF3F4F6), indent: 64),
              _buildPremiumDetailRow(Icons.location_on_rounded, 'Venue', location),
              if (isSeminarBased) ...[
                const Divider(height: 1, color: Color(0xFFF3F4F6)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: const [
                      Icon(Icons.auto_stories_rounded, size: 16, color: Color(0xFF064E3B)),
                      SizedBox(width: 8),
                      Text(
                        'Seminar Sessions',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: _buildSessionScheduleSection(),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          'ABOUT THE EVENT',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: Color(0xFF6B7280),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 15,
                offset: const Offset(0, 4),
              )
            ],
            border: Border.all(color: const Color(0xFFF3F4F6)),
          ),
          child: Text(
            description,
            style: const TextStyle(
              fontSize: 15,
              color: Color(0xFF374151),
              height: 1.6,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
  Widget _buildSessionScheduleSection() {
    if (_eventSessions.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFF3F4F6)),
        ),
        child: const Text(
          'No seminar schedule found for this event yet.',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6B7280),
          ),
        ),
      );
    }

    return Column(
      children: _eventSessions.asMap().entries.map((entry) {
        final index = entry.key;
        final session = entry.value;
        final rawTitle = (session['title']?.toString() ?? '').trim();
        final title = rawTitle.isNotEmpty ? rawTitle : buildSessionDisplayName(session);
        final start = parseStoredEventDateTime(session['start_at']);
        final end = parseStoredEventDateTime(session['end_at']);
        final topic = (session['topic']?.toString() ?? '').trim();
        final showTopic =
            topic.isNotEmpty && !title.toLowerCase().contains(topic.toLowerCase());

        return Container(
          width: double.infinity,
          margin: EdgeInsets.only(bottom: index == _eventSessions.length - 1 ? 0 : 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF3F4F6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Seminar ${index + 1}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                  color: Color(0xFF6B7280),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827),
                ),
              ),
              if (showTopic) ...[
                const SizedBox(height: 6),
                Text(
                  topic,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF374151),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _buildPremiumDetailRow(
                Icons.calendar_today_rounded,
                'Date',
                formatDateRange(start, end),
              ),
              const Divider(height: 1, color: Color(0xFFF3F4F6), indent: 64),
              _buildPremiumDetailRow(
                Icons.login_rounded,
                'Start Time',
                start != null ? DateFormat('hh:mm a').format(start) : 'TBA',
              ),
              const Divider(height: 1, color: Color(0xFFF3F4F6), indent: 64),
              _buildPremiumDetailRow(
                Icons.logout_rounded,
                'End Time',
                end != null ? DateFormat('hh:mm a').format(end) : 'TBA',
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildPremiumDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF064E3B).withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: const Color(0xFF064E3B), size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9CA3AF),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
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

  // â•â•â•â•â•â•â•â•â•â•â• PARTICIPANTS TAB â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildParticipantsTab() {
    final filtered = _searchQuery.isEmpty
        ? _participants
        : _participants.where((p) {
            final name = _getName(p).toLowerCase();
            final email = ((p['users'] is Map ? p['users']['email'] : null) ?? '')
                .toString()
                .toLowerCase();
            return name.contains(_searchQuery.toLowerCase()) ||
                email.contains(_searchQuery.toLowerCase());
          }).toList();

    final isSeminarBased = _isSeminarBasedEvent();
    final presentCount =
        _participants.where((p) => _getAttStatus(p) == 'present').length;
    final unscanned =
        _participants.where((p) => _getAttStatus(p) == 'unscanned').length;
    final seminarOneCount = _eventSessions.isNotEmpty
        ? _participants
            .where((p) => _hasSessionScan(
                  p,
                  _eventSessions.first['id']?.toString() ?? '',
                ))
            .length
        : 0;
    final seminarTwoCount = _eventSessions.length > 1
        ? _participants
            .where((p) => _hasSessionScan(
                  p,
                  _eventSessions[1]['id']?.toString() ?? '',
                ))
            .length
        : 0;

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: _buildStatChip(
                  'Joined',
                  '${_participants.length}',
                  const Color(0xFF064E3B),
                  Icons.people_rounded,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildStatChip(
                  isSeminarBased ? 'Seminar 1' : 'Present',
                  '${isSeminarBased ? seminarOneCount : presentCount}',
                  const Color(0xFF10B981),
                  isSeminarBased
                      ? Icons.looks_one_rounded
                      : Icons.login_rounded,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildStatChip(
                  isSeminarBased
                      ? (_eventSessions.length > 1 ? 'Seminar 2' : 'Present')
                      : 'Present',
                  '${isSeminarBased ? (_eventSessions.length > 1 ? seminarTwoCount : presentCount) : presentCount}',
                  const Color(0xFF1D4ED8),
                  isSeminarBased && _eventSessions.length > 1
                      ? Icons.looks_two_rounded
                      : Icons.check_circle_rounded,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildStatChip(
                  'Absent',
                  '$unscanned',
                  const Color(0xFFF59E0B),
                  Icons.pending_actions_rounded,
                ),
              ),
            ],
          ),
        ),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextField(
                    onChanged: (v) => setState(() => _searchQuery = v),
                    style: const TextStyle(fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'Search students...',
                      hintStyle: TextStyle(
                        color: Color(0xFF9CA3AF),
                        fontSize: 14,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        color: Color(0xFF9CA3AF),
                        size: 20,
                      ),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF064E3B).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: IconButton(
                  icon: const Icon(
                    Icons.download_rounded,
                    color: Color(0xFF064E3B),
                    size: 20,
                  ),
                  onPressed: () => _exportCsv(filtered),
                  tooltip: 'Export CSV',
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF3F4F6)),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(
                  _searchQuery.isNotEmpty
                      ? 'No students match your search.'
                      : 'No students have registered yet.',
                  _searchQuery.isNotEmpty
                      ? Icons.search_off_rounded
                      : Icons.group_off_rounded,
                )
              : RefreshIndicator(
                  color: const Color(0xFF064E3B),
                  onRefresh: _loadData,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, i) =>
                        _buildParticipantCard(filtered[i], i),
                  ),
                ),
        ),
      ],
    );
  }
  Widget _buildStatChip(String label, String value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 20, height: 1.0)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: color.withValues(alpha: 0.75), fontWeight: FontWeight.w600, fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _buildParticipantCard(Map<String, dynamic> p, int index) {
    final name = _getName(p);
    final initials = _getInitials(name);
    final isSeminarBased = _isSeminarBasedEvent();
    final attStatus = _getAttStatus(p);
    final checkIn = _getCheckIn(p);
    final sessionAttendance = _getSessionAttendance(p);
    final sessionCount = _getSessionCount(p);

    final u = p['users'];
    final email = (u is Map ? u['email'] : null)?.toString() ?? '';
    final course = (u is Map ? u['course'] : null)?.toString() ?? '';
    final yearLevel = (u is Map ? u['year_level'] : null)?.toString() ?? '';
    final levelText = [
      if (yearLevel.isNotEmpty) yearLevel,
      if (course.isNotEmpty) course,
    ].join(' • ');

    Color statusColor;
    Color statusBg;
    String statusLabel;
    IconData statusIcon;

    switch (attStatus) {
      case 'present':
        statusColor = const Color(0xFF064E3B);
        statusBg = const Color(0xFF064E3B).withValues(alpha: 0.1);
        statusLabel = isSeminarBased
            ? (sessionCount > 1 ? '$sessionCount Seminars' : 'Present')
            : 'Present';
        statusIcon = Icons.check_circle_rounded;
        break;
      default:
        statusColor = Colors.grey.shade600;
        statusBg = const Color(0xFFF3F4F6);
        statusLabel = 'Registered';
        statusIcon = Icons.confirmation_num_rounded;
    }

    const avatarColors = [
      Color(0xFF064E3B),
      Color(0xFF1D4ED8),
      Color(0xFF7C3AED),
      Color(0xFF0F766E),
      Color(0xFFB45309),
    ];
    final avatarColor = avatarColors[index % avatarColors.length];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(color: const Color(0xFFF3F4F6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: avatarColor,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  initials,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: Color(0xFF111827),
                    ),
                  ),
                  if (email.isNotEmpty)
                    Text(
                      email,
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  if (levelText.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      levelText,
                      style: const TextStyle(
                        color: Color(0xFF9CA3AF),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (checkIn != '—')
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.login_rounded,
                              size: 11,
                              color: Color(0xFF10B981),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              checkIn,
                              style: const TextStyle(
                                color: Color(0xFF10B981),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      if (isSeminarBased)
                        ...sessionAttendance.map((scan) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDBEAFE),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              _sessionIndicatorLabel(scan),
                              style: const TextStyle(
                                color: Color(0xFF1D4ED8),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          );
                        }),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: statusBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, size: 12, color: statusColor),
                      const SizedBox(width: 4),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  Widget _buildEmptyState(String message, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: const Color(0xFFF3F4F6), shape: BoxShape.circle),
            child: Icon(icon, size: 40, color: Colors.grey.shade400),
          ),
          const SizedBox(height: 16),
          Text(message, style: const TextStyle(color: Color(0xFF6B7280), fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          const Text('Pull down to refresh', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12)),
        ],
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â• ASSISTANTS TAB â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildAssistantsTab() {
    final isExpired = widget.event['status'] == 'expired';

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Authorized Scanners', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Color(0xFF111827))),
                    Text(
                      isExpired
                          ? 'This event is completed. Assistant management is disabled.'
                          : _canManageAssistants
                              ? 'These students can scan tickets on your behalf.'
                              : 'Assistant management is limited to teachers assigned by admin.',
                      style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                    ),
                  ],
                ),
              ),
              ElevatedButton.icon(
                onPressed: (_canManageAssistants && !isExpired) ? _showAssignAssistantSheet : null,
                icon: const Icon(Icons.person_add_rounded, size: 16),
                label: const Text('Assign'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF064E3B),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF3F4F6)),
        Expanded(
          child: _assistants.isEmpty
              ? RefreshIndicator(
                  color: const Color(0xFF064E3B),
                  onRefresh: () => _loadData(true),
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Container(
                      height: MediaQuery.of(context).size.height * 0.5,
                      alignment: Alignment.center,
                      child: _buildEmptyState(
                        isExpired 
                            ? 'No assistants were assigned to this event.'
                            : _canManageAssistants
                                ? 'No assistants assigned yet.'
                                : 'Only assigned teachers can manage assistants.',
                        isExpired
                            ? Icons.person_off_rounded
                            : _canManageAssistants
                                ? Icons.person_off_rounded
                                : Icons.lock_outline_rounded,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  itemCount: _assistants.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final a = _assistants[i];
                    final assistantName = _getAssistantName(a);
                    final assistantIdNumber = _getAssistantStudentNumber(a);
                    final initials = _getInitials(assistantName);
                    
                    const avatarColors = [
                      Color(0xFF064E3B),
                      Color(0xFF1D4ED8),
                      Color(0xFF7C3AED),
                      Color(0xFF0F766E),
                      Color(0xFFB45309),
                    ];
                    final avatarColor = avatarColors[i % avatarColors.length];

                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 2))],
                        border: Border.all(color: const Color(0xFFF3F4F6)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(color: avatarColor, shape: BoxShape.circle),
                            child: Center(
                              child: Text(
                                initials,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  assistantName,
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFF111827)),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Student ID: $assistantIdNumber',
                                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280), fontWeight: FontWeight.w500),
                                ),
                              ],
                            ),
                          ),
                          Transform.scale(
                            scale: 0.85,
                            child: Switch(
                              value: a['allow_scan'] == true,
                              activeColor: Colors.white,
                              activeTrackColor: const Color(0xFF064E3B),
                              inactiveThumbColor: Colors.grey.shade400,
                              inactiveTrackColor: Colors.grey.shade200,
                              onChanged: (_canManageAssistants && !isExpired)
                                  ? (v) => _toggleAssistant(a, v)
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}




