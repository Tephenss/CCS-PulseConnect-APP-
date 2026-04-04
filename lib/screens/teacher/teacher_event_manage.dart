import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/event_service.dart';

class TeacherEventManage extends StatefulWidget {
  final Map<String, dynamic> event;
  const TeacherEventManage({super.key, required this.event});

  @override
  State<TeacherEventManage> createState() => _TeacherEventManageState();
}

class _TeacherEventManageState extends State<TeacherEventManage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _eventService = EventService();

  List<Map<String, dynamic>> _participants = [];
  List<Map<String, dynamic>> _assistants = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  Future<void> _loadData() async {
    final eventId = widget.event['id']?.toString() ?? '';
    if (eventId.isEmpty) {
      setState(() => _isLoading = false);
      return;
    }

    final participants = await _eventService.getEventParticipants(eventId);

    if (mounted) {
      setState(() {
        _isLoading = false;
        _participants = participants;
        // Assistants still mocked for now
        _assistants = [
          {'name': 'Pedro Penduko', 'id_number': '2019-12345', 'allow_scan': true},
        ];
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ─── Helper: extract student name ───
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

  // ─── Helper: initials (max 2 chars) ───
  String _getInitials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[parts.length - 1][0]}'.toUpperCase();
  }

  // ─── Helper: attendance status ───
  String _getAttStatus(Map<String, dynamic> p) {
    try {
      final tickets = p['tickets'];
      if (tickets == null) return 'unscanned';
      final ticket = (tickets is List && tickets.isNotEmpty) ? tickets[0] : null;
      if (ticket == null) return 'unscanned';
      final attendance = ticket['attendance'];
      if (attendance == null) return 'unscanned';
      final att = (attendance is List && attendance.isNotEmpty) ? attendance[0] : null;
      return att?['status']?.toString() ?? 'unscanned';
    } catch (_) {
      return 'unscanned';
    }
  }

  // ─── Helper: check-in time ───
  String _getCheckIn(Map<String, dynamic> p) {
    try {
      final tickets = p['tickets'];
      if (tickets == null || (tickets is List && tickets.isEmpty)) return '—';
      final ticket = (tickets is List) ? tickets[0] : null;
      if (ticket == null) return '—';
      final attendance = ticket['attendance'];
      final att = (attendance is List && attendance.isNotEmpty) ? attendance[0] : null;
      return att != null && att['check_in_at'] != null
        ? DateFormat('hh:mm a').format(DateTime.parse(att['check_in_at']))
        : '—';
    } catch (_) {
      return '—';
    }
  }

  Future<void> _toggleAssistant(Map<String, dynamic> assistant, bool val) async {
    final oldVal = assistant['allow_scan'];
    setState(() => assistant['allow_scan'] = val);
    
    try {
      await Supabase.instance.client
        .from('event_assistants')
        .update({'allow_scan': val})
        .eq('id', assistant['id']);
    } catch (e) {
      // Revert if HTTP failed
      setState(() => assistant['allow_scan'] = oldVal);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update assistant access.')),
        );
      }
    }
  }

  Future<void> _exportCsv(List<Map<String, dynamic>> participants) async {
    if (participants.isEmpty) return;

    List<List<dynamic>> rows = [];
    rows.add(['Name', 'Email', 'ID Number', 'Course', 'Year Level', 'Status', 'Check-in Time']);

    for (var p in participants) {
      final name = _getName(p);
      final u = p['users'];
      final email = (u is Map ? u['email'] : null)?.toString() ?? '';
      final idNum = (u is Map ? u['id_number'] : null)?.toString() ?? '';
      final course = (u is Map ? u['course'] : null)?.toString() ?? '';
      final yearLevel = (u is Map ? u['year_level'] : null)?.toString() ?? '';
      
      final attStatus = _getAttStatus(p);
      final checkIn = _getCheckIn(p);

      rows.add([name, email, idNum, course, yearLevel, attStatus, checkIn]);
    }

    String csvData = rows.map((row) {
      return row.map((cell) {
        String s = cell.toString().replaceAll('"', '""');
        return '"$s"';
      }).join(',');
    }).join('\n');

    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/PulseConnect_Participants_${DateTime.now().millisecondsSinceEpoch}.csv';
    final file = File(path);
    await file.writeAsString(csvData);

    await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: 'Exported Event Participants'));
  }

  @override
  Widget build(BuildContext context) {
    bool isPending = widget.event['status'] == 'pending';
    bool isRejected = widget.event['status'] == 'rejected';

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
          // ── Status Banner (if pending/rejected) ──
          if (isPending || isRejected)
            Container(
              color: isPending ? Colors.orange.shade50 : Colors.red.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    isPending ? Icons.hourglass_top_rounded : Icons.cancel_rounded,
                    color: isPending ? Colors.orange.shade700 : Colors.red.shade700,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isPending
                          ? 'This event is pending admin approval.'
                          : 'This event was rejected. Reason: Conflict with schedule.',
                      style: TextStyle(
                        color: isPending ? Colors.orange.shade900 : Colors.red.shade900,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Tab Bar ──
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
              tabs: [
                const Tab(text: 'Details'),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Participants'),
                      if (_participants.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF064E3B),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            '${_participants.length}',
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Tab(text: 'Assistants'),
              ],
            ),
          ),

          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF064E3B)))
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildDetailsTab(),
                      _buildParticipantsTab(),
                      _buildAssistantsTab(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ═══════════ DETAILS TAB ═══════════
  Widget _buildDetailsTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _buildInfoBox('Description', widget.event['description'] ?? 'No description provided.', Icons.description_outlined),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _buildInfoBox('Type', widget.event['type'] ?? 'Academic', Icons.category_outlined)),
            const SizedBox(width: 16),
            Expanded(child: _buildInfoBox('Target', widget.event['target_grade'] ?? 'All Grades', Icons.group_outlined)),
          ],
        ),
        const SizedBox(height: 16),
        _buildInfoBox('Venue', widget.event['location'] ?? 'TBA', Icons.location_on_outlined),
      ],
    );
  }

  Widget _buildInfoBox(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: const Color(0xFF064E3B)),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(color: Color(0xFF064E3B), fontWeight: FontWeight.w700, fontSize: 11, letterSpacing: 0.3)),
            ],
          ),
          const SizedBox(height: 10),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF1F2937))),
        ],
      ),
    );
  }

  // ═══════════ PARTICIPANTS TAB ═══════════
  Widget _buildParticipantsTab() {
    // Filter by search
    final filtered = _searchQuery.isEmpty
        ? _participants
        : _participants.where((p) {
            final name = _getName(p).toLowerCase();
            final email = ((p['users'] is Map ? p['users']['email'] : null) ?? '').toString().toLowerCase();
            return name.contains(_searchQuery.toLowerCase()) || email.contains(_searchQuery.toLowerCase());
          }).toList();

    // Stats
    final checkedIn = _participants.where((p) => _getAttStatus(p) == 'present').length;
    final unscanned = _participants.where((p) => _getAttStatus(p) == 'unscanned').length;

    return Column(
      children: [
        // ── Stats ──
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Row(
            children: [
              Expanded(child: _buildStatChip('Registered', '${_participants.length}', const Color(0xFF064E3B), Icons.people_rounded)),
              const SizedBox(width: 8),
              Expanded(child: _buildStatChip('Checked In', '$checkedIn', const Color(0xFF10B981), Icons.check_circle_rounded)),
              const SizedBox(width: 8),
              Expanded(child: _buildStatChip('Unscanned', '$unscanned', const Color(0xFFF59E0B), Icons.pending_actions_rounded)),
            ],
          ),
        ),

        // ── Search & Export ──
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 42,
                  decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(12)),
                  child: TextField(
                    onChanged: (v) => setState(() => _searchQuery = v),
                    style: const TextStyle(fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'Search students...',
                      hintStyle: TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
                      prefixIcon: Icon(Icons.search_rounded, color: Color(0xFF9CA3AF), size: 20),
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
                  icon: const Icon(Icons.download_rounded, color: Color(0xFF064E3B), size: 20),
                  onPressed: () => _exportCsv(filtered),
                  tooltip: 'Export CSV',
                ),
              ),
            ],
          ),
        ),

        const Divider(height: 1, color: Color(0xFFF3F4F6)),

        // ── Participant List ──
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(
                  _searchQuery.isNotEmpty ? 'No students match your search.' : 'No students have registered yet.',
                  _searchQuery.isNotEmpty ? Icons.search_off_rounded : Icons.group_off_rounded,
                )
              : RefreshIndicator(
                  color: const Color(0xFF064E3B),
                  onRefresh: _loadData,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 10),
                    itemBuilder: (context, i) => _buildParticipantCard(filtered[i], i),
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
    final attStatus = _getAttStatus(p);
    final checkIn = _getCheckIn(p);

    final u = p['users'];
    final email = (u is Map ? u['email'] : null)?.toString() ?? '';
    final course = (u is Map ? u['course'] : null)?.toString() ?? '';
    final yearLevel = (u is Map ? u['year_level'] : null)?.toString() ?? '';
    final levelText = [if (yearLevel.isNotEmpty) yearLevel, if (course.isNotEmpty) course].join(' — ');

    // Status chip
    Color statusColor;
    Color statusBg;
    String statusLabel;
    IconData statusIcon;

    switch (attStatus) {
      case 'present':
        statusColor = const Color(0xFF064E3B);
        statusBg = const Color(0xFF064E3B).withValues(alpha: 0.1);
        statusLabel = 'Checked In';
        statusIcon = Icons.check_circle_rounded;
        break;
      case 'late':
        statusColor = Colors.orange.shade700;
        statusBg = Colors.orange.shade50;
        statusLabel = 'Late';
        statusIcon = Icons.schedule_rounded;
        break;
      case 'absent':
        statusColor = Colors.red.shade700;
        statusBg = Colors.red.shade50;
        statusLabel = 'Absent';
        statusIcon = Icons.cancel_rounded;
        break;
      default:
        statusColor = Colors.grey.shade600;
        statusBg = const Color(0xFFF3F4F6);
        statusLabel = 'Registered';
        statusIcon = Icons.confirmation_num_rounded;
    }

    // Avatar color cycling
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
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(color: avatarColor, shape: BoxShape.circle),
              child: Center(
                child: Text(initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ),
            const SizedBox(width: 14),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFF111827))),
                  if (email.isNotEmpty)
                    Text(email, style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12, fontWeight: FontWeight.w500)),
                  if (levelText.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(levelText, style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 11)),
                  ],
                  if (attStatus == 'present' && checkIn != '—') ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.login_rounded, size: 12, color: Color(0xFF064E3B)),
                        const SizedBox(width: 4),
                        Text(checkIn, style: const TextStyle(color: Color(0xFF064E3B), fontSize: 11, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // Status Badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: statusBg, borderRadius: BorderRadius.circular(8)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(statusIcon, size: 13, color: statusColor),
                  const SizedBox(width: 4),
                  Text(statusLabel, style: TextStyle(color: statusColor, fontWeight: FontWeight.w700, fontSize: 11)),
                ],
              ),
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

  // ═══════════ ASSISTANTS TAB ═══════════
  Widget _buildAssistantsTab() {
    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Authorized Scanners', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Color(0xFF111827))),
                    Text('These students can scan tickets on your behalf.', style: TextStyle(color: Color(0xFF6B7280), fontSize: 12)),
                  ],
                ),
              ),
              ElevatedButton.icon(
                onPressed: () {},
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
              ? _buildEmptyState('No assistants assigned yet.', Icons.person_off_rounded)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  itemCount: _assistants.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final a = _assistants[i];
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 2))],
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        leading: Container(
                          width: 44, height: 44,
                          decoration: const BoxDecoration(color: Color(0xFFD4A843), shape: BoxShape.circle),
                          child: Center(child: Text(a['name'][0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18))),
                        ),
                        title: Text(a['name'], style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF111827))),
                        subtitle: Text('ID: ${a['id_number']}', style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                        trailing: Switch(
                          value: a['allow_scan'] == true,
                          activeTrackColor: const Color(0xFF064E3B),
                          onChanged: (v) => _toggleAssistant(a, v),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
