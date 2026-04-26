import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../../services/auth_service.dart';
import '../../services/offline_sync_service.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/safe_circle_avatar.dart';
import '../welcome_screen.dart';
import '../auth/change_password_screen.dart';
import 'student_certificates.dart';
import '../../utils/course_theme_utils.dart';

class StudentProfile extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback? onUpdate;
  const StudentProfile({super.key, required this.user, this.onUpdate});

  @override
  State<StudentProfile> createState() => _StudentProfileState();
}


class _StudentProfileState extends State<StudentProfile> {
  final _authService = AuthService();
  final _offlineSyncService = OfflineSyncService();
  final Connectivity _connectivity = Connectivity();
  String _sectionName = 'Loading...';
  final ImagePicker _picker = ImagePicker();
  bool _isUploading = false;
  bool _isLoggingOut = false;
  bool _isOffline = false;
  bool _isLoadingOfflineStatus = false;
  Map<String, dynamic>? _localUser;
  Map<String, dynamic>? _offlineStatus;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  Color _studentPrimary(BuildContext context) => CourseThemeUtils
      .studentPrimaryForCourse(_localUser?['course']);
  Color _studentLight(BuildContext context) =>
      CourseThemeUtils.studentLightForCourse(_localUser?['course']);

  @override
  void initState() {
    super.initState();
    _localUser = widget.user;
    unawaited(_initOfflineMonitoring());
    _fetchSectionName();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
      );

      if (pickedFile == null) return;

      // Crop the selected image
      final croppedFile = await _cropImage(pickedFile.path);
      if (croppedFile == null) return;

      setState(() => _isUploading = true);

