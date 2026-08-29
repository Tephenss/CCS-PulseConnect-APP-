import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../widgets/app_snackbar.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/event_service.dart';
import '../../services/event_live_service.dart';
import '../../services/native_document_picker.dart';
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

  static void clearPageCache([String? eventId]) {
    _StudentRegistrationRequirementsPageState.clearPageCache(eventId);
  }

  @override
  State<StudentRegistrationRequirementsPage> createState() =>
      _StudentRegistrationRequirementsPageState();
}

class _RequirementsPageSnapshot {
  final List<Map<String, dynamic>> requirements;
  final Map<String, Map<String, dynamic>> documentsByRequirement;
  final String status;
  final String declineReason;
  final String statusMessage;
  final DateTime cachedAt;

  const _RequirementsPageSnapshot({
    required this.requirements,
    required this.documentsByRequirement,
    required this.status,
    required this.declineReason,
    required this.statusMessage,
    required this.cachedAt,
  });
}

class _StudentRegistrationRequirementsPageState
    extends State<StudentRegistrationRequirementsPage>
    with WidgetsBindingObserver {
  static const _pendingPickRequirementKey = 'pending_student_req_upload_id';
  static const _pendingPickEventKey = 'pending_student_req_upload_event';

  static final Map<String, _RequirementsPageSnapshot> _pageCache = {};
  static const Duration _pageCacheTtl = Duration(minutes: 5);

  static void clearPageCache([String? eventId]) {
    if (eventId == null || eventId.trim().isEmpty) {
      _pageCache.clear();
      return;
    }
    final suffix = '|${eventId.trim()}';
    _pageCache.removeWhere((key, _) => key.endsWith(suffix));
  }

  static String _pageCacheKey(String eventId, String userId) {
    final event = eventId.trim();
    final user = userId.trim();
    if (event.isEmpty) return '';
    if (user.isEmpty) return event;
    return '$user|$event';
  }

  final _eventService = EventService();
  StreamSubscription<String>? _eventLiveSubscription;

  String _studentId = '';
  bool _isLoading = true;
  bool _isUploading = false;
  bool _isPickingFile = false;
  bool _isSubmitting = false;
  bool _recoveringPendingPick = false;
  int _uploadProgress = 0;
  String? _errorMessage;
  String? _uploadingRequirementId;
  String? _pickingRequirementId;
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
    WidgetsBinding.instance.addObserver(this);
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
      unawaited(_loadData(silent: _requirements.isNotEmpty));
    });
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await _hydrateFromCache();
    final hadCache = _requirements.isNotEmpty;
    await _loadData(silent: hadCache);
    await _recoverPendingPickIfNeeded();
  }

  Future<void> _hydrateFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    if (userId.isEmpty || !mounted) return;

    _studentId = userId;
    final cacheKey = _pageCacheKey(widget.eventId, userId);
    final cached = cacheKey.isEmpty ? null : _pageCache[cacheKey];
    if (cached == null ||
        DateTime.now().difference(cached.cachedAt) > _pageCacheTtl) {
      return;
    }

    setState(() {
      _requirements = List<Map<String, dynamic>>.from(
        cached.requirements.map((row) => Map<String, dynamic>.from(row)),
      );
      _documentsByRequirement = cached.documentsByRequirement.map(
        (key, value) => MapEntry(key, Map<String, dynamic>.from(value)),
      );
      _status = cached.status;
      _declineReason = cached.declineReason;
      _statusMessage = cached.statusMessage;
      _isLoading = false;
      _errorMessage = null;
    });
  }

  void _storePageCache() {
    if (_studentId.trim().isEmpty || _requirements.isEmpty) return;
    final cacheKey = _pageCacheKey(widget.eventId, _studentId);
    if (cacheKey.isEmpty) return;
    _pageCache[cacheKey] = _RequirementsPageSnapshot(
      requirements: _requirements
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false),
      documentsByRequirement: _documentsByRequirement.map(
        (key, value) => MapEntry(key, Map<String, dynamic>.from(value)),
      ),
      status: _status,
      declineReason: _declineReason,
      statusMessage: _statusMessage,
      cachedAt: DateTime.now(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventLiveSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_recoverPendingPickIfNeeded());
    }
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
      _storePageCache();
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
      _storePageCache();
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
    _storePageCache();
  }

  static const _allowedExtensions = <String>{
    'pdf',
    'doc',
    'docx',
    'jpg',
    'jpeg',
    'png',
    'webp',
  };

  Future<Uint8List?> _readPickedBytes(PlatformFile picked) async {
    final inline = picked.bytes;
    if (inline != null && inline.isNotEmpty) {
      return Uint8List.fromList(inline);
    }

    final stream = picked.readStream;
    if (stream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (bytes.isNotEmpty) return bytes;
    }

    final filePath = picked.path;
    if (filePath != null && filePath.trim().isNotEmpty) {
      final file = File(filePath);
      if (await file.exists()) {
        return file.readAsBytes();
      }
    }

    return null;
  }

  Future<void> _rememberPendingPick(String requirementId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingPickRequirementKey, requirementId);
    await prefs.setString(_pendingPickEventKey, widget.eventId);
  }

  Future<void> _clearPendingPickMemory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingPickRequirementKey);
    await prefs.remove(_pendingPickEventKey);
    await NativeDocumentPicker.clearPendingDocument();
  }

  Future<void> _recoverPendingPickIfNeeded() async {
    if (!_canUpload || _isUploading || _isPickingFile || _recoveringPendingPick) {
      return;
    }
    if (_studentId.isEmpty) return;

    _recoveringPendingPick = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final requirementId =
          (prefs.getString(_pendingPickRequirementKey) ?? '').trim();
      final eventId = (prefs.getString(_pendingPickEventKey) ?? '').trim();
      if (requirementId.isEmpty || eventId != widget.eventId) {
        return;
      }

      final pending = await NativeDocumentPicker.takePendingDocument();
      if (pending == null) return;

      Map<String, dynamic>? requirement;
      for (final row in _requirements) {
        if ((row['id']?.toString() ?? '') == requirementId) {
          requirement = row;
          break;
        }
      }
      if (requirement == null) {
        await _clearPendingPickMemory();
        return;
      }

      if (!mounted) return;
      AppSnackBar.info(context, 'Resuming your file upload…');
      await _uploadPickedFile(
        requirement: requirement,
        fileName: pending.name,
        filePath: pending.path,
      );
    } finally {
      _recoveringPendingPick = false;
    }
  }

  Future<void> _pickAndUpload(Map<String, dynamic> requirement) async {
    if (!_canUpload || _isUploading || _isPickingFile) return;

    final requirementId = requirement['id']?.toString() ?? '';
    if (requirementId.isEmpty) return;

    String fileName = 'document.pdf';
    String? filePath;
    Uint8List? bytes;

    setState(() {
      _isPickingFile = true;
      _pickingRequirementId = requirementId;
    });
    try {
      await _rememberPendingPick(requirementId);

      // Free image cache before leaving to the system picker — low-RAM Oppo
      // devices often kill the Flutter process while Documents UI is open.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      if (Platform.isAndroid) {
        // Native SAF picker + pending recovery (stable on low-RAM / ColorOS).
        final native = await NativeDocumentPicker.pickAndroid();
        if (native == null) {
          await _clearPendingPickMemory();
          return;
        }
        fileName = native.name.trim().isNotEmpty
            ? native.name.trim()
            : 'document.pdf';
        filePath = native.path;
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: _allowedExtensions.toList(),
          allowMultiple: false,
          withData: false,
          withReadStream: false,
          compressionQuality: 0,
        );
        if (result == null || result.files.isEmpty) {
          await _clearPendingPickMemory();
          return;
        }
        final picked = result.files.first;
        fileName = picked.name.trim().isNotEmpty
            ? picked.name.trim()
            : 'document.pdf';
        filePath = picked.path;
        if (filePath == null || filePath.trim().isEmpty) {
          bytes = await _readPickedBytes(picked);
        }
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      final message = (error.message ?? error.code).trim();
      AppSnackBar.error(context, message.isEmpty ? 'Unable to open file picker.' : message);
      await _clearPendingPickMemory();
      return;
    } catch (error) {
      if (!mounted) return;
      AppSnackBar.error(context, 'Unable to open file picker: $error');
      await _clearPendingPickMemory();
      return;
    } finally {
      if (mounted) {
        setState(() {
          _isPickingFile = false;
          _pickingRequirementId = null;
        });
      }
    }

    await _uploadPickedFile(
      requirement: requirement,
      fileName: fileName,
      filePath: filePath,
      bytes: bytes,
    );
  }

  Future<void> _uploadPickedFile({
    required Map<String, dynamic> requirement,
    required String fileName,
    String? filePath,
    Uint8List? bytes,
  }) async {
    final requirementId = requirement['id']?.toString() ?? '';
    if (requirementId.isEmpty || _isUploading) return;

    final extension =
        path.extension(fileName).toLowerCase().replaceFirst('.', '');
    if (!_allowedExtensions.contains(extension)) {
      await _clearPendingPickMemory();
      if (!mounted) return;
      AppSnackBar.error(context, 'Unsupported file. Use PDF, DOC, DOCX, JPG, PNG, or WEBP.');
      return;
    }

    final resolvedPath = (filePath ?? '').trim();
    final hasPath = resolvedPath.isNotEmpty && await File(resolvedPath).exists();
    final hasBytes = bytes != null && bytes.isNotEmpty;
    if (!hasPath && !hasBytes) {
      await _clearPendingPickMemory();
      if (!mounted) return;
      AppSnackBar.error(context, 'Unable to read the selected file.');
      return;
    }

    // Guard oversized files without loading them fully into RAM.
    if (hasPath) {
      final size = await File(resolvedPath).length();
      if (size > 15 * 1024 * 1024) {
        await _clearPendingPickMemory();
        if (!mounted) return;
        AppSnackBar.error(context, 'File is too large. Max 15 MB.');
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _isUploading = true;
      _uploadingRequirementId = requirementId;
      _uploadProgress = 0;
    });

    try {
      final upload = await _trackUploadProgress(
        _eventService.uploadStudentRequirementDocument(
          eventId: widget.eventId,
          requirementId: requirementId,
          studentId: _studentId,
          filePath: hasPath ? resolvedPath : null,
          bytes: hasPath ? null : bytes,
          fileName: fileName,
          mimeType: _detectMimeType(fileName),
        ),
      );

      if (upload['ok'] != true) {
        throw Exception(upload['error']?.toString() ?? 'Upload failed.');
      }

      await _clearPendingPickMemory();
      if (!mounted) return;
      _applyUploadedDocument(requirementId, upload, fileName);
      AppSnackBar.success(context, 'Document uploaded successfully.');
    } catch (error) {
      if (!mounted) return;
      AppSnackBar.error(context, 'Upload failed: $error');
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
      if (result['ok'] != true &&
          result['already_approved'] != true &&
          result['already_pending'] != true) {
        throw Exception(result['error']?.toString() ?? 'Submit failed.');
      }

      if (!mounted) return;
      setState(() {
        _status = result['already_approved'] == true
            ? 'approved'
            : 'pending_review';
        _statusMessage = _status == 'approved'
            ? 'Your documents were approved. You may now register.'
            : 'Your documents are under review. Registration will open after approval.';
      });
      _storePageCache();
      AppSnackBar.success(context, _status == 'approved' ? 'Documents already approved.' : 'Documents submitted for review. You can register after approval.');
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      final raw = error.toString();
      final message = raw.startsWith('Exception: ')
          ? raw.substring('Exception: '.length)
          : raw;
      // Recover UI if server already has pending but local status was stale.
      if (message.toLowerCase().contains('under review')) {
        setState(() {
          _status = 'pending_review';
          _statusMessage =
              'Your documents are under review. Registration will open after approval.';
        });
        AppSnackBar.info(context, 'Documents are already under review. Waiting for teacher approval.');
        Navigator.pop(context, true);
        return;
      }
      AppSnackBar.error(context, message);
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
          ] else if (_isPickingFile && _pickingRequirementId == requirementId) ...[
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: _studentPrimary(context),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Opening files… keep the app open',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: _studentPrimary(context),
                    ),
                  ),
                ),
              ],
            ),
          ] else
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                onPressed: (_canUpload && !_isPickingFile && !_isUploading)
                    ? () => _pickAndUpload(requirement)
                    : null,
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
