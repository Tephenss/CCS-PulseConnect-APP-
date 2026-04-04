import 'package:flutter/material.dart';
import '../../services/event_service.dart';
import '../../services/auth_service.dart';
import 'package:intl/intl.dart';
import 'teacher_create_event.dart';
import 'teacher_event_manage.dart';

class TeacherEventsTab extends StatefulWidget {
  const TeacherEventsTab({super.key});

  @override
  State<TeacherEventsTab> createState() => _TeacherEventsTabState();
}

class _TeacherEventsTabState extends State<TeacherEventsTab> with SingleTickerProviderStateMixin {
  final _eventService = EventService();
  final _authService = AuthService();
  late TabController _tabController;
  List<Map<String, dynamic>> _events = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    final user = await _authService.getCurrentUser();
    if (user == null) return;
    
    // Fetch ALL events (to match what we see in the Admin screenshots)
    final events = await _eventService.getAllEvents();
    
    if (mounted) {
      setState(() {
        _events = events;
        _isLoading = false;
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
    return SafeArea(
      child: Column(
        children: [
          // Header with Create Event button
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Row(
              children: [
                const Text('My Events', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Color(0xFF1F2937))),
                const Spacer(),
                GestureDetector(
                  onTap: () async {
                    final refresh = await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TeacherCreateEvent()),
                    );
                    if (refresh == true) {
                      _loadEvents();
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF064E3B),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.add, color: Colors.white, size: 18),
                        SizedBox(width: 4),
                        Text('Create', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Tab Bar matching Image 1
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent, // Remove line under tabs natively
              indicator: BoxDecoration(
                color: const Color(0xFFD4A843), // Gold Pill
                borderRadius: BorderRadius.circular(10),
              ),
              labelColor: const Color(0xFF064E3B), // Dark Green text
              unselectedLabelColor: const Color(0xFF6B7280),
              labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              tabs: const [
                Tab(text: 'Active'),
                Tab(text: 'Approval'),
                Tab(text: 'Expired'),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Tab Views
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF064E3B)))
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildEventList('active'),
                      _buildEventList('pending'),
                      _buildEventList('expired'),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventList(String statusFilter) {
    final now = DateTime.now();

    var filteredEvents = _events.where((e) {
      final status = (e['status'] as String? ?? 'pending').toLowerCase(); // Normalize string
      
      // Calculate if the event is truly expired based on datetime
      final startAtStr = e['start_at'] as String?;
      DateTime? checkDate;
      
      if (startAtStr != null && startAtStr.isNotEmpty) {
        try { checkDate = DateTime.parse(startAtStr); } catch (_) {}
      }

      bool isPast = checkDate != null && checkDate.isBefore(now);

      if (statusFilter == 'expired') {
        // Shown in Expired if time naturally passed, excluding manually archived ones
        return (status == 'expired' || status == 'finished' || isPast) && status != 'archived';
      } else if (statusFilter == 'active') {
        // Shown in Active if published AND time has NOT passed
        return status == 'published' && !isPast;
      } else if (statusFilter == 'pending') {
        // Shown in Approval if pending, approved, or rejected AND time has NOT passed
        return (status == 'pending' || status == 'approved' || status == 'rejected') && !isPast;
      }
      return false;
    }).toList();
    
    if (filteredEvents.isEmpty) {
      return _buildEmptyState('No $statusFilter events found');
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      itemCount: filteredEvents.length,
      itemBuilder: (context, index) {
        final event = filteredEvents[index];
        return _buildEventCard(event);
      },
    );
  }

  Widget _buildEmptyState(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.event_busy_rounded, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(message, style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.w600, fontSize: 15)),
        ],
      ),
    );
  }

  // Exact Match for UI Image 2
  Widget _buildEventCard(Map<String, dynamic> event) {
    final title = event['title'] as String? ?? 'Sample Event';
    final startAt = event['start_at'] as String?;
    String status = event['status'] as String? ?? 'active';
    final target = event['target_grade'] as String? ?? 'All';

    DateTime? startDate;
    if (startAt != null) {
      try { startDate = DateTime.parse(startAt); } catch (_) {}
    }

    // Auto-expire visually if 'start_at' has passed
    if (status != 'archived' && startDate != null && startDate.isBefore(DateTime.now())) {
      status = 'expired';
    }

    // Status Badge Colors (Aligned with Admin UI Tags)
    Color statusBg = const Color(0xFF064E3B); // Published/Active
    String displayStatus = status.toUpperCase();

    if (displayStatus == 'PENDING') {
      statusBg = const Color(0xFFD97706);
    } else if (displayStatus == 'REJECTED') {
      statusBg = const Color(0xFFFF0000); 
    } else if (displayStatus == 'APPROVED') {
      statusBg = const Color(0xFF3B82F6); // Blue matching the Admin image
    } else if (displayStatus == 'ARCHIVED' || displayStatus == 'EXPIRED' || displayStatus == 'FINISHED') {
      statusBg = const Color(0xFF6B7280);
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TeacherEventManage(event: event),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade300),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left Blue Square (We use Dark Green to match app theme, matching structure)
              Container(
                width: 90,
                decoration: const BoxDecoration(
                  color: Color(0xFF064E3B), // Dark Green replacing blue
                  borderRadius: BorderRadius.only(topLeft: Radius.circular(16), bottomLeft: Radius.circular(16)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      startDate != null ? DateFormat('dd').format(startDate) : '--',
                      style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800, height: 1.1),
                    ),
                    Text(
                      startDate != null ? DateFormat('MMM').format(startDate) : '---',
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              
              // Right Details Area
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title & Status Badge
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFF1F2937)),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: statusBg, borderRadius: BorderRadius.circular(6)),
                            child: Text(displayStatus, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 8),
                      Container(height: 2, width: 40, color: const Color(0xFF93C5FD)), // Light blue separator mimicking image
                      const SizedBox(height: 8),
                      
                      Text('For: $target', style: const TextStyle(color: Color(0xFF1D4ED8), fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 10),
                      
                      // Start Date
                      Row(
                        children: [
                          const Icon(Icons.stop_rounded, size: 10, color: Color(0xFF3B82F6)), // Tiny square dot
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Date: ${startDate != null ? DateFormat('MMM dd, yyyy').format(startDate) : 'TBA'}',
                              style: const TextStyle(color: Color(0xFF3B82F6), fontSize: 11, fontWeight: FontWeight.w700),
                            ),
                          ),
                          Text(
                            startDate != null ? DateFormat('h:mm a').format(startDate) : '--:--',
                            style: const TextStyle(color: Color(0xFF3B82F6), fontSize: 11, fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Location
                      Row(
                        children: [
                          const Icon(Icons.location_on_rounded, size: 12, color: Color(0xFF6B7280)), 
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              event['location']?.toString().toUpperCase() ?? 'TBA',
                              style: const TextStyle(color: Color(0xFF6B7280), fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
