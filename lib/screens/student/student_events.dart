import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/event_service.dart';
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
        backgroundColor: const Color(0xFF7F1D1D),
        title: const Text('Events', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, color: Colors.white)),
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.filter_list_rounded, color: Colors.white),
                onPressed: _showFilterSheet,
                tooltip: 'Filter Events',
              ),
              if (_hasActiveFilter)
                Positioned(
                  right: 8, top: 8,
                  child: Container(
                    width: 10, height: 10,
                    decoration: const BoxDecoration(
                      color: Color(0xFFD4A843),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFFD4A843),
          indicatorWeight: 4,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700),
          tabs: const [
            Tab(text: 'Active'),
            Tab(text: 'Expired'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF7F1D1D)))
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
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
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
    final description = event['description'] as String? ?? 'No description';
    final startAt = event['start_at'] as String?;
    final endAt = event['end_at'] as String?;
    final location = event['location'] as String? ?? '';
    final eventType = event['event_type'] as String? ?? '';
    final eventFor = event['event_for'] as String? ?? '';

    DateTime? startDate, endDate;
    if (startAt != null) {
      try { startDate = DateTime.parse(startAt).toLocal(); } catch (_) {}
    }
    if (endAt != null) {
      try { endDate = DateTime.parse(endAt).toLocal(); } catch (_) {}
    }

    // Determine if multi-day
    bool isMultiDay = false;
    if (startDate != null && endDate != null) {
      isMultiDay = startDate.day != endDate.day ||
          startDate.month != endDate.month ||
          startDate.year != endDate.year;
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
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // Date Badge
            Container(
              width: 60,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF7F1D1D).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Text(
                    startDate != null ? DateFormat('dd').format(startDate) : '--',
                    style: const TextStyle(
                      color: Color(0xFF7F1D1D),
                      fontWeight: FontWeight.w900,
                      fontSize: 22,
                      letterSpacing: -0.5,
                    ),
                  ),
                  Text(
                    startDate != null ? DateFormat('MMM').format(startDate).toUpperCase() : '---',
                    style: const TextStyle(
                      color: Color(0xFF7F1D1D),
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),

            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Event Type Badge + Title Row
                  if (eventType.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _getEventTypeColor(eventType).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        eventType,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: _getEventTypeColor(eventType),
                        ),
                      ),
                    ),
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: Color(0xFF1F2937),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (startDate != null) ...[
                        Icon(Icons.schedule_rounded, size: 14, color: Colors.grey.shade500),
                        const SizedBox(width: 4),
                        Text(
                          isMultiDay && endDate != null
                              ? '${DateFormat('MMM dd').format(startDate)} - ${DateFormat('MMM dd').format(endDate)}'
                              : DateFormat('hh:mm a').format(startDate),
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      if (location.isNotEmpty) ...[
                        Icon(Icons.location_on_rounded, size: 14, color: Colors.grey.shade500),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            location,
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (eventFor.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          Icon(Icons.people_rounded, size: 14, color: Colors.grey.shade500),
                          const SizedBox(width: 4),
                          Text(
                            eventFor,
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
}
