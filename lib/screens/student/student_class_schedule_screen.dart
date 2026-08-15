import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/auth_service.dart';
import '../../services/native_document_picker.dart';
import '../../utils/class_schedule_format.dart';
import '../../utils/course_theme_utils.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/custom_loader.dart';

class StudentClassScheduleScreen extends StatefulWidget {
  const StudentClassScheduleScreen({super.key});

  @override
  State<StudentClassScheduleScreen> createState() =>
      _StudentClassScheduleScreenState();
}

class _StudentClassScheduleScreenState extends State<StudentClassScheduleScreen> {
  final _authService = AuthService();
  List<Map<String, dynamic>> _subjects = [];
  bool _isLoading = true;
  bool _isUpdating = false;
  String? _error;
  String? _course;

  Color get _primary => CourseThemeUtils.studentPrimaryForCourse(_course);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final user = await _authService.getCurrentUser();
      final result = await _authService.fetchClassSchedule();
      if (!mounted) return;
      if (result['ok'] != true) {
        setState(() {
          _course = user?['course']?.toString();
          _isLoading = false;
          _error = result['error']?.toString() ?? 'Could not load class schedule.';
        });
        return;
      }
      setState(() {
        _course = user?['course']?.toString();
        _subjects = _asSubjectMaps(result['subjects']);
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Could not load class schedule.';
      });
    }
  }

  Future<void> _updateSchedule() async {
    if (_isUpdating || _isLoading) return;
    setState(() => _isUpdating = true);
    try {
      String? fileName;
      String? filePath;
      List<int>? bytes;
      if (Platform.isAndroid) {
        final native = await NativeDocumentPicker.pickAndroid(
          maxBytes: 8 * 1024 * 1024,
        );
        if (native == null) {
          if (mounted) setState(() => _isUpdating = false);
          return;
        }
        fileName = native.name;
        filePath = native.path;
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
          allowMultiple: false,
          withData: !Platform.isIOS,
        );
        if (result == null || result.files.isEmpty) {
          if (mounted) setState(() => _isUpdating = false);
          return;
        }
        final picked = result.files.first;
        fileName = picked.name;
        filePath = picked.path;
        bytes = picked.bytes;
      }
      if (!(fileName ?? '').toLowerCase().endsWith('.pdf')) {
        if (!mounted) return;
        setState(() => _isUpdating = false);
        AppSnackBar.error(context, 'Please choose the PDF registration form.');
        return;
      }
      final result = await _authService.uploadClassSchedule(
        fileName: fileName ?? 'registration.pdf',
        filePath: filePath,
        bytes: bytes,
      );
      if (!mounted) return;
      if (result['ok'] == true) {
        final subjects = _asSubjectMaps(result['subjects']);
        setState(() {
          _subjects = subjects;
          _isUpdating = false;
          _error = null;
        });
        AppSnackBar.info(
          context,
          'Class schedule updated (${subjects.length} subject${subjects.length == 1 ? '' : 's'}).',
        );
      } else {
        setState(() => _isUpdating = false);
        AppSnackBar.error(
          context,
          result['error']?.toString() ?? 'Could not update class schedule.',
        );
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _isUpdating = false);
      final message = (error.message ?? error.code).trim();
      AppSnackBar.error(
        context,
        message.isEmpty ? 'Unable to open file picker.' : message,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _isUpdating = false);
      AppSnackBar.error(context, 'Unable to update class schedule: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F4F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF111827)),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        centerTitle: false,
        title: const Text(
          'Class schedule',
          style: TextStyle(
            color: Color(0xFF111827),
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: Color(0xFFE5E7EB)),
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(child: _buildBody()),
              _buildUpdateBar(),
            ],
          ),
          if (_isUpdating)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.28),
                child: Center(
                  child: PulseConnectLoader(size: 22, color: _primary),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildUpdateBar() {
    return Container(
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: (_isUpdating || _isLoading) ? null : _updateSchedule,
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _primary.withValues(alpha: 0.45),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(
                _isUpdating ? 'Updating…' : 'Update your Schedule',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(child: PulseConnectLoader(size: 22, color: _primary));
    }
    if (_error != null && _subjects.isEmpty) {
      return _emptyState(
        icon: Icons.wifi_off_rounded,
        message: _error!,
        action: 'Try again',
        onAction: _load,
      );
    }
    if (_subjects.isEmpty) {
      return _emptyState(
        icon: Icons.calendar_month_rounded,
        message: 'No class schedule uploaded yet.\nTap Update your Schedule to upload your registration form.',
      );
    }
    return RefreshIndicator(
      color: _primary,
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        itemCount: _subjects.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          if (index == 0) {
            return Text(
              '${_subjects.length} subject${_subjects.length == 1 ? '' : 's'}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF6B7280),
                letterSpacing: 0.6,
              ),
            );
          }
          return _SubjectCard(
            subject: _subjects[index - 1],
            primary: _primary,
          );
        },
      ),
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String message,
    String? action,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: _primary, size: 28),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
            if (action != null && onAction != null) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: onAction,
                child: Text(
                  action,
                  style: TextStyle(color: _primary, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SubjectCard extends StatelessWidget {
  const _SubjectCard({
    required this.subject,
    required this.primary,
  });

  final Map<String, dynamic> subject;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    final code = (subject['course_code']?.toString() ?? '').trim();
    final desc = (subject['course_description']?.toString() ?? '').trim();
    final inst = (subject['instructor']?.toString() ?? '').trim();
    final meetings = classScheduleMeetingRows(subject);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: primary),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (code.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                code,
                                style: TextStyle(
                                  color: primary,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          const Spacer(),
                          if (inst.isNotEmpty)
                            Flexible(
                              child: Text(
                                inst,
                                textAlign: TextAlign.right,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF6B7280),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (desc.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          desc,
                          style: const TextStyle(
                            color: Color(0xFF111827),
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            height: 1.3,
                          ),
                        ),
                      ],
                      if (meetings.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        ...meetings.map(
                          (row) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 46,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF4F4F5),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    row.day,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Color(0xFF111827),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    row.time,
                                    style: const TextStyle(
                                      color: Color(0xFF374151),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
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

class _MeetingRow {
  const _MeetingRow({required this.day, required this.time});
  final String day;
  final String time;
}

List<Map<String, dynamic>> _asSubjectMaps(dynamic raw) {
  final subjects = <Map<String, dynamic>>[];
  if (raw is! List) return subjects;
  for (final row in raw) {
    if (row is Map<String, dynamic>) {
      subjects.add(row);
    } else if (row is Map) {
      subjects.add(Map<String, dynamic>.from(row));
    }
  }
  return subjects;
}

List<_MeetingRow> classScheduleMeetingRows(Map<String, dynamic> subject) {
  final meetings = subject['meetings'];
  final rows = <_MeetingRow>[];
  if (meetings is List && meetings.isNotEmpty) {
    for (final item in meetings) {
      if (item is! Map) continue;
      final day = classScheduleDayLabel(item['day']?.toString() ?? '');
      final time = classScheduleFormatTimeRange(item['time']?.toString() ?? '');
      if (day.isEmpty && time.isEmpty) continue;
      rows.add(_MeetingRow(day: day.isEmpty ? '—' : day, time: time));
    }
    if (rows.isNotEmpty) return rows;
  }

  final days = (subject['days']?.toString() ?? '')
      .split(RegExp(r'\s*,\s*'))
      .where((d) => d.trim().isNotEmpty)
      .toList();
  final times = (subject['time_label']?.toString() ?? '')
      .split(RegExp(r'\s*;\s*'))
      .where((t) => t.trim().isNotEmpty)
      .toList();
  final count = days.length > times.length ? days.length : times.length;
  for (var i = 0; i < count; i++) {
    final day = i < days.length ? classScheduleDayLabel(days[i]) : '—';
    final time = i < times.length
        ? classScheduleFormatTimeRange(times[i])
        : (times.isNotEmpty ? classScheduleFormatTimeRange(times.first) : '');
    rows.add(_MeetingRow(day: day.isEmpty ? '—' : day, time: time));
  }
  return rows;
}
