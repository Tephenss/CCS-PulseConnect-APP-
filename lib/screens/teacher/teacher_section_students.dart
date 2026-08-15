import 'package:flutter/material.dart';

import '../../services/event_service.dart';
import '../../services/mobile_backend_service.dart';
import '../../utils/teacher_theme_utils.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/safe_circle_avatar.dart';

class TeacherSectionStudents extends StatefulWidget {
  final String sectionId;
  final String sectionName;

  const TeacherSectionStudents({
    super.key,
    required this.sectionId,
    required this.sectionName,
  });

  @override
  State<TeacherSectionStudents> createState() => _TeacherSectionStudentsState();
}
class _TeacherSectionStudentsState extends State<TeacherSectionStudents> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _students = [];
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchStudents();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchStudents() async {
    try {
      if (!MobileBackendService.isConfigured) {
        throw Exception(
          'Hosted backend is not configured. Student lists load through the server.',
        );
      }

      final res = await MobileBackendService().getTeacherBlockStudentsSecure(
        sectionId: widget.sectionId,
      );
      if (res['ok'] != true) {
        throw Exception(res['error']?.toString() ?? 'Failed to load students.');
      }

      final rows = res['students'] is List
          ? List<Map<String, dynamic>>.from(
              (res['students'] as List).whereType<Map>().map(
                (row) => Map<String, dynamic>.from(row),
              ),
            )
          : <Map<String, dynamic>>[];

      final eventService = EventService();
      for (final student in rows) {
        final photo = (student['photo_url']?.toString() ?? '').trim();
        if (photo.isEmpty) continue;
        student['photo_url'] = await eventService.resolveAvatarDisplayUrl(photo);
      }

      if (!mounted) return;
      setState(() {
        _students = rows;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnackBar.error(context, 'Failed to load students: $e');
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: Text(widget.sectionName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Colors.white)),
        backgroundColor: TeacherThemeUtils.primary,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: TeacherThemeUtils.dark,
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 4)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Student Masterlist',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  'Showing students with PulseConnect accounts in ${widget.sectionName}.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 14),
                ),
                const SizedBox(height: 20),
                // Search Bar
                TextField(
                  controller: _searchController,
                  onChanged: (val) => setState(() => _searchQuery = val),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search by name, student no, or email...',
                    hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                    prefixIcon: Icon(Icons.search_rounded, color: Colors.white.withValues(alpha: 0.7)),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.15),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _fetchStudents,
              color: TeacherThemeUtils.primary,
              child: Builder(
                builder: (context) {
                  final query = _searchQuery.trim().toLowerCase();
                  final filteredStudents = _students.where((s) {
                    if (query.isEmpty) return true;
                    final name = (s['name']?.toString() ?? '').toLowerCase();
                    final studentNo =
                        (s['student_id']?.toString() ?? '').toLowerCase();
                    final email = (s['email']?.toString() ?? '').toLowerCase();
                    return name.contains(query) ||
                        studentNo.contains(query) ||
                        email.contains(query);
                  }).toList();

                  if (_isLoading) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(
                          height: 320,
                          child: Center(child: PulseConnectLoader()),
                        ),
                      ],
                    );
                  }

                  if (filteredStudents.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: 320,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.person_search_rounded, size: 64, color: Colors.grey.shade300),
                                const SizedBox(height: 16),
                                const Text(
                                  'No students found',
                                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1F2937)),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _students.isEmpty
                                      ? 'No students have created an account in this block yet.'
                                      : 'No student matches your search.',
                                  style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  }

                  return ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(24),
                    itemCount: filteredStudents.length,
                    itemBuilder: (context, index) {
                      final student = filteredStudents[index];
                      final name = (student['name']?.toString() ?? '').trim();
                      final photoUrl = (student['photo_url']?.toString() ?? '').trim();

                      return Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.shade200),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 10, offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            SafeCircleAvatar(
                              size: 52,
                              imagePathOrUrl: photoUrl.isEmpty ? null : photoUrl,
                              fallbackText: (name.isNotEmpty ? name[0] : 'S')
                                  .toUpperCase(),
                              backgroundColor: TeacherThemeUtils.primary.withValues(
                                alpha: 0.1,
                              ),
                              textColor: TeacherThemeUtils.primary,
                              textStyle: const TextStyle(
                                color: TeacherThemeUtils.primary,
                                fontWeight: FontWeight.w800,
                                fontSize: 22,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name.isEmpty ? 'Student' : name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16,
                                      color: Color(0xFF1F2937),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      const Icon(Icons.badge_rounded, size: 14, color: Colors.grey),
                                      const SizedBox(width: 4),
                                      Text(
                                        (student['student_id']?.toString() ?? '').trim().isEmpty
                                            ? 'No ID'
                                            : student['student_id'].toString(),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    (student['email']?.toString() ?? '').trim(),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w500,
                                      fontSize: 12,
                                      color: Colors.grey.shade500,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
