import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';
import 'student_event_details.dart';

class StudentEvents extends StatefulWidget {
  const StudentEvents({super.key});

  @override
  State<StudentEvents> createState() => _StudentEventsState();
}

class _StudentEventsState extends State<StudentEvents> with SingleTickerProviderStateMixin {
  final _eventService = EventService();
  List<Map<String, dynamic>> _activeEvents = [];
  List<Map<String, dynamic>> _expiredEvents = [];
  List<Map<String, dynamic>> _filteredActive = [];
  List<Map<String, dynamic>> _filteredExpired = [];
  bool _isLoading = true;

  // Filter state
  String _selectedEventType = 'All';
  String _selectedEventFor = 'All';

  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadEvents();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadEvents() async {
    setState(() => _isLoading = true);
    final active = await _eventService.getActiveEvents();
    final expired = await _eventService.getExpiredEvents();

    if (mounted) {
      setState(() {
        _activeEvents = active;
        _expiredEvents = expired;
        _applyFilters();
        _isLoading = false;
      });
    }
  }

  void _applyFilters() {
    _filteredActive = _filterList(_activeEvents);
    _filteredExpired = _filterList(_expiredEvents);
  }

  List<Map<String, dynamic>> _filterList(List<Map<String, dynamic>> events) {
    return events.where((e) {
      final type = e['event_type'] as String? ?? '';
      final eventFor = e['event_for'] as String? ?? '';

      if (_selectedEventType != 'All' && type != _selectedEventType) {
        return false;
      }
      if (_selectedEventFor != 'All' && eventFor != _selectedEventFor) {
        return false;
      }
      return true;
    }).toList();
  }

