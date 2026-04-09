import 'package:flutter/material.dart';
import '../../services/event_service.dart';
import '../../services/auth_service.dart';
import 'package:intl/intl.dart';
import '../../widgets/custom_loader.dart';
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
              borderRadius: BorderRadius.circular(16),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              indicator: BoxDecoration(
                color: const Color(0xFF064E3B),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF064E3B).withValues(alpha: 0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              labelColor: Colors.white,
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
                ? const Center(child: PulseConnectLoader())
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
      
      // Calculate if the event is truly expired based on event end time.
      final endAtStr = e['end_at'] as String?;
      DateTime? endDate;
      
      if (endAtStr != null && endAtStr.isNotEmpty) {
        try { endDate = DateTime.parse(endAtStr); } catch (_) {}
      }

      bool isPast = endDate != null && endDate.isBefore(now);

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

  Widget _buildEventCard(Map<String, dynamic> event) {
    final title = event['title'] as String? ?? 'Sample Event';
    final startAt = event['start_at'] as String?;
    final endAt = event['end_at'] as String?;
    String status = event['status'] as String? ?? 'active';
    final target = event['target_grade'] as String? ?? 'All';

    DateTime? startDate;
    if (startAt != null) {
      try { startDate = DateTime.parse(startAt); } catch (_) {}
    }

    DateTime? endDate;
    if (endAt != null) {
      try { endDate = DateTime.parse(endAt); } catch (_) {}
    }

    if (status != 'archived' && endDate != null && endDate.isBefore(DateTime.now())) {
      status = 'expired';
    }

    Color statusBg = const Color(0xFF064E3B);
    String displayStatus = status.toUpperCase();

    if (displayStatus == 'PENDING') {
      statusBg = const Color(0xFFD97706);
    } else if (displayStatus == 'REJECTED') {
      statusBg = const Color(0xFFFF0000); 
    } else if (displayStatus == 'APPROVED') {
      statusBg = const Color(0xFF3B82F6);
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
        margin: const EdgeInsets.only(bottom: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            children: [
              // CCS Watermark Logo
              Positioned(
                right: -10,
                bottom: -10,
                child: Opacity(
                  opacity: 0.08,
                  child: Image.asset(
                    'assets/CCS.png',
                    width: 160,
                    errorBuilder: (context, error, stackTrace) => const SizedBox(),
                  ),
                ),
              ),
              
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Date Badge
                    Container(
                      width: 75,
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
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            startDate != null ? DateFormat('dd').format(startDate) : '--',
                            style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900, height: 1.1, letterSpacing: -1),
                          ),
                          Text(
                            startDate != null ? DateFormat('MMM').format(startDate).toUpperCase() : '---',
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 1.5),
                          ),
                          const SizedBox(height: 4),
                          Container(height: 2, width: 12, decoration: BoxDecoration(color: const Color(0xFFD4A843), borderRadius: BorderRadius.circular(1))),
                        ],
                      ),
                    ),
                    
                    // Right Details Area
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Status Badge
                            Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: statusBg.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                              child: Text(
                                displayStatus, 
                                style: TextStyle(color: statusBg, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.5)
                              ),
                            ),
                            
                            Text(
                              title,
                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF111827), letterSpacing: -0.3),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                            ),
                            
                            const SizedBox(height: 12),
                            
                            // Metadata Row
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(6)),
                                  child: const Icon(Icons.people_rounded, size: 12, color: Color(0xFF4B5563)),
                                ),
                                const SizedBox(width: 8),
                                Text('For: $target', style: const TextStyle(color: Color(0xFF374151), fontSize: 12, fontWeight: FontWeight.w700)),
                              ],
                            ),
                            
                            const SizedBox(height: 8),
                            
                            // Time Row
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(6)),
                                  child: const Icon(Icons.schedule_rounded, size: 12, color: Color(0xFF4B5563)),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    startDate != null ? DateFormat('MMM dd, yyyy  -  h:mm a').format(startDate) : 'TBA',
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
            ],
          ),
        ),
      ),
    );
  }
}
