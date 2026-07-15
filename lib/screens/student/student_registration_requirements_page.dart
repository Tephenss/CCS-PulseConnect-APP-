import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/event_service.dart';
import '../../services/event_live_service.dart';
import '../../utils/course_theme_utils.dart';
import '../../widgets/custom_loader.dart';

class StudentRegistrationRequirementsPage extends StatefulWidget {
  final String eventId;
  final Map<String, dynamic> event;

  const StudentRegistrationRequirementsPage({
    super.key,
    required this.eventId,
    required this.event,
  });

  @override
  State<StudentRegistrationRequirementsPage> createState() =>
      _StudentRegistrationRequirementsPageState();
}

class _StudentRegistrationRequirementsPageState
    extends State<StudentRegistrationRequirementsPage> {
  final _eventService = EventService();
  StreamSubscription<String>? _eventLiveSubscription;

  String _studentId = '';
  bool _isLoading = true;
  bool _isUploading = false;
  bool _isSubmitting = false;
  int _uploadProgress = 0;
  String? _errorMessage;
  String? _uploadingRequirementId;
  String _status = '';
  String _declineReason = '';
  String _statusMessage = '';

  List<Map<String, dynamic>> _requirements = <Map<String, dynamic>>[];
  Map<String, Map<String, dynamic>> _documentsByRequirement =
      <String, Map<String, dynamic>>{};

  Color _studentPrimary(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
  Color _studentDark(BuildContext context) =>
      CourseThemeUtils.studentDarkFromPrimary(_studentPrimary(context));

  @override
  void initState() {
    super.initState();
    _eventLiveSubscription = EventLiveService.instance.changes.listen((reason) {
      if (!mounted) return;
      final eventId = widget.eventId;
      final relevant = reason.contains(eventId) ||
          reason.contains('student_submissions') ||
          reason.contains('student_requirements') ||
          reason.startsWith('push:student_requirements');
      if (!relevant) return;

      if (reason.contains('student_requirements_approved') &&
          reason.contains(eventId)) {
        setState(() {
          _status = 'approved';
          _statusMessage = 'Your documents were approved. You may now register.';
          _declineReason = '';
        });
      } else if (reason.contains('student_requirements_declined') &&
          reason.contains(eventId)) {
        setState(() {
          _status = 'declined';
          _statusMessage =
              'Your documents were declined. Please update and resubmit.';
        });
      }

      _eventService.clearStudentRequirementsCache(eventId);
      unawaited(_loadData(silent: true));
    });
    _loadData();
  }

  @override
  void dispose() {
    _eventLiveSubscription?.cancel();
    super.dispose();
  }

  String get _eventTitle =>
      widget.event['title']?.toString().trim().isNotEmpty == true
      ? widget.event['title'].toString().trim()
      : 'Event';

  int get _completedCount {
    var count = 0;
    for (final requirement in _requirements) {
      final requirementId = requirement['id']?.toString() ?? '';
      final document = _documentsByRequirement[requirementId];
      final hasUpload = document != null &&
          ((document['file_url']?.toString().trim().isNotEmpty ?? false) ||
              (document['file_path']?.toString().trim().isNotEmpty ?? false));
      if (hasUpload) count += 1;
    }
    return count;
  }

  int get _progressPercent {
    if (_requirements.isEmpty) return 0;
    return ((_completedCount / _requirements.length) * 100).round();
  }

  bool get _canUpload =>
      _status != 'pending_review' && _status != 'approved';

  bool get _canSubmitForReview =>
      _canUpload &&
      _completedCount == _requirements.length &&
      _requirements.isNotEmpty;

  Future<void> _loadData({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      _studentId = prefs.getString('user_id') ?? '';
      if (_studentId.isEmpty) {
        throw Exception('Student session not found.');
      }

      final info = await _eventService.getStudentRequirementsInfo(
        widget.eventId,
        _studentId,
      );
      if (info['ok'] != true) {
        throw Exception(
          info['error']?.toString() ?? 'Unable to load requirements.',
        );
      }

      final requirements = List<Map<String, dynamic>>.from(
        info['requirements'] as List? ?? const [],
      );
      final documents = List<Map<String, dynamic>>.from(
        info['documents'] as List? ?? const [],
      );
      final access = info['access'] is Map
          ? Map<String, dynamic>.from(info['access'] as Map)
          : <String, dynamic>{};

      final mappedDocuments = <String, Map<String, dynamic>>{};
      for (final document in documents) {
        final requirementId = document['requirement_id']?.toString() ?? '';
        if (requirementId.isNotEmpty) {
          mappedDocuments[requirementId] = Map<String, dynamic>.from(document);
        }
      }

      if (!mounted) return;
      setState(() {
        _requirements = requirements;
        _documentsByRequirement = mappedDocuments;
        _status = (access['status']?.toString() ?? '').trim().toLowerCase();
        _declineReason = (access['decline_reason']?.toString() ?? '').trim();
        _statusMessage = (access['message']?.toString() ?? '').trim();
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
        _isLoading = false;
      });
    }
  }

  String _detectMimeType(String filePath) {
    switch (path.extension(filePath).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.pdf':
        return 'application/pdf';
      case '.doc':
        return 'application/msword';
      case '.docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      default:
        return 'image/jpeg';
    }
  }

  Future<Map<String, dynamic>> _trackUploadProgress(
    Future<Map<String, dynamic>> uploadFuture,
  ) async {
    var progress = 1;
    if (mounted) {
      setState(() => _uploadProgress = progress);
    }

    Timer? timer;
    timer = Timer.periodic(const Duration(milliseconds: 90), (tick) {
      if (!mounted) {
        tick.cancel();
        return;
      }
      if (progress >= 90) return;
      progress += progress < 35
          ? 6
          : progress < 65
          ? 4
          : 2;
      if (progress > 90) progress = 90;
      setState(() => _uploadProgress = progress);
    });

    try {
      final result = await uploadFuture;
      timer.cancel();
      if (mounted) {
        setState(() => _uploadProgress = 100);
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      return result;
    } catch (error) {
      timer.cancel();
      rethrow;
    }
  }

  void _applyUploadedDocument(
    String requirementId,
    Map<String, dynamic> upload,
    String fileName,
  ) {
    final rawDoc = upload['document'];
    if (rawDoc is Map) {
      setState(() {
        _documentsByRequirement[requirementId] =
            Map<String, dynamic>.from(rawDoc);
      });
      return;
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    setState(() {
      _documentsByRequirement[requirementId] = {
        'requirement_id': requirementId,
        'file_name': fileName,
        'file_url': upload['file_url']?.toString() ?? '',
        'file_path': upload['file_path']?.toString() ?? '',
        'uploaded_at': nowIso,
        'updated_at': nowIso,
      };
    });
  }

  Future<void> _pickAndUpload(Map<String, dynamic> requirement) async {
    if (!_canUpload || _isUploading) return;

    final requirementId = requirement['id']?.toString() ?? '';
    if (requirementId.isEmpty) return;

    setState(() {
      _isUploading = true;
      _uploadingRequirementId = requirementId;
      _uploadProgress = 0;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'doc', 'docx', 'jpg', 'jpeg', 'png', 'webp'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final picked = result.files.first;
      final bytes = picked.bytes;
      if (bytes == null || bytes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to read the selected file.')),
        );
        return;
      }

      final fileName = picked.name.trim().isNotEmpty
          ? picked.name.trim()
          : 'document.pdf';

      final upload = await _trackUploadProgress(
        _eventService.uploadStudentRequirementDocument(
          eventId: widget.eventId,
          requirementId: requirementId,
          studentId: _studentId,
          bytes: bytes,
          fileName: fileName,
          mimeType: _detectMimeType(fileName),
        ),
      );

      if (upload['ok'] != true) {
        throw Exception(upload['error']?.toString() ?? 'Upload failed.');
      }

      if (!mounted) return;
      _applyUploadedDocument(requirementId, upload, fileName);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Document uploaded successfully.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadingRequirementId = null;
          _uploadProgress = 0;
        });
      }
    }
  }

  Future<void> _submitForReview() async {
    if (!_canSubmitForReview || _isSubmitting) return;

    setState(() => _isSubmitting = true);
    try {
      final result = await _eventService.submitStudentRequirementsForReview(
        widget.eventId,
        _studentId,
      );
      if (result['ok'] != true && result['already_approved'] != true) {
        throw Exception(result['error']?.toString() ?? 'Submit failed.');
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Documents submitted for review. You can register after approval.',
          ),
        ),
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  String _statusLabel() {
    switch (_status) {
      case 'pending_review':
        return 'Under Review';
      case 'approved':
        return 'Approved';
      case 'declined':
        return 'Declined';
      case 'ready_to_submit':
        return 'Ready to Submit';
      default:
        return 'Incomplete';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: _studentDark(context),
        foregroundColor: Colors.white,
        title: const Text(
          'Submit Requirements',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: _isLoading
          ? const Center(child: PulseConnectLoader())
          : _errorMessage != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF6B7280)),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [_studentDark(context), _studentPrimary(context)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _eventTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Upload the required PDF or Word files. Submitting does not register you yet — wait for teacher approval first.',
                        style: TextStyle(color: Colors.white70, height: 1.4),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: 8,
                                value: _requirements.isEmpty
                                    ? 0
                                    : _completedCount / _requirements.length,
                                backgroundColor: Colors.white24,
                                color: const Color(0xFFD4A843),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '$_progressPercent%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _status == 'declined'
                            ? Icons.error_outline_rounded
                            : Icons.assignment_turned_in_outlined,
                        color: _studentPrimary(context),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Status: ${_statusLabel()}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF111827),
                              ),
                            ),
                            if (_statusMessage.isNotEmpty)
                              Text(
                                _statusMessage,
                                style: const TextStyle(
                                  color: Color(0xFF6B7280),
                                  height: 1.35,
                                ),
                              ),
                            if (_declineReason.isNotEmpty)
                              Text(
                                'Reason: $_declineReason',
                                style: const TextStyle(
                                  color: Color(0xFFB91C1C),
                                  height: 1.35,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ..._requirements.map(_buildRequirementCard),
              ],
            ),
      bottomNavigationBar: _isLoading || _errorMessage != null
          ? null
          : Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 16,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _canSubmitForReview && !_isSubmitting
                      ? _submitForReview
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _studentPrimary(context),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFFE5E7EB),
                    disabledForegroundColor: const Color(0xFF9CA3AF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: _isSubmitting
                      ? const PulseConnectLoader(size: 14, color: Colors.white)
                      : Text(
                          _status == 'declined'
                              ? 'Resubmit for Review'
                              : 'Submit for Review',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                ),
              ),
            ),
    );
  }

  Widget _buildRequirementCard(Map<String, dynamic> requirement) {
    final requirementId = requirement['id']?.toString() ?? '';
    final label = requirement['label']?.toString().trim().isNotEmpty == true
        ? requirement['label'].toString().trim()
        : 'Requirement';
    final document = _documentsByRequirement[requirementId];
    final hasUpload = document != null &&
        ((document['file_url']?.toString().trim().isNotEmpty ?? false) ||
            (document['file_path']?.toString().trim().isNotEmpty ?? false));
    final isUploadingThis =
        _isUploading && _uploadingRequirementId == requirementId;
    final uploadedAtRaw = document?['uploaded_at']?.toString();
    DateTime? uploadedAt;
    if (uploadedAtRaw != null && uploadedAtRaw.isNotEmpty) {
      uploadedAt = DateTime.tryParse(uploadedAtRaw)?.toLocal();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: hasUpload
              ? const Color(0xFF86EFAC)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: hasUpload
                      ? const Color(0xFFECFDF5)
                      : const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  hasUpload ? 'Uploaded' : 'Required',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: hasUpload
                        ? const Color(0xFF047857)
                        : const Color(0xFFEA580C),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Accepted: PDF, DOC, DOCX, JPG, PNG',
            style: TextStyle(color: Color(0xFF6B7280), fontSize: 12),
          ),
          if (hasUpload) ...[
            const SizedBox(height: 8),
            Text(
              document['file_name']?.toString() ?? 'Uploaded file',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFF374151),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (uploadedAt != null) ...[
            const SizedBox(height: 4),
            Text(
              'Updated ${DateFormat('MMM d, yyyy • h:mm a').format(uploadedAt)}',
              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          if (isUploadingThis) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Uploading file...',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: _studentPrimary(context),
                    ),
                  ),
                ),
                Text(
                  '$_uploadProgress%',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _studentPrimary(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 10,
                value: _uploadProgress <= 0 ? null : _uploadProgress / 100,
                backgroundColor: const Color(0xFFE5E7EB),
                color: _studentPrimary(context),
              ),
            ),
          ] else
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _canUpload ? () => _pickAndUpload(requirement) : null,
                icon: Icon(
                  hasUpload
                      ? Icons.refresh_rounded
                      : Icons.upload_file_rounded,
                  size: 20,
                ),
                label: Text(
                  hasUpload ? 'Replace File' : 'Upload PDF or Word',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
