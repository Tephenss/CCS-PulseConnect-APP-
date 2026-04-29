import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/auth_service.dart';
import '../../utils/event_time_utils.dart';
import '../../utils/teacher_theme_utils.dart';
import '../../widgets/custom_loader.dart';

class TeacherProposalRequirementsPage extends StatefulWidget {
  final Map<String, dynamic> event;

  const TeacherProposalRequirementsPage({super.key, required this.event});

  @override
  State<TeacherProposalRequirementsPage> createState() =>
      _TeacherProposalRequirementsPageState();
}

class _TeacherProposalRequirementsPageState
    extends State<TeacherProposalRequirementsPage> {
  final _supabase = Supabase.instance.client;
  final _authService = AuthService();
  final _picker = ImagePicker();
  Timer? _refreshTimer;

  String _teacherId = '';
  String _proposalStage = 'pending_requirements';
  bool _isLoading = true;
  bool _isUploading = false;
  bool _isSubmitting = false;
  bool _requirementsFeatureUnavailable = false;
  String? _errorMessage;
  String? _uploadingRequirementId;

  List<Map<String, dynamic>> _requirements = <Map<String, dynamic>>[];
  Map<String, Map<String, dynamic>> _submissionsByRequirement =
      <String, Map<String, dynamic>>{};

  @override
  void initState() {
    super.initState();
    _proposalStage = _normalizeStage(widget.event['proposal_stage']);
    _loadData();
    _startAutoRefresh();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  String get _eventId => widget.event['id']?.toString() ?? '';

  String get _eventTitle =>
      widget.event['title']?.toString().trim().isNotEmpty == true
      ? widget.event['title'].toString().trim()
      : 'Pending proposal';

  int get _completedCount {
    var count = 0;
    for (final requirement in _requirements) {
      final requirementId = requirement['id']?.toString() ?? '';
      final submission = _submissionsByRequirement[requirementId];
      final hasUpload =
          submission != null &&
          ((submission['file_url']?.toString().trim().isNotEmpty ?? false) ||
              (submission['file_path']?.toString().trim().isNotEmpty ?? false));
      if (hasUpload) count += 1;
    }
    return count;
  }

  int get _progressPercent {
    if (_requirements.isEmpty) return 0;
    return ((_completedCount / _requirements.length) * 100).round();
  }

  bool get _canUpload =>
      _proposalStage == 'requirements_requested' ||
      (_proposalStage == 'pending_requirements' && _requirements.isNotEmpty);

  bool get _canSubmitForReview =>
      _proposalStage == 'requirements_requested' && _progressPercent == 100;

  String _normalizeStage(dynamic raw) {
    final value = raw?.toString().trim().toLowerCase() ?? '';
    switch (value) {
      case 'requirements_requested':
      case 'under_review':
      case 'approved':
        return value;
      default:
        return 'pending_requirements';
    }
  }

  bool _isMissingProposalSchemaError(Object error) {
    final message = error.toString().toLowerCase();
    final mentionsProposalTable =
        message.contains('event_proposal_requirements') ||
        message.contains('event_proposal_documents');
    final missingSchemaHint =
        message.contains('could not find the table') ||
        message.contains('schema cache') ||
        message.contains('does not exist');
    return mentionsProposalTable && missingSchemaHint;
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || _isLoading || _isUploading || _isSubmitting) return;
      if (_requirementsFeatureUnavailable || _proposalStage == 'approved') {
        return;
      }
      unawaited(_loadData(showLoading: false));
    });
  }

  Future<void> _loadData({bool showLoading = true}) async {
    if (_eventId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Missing event id.';
      });
      return;
    }

    if (showLoading && mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      final user = await _authService.getCurrentUser();
      if (user == null) {
        throw Exception('You must be logged in to manage proposal documents.');
      }

      final teacherId = user['id']?.toString() ?? '';
      final requirements = await _supabase
          .from('event_proposal_requirements')
          .select('id,event_id,code,label,sort_order,created_at')
          .eq('event_id', _eventId)
          .order('sort_order', ascending: true)
          .order('created_at', ascending: true);

      final documents = await _supabase
          .from('event_proposal_documents')
          .select(
            'id,event_id,requirement_id,teacher_id,file_name,file_path,file_url,mime_type,uploaded_at,updated_at',
          )
          .eq('event_id', _eventId)
          .eq('teacher_id', teacherId);

      final eventRefresh = await _supabase
          .from('events')
          .select(
            'id,status,proposal_stage,requirements_requested_at,requirements_submitted_at',
          )
          .eq('id', _eventId)
          .maybeSingle();
      final refreshedEvent = eventRefresh == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(eventRefresh);

      final submissionMap = <String, Map<String, dynamic>>{};
      for (final rawDocument in documents) {
        final document = Map<String, dynamic>.from(rawDocument);
        final requirementId = document['requirement_id']?.toString() ?? '';
        if (requirementId.isEmpty) continue;
        submissionMap[requirementId] = document;
      }

      if (!mounted) return;
      setState(() {
        _teacherId = teacherId;
        _requirements = requirements
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
        _submissionsByRequirement = submissionMap;
        _proposalStage = _normalizeStage(
          refreshedEvent['proposal_stage'] ?? widget.event['proposal_stage'],
        );
        _requirementsFeatureUnavailable = false;
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (error) {
      if (!mounted) return;
      if (_isMissingProposalSchemaError(error)) {
        setState(() {
          _isLoading = false;
          _requirementsFeatureUnavailable = true;
          _errorMessage = null;
        });
        return;
      }
      setState(() {
        _isLoading = false;
        _requirementsFeatureUnavailable = false;
        _errorMessage = error.toString();
      });
    }
  }

  Future<ImageSource?> _pickSource() async {
    return showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from gallery'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
            ],
          ),
        );
      },
    );
  }

  String _detectMimeType(String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    switch (extension) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      default:
        return 'image/jpeg';
    }
  }

  Future<void> _uploadRequirement(Map<String, dynamic> requirement) async {
    if (_teacherId.isEmpty || !_canUpload || _isUploading) return;

    final source = await _pickSource();
    if (source == null) return;

    final pickedFile = await _picker.pickImage(
      source: source,
      imageQuality: 88,
      maxWidth: 2000,
    );
    if (pickedFile == null) return;

    final file = File(pickedFile.path);
    final requirementId = requirement['id']?.toString() ?? '';
    if (requirementId.isEmpty) return;

    setState(() {
      _isUploading = true;
      _uploadingRequirementId = requirementId;
    });

    try {
      final extension = path.extension(file.path).toLowerCase().replaceFirst('.', '');
      final safeExtension = extension.isEmpty ? 'jpg' : extension;
      final storagePath =
          '$_teacherId/$_eventId/$requirementId-${DateTime.now().millisecondsSinceEpoch}.$safeExtension';

      await _supabase.storage.from('proposal-documents').upload(
        storagePath,
        file,
        fileOptions: FileOptions(
          cacheControl: '0',
          upsert: true,
          contentType: _detectMimeType(file.path),
        ),
      );

      final publicUrl =
          _supabase.storage.from('proposal-documents').getPublicUrl(storagePath);

      await _supabase.from('event_proposal_documents').upsert(
        {
          'event_id': _eventId,
          'requirement_id': requirementId,
          'teacher_id': _teacherId,
          'file_name': path.basename(file.path),
          'file_path': storagePath,
          'file_url': publicUrl,
          'mime_type': _detectMimeType(file.path),
          'admin_visible': false,
          'visible_at': null,
          'uploaded_at': DateTime.now().toUtc().toIso8601String(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'requirement_id,teacher_id',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Requirement uploaded successfully.')),
      );
      await _loadData();
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
        });
      }
    }
  }

  Future<void> _submitForReview() async {
    if (!_canSubmitForReview || _isSubmitting) return;

    setState(() => _isSubmitting = true);
    try {
      final nowIso = DateTime.now().toUtc().toIso8601String();

      await _supabase
          .from('event_proposal_documents')
          .update({
            'admin_visible': true,
            'visible_at': nowIso,
            'updated_at': nowIso,
          })
          .eq('event_id', _eventId)
          .eq('teacher_id', _teacherId);

      await _supabase
          .from('events')
          .update({
            'proposal_stage': 'under_review',
            'requirements_submitted_at': nowIso,
            'updated_at': nowIso,
          })
          .eq('id', _eventId);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Proposal submitted for admin review.')),
      );
      await _loadData();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Submit failed: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _viewUploadedRequirement(Map<String, dynamic> requirement) async {
    final requirementId = requirement['id']?.toString() ?? '';
    final submission = _submissionsByRequirement[requirementId];
    final fileUrl = submission?['file_url']?.toString().trim() ?? '';
    final label = requirement['label']?.toString().trim().isNotEmpty == true
        ? requirement['label'].toString().trim()
        : (requirement['code']?.toString().trim().isNotEmpty == true
              ? requirement['code'].toString().trim()
              : 'Uploaded document');

    if (fileUrl.isEmpty || !mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.white,
          insetPadding: const EdgeInsets.all(20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
                  child: Row(
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
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: InteractiveViewer(
                      minScale: 0.8,
                      maxScale: 4,
                      child: Image.network(
                        fileUrl,
                        fit: BoxFit.contain,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return const SizedBox(
                            height: 280,
                            child: Center(child: CircularProgressIndicator()),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return const SizedBox(
                            height: 220,
                            child: Center(
                              child: Text(
                                'Unable to preview this uploaded file.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFF6B7280),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _stageColor() {
    switch (_proposalStage) {
      case 'requirements_requested':
        return const Color(0xFFD97706);
      case 'under_review':
        return const Color(0xFF7C3AED);
      case 'approved':
        return const Color(0xFF059669);
      default:
        return const Color(0xFFB45309);
    }
  }

  String _stageLabel() {
    switch (_proposalStage) {
      case 'requirements_requested':
        return 'Requirements Requested';
      case 'under_review':
        return 'Under Review';
      case 'approved':
        return 'Approved';
      default:
        return 'Pending Requirements';
    }
  }

  String _subtitleText() {
    if (_requirementsFeatureUnavailable) {
      return 'This proposal is still pending, but the document upload workflow is not enabled on the current server setup yet.';
    }
    if (_proposalStage == 'pending_requirements' && _requirements.isEmpty) {
      return 'Admin has not listed the required documents yet.';
    }
    if (_proposalStage == 'requirements_requested' && _requirements.isEmpty) {
      return 'Admin already requested documents for this proposal.';
    }
    if (_proposalStage == 'under_review') {
      return 'Everything has been submitted. Waiting for final admin review.';
    }
    if (_proposalStage == 'approved') {
      return 'Proposal documents are complete. Waiting for admin publish.';
    }
    return 'Upload every requested document to unlock final review.';
  }

  @override
  Widget build(BuildContext context) {
    final startDate = parseStoredEventDateTime(widget.event['start_at']);
    final endDate = parseStoredEventDateTime(widget.event['end_at']);
    final stageColor = _stageColor();

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: AppBar(
        title: const Text('Proposal Requirements'),
        backgroundColor: TeacherThemeUtils.primary,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: PulseConnectLoader())
          : _requirementsFeatureUnavailable
          ? SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.04),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF3C7),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              'Pending Setup',
                              style: TextStyle(
                                color: Color(0xFF92400E),
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _eventTitle,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF111827),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Proposal document uploads are not available on this server yet. Ask the admin to finish the proposal requirements setup, then reopen this page.',
                            style: TextStyle(
                              fontSize: 14,
                              color: Color(0xFF6B7280),
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 18),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () {
                                setState(() => _isLoading = true);
                                _loadData();
                              },
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('Retry'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: TeacherThemeUtils.primary,
                                side: BorderSide(
                                  color: TeacherThemeUtils.primary.withValues(
                                    alpha: 0.25,
                                  ),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )
          : _errorMessage != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 14,
                  ),
                ),
              ),
            )
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.04),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: stageColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              _stageLabel(),
                              style: TextStyle(
                                color: stageColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            _eventTitle,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF111827),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _subtitleText(),
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF6B7280),
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _metaChip(
                                Icons.event_outlined,
                                startDate != null
                                    ? DateFormat(
                                        'MMM d, yyyy • h:mm a',
                                      ).format(startDate)
                                    : 'Schedule unavailable',
                              ),
                              _metaChip(
                                Icons.flag_outlined,
                                widget.event['event_type']?.toString() ??
                                    'Event',
                              ),
                              if (endDate != null)
                                _metaChip(
                                  Icons.schedule_outlined,
                                  'Ends ${DateFormat('MMM d • h:mm a').format(endDate)}',
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (_requirements.isEmpty) ...[
                      const SizedBox(height: 18),
                      _buildWaitingCard()
                    ] else ...[
                      const SizedBox(height: 18),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 24,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    'Requirement Progress',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF111827),
                                    ),
                                  ),
                                ),
                                Text(
                                  '$_completedCount/${_requirements.length}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF6B7280),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: 12,
                                value: _progressPercent / 100,
                                backgroundColor: const Color(0xFFE5E7EB),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  TeacherThemeUtils.primary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '$_progressPercent% complete',
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      ..._requirements.map(_buildRequirementCard),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _canSubmitForReview && !_isSubmitting
                            ? _submitForReview
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: TeacherThemeUtils.primary,
                          disabledBackgroundColor: const Color(0xFFD1D5DB),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: _isSubmitting
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : Text(
                                _proposalStage == 'under_review'
                                    ? 'Submitted for Review'
                                    : _proposalStage == 'approved'
                                    ? 'Approved'
                                    : _proposalStage == 'pending_requirements'
                                    ? 'Waiting for Admin Requirements'
                                    : 'Submit for Review',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _metaChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF6B7280)),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF374151),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _proposalStage == 'requirements_requested'
                ? 'Requirements requested'
                : 'No requirements yet',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _proposalStage == 'requirements_requested'
                ? 'The admin already sent the document request for this proposal. Reopen the page after the requirement list becomes available.'
                : 'This proposal is still waiting for the admin to list the required documents. Once that happens, the upload checklist will appear here.',
            style: TextStyle(
              fontSize: 13,
              color: Color(0xFF6B7280),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequirementCard(Map<String, dynamic> requirement) {
    final requirementId = requirement['id']?.toString() ?? '';
    final isUploadingThisRequirement =
        _isUploading && _uploadingRequirementId == requirementId;
    final submission = _submissionsByRequirement[requirementId];
    final hasUpload =
        submission != null &&
        ((submission['file_url']?.toString().trim().isNotEmpty ?? false) ||
            (submission['file_path']?.toString().trim().isNotEmpty ?? false));
    final code = requirement['code']?.toString().trim().isNotEmpty == true
        ? requirement['code'].toString().trim()
        : 'DOC';
    final label = requirement['label']?.toString().trim().isNotEmpty == true
        ? requirement['label'].toString().trim()
        : code;
    final uploadedAt = submission == null
        ? null
        : DateTime.tryParse(
            submission['updated_at']?.toString() ??
                submission['uploaded_at']?.toString() ??
                '',
          )?.toLocal();
    final fileUrl = submission?['file_url']?.toString().trim() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  code,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF374151),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: hasUpload
                      ? const Color(0xFFD1FAE5)
                      : const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  hasUpload ? 'Uploaded' : 'Pending',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: hasUpload
                        ? const Color(0xFF047857)
                        : const Color(0xFF92400E),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            hasUpload
                ? 'Latest file: ${submission['file_name'] ?? 'Uploaded file'}'
                : 'Upload this document to move the proposal toward final review.',
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF6B7280),
              height: 1.4,
            ),
          ),
          if (uploadedAt != null) ...[
            const SizedBox(height: 6),
            Text(
              'Updated ${DateFormat('MMM d, yyyy • h:mm a').format(uploadedAt)}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF4B5563),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              if (hasUpload && fileUrl.isNotEmpty) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _viewUploadedRequirement(requirement),
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('View Upload'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF374151),
                      side: const BorderSide(color: Color(0xFFD1D5DB)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _canUpload && !_isUploading
                      ? () => _uploadRequirement(requirement)
                      : null,
                  icon: isUploadingThisRequirement
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          hasUpload ? Icons.refresh_rounded : Icons.upload_file,
                        ),
                  label: Text(
                    _proposalStage == 'under_review'
                        ? 'Submitted to admin'
                        : _proposalStage == 'approved'
                        ? 'Approved'
                        : hasUpload
                        ? 'Replace Upload'
                        : 'Upload Document',
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: TeacherThemeUtils.primary,
                    side: BorderSide(
                      color: TeacherThemeUtils.primary.withValues(alpha: 0.25),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
