import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }
  
  Future<void> _loadData() async {
    // In MVP, we are mocking the participant fetch since the specific method might not exist in event_service yet for teachers.
    // Assuming backend returns mocked data or an empty list.
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      setState(() {
        _isLoading = false;
        // Mocks for UI logic matching Pages 60-61
        _participants = [
          {'name': 'Juan Dela Cruz', 'year': 'Grade 12', 'section': 'A', 'status': 'checked_in'},
          {'name': 'Maria Clara', 'year': 'Grade 11', 'section': 'C', 'status': 'registered'},
        ];
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

  @override
  Widget build(BuildContext context) {
    bool isPending = widget.event['status'] == 'pending';
    bool isRejected = widget.event['status'] == 'rejected';

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text('Manage Event', style: TextStyle(fontWeight: FontWeight.w800)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_document),
            onPressed: () {
               // Logic to edit event setup
               ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Edit mode opened.')));
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Event Basic Info Header
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(widget.event['title'] ?? 'Untitled Event', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF1F2937)))),
                    if (isPending)
                      Container(padding: const EdgeInsets.all(6), decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(6)), child: const Text('PENDING', style: TextStyle(color: Colors.orange, fontSize: 10, fontWeight: FontWeight.w800))),
                    if (isRejected)
                      Container(padding: const EdgeInsets.all(6), decoration: BoxDecoration(color: Colors.red.shade100, borderRadius: BorderRadius.circular(6)), child: const Text('REJECTED', style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.w800))),
                  ],
                ),
                if (isRejected) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.red.shade50, border: Border.all(color: Colors.red.shade200), borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                        const SizedBox(width: 8),
                        Expanded(child: Text('Reason: Conflict with schedule.', style: TextStyle(color: Colors.red.shade800, fontWeight: FontWeight.w600, fontSize: 13))),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          
          Container(
            color: Colors.white,
            child: TabBar(
              controller: _tabController,
              indicatorColor: const Color(0xFF064E3B),
              labelColor: const Color(0xFF064E3B),
              unselectedLabelColor: Colors.grey.shade500,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700),
              tabs: const [
                 Tab(text: 'Details'),
                 Tab(text: 'Participants'),
                 Tab(text: 'Assistants'),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.grey.shade200)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: Colors.grey.shade500),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.w600, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF1F2937))),
        ],
      ),
    );
  }

  Widget _buildParticipantsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Expanded(child: Text('Live Roster', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text('Export CSV'),
                style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF064E3B), side: const BorderSide(color: Color(0xFF064E3B))),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _participants.length,
            itemBuilder: (context, i) {
              final p = _participants[i];
              bool isCheckedIn = p['status'] == 'checked_in';
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  tileColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade200)),
                  leading: CircleAvatar(backgroundColor: const Color(0xFF064E3B), child: Text(p['name'][0], style: const TextStyle(color: Colors.white))),
                  title: Text(p['name'], style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  subtitle: Text('${p['year']} - ${p['section']}', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  trailing: isCheckedIn 
                    ? const Icon(Icons.check_circle_rounded, color: Color(0xFF064E3B))
                    : const Icon(Icons.pending_actions_rounded, color: Colors.orange),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAssistantsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Expanded(child: Text('Authorized Scanners', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.person_add_rounded, size: 16),
                label: const Text('Assign'),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD4A843), foregroundColor: const Color(0xFF064E3B)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _assistants.length,
            itemBuilder: (context, i) {
              final a = _assistants[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  tileColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade200)),
                  title: Text(a['name'], style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  subtitle: Text('ID: ${a['id_number']}', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  trailing: Switch(
                    value: a['allow_scan'],
                    activeColor: const Color(0xFF064E3B),
                    onChanged: (v) {
                      setState(() => a['allow_scan'] = v);
                    },
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