      // Save to local storage for instant feedback
      final directory = await getApplicationDocumentsDirectory();
      final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}${path.extension(croppedFile.path)}';
      final savedImage = await File(croppedFile.path).copy('${directory.path}/$fileName');

      // Update AuthService (Uploads to Supabase Storage and updates database)
      final res = await _authService.uploadAvatar(savedImage);
      
      if (mounted) {
        setState(() {
          _isUploading = false;
          if (res['ok']) {
            _localUser = res['user'];
          }
        });
        
        if (res['ok']) {
          final warning = res['warning']?.toString();
          if (widget.onUpdate != null) widget.onUpdate!();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                (warning != null && warning.isNotEmpty)
                    ? warning
                    : 'Profile picture cloud-synced!',
              ),
              backgroundColor:
                  (warning != null && warning.isNotEmpty) ? Colors.orange : Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(res['error'] ?? 'Upload failed'), backgroundColor: Colors.red),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<CroppedFile?> _cropImage(String filePath) async {
    return await ImageCropper().cropImage(
      sourcePath: filePath,
      maxWidth: 512,
      maxHeight: 512,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1), // Square for circular avatar
      compressQuality: 90,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Edit Profle Picture',
          toolbarColor: _studentPrimary(context),
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true,
          hideBottomControls: false,
        ),
        IOSUiSettings(
          title: 'Edit Profile Picture',
          rotateButtonsHidden: false,
          rotateClockwiseButtonHidden: false,
          aspectRatioLockEnabled: true,
        ),
      ],
    );
  }

  void _showPickOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Change Profile Picture', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1F2937))),
              const SizedBox(height: 20),
              ListTile(
                leading: Icon(
                  Icons.photo_library_rounded,
                  color: _studentPrimary(context),
                ),
                title: const Text('Choose from Gallery', style: TextStyle(fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.camera_alt_rounded,
                  color: _studentPrimary(context),
                ),
                title: const Text('Take a Photo', style: TextStyle(fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _fetchSectionName() async {
    final sectionId = _localUser?['section_id']?.toString();
    if (sectionId == null || sectionId.isEmpty) {
      if (mounted) setState(() => _sectionName = 'Not Set');
      return;
    }
    final sections = await _authService.getSections();
    final match = sections.firstWhere((s) => s['id'].toString() == sectionId, orElse: () => {});
    if (mounted) {
      setState(() {
        _sectionName = match.isNotEmpty ? (match['name'] as String? ?? 'Not Set') : 'Not Set';
      });
    }
  }

  Future<void> _refreshProfile() async {
    final latestUser = await _authService.getCurrentUser();
    if (!mounted) return;
    setState(() {
      _localUser = latestUser ?? _localUser;
    });
    await _fetchSectionName();
    await _loadOfflineStatus(refreshSnapshot: !_isOffline);
    if (widget.onUpdate != null) {
      widget.onUpdate!();
    }
  }

  bool _resultsAreOffline(List<ConnectivityResult> results) {
    return results.isEmpty ||
        results.every((result) => result == ConnectivityResult.none);
  }

  Future<void> _initOfflineMonitoring() async {
    final initial = await _connectivity.checkConnectivity();
    if (!mounted) return;
    setState(() => _isOffline = _resultsAreOffline(initial));
    await _loadOfflineStatus(refreshSnapshot: !_isOffline);
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((
      results,
    ) {
      final offline = _resultsAreOffline(results);
      if (!mounted) return;
      setState(() => _isOffline = offline);
      unawaited(_loadOfflineStatus(refreshSnapshot: !offline));
    });
  }

  Future<void> _loadOfflineStatus({bool refreshSnapshot = false}) async {
    final activeUser = _localUser ?? await _authService.getCurrentUser();
    final studentId = (activeUser?['id']?.toString() ?? '').trim();
    if (studentId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _offlineStatus = null;
        _isLoadingOfflineStatus = false;
      });
      return;
    }

    if (mounted) {
      setState(() => _isLoadingOfflineStatus = true);
    }
    final status = await _offlineSyncService.getOfflineMonitorStatus(
      actorId: studentId,
      isTeacher: false,
      refreshSnapshot: refreshSnapshot,
      isOffline: _isOffline,
    );
    if (!mounted) return;
    setState(() {
      _offlineStatus = status;
      _isLoadingOfflineStatus = false;
      _localUser ??= activeUser;
    });
  }

  DateTime? _parseOfflineDate(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  String _formatOfflineDateTime(DateTime? dateTime) {
    if (dateTime == null) return 'Not yet synced';
    final hour = dateTime.hour % 12 == 0 ? 12 : dateTime.hour % 12;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final period = dateTime.hour >= 12 ? 'PM' : 'AM';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[dateTime.month - 1]} ${dateTime.day}, ${dateTime.year} - $hour:$minute $period';
  }

  String _offlineSummarySubtitle() {
    if (_isLoadingOfflineStatus && _offlineStatus == null) {
      return 'Loading scanner cache details...';
    }
    final status = _offlineStatus;
    if (status == null) {
      return 'Open to view scanner cache, queue, and last sync details.';
    }
    final pending = int.tryParse(
          status['pending_queue_count']?.toString() ?? '',
        ) ??
        0;
    final refreshError = (status['refresh_error']?.toString() ?? '').trim();
    final lastSynced = _formatOfflineDateTime(
      _parseOfflineDate(status['last_synced_at']?.toString()),
    );
    if (status['has_snapshot'] != true) {
      if (refreshError.isNotEmpty) {
        return refreshError;
      }
      return 'No saved snapshot yet. Pending queue: $pending.';
    }
    if (status['offline_ready'] != true) {
      return 'Scanner context is saved, but the cached offline package for this event is still incomplete.';
    }
    return 'Last synced $lastSynced - Pending queue: $pending';
  }

  String _scannerStatusLabel(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'open':
        return 'Open';
      case 'waiting':
        return 'Waiting';
      case 'closed':
        return 'Closed';
      case 'no_assignment':
        return 'No assignment';
      case 'conflict':
        return 'Conflict';
      case 'error':
        return 'Error';
      default:
        return 'Unavailable';
    }
  }

  IconData _offlineChecklistIcon(String state) {
    switch (state.trim().toLowerCase()) {
      case 'ready':
        return Icons.check_circle_rounded;
      case 'partial':
        return Icons.error_outline_rounded;
      case 'not_required':
        return Icons.remove_circle_outline_rounded;
      default:
        return Icons.cancel_rounded;
    }
  }

  Color _offlineChecklistColor(String state, Color accent) {
    switch (state.trim().toLowerCase()) {
      case 'ready':
        return accent;
      case 'partial':
        return const Color(0xFFD97706);
      case 'not_required':
        return Colors.grey.shade500;
      default:
        return Colors.red.shade600;
    }
  }

  Widget _buildOfflineCacheInlineMetric({
    required String label,
    required String value,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            color: Color(0xFF111827),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12.2,
            fontWeight: FontWeight.w700,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  Widget _buildOfflineCacheMetricDivider() {
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: const Color(0xFFE5E7EB),
    );
  }

  Widget _buildOfflineChecklistItem(
    Map<String, dynamic> item,
    Color accent,
  ) {
    final label = (item['label']?.toString() ?? '').trim();
    final detail = (item['detail']?.toString() ?? '').trim();
    final state = (item['state']?.toString() ?? 'missing').trim().toLowerCase();
    final itemColor = _offlineChecklistColor(state, accent);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_offlineChecklistIcon(state), size: 18, color: itemColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: TextStyle(
                      fontSize: 12.2,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

    Widget _buildOfflineCacheCoverageCard(
    Map<String, dynamic>? status,
    Color accent,
  ) {
    final eventTitle = (status?['event_title']?.toString() ?? '').trim();
    final scopeLabel = (status?['cache_scope_label']?.toString() ?? '').trim();
    final participantCount =
        int.tryParse(status?['cached_participant_count']?.toString() ?? '') ?? 0;
    final ticketCount =
        int.tryParse(status?['cached_ticket_count']?.toString() ?? '') ?? 0;
    final localAvatarCount =
        int.tryParse(status?['cached_local_avatar_count']?.toString() ?? '') ?? 0;
    final sessionCount =
        int.tryParse(status?['cached_session_count']?.toString() ?? '') ?? 0;
    final checklist = status?['cache_checklist'] is List
        ? List<Map<String, dynamic>>.from(
            (status!['cache_checklist'] as List).map(
              (item) => Map<String, dynamic>.from(item as Map),
            ),
          )
        : <Map<String, dynamic>>[];
    final sessions = status?['cached_sessions'] is List
        ? List<Map<String, dynamic>>.from(
            (status!['cached_sessions'] as List).map(
              (item) => Map<String, dynamic>.from(item as Map),
            ),
          )
        : <Map<String, dynamic>>[];

    final subtitleParts = <String>[
      if (scopeLabel.isNotEmpty) scopeLabel,
      '$participantCount participant${participantCount == 1 ? '' : 's'}',
      '$ticketCount ticket${ticketCount == 1 ? '' : 's'}',
      '$localAvatarCount avatar${localAvatarCount == 1 ? '' : 's'}',
      if (sessionCount > 0) '$sessionCount seminar${sessionCount == 1 ? '' : 's'}',
    ];

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          iconColor: accent,
          collapsedIconColor: accent,
          title: Text(
            eventTitle.isNotEmpty ? eventTitle : 'Cached offline package',
            style: const TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w900,
              color: Color(0xFF111827),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              subtitleParts.join(' | '),
              style: TextStyle(
                fontSize: 12.2,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade600,
                height: 1.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildOfflineCacheInlineMetric(
                      label: 'participants',
                      value: '$participantCount',
                    ),
                    _buildOfflineCacheMetricDivider(),
                    _buildOfflineCacheInlineMetric(
                      label: 'tickets',
                      value: '$ticketCount',
                    ),
                    _buildOfflineCacheMetricDivider(),
                    _buildOfflineCacheInlineMetric(
                      label: 'avatars',
                      value: '$localAvatarCount',
                    ),
                    if (sessionCount > 0) ...[
                      _buildOfflineCacheMetricDivider(),
                      _buildOfflineCacheInlineMetric(
                        label: 'seminars',
                        value: '$sessionCount',
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (sessions.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                'Cached seminar windows',
                style: TextStyle(
                  fontSize: 12.8,
                  fontWeight: FontWeight.w800,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: sessions.map((session) {
                  final title = (session['title']?.toString() ?? 'Seminar').trim();
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 11.8,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
            if (checklist.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                'Already cached on this device',
                style: TextStyle(
                  fontSize: 12.8,
                  fontWeight: FontWeight.w800,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 10),
              ...checklist.map((item) => _buildOfflineChecklistItem(item, accent)),
            ],
          ],
        ),
      ),
    );
  }
  Future<void> _showOfflineStatusSheet() async {
    if (!mounted) return;

    Map<String, dynamic>? sheetStatus = _offlineStatus;
    var sheetOffline = _isOffline;
    var sheetBusy = false;
    var sheetMounted = true;
    var startedLiveUpdates = false;
    StateSetter? sheetSetState;
    Timer? statusTicker;

    Future<void> refreshSheet({bool refreshSnapshot = false}) async {
      if (sheetBusy || !sheetMounted) return;
      if (sheetSetState != null) {
        sheetSetState!(() => sheetBusy = true);
      } else {
        sheetBusy = true;
      }

      final activeUser = _localUser ?? await _authService.getCurrentUser();
      final studentId = (activeUser?['id']?.toString() ?? '').trim();
      if (studentId.isEmpty) {
        if (sheetMounted && sheetSetState != null) {
          sheetSetState!(() => sheetBusy = false);
        } else {
          sheetBusy = false;
        }
        return;
      }

      final connectivity = await _connectivity.checkConnectivity();
      final offlineNow = _resultsAreOffline(connectivity);
      final status = await _offlineSyncService.getOfflineMonitorStatus(
        actorId: studentId,
        isTeacher: false,
        refreshSnapshot: refreshSnapshot && !offlineNow,
        isOffline: offlineNow,
      );

      if (!mounted || !sheetMounted) return;
      setState(() {
        _isOffline = offlineNow;
        _offlineStatus = status;
        _localUser ??= activeUser;
        _isLoadingOfflineStatus = false;
      });
      if (sheetSetState != null) {
        sheetSetState!(() {
          sheetStatus = status;
          sheetOffline = offlineNow;
          sheetBusy = false;
        });
      } else {
        sheetStatus = status;
        sheetOffline = offlineNow;
        sheetBusy = false;
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, modalSetState) {
            sheetSetState = modalSetState;
            if (!startedLiveUpdates) {
              startedLiveUpdates = true;
              unawaited(refreshSheet());
              statusTicker = Timer.periodic(const Duration(seconds: 3), (_) {
                unawaited(refreshSheet());
              });
            }

            final status = sheetStatus;
            final lastSynced = _formatOfflineDateTime(
              _parseOfflineDate(status?['last_synced_at']?.toString()),
            );
            final pending =
                int.tryParse(status?['pending_queue_count']?.toString() ?? '') ??
                0;
            final refreshError = (status?['refresh_error']?.toString() ?? '')
                .trim();
            final refreshAttempted = status?['refresh_attempted'] == true;
            final connectionLabel =
                (status?['connection_label']?.toString() ?? '').trim().isNotEmpty
                ? status!['connection_label'].toString().trim()
                : (sheetOffline ? 'Offline' : 'Online');
            final statusLabel = () {
              if (sheetBusy && status == null) return 'Checking offline status';
              if (status == null || status['has_snapshot'] != true) {
                return 'Offline unavailable';
              }
              if (status['snapshot_stale'] == true) {
                return 'Offline data needs refresh';
              }
              if (status['offline_ready'] != true) {
                return 'Offline cache incomplete';
              }
              return sheetOffline ? 'Offline mode active' : 'Offline ready';
            }();
            final accent = (status?['has_snapshot'] == true &&
                    status?['snapshot_stale'] != true)
                ? (sheetOffline
                      ? Colors.orange.shade700
                      : _studentPrimary(context))
                : (status?['snapshot_stale'] == true
                      ? Colors.orange.shade700
                      : Colors.red.shade700);

            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.82,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.offline_bolt_rounded,
                              color: accent,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Offline Status',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF111827),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  statusLabel,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: accent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _buildOfflineStatusRow('Connection', connectionLabel),
                      _buildOfflineStatusRow(
                        'Snapshot',
                        status?['has_snapshot'] == true
                            ? (status?['snapshot_stale'] == true
                                  ? 'Needs refresh'
                                  : (status?['offline_ready'] == true
                                        ? 'Ready'
                                        : 'Incomplete'))
                            : 'Unavailable',
                      ),
                      if (refreshAttempted)
                        _buildOfflineStatusRow(
                          'Latest refresh',
                          refreshError.isEmpty ? 'Successful' : 'Needs attention',
                        ),
                      _buildOfflineStatusRow('Last synced', lastSynced),
                      _buildOfflineStatusRow('Pending offline scans', '$pending'),
                      _buildOfflineStatusRow(
                        'Scanner status',
                        _scannerStatusLabel(
                          status?['scanner_status']?.toString() ?? '',
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildOfflineCacheCoverageCard(status, accent),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    sheetMounted = false;
    statusTicker?.cancel();
  }

  Future<void> _confirmLogout() async {
    if (_isLoggingOut) return;

    final shouldLogout = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Sign Out?',
          style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF111827)),
        ),
        content: const Text(
          'Are you sure you want to sign out of your account?',
          style: TextStyle(color: Color(0xFF4B5563), height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Color(0xFF6B7280), fontWeight: FontWeight.w700),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _studentPrimary(context),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (shouldLogout == true) {
      await _logout();
    }
  }

  Future<void> _logout() async {
    if (_isLoggingOut) return;
    setState(() => _isLoggingOut = true);
    try {
      await _authService.logout();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const WelcomeScreen()),
        (route) => false,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoggingOut = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to sign out. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final firstName = _localUser?['first_name'] as String? ?? 'Student';
    final lastName = _localUser?['last_name'] as String? ?? '';
    final email = _localUser?['email'] as String? ?? '';
    final studentId = _localUser?['student_id'] as String? ?? 'N/A';
    final photoUrl = _localUser?['photo_url'] as String?;

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refreshProfile,
            color: _studentPrimary(context),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
              children: [
            // Curved Header with Profile Info
            Stack(
              clipBehavior: Clip.none,
              children: [
                // Maroon Curved Background
                Container(
                  height: 220,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [_studentLight(context), _studentPrimary(context)],
                    ),
                    borderRadius: BorderRadius.vertical(bottom: Radius.circular(40)),
                  ),
                ),
                
                // Content over background
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    child: Column(
                      children: [
                        // Header Row
                        Row(
                          children: [
                            const Expanded(child: Text('My Profile', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.5))),
                            IconButton(
                              icon: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                                child: const Icon(Icons.logout_rounded, color: Colors.white, size: 20),
                              ),
                              onPressed: (_isUploading || _isLoggingOut) ? null : _confirmLogout,
                            ),
                          ],
                        ),
                        const SizedBox(height: 30),
                        
                        // Centered Avatar
                        GestureDetector(
                          onTap: (_isUploading || _isLoggingOut) ? null : _showPickOptions,
                          child: Stack(
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 4),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.1),
                                      blurRadius: 20,
                                      spreadRadius: 5,
                                    ),
                                  ],
                                ),
                                child: SafeCircleAvatar(
                                  size: 120,
                                  imagePathOrUrl: photoUrl,
                                  fallbackText: firstName.isNotEmpty
                                      ? firstName[0].toUpperCase()
                                      : 'S',
                                  backgroundColor: const Color(0xFFFFF1F2),
                                  textColor: _studentPrimary(context),
                                  borderColor: const Color(0xFFD4A843),
                                  borderWidth: 2,
                                  textStyle: TextStyle(
                                    color: _studentPrimary(context),
                                    fontSize: 44,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              if (_isUploading)
                                Positioned.fill(
                                  child: Container(
                                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.3), shape: BoxShape.circle),
                                    child: const Center(child: PulseConnectLoader(size: 14)),
                                  ),
                                ),
                              Positioned(
                                bottom: 4,
                                right: 4,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFD4A843), // Gold camera button
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                  ),
                                  child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 16),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            
            // Bottom Content
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
              child: Column(
                children: [
                  Text('$firstName $lastName', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Color(0xFF111827), letterSpacing: -0.5)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: _studentPrimary(context).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      email,
                      style: TextStyle(
                        color: _studentPrimary(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  
                  // Unified Info Card
                  Container(
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
                    child: Column(
                      children: [
                        IntrinsicHeight(
                          child: Row(
                            children: [
                              Expanded(
                                child: _buildSimpleInfo('STUDENT ID', studentId),
                              ),
                              Container(width: 1, height: 40, color: Colors.grey.withValues(alpha: 0.1)),
                              Expanded(
                                child: _buildSimpleInfo('COURSE/SECTION', _sectionName),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 40),
                  
                  // Menu Items Header
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('ACCOUNT SETTINGS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF6B7280), letterSpacing: 1.2)),
                  ),
                  const SizedBox(height: 16),
                  
                  _buildMenuCard(
                    icon: Icons.workspace_premium_rounded,
                    title: 'My Certificates',
                    subtitle: 'View your earned achievements',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StudentCertificates())),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  _buildMenuCard(
                    icon: Icons.lock_person_rounded,
                    title: 'Security',
                    subtitle: 'Manage your password and auth',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
                  ),
                  const SizedBox(height: 16),
                  _buildMenuCard(
                    icon: Icons.offline_bolt_rounded,
                    title: 'Offline Status',
                    subtitle: _offlineSummarySubtitle(),
                    onTap: _showOfflineStatusSheet,
                  ),
                  const SizedBox(height: 120), // Extra space for bottom nav
                ],
              ),
            ),
          ],
              ),
            ),
          ),
          if (_isLoggingOut)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.35),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PulseConnectLoader(size: 16, color: Colors.white),
                      SizedBox(height: 14),
                      Text(
                        'Signing out...',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSimpleInfo(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.grey.shade500, letterSpacing: 1)),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF111827))),
        ],
      ),
    );
  }

  Widget _buildOfflineStatusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 124,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13.5,
                color: Color(0xFF111827),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuCard({required IconData icon, required String title, required String subtitle, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
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
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _studentPrimary(context).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: _studentPrimary(context), size: 22),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey.shade500)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFFD1D5DB), size: 24),
          ],
        ),
      ),
    );
  }
}