  void _showFilterSheet() {
    String tempType = _selectedEventType;
    String tempFor = _selectedEventFor;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Handle bar
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Text(
                    'Filter Events',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF1F2937)),
                  ),
                  const SizedBox(height: 20),

                  // Event Type Section
                  const Text('Event Type', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF6B7280))),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: ['All', 'Seminar', 'Off-Campus Activity', 'Sports Event', 'Other'].map((type) {
                      final selected = tempType == type;
                      return ChoiceChip(
                        label: Text(type, style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected ? Colors.white : const Color(0xFF374151),
                        )),
                        selected: selected,
                        selectedColor: const Color(0xFF7F1D1D),
                        backgroundColor: Colors.grey.shade100,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        side: BorderSide.none,
                        onSelected: (_) => setSheetState(() => tempType = type),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),

                  // Event For Section
                  const Text('Event For', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF6B7280))),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: ['All', '1st Year', '2nd Year', '3rd Year', '4th Year'].map((grade) {
                      final selected = tempFor == grade;
                      return ChoiceChip(
                        label: Text(grade, style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected ? Colors.white : const Color(0xFF374151),
                        )),
                        selected: selected,
                        selectedColor: const Color(0xFF7F1D1D),
                        backgroundColor: Colors.grey.shade100,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        side: BorderSide.none,
                        onSelected: (_) => setSheetState(() => tempFor = grade),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 28),

                  // Action buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            setSheetState(() {
                              tempType = 'All';
                              tempFor = 'All';
                            });
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF7F1D1D),
                            side: const BorderSide(color: Color(0xFF7F1D1D)),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          child: const Text('Reset', style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: () {
                            setState(() {
                              _selectedEventType = tempType;
                              _selectedEventFor = tempFor;
                              _applyFilters();
                            });
                            Navigator.pop(context);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF7F1D1D),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          child: const Text('Apply Filters', style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  bool get _hasActiveFilter => _selectedEventType != 'All' || _selectedEventFor != 'All';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        title: const Text(
          'Events',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 28,
            color: Color(0xFF1F2937),
            letterSpacing: -0.5,
          ),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Stack(
              children: [
                IconButton(
                  icon: const Icon(Icons.tune_rounded, color: Color(0xFF4B5563)),
                  onPressed: _showFilterSheet,
                  tooltip: 'Filter Events',
                ),
                if (_hasActiveFilter)
                  Positioned(
                    right: 12,
                    top: 12,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFFD4A843),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(70),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
                color: const Color(0xFF7F1D1D),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF7F1D1D).withValues(alpha: 0.2),
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
                Tab(text: 'Expired'),
              ],
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: PulseConnectLoader())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildEventList(_filteredActive, 'No active events found'),
                _buildEventList(_filteredExpired, 'No expired events found'),
              ],
            ),
    );
  }

  Widget _buildEventList(List<Map<String, dynamic>> events, String emptyMessage) {
    if (events.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.event_busy_rounded, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              emptyMessage,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.grey.shade500),
            ),
            if (_hasActiveFilter) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  setState(() {
                    _selectedEventType = 'All';
                    _selectedEventFor = 'All';
                    _applyFilters();
                  });
                },
                child: const Text('Clear filters', style: TextStyle(color: Color(0xFF7F1D1D), fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadEvents,
      color: const Color(0xFF7F1D1D),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        itemCount: events.length,
        itemBuilder: (context, index) {
          final event = events[index];
          return _buildEventCard(event);
        },
      ),
    );
  }

  Widget _buildEventCard(Map<String, dynamic> event) {
    final title = event['title'] as String? ?? 'Untitled';
    final startAt = event['start_at'] as String?;
    final endAt = event['end_at'] as String?;
    final eventFor = event['event_for'] as String? ?? 'All';
    String status = (event['status'] as String? ?? 'published').toLowerCase();

    DateTime? startDate;
    if (startAt != null) {
      try { startDate = DateTime.parse(startAt).toLocal(); } catch (_) {}
    }

    DateTime? endDate;
    if (endAt != null) {
      try { endDate = DateTime.parse(endAt).toLocal(); } catch (_) {}
    }

    // Event becomes expired only when it has already ended.
    if (status != 'archived' && endDate != null && endDate.isBefore(DateTime.now())) {
      status = 'expired';
    }

    Color statusBg = const Color(0xFF064E3B);
    String displayStatus = status.toUpperCase();
    if (displayStatus == 'PENDING') {
      statusBg = const Color(0xFFD97706);
    } else if (displayStatus == 'REJECTED') {
      statusBg = const Color(0xFFEF4444);
    } else if (displayStatus == 'APPROVED') {
      statusBg = const Color(0xFF3B82F6);
    } else if (displayStatus == 'ARCHIVED' || displayStatus == 'EXPIRED' || displayStatus == 'FINISHED') {
      statusBg = const Color(0xFF6B7280);
    }

    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StudentEventDetails(eventId: event['id'].toString()),
          ),
        );
        _loadEvents();
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
                    Container(
                      width: 75,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0xFF991B1B),
                            Color(0xFF7F1D1D),
                          ],
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            startDate != null ? DateFormat('dd').format(startDate) : '--',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 28,
                              height: 1.1,
                              letterSpacing: -1,
                            ),
                          ),
                          Text(
                            startDate != null ? DateFormat('MMM').format(startDate).toUpperCase() : '---',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              letterSpacing: 1.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            height: 2,
                            width: 12,
                            decoration: BoxDecoration(
                              color: const Color(0xFFD4A843),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Content
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: statusBg.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                displayStatus,
                                style: TextStyle(
                                  color: statusBg,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            Text(
                              title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                                color: Color(0xFF111827),
                                letterSpacing: -0.3,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3F4F6),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(Icons.people_rounded, size: 12, color: Color(0xFF4B5563)),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'For: ${eventFor.isEmpty ? 'All' : eventFor}',
                                  style: const TextStyle(color: Color(0xFF374151), fontSize: 12, fontWeight: FontWeight.w700),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3F4F6),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(Icons.schedule_rounded, size: 12, color: Color(0xFF4B5563)),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    startDate != null ? DateFormat('MMM dd, yyyy  -  h:mm a').format(startDate) : 'TBA',
                                    style: const TextStyle(
                                      color: Color(0xFF6B7280),
                                      fontSize: 11,
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

