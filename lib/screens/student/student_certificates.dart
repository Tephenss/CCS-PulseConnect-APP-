import 'dart:async';
import 'dart:convert';
import 'dart:io';


import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../widgets/app_snackbar.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../config/env.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';
import '../../utils/course_theme_utils.dart';

class StudentCertificates extends StatefulWidget {
  const StudentCertificates({super.key});

  @override
  State<StudentCertificates> createState() => _StudentCertificatesState();
}

class _StudentCertificatesState extends State<StudentCertificates>
    with WidgetsBindingObserver {
  final _eventService = EventService();
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _certificates = [];
  bool _isLoading = true;
  bool _isDownloading = false;
  String _searchQuery = '';
  String? _cachedParticipantName;

  Color _studentPrimary(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
  Color _studentDark(BuildContext context) =>
      CourseThemeUtils.studentDarkFromPrimary(_studentPrimary(context));

  String _composeUserDisplayName(Map<String, dynamic> user) {
    final firstName = (user['first_name']?.toString() ?? '').trim();
    final middleName = (user['middle_name']?.toString() ?? '').trim();
    final lastName = (user['last_name']?.toString() ?? '').trim();
    final suffix = (user['suffix']?.toString() ?? '').trim();
    final parts = <String>[
      if (firstName.isNotEmpty) firstName,
      if (middleName.isNotEmpty) middleName,
      if (lastName.isNotEmpty) lastName,
    ];
    var full = parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (suffix.isNotEmpty) {
      full = full.isEmpty ? suffix : '$full $suffix';
    }
    if (full.isNotEmpty) return full;
    final display = (user['display_name']?.toString() ?? '').trim();
    if (display.isNotEmpty) return display;
    return (user['full_name']?.toString() ?? '').trim();
  }

  String _participantName(Map<String, dynamic> cert) {
    final raw = (cert['participant_name']?.toString() ?? '').trim();
    if (raw.isNotEmpty &&
        raw.toLowerCase() != 'student name' &&
        !raw.contains('{{')) {
      return raw;
    }
    final display = (cert['display_name']?.toString() ?? '').trim();
    if (display.isNotEmpty && !display.contains('{{')) return display;
    final full = (cert['full_name']?.toString() ?? '').trim();
    if (full.isNotEmpty && !full.contains('{{')) return full;
    return '';
  }

  Future<String> _resolveParticipantName(Map<String, dynamic> cert) async {
    // Certificates always use First Middle Last (never surname-first).
    final cached = (_cachedParticipantName ?? '').trim();
    if (cached.isNotEmpty) return cached;

    try {
      final user = await AuthService().getCurrentUser();
      if (user != null) {
        final composed = _composeUserDisplayName(user);
        if (composed.isNotEmpty) {
          _cachedParticipantName = composed;
          return composed;
        }
      }
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user_data');
      if (raw != null && raw.trim().isNotEmpty) {
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          final composed =
              _composeUserDisplayName(Map<String, dynamic>.from(parsed));
          if (composed.isNotEmpty) {
            _cachedParticipantName = composed;
            return composed;
          }
        }
      }
    } catch (_) {}

    final fromCert = _participantName(cert);
    if (fromCert.isNotEmpty && !fromCert.contains(',')) return fromCert;
    // Avoid showing "LAST, FIRST..." if that was cached from attendance format.
    if (fromCert.contains(',')) {
      final rebuilt = _normalizeCertificateNameOrder(fromCert);
      if (rebuilt.isNotEmpty) return rebuilt;
    }
    return fromCert;
  }

  /// Convert "LAST, FIRST MIDDLE" → "FIRST MIDDLE LAST" for certificate display.
  String _normalizeCertificateNameOrder(String raw) {
    final name = raw.trim();
    final comma = name.indexOf(',');
    if (comma <= 0) return name;
    final last = name.substring(0, comma).trim();
    final given = name.substring(comma + 1).trim();
    if (last.isEmpty || given.isEmpty) return name;
    return '$given $last'.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _sanitizeFilePart(String raw) {
    return raw
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _safePdfFileName(
    String participantName, {
    String? seminarOrTopic,
  }) {
    var name = _sanitizeFilePart(participantName);
    if (name.isEmpty || name.toLowerCase() == 'student name') {
      name = 'Certificate';
    }

    final label = _sanitizeFilePart(seminarOrTopic ?? '');
    if (label.isNotEmpty) {
      name = '$name($label)';
    }

    if (name.length > 120) {
      name = name.substring(0, 120).trim();
    }
    return '$name.pdf';
  }

  Future<Directory> _resolveDownloadsDirectory() async {
    if (Platform.isAndroid) {
      for (final path in const [
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Downloads',
      ]) {
        final dir = Directory(path);
        if (await dir.exists()) return dir;
      }
    }

    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    } catch (_) {}

    if (Platform.isIOS) {
      return getApplicationDocumentsDirectory();
    }
    return getTemporaryDirectory();
  }

  Future<Uint8List> _buildCertificatePdfBytes(Uint8List imageBytes) async {
    final image = pw.MemoryImage(imageBytes);
    final doc = pw.Document();
    // Match common certificate canvas ratio (landscape).
    const pageFormat = PdfPageFormat(1123, 794, marginAll: 0);
    doc.addPage(
      pw.Page(
        pageFormat: pageFormat,
        margin: pw.EdgeInsets.zero,
        build: (context) {
          return pw.SizedBox(
            width: pageFormat.width,
            height: pageFormat.height,
            child: pw.Image(image, fit: pw.BoxFit.contain),
          );
        },
      ),
    );
    return Uint8List.fromList(await doc.save());
  }

  Future<String?> _savePdfToDownloads({
    required String fileName,
    required Uint8List pdfBytes,
  }) async {
    if (Platform.isAndroid) {
      try {
        const channel = MethodChannel('pulseconnect/downloads');
        final result = await channel.invokeMethod<dynamic>('saveFile', {
          'fileName': fileName,
          'mimeType': 'application/pdf',
          'bytes': pdfBytes,
        });
        if (result is Map) {
          final savedName = (result['fileName']?.toString() ?? fileName).trim();
          if (savedName.isNotEmpty) return savedName;
        }
        return fileName;
      } catch (_) {
        // Fall through to path-based write.
      }
    }

    try {
      final downloadsDir = await _resolveDownloadsDirectory();
      var target = File(p.join(downloadsDir.path, fileName));
      if (await target.exists()) {
        final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
        final base = fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
        target = File(p.join(downloadsDir.path, '${base}_$stamp.pdf'));
      }
      await target.writeAsBytes(pdfBytes, flush: true);
      return p.basename(target.path);
    } catch (_) {
      return null;
    }
  }

  Future<void> _downloadCertificate(
    Map<String, dynamic> cert, {
    Uint8List? renderedImageBytes,
    bool alreadyLocked = false,
  }) async {
    if (!alreadyLocked) {
      if (_isDownloading) return;
      _isDownloading = true;
    }

    try {
      Uint8List? imageBytes = renderedImageBytes;

      if (imageBytes == null || imageBytes.isEmpty) {
        final raw = cert['thumbnail_url']?.toString().trim() ?? '';
        final decoded = _decodeThumbnailBytes(raw);
        if (decoded != null) {
          imageBytes = decoded;
        } else if (raw.startsWith('http://') || raw.startsWith('https://')) {
          final response = await http.get(Uri.parse(raw));
          if (response.statusCode >= 200 && response.statusCode < 300) {
            imageBytes = response.bodyBytes;
          }
        }
      }

      if (imageBytes == null || imageBytes.isEmpty) {
        AppSnackBar.error(context, 'Certificate file is unavailable for download.');
        return;
      }

      final participantName = await _resolveParticipantName(cert);
      final titleParts = _resolveTitleParts(cert);
      final fileName = _safePdfFileName(
        participantName,
        seminarOrTopic: titleParts.seminarLabel ?? titleParts.eventTitle,
      );
      final pdfBytes = await _buildCertificatePdfBytes(imageBytes);

      final savedName = await _savePdfToDownloads(
        fileName: fileName,
        pdfBytes: pdfBytes,
      );

      if (savedName != null && savedName.isNotEmpty) {
        AppSnackBar.success(context, 'Saved to Downloads as $savedName');
        return;
      }

      // Fallback: share sheet with the correct PDF filename.
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, fileName));
      await tempFile.writeAsBytes(pdfBytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(tempFile.path, mimeType: 'application/pdf', name: fileName)],
          text: 'Your CCS PulseConnect certificate',
        ),
      );
    } catch (_) {
      AppSnackBar.error(context, 'Failed to download certificate.');
    } finally {
      if (!alreadyLocked) {
        _isDownloading = false;
      }
    }
  }

  Uint8List? _decodeThumbnailBytes(String? thumbnailUrl) {
    final raw = thumbnailUrl?.trim() ?? '';
    if (!raw.startsWith('data:image')) return null;
    final commaIndex = raw.indexOf(',');
    if (commaIndex < 0 || commaIndex >= raw.length - 1) return null;
    try {
      return base64Decode(raw.substring(commaIndex + 1));
    } catch (_) {
      return null;
    }
  }

  bool _hasThumbnail(Map<String, dynamic> cert) {
    final raw = cert['thumbnail_url']?.toString().trim() ?? '';
    return raw.isNotEmpty;
  }

  Map<String, dynamic>? _parseCanvasState(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {}
    }
    return null;
  }

  Widget _buildCertificateThumbnail(
    Map<String, dynamic> cert, {
    BoxFit fit = BoxFit.cover,
  }) {
    final raw = cert['thumbnail_url']?.toString().trim() ?? '';
    final bytes = _decodeThumbnailBytes(raw);

    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: fit,
        width: double.infinity,
        height: double.infinity,
        filterQuality: FilterQuality.high,
      );
    }

    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: raw,
        imageBuilder: (context, imageProvider) => Image(
          image: imageProvider,
          fit: fit,
          width: double.infinity,
          height: double.infinity,
          filterQuality: FilterQuality.high,
        ),
        placeholder: (context, url) => _buildThumbnailFallback(),
        errorWidget: (context, url, error) => _buildThumbnailFallback(),
      );
    }

    return _buildThumbnailFallback();
  }

  Widget _buildThumbnailFallback() {
    return Container(
      color: const Color(0xFFF9FAFB),
      alignment: Alignment.center,
      child: Icon(
        Icons.workspace_premium_rounded,
        size: 48,
        color: const Color(0xFFD4A843),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootCertificates());
  }

  /// Soft open: paint cached list ASAP, refresh in background (no spinner on re-enter).
  Future<void> _bootCertificates() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = (prefs.getString('user_id') ?? '').trim();
    if (userId.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    // Warm name from prefs (no network).
    try {
      final raw = prefs.getString('user_data');
      if (raw != null && raw.trim().isNotEmpty) {
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          final composed =
              _composeUserDisplayName(Map<String, dynamic>.from(parsed));
          if (composed.isNotEmpty) _cachedParticipantName = composed;
        }
      }
    } catch (_) {}

    try {
      // Uses mem/disk cache inside EventService — should be near-instant on re-enter.
      await _refreshCertificates(userId, forceFresh: false);
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }

    // Quiet catch-up; keep current cards visible.
    unawaited(_refreshCertificates(userId, forceFresh: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Soft catch-up — keep current list visible; no full-page loader.
      unawaited(_loadCertificates(showLoader: false, forceFresh: true));
    }
  }

  Future<void> _loadCertificates({
    bool showLoader = false,
    bool forceFresh = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    if (userId.isEmpty) {
      if (mounted) {
        setState(() {
          _certificates = [];
          _isLoading = false;
        });
      }
      return;
    }

    final hasLocal = _certificates.isNotEmpty;
    // Full-page spinner only when list is empty and explicitly requested.
    // First open already starts with _isLoading=true; resume/pull keep cards.
    if (!hasLocal && mounted && showLoader) {
      setState(() => _isLoading = true);
    }

    try {
      await _refreshCertificates(userId, forceFresh: forceFresh);
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _refreshCertificates(
    String userId, {
    bool forceFresh = false,
  }) async {
    try {
      final certs = await _eventService.getMyCertificates(
        userId,
        forceFresh: forceFresh,
      );
      final resolvedName = (_cachedParticipantName ?? '').trim().isNotEmpty
          ? _cachedParticipantName!.trim()
          : await _resolveParticipantName({
              if (certs.isNotEmpty) ...certs.first,
            });
      if (resolvedName.isNotEmpty) {
        _cachedParticipantName = resolvedName;
      }
      await Future.wait(certs.map((cert) async {
        final id = cert['id']?.toString() ?? '';
        if (id.isEmpty) return;
        if (_CertificatePreviewCache.peek(id) != null) return;
        await _CertificatePreviewCache.load(id);
      }));
      final previousById = <String, Map<String, dynamic>>{
        for (final row in _certificates)
          if ((row['id']?.toString() ?? '').isNotEmpty)
            row['id'].toString(): row,
      };
      final enriched = certs.map((cert) {
        final preferred = resolvedName.isNotEmpty
            ? resolvedName
            : _normalizeCertificateNameOrder(_participantName(cert));
        final id = cert['id']?.toString() ?? '';
        final prev = previousById[id];
        final keptCanvas = _parseCanvasState(prev?['template_canvas_state']) ??
            _parseCanvasState(cert['template_canvas_state']);
        return {
          ...cert,
          if (preferred.isNotEmpty) 'participant_name': preferred,
          if (keptCanvas != null) 'template_canvas_state': keptCanvas,
        };
      }).toList();
      if (mounted) {
        setState(() {
          _certificates = enriched;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<Map<String, dynamic>> get _filteredCertificates {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return _certificates;
    return _certificates.where((cert) {
      final event = cert['events'] as Map<String, dynamic>? ?? {};
      final title = cert['display_title']?.toString() ??
          event['title']?.toString() ??
          '';
      final code = cert['certificate_code']?.toString() ?? '';
      return title.toLowerCase().contains(query) ||
          code.toLowerCase().contains(query);
    }).toList();
  }

  ({String eventTitle, String? seminarLabel}) _resolveTitleParts(
    Map<String, dynamic> cert,
  ) {
    final event = cert['events'] as Map<String, dynamic>? ?? {};
    final rawTitle =
        cert['display_title']?.toString().trim() ??
        event['title']?.toString().trim() ??
        'Event';

    final session =
        cert['session'] is Map ? (cert['session'] as Map) : const <dynamic, dynamic>{};
    final sessionTopic = (session['topic']?.toString() ?? '').trim();
    final sessionTitle = (session['title']?.toString() ?? '').trim();

    String eventTitle = rawTitle;
    String? seminarLabel;

    if (rawTitle.contains(' - ')) {
      final idx = rawTitle.indexOf(' - ');
      eventTitle = rawTitle.substring(0, idx).trim();
      seminarLabel = rawTitle.substring(idx + 3).trim();
    } else if (sessionTopic.isNotEmpty) {
      seminarLabel = sessionTopic;
    } else if (sessionTitle.isNotEmpty) {
      seminarLabel = sessionTitle;
    }

    if (seminarLabel != null && seminarLabel.isNotEmpty) {
      final normalizedEvent = eventTitle.toLowerCase();
      final normalizedSeminar = seminarLabel.toLowerCase();
      if (normalizedEvent.endsWith(normalizedSeminar)) {
        seminarLabel = null;
      }
    }

    return (eventTitle: eventTitle, seminarLabel: seminarLabel);
  }

  @override
  Widget build(BuildContext context) {
    final chromeColor = CourseThemeUtils.studentChromeFromPrimary(
      _studentPrimary(context),
    );
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(100.0),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: CourseThemeUtils.studentTicketGradientFromPrimary(
                _studentPrimary(context),
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: chromeColor.withValues(alpha: 0.3),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
            ],
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(32),
              bottomRight: Radius.circular(32),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 24, 16),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.25),
                        width: 1.5,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 8,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.workspace_premium_rounded,
                      color: Color(0xFFFBBF24), // Gold
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Certificates',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Your earned achievements',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: PulseConnectLoader())
          : RefreshIndicator(
              onRefresh: () => _loadCertificates(forceFresh: true),
              color: _studentPrimary(context),
              child: _certificates.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.72,
                          child: _buildEmptyState(),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Container(
                            decoration: BoxDecoration(
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.04),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: TextField(
                              controller: _searchController,
                              onChanged: (value) {
                                setState(() {
                                  _searchQuery = value;
                                });
                              },
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Search certificates',
                                hintStyle: TextStyle(
                                  color: Colors.grey.shade400,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                                prefixIcon: Icon(
                                  Icons.search_rounded,
                                  color: _studentPrimary(context).withValues(alpha: 0.7),
                                ),
                                suffixIcon: _searchQuery.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.close_rounded),
                                        onPressed: () {
                                          _searchController.clear();
                                          setState(() {
                                            _searchQuery = '';
                                          });
                                        },
                                      )
                                    : Icon(
                                        Icons.tune_rounded,
                                        color: Colors.grey.shade400,
                                      ),
                                filled: true,
                                fillColor: Colors.white,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                  horizontal: 16,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide(
                                    color: Colors.grey.shade200,
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide(
                                    color: Colors.grey.shade200,
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide(
                                    color: _studentPrimary(context),
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: _filteredCertificates.isEmpty
                              ? ListView(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  children: [
                                    SizedBox(
                                      height:
                                          MediaQuery.of(context).size.height *
                                              0.56,
                                      child: Center(
                                        child: Text(
                                          'No certificates matched your search.',
                                          style: TextStyle(
                                            color: Colors.grey.shade500,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : ListView.builder(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    20,
                                  ),
                                  itemCount: _filteredCertificates.length,
                                  itemBuilder: (context, index) {
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 14),
                                      child: _buildCertificateCard(
                                        _filteredCertificates[index],
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.workspace_premium_outlined,
              size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            'No certificates yet',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Complete events to earn certificates!',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Text(
            'Pull down to refresh after certificates are sent.',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCertificateCard(Map<String, dynamic> cert) {
    final event = cert['events'] as Map<String, dynamic>? ?? {};
    final titleParts = _resolveTitleParts(cert);
    final eventTitle = titleParts.eventTitle;
    final seminarLabel = titleParts.seminarLabel;
    final startAt = event['start_at'] as String?;

    DateTime? startDate;
    if (startAt != null) {
      try { startDate = DateTime.parse(startAt); } catch (_) {}
    }

    return SizedBox(
        width: double.infinity,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE5E7EB)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: _studentPrimary(context).withValues(alpha: 0.03),
                blurRadius: 30,
                offset: const Offset(0, 15),
                spreadRadius: -5,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 160,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(19),
                  ),
                  // Cached personal PNG only — never Fabric / never raw {{participant_name}} thumb.
                  child: _CertificateListThumb(
                    key: ValueKey('cert-thumb-${cert['id']?.toString() ?? ''}'),
                    cert: cert,
                    certId: cert['id']?.toString() ?? '',
                    participantName: () {
                      final n = _participantName(cert);
                      if (n.isNotEmpty) return n;
                      return (_cachedParticipantName ?? '').trim();
                    }(),
                    title: eventTitle,
                    eventService: _eventService,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (seminarLabel != null && seminarLabel.isNotEmpty)
                            Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFFFFFBEB), Color(0xFFFEF3C7)],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(30),
                                border: Border.all(
                                  color: const Color(0xFFFDE68A),
                                  width: 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFFD97706).withValues(alpha: 0.08),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.bookmark_added_rounded,
                                    size: 13,
                                    color: Color(0xFFD97706),
                                  ),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      seminarLabel,
                                      style: GoogleFonts.inter(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        color: const Color(0xFF92400E),
                                        letterSpacing: 0.2,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Text(
                            eventTitle,
                            style: GoogleFonts.inter(
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                              color: const Color(0xFF1F2937),
                              letterSpacing: -0.3,
                              height: 1.25,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(
                                Icons.calendar_today_rounded,
                                size: 13,
                                color: Colors.grey.shade400,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                startDate != null
                                    ? DateFormat('MMMM dd, yyyy').format(startDate)
                                    : '--',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: const Color(0xFF6B7280),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: () => _showCertificatePreview(cert),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              _studentPrimary(context),
                              CourseThemeUtils.studentDarkFromPrimary(_studentPrimary(context)),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: _studentPrimary(context).withValues(alpha: 0.35),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.arrow_forward_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
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

  void _showCertificatePreview(Map<String, dynamic> cert) {
    final titleParts = _resolveTitleParts(cert);
    final eventTitle = titleParts.eventTitle;
    final seminarLabel = titleParts.seminarLabel;
    final seedCanvas = _parseCanvasState(cert['template_canvas_state']);
    final seedName = _participantName(cert);

    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _CertificatePreviewDialog(
        cert: Map<String, dynamic>.from(cert),
        eventTitle: eventTitle,
        seminarLabel: seminarLabel,
        seedCanvas: seedCanvas,
        seedParticipantName: seedName,
        studentPrimary: _studentPrimary(context),
        studentDark: _studentDark(context),
        eventService: _eventService,
        resolveParticipantName: _resolveParticipantName,
        buildThumbnail: _buildCertificateThumbnail,
        hasThumbnail: _hasThumbnail,
        onDownload: ({
          required Map<String, dynamic> certRow,
          Uint8List? renderedImageBytes,
        }) async {
          if (_isDownloading) return;
          _isDownloading = true;
          try {
            await _downloadCertificate(
              certRow,
              renderedImageBytes: renderedImageBytes,
              alreadyLocked: true,
            );
          } finally {
            _isDownloading = false;
          }
        },
        onCanvasReady: (canvas) {
          final id = cert['id']?.toString() ?? '';
          if (id.isEmpty || !mounted) return;
          final idx = _certificates.indexWhere(
            (row) => (row['id']?.toString() ?? '') == id,
          );
          if (idx < 0) return;
          _certificates[idx] = {
            ..._certificates[idx],
            'template_canvas_state': canvas,
          };
        },
        onPreviewCached: () {
          if (mounted) setState(() {});
        },
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }
}

class _CertificatePreviewDialog extends StatefulWidget {
  const _CertificatePreviewDialog({
    required this.cert,
    required this.eventTitle,
    required this.seminarLabel,
    required this.seedCanvas,
    required this.seedParticipantName,
    required this.studentPrimary,
    required this.studentDark,
    required this.eventService,
    required this.resolveParticipantName,
    required this.buildThumbnail,
    required this.hasThumbnail,
    required this.onDownload,
    required this.onCanvasReady,
    required this.onPreviewCached,
  });

  final Map<String, dynamic> cert;
  final String eventTitle;
  final String? seminarLabel;
  final Map<String, dynamic>? seedCanvas;
  final String seedParticipantName;
  final Color studentPrimary;
  final Color studentDark;
  final EventService eventService;
  final Future<String> Function(Map<String, dynamic> cert) resolveParticipantName;
  final Widget Function(Map<String, dynamic> cert, {BoxFit fit}) buildThumbnail;
  final bool Function(Map<String, dynamic> cert) hasThumbnail;
  final Future<void> Function({
    required Map<String, dynamic> certRow,
    Uint8List? renderedImageBytes,
  }) onDownload;
  final void Function(Map<String, dynamic> canvas) onCanvasReady;
  final VoidCallback onPreviewCached;

  @override
  State<_CertificatePreviewDialog> createState() =>
      _CertificatePreviewDialogState();
}

class _CertificatePreviewDialogState extends State<_CertificatePreviewDialog> {
  late Map<String, dynamic> _cert;
  Map<String, dynamic>? _canvasState;
  String _participantName = '';
  bool _loadingCanvas = true;
  bool _previewReady = false;
  bool _isSaving = false;
  Uint8List? _cachedPng;
  final GlobalKey<_CertificateCanvasPreviewState> _canvasKey =
      GlobalKey<_CertificateCanvasPreviewState>();

  String get _certId => _cert['id']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _cert = widget.cert;
    _canvasState = widget.seedCanvas;
    _participantName = widget.seedParticipantName;
    _cachedPng = _CertificatePreviewCache.peek(_certId);
    _loadingCanvas = _cachedPng == null;
    _previewReady = _cachedPng != null;
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    if (_cachedPng == null && _certId.isNotEmpty) {
      final disk = await _CertificatePreviewCache.load(_certId);
      if (!mounted) return;
      if (disk != null && disk.isNotEmpty) {
        setState(() {
          _cachedPng = disk;
          _loadingCanvas = false;
          _previewReady = true;
        });
        final name = await widget.resolveParticipantName(_cert);
        if (!mounted) return;
        if (name.isNotEmpty) {
          setState(() => _participantName = name);
        }
        return;
      }
    } else if (_cachedPng != null) {
      final name = await widget.resolveParticipantName(_cert);
      if (!mounted) return;
      if (name.isNotEmpty) {
        setState(() => _participantName = name);
      }
      return;
    }

    final nameFuture = widget.resolveParticipantName(_cert);
    Map<String, dynamic>? canvas = _canvasState;
    if (canvas == null) {
      try {
        canvas = await widget.eventService.fetchCertificateCanvasState(
          templateId: _cert['template_id']?.toString(),
          sessionTemplateId: _cert['session_template_id']?.toString(),
        );
      } catch (_) {
        canvas = null;
      }
    }
    final name = await nameFuture;
    if (!mounted) return;
    if (canvas != null) {
      _cert = {
        ..._cert,
        'template_canvas_state': canvas,
        if (name.isNotEmpty) 'participant_name': name,
      };
      widget.onCanvasReady(canvas);
    }
    setState(() {
      _canvasState = canvas;
      if (name.isNotEmpty) _participantName = name;
      _loadingCanvas = false;
      _previewReady = canvas == null || _cachedPng != null;
    });
  }

  Future<void> _onFabricReady() async {
    if (!mounted) return;
    if (!_previewReady) {
      setState(() => _previewReady = true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final bytes = await _canvasKey.currentState?.exportPng();
    final certId = _cert['id']?.toString() ?? '';
    if (bytes == null || bytes.isEmpty || certId.isEmpty) return;
    await _CertificatePreviewCache.save(certId, bytes);
    widget.onPreviewCached();
  }

  Widget _loadingPanel() {
    return const ColoredBox(
      color: Color(0xFFF9FAFB),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(height: 12),
            Text(
              'Loading preview…',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6B7280),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewBody() {
    if (_cachedPng != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(
          _cachedPng!,
          fit: BoxFit.contain,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
          filterQuality: FilterQuality.high,
        ),
      );
    }

    if (_canvasState == null) {
      if (_loadingCanvas) return _loadingPanel();
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'CERTIFICATE OF PARTICIPATION',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                  color: Color(0xFFD4A843),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Text(
                _participantName.isNotEmpty ? _participantName : 'Participant',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'serif',
                  fontSize: 22,
                  fontStyle: FontStyle.italic,
                  color: Color(0xFF1F2937),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // One WebView + loading overlay until Fabric is ready (no remount flicker).
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: _CertificateCanvasPreview(
            key: _canvasKey,
            cert: _cert,
            title: widget.eventTitle,
            participantName: _participantName,
            canvasState: _canvasState!,
            showFrame: true,
            onReady: () => unawaited(_onFabricReady()),
          ),
        ),
        if (!_previewReady) _loadingPanel(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final headerTitle = widget.seminarLabel == null ||
            widget.seminarLabel!.isEmpty
        ? widget.eventTitle
        : '${widget.eventTitle} - ${widget.seminarLabel}';

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(20),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 640),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      headerTitle,
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: const Color(0xFF1F2937),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      color: Colors.grey.shade500,
                    ),
                    onPressed:
                        _isSaving ? null : () => Navigator.pop(context),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            Container(
              height: 340,
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _previewBody(),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: LinearGradient(
                      colors: [widget.studentDark, widget.studentPrimary],
                    ),
                  ),
                  child: ElevatedButton.icon(
                    onPressed: _isSaving || !_previewReady
                        ? null
                        : () async {
                            if (_isSaving) return;
                            setState(() => _isSaving = true);
                            try {
                              Uint8List? rendered = _cachedPng;
                              final state = _canvasKey.currentState;
                              if ((rendered == null || rendered.isEmpty) &&
                                  state != null) {
                                rendered = await state.exportPng();
                              }
                              if (rendered != null &&
                                  rendered.isNotEmpty &&
                                  _participantName.isNotEmpty) {
                                unawaited(
                                  _CertificatePreviewCache.save(
                                    _certId,
                                    rendered,
                                  ),
                                );
                              }
                              if (!mounted) return;
                              await widget.onDownload(
                                certRow: _cert,
                                renderedImageBytes: rendered,
                              );
                            } finally {
                              if (mounted) {
                                setState(() => _isSaving = false);
                              }
                            }
                          },
                    icon: _isSaving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.download_rounded),
                    label: Text(_isSaving ? 'SAVING...' : 'DOWNLOAD'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      disabledBackgroundColor: Colors.transparent,
                      foregroundColor: Colors.white,
                      disabledForegroundColor: Colors.white70,
                      minimumSize: const Size(220, 48),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Personal certificate preview PNG — keyed by cert id (survives back/re-enter).
class _CertificatePreviewCache {
  static final Map<String, Uint8List> _memory = {};

  static String _safeId(String certId) =>
      certId.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  static Future<File> _fileFor(String certId) async {
    final dir = await getApplicationSupportDirectory();
    final folder = Directory(p.join(dir.path, 'cert_previews'));
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return File(p.join(folder.path, '${_safeId(certId)}.png'));
  }

  static Uint8List? peek(String certId) {
    final id = certId.trim();
    if (id.isEmpty) return null;
    return _memory[id];
  }

  static Future<Uint8List?> load(String certId) async {
    final id = certId.trim();
    if (id.isEmpty) return null;
    final mem = _memory[id];
    if (mem != null && mem.isNotEmpty) return mem;
    try {
      final file = await _fileFor(id);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _memory[id] = bytes;
          return bytes;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<void> save(String certId, Uint8List bytes) async {
    final id = certId.trim();
    if (id.isEmpty || bytes.isEmpty) return;
    _memory[id] = bytes;
    try {
      final file = await _fileFor(id);
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }
}

/// List thumb: show loading → real PNG. Generates once via Fabric if not cached.
class _CertificateListThumb extends StatefulWidget {
  const _CertificateListThumb({
    super.key,
    required this.cert,
    required this.certId,
    required this.participantName,
    required this.title,
    required this.eventService,
  });

  final Map<String, dynamic> cert;
  final String certId;
  final String participantName;
  final String title;
  final EventService eventService;

  @override
  State<_CertificateListThumb> createState() => _CertificateListThumbState();
}

class _CertificateListThumbState extends State<_CertificateListThumb> {
  final GlobalKey<_CertificateCanvasPreviewState> _canvasKey =
      GlobalKey<_CertificateCanvasPreviewState>();
  Uint8List? _pngBytes;
  Map<String, dynamic>? _canvasState;
  bool _exporting = false;

  Map<String, dynamic>? _parseCanvas(dynamic raw) {
    if (raw is Map<String, dynamic>) return Map<String, dynamic>.from(raw);
    if (raw is Map) return raw.map((k, v) => MapEntry(k.toString(), v));
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return Map<String, dynamic>.from(decoded);
        }
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {}
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final peeked = _CertificatePreviewCache.peek(widget.certId);
    if (peeked != null) {
      _pngBytes = peeked;
    }
    if (_pngBytes == null) {
      unawaited(_bootstrap());
    }
  }

  @override
  void didUpdateWidget(covariant _CertificateListThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.certId != widget.certId) {
      final peeked = _CertificatePreviewCache.peek(widget.certId);
      _pngBytes = peeked;
      _canvasState = null;
      if (peeked == null) unawaited(_bootstrap());
    } else {
      final peeked = _CertificatePreviewCache.peek(widget.certId);
      if (peeked != null && !identical(peeked, _pngBytes)) {
        setState(() {
          _pngBytes = peeked;
          _canvasState = null;
        });
      }
    }
  }

  Future<void> _bootstrap() async {
    final cached = await _CertificatePreviewCache.load(widget.certId);
    if (!mounted) return;
    if (cached != null) {
      setState(() {
        _pngBytes = cached;
        _canvasState = null;
      });
      return;
    }

    var canvas = _parseCanvas(widget.cert['template_canvas_state']);
    canvas ??= await widget.eventService.fetchCertificateCanvasState(
      templateId: widget.cert['template_id']?.toString(),
      sessionTemplateId: widget.cert['session_template_id']?.toString(),
    );
    if (!mounted) return;
    if (canvas == null || widget.participantName.trim().isEmpty) {
      return;
    }
    widget.cert['template_canvas_state'] = canvas;
    setState(() {
      _canvasState = canvas;
    });
  }

  Future<void> _capture() async {
    if (_exporting || _pngBytes != null) return;
    _exporting = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final bytes = await _canvasKey.currentState?.exportPng();
      if (bytes == null || bytes.isEmpty || !mounted) return;
      await _CertificatePreviewCache.save(widget.certId, bytes);
      if (!mounted) return;
      setState(() {
        _pngBytes = bytes;
        _canvasState = null;
      });
    } finally {
      _exporting = false;
    }
  }

  Widget _loadingPanel() {
    return const ColoredBox(
      color: Color(0xFFF8FAFC),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            SizedBox(height: 10),
            Text(
              'Loading preview…',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6B7280),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_pngBytes != null) {
      return Image.memory(
        _pngBytes!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (_canvasState != null && widget.participantName.trim().isNotEmpty)
          IgnorePointer(
            child: _CertificateCanvasPreview(
              key: _canvasKey,
              cert: widget.cert,
              canvasState: _canvasState!,
              title: widget.title,
              participantName: widget.participantName,
              showFrame: false,
              onReady: () => unawaited(_capture()),
            ),
          ),
        _loadingPanel(),
      ],
    );
  }
}

class _CertificateCanvasPreview extends StatefulWidget {
  final Map<String, dynamic> cert;
  final Map<String, dynamic> canvasState;
  final String title;
  final String participantName;
  final bool showFrame;
  final VoidCallback? onReady;

  const _CertificateCanvasPreview({
    super.key,
    required this.cert,
    required this.canvasState,
    required this.title,
    required this.participantName,
    this.showFrame = true,
    this.onReady,
  });

  @override
  State<_CertificateCanvasPreview> createState() =>
      _CertificateCanvasPreviewState();
}

class _CertificateCanvasPreviewState extends State<_CertificateCanvasPreview> {
  late final WebViewController _controller;
  bool _canvasReady = false;

  String _assetBaseUrl() {
    var base = Env.mobilePushApiBaseUrl.trim();
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.isEmpty) base = 'https://ccspulseconnect.com';
    return base;
  }

  String _buildCanvasHtml() {
    final event = widget.cert['events'] is Map
        ? Map<String, dynamic>.from(widget.cert['events'] as Map)
        : <String, dynamic>{};
    final session = widget.cert['session'] is Map
        ? Map<String, dynamic>.from(widget.cert['session'] as Map)
        : <String, dynamic>{};

    final eventTitle = event['title']?.toString() ?? widget.title;
    final sessionTitle =
        session['title']?.toString() ?? session['topic']?.toString() ?? '';
    final certificateCode = widget.cert['certificate_code']?.toString() ?? '';
    final issuedAt = widget.cert['issued_at']?.toString() ?? '';

    final escapedState = jsonEncode(widget.canvasState);
    final escapedData = jsonEncode({
      'participant_name': widget.participantName,
      'name': widget.participantName,
      'event': eventTitle,
      'session': sessionTitle,
      'certificate_code': certificateCode,
      'issued_at': issuedAt,
    });
    final escapedAssetBase = jsonEncode(_assetBaseUrl());

    final showFrame = widget.showFrame ? '1' : '0';

    return '''
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <script src="https://cdnjs.cloudflare.com/ajax/libs/fabric.js/5.3.1/fabric.min.js"></script>
    <style>
      html, body {
        margin: 0;
        width: 100%;
        height: 100%;
        background: #f9fafb;
        overflow: hidden;
      }
      #holder {
        width: 100%;
        height: 100%;
        display: flex;
        align-items: center;
        justify-content: center;
      }
      #wrap {
        position: relative;
        box-shadow: 0 8px 24px rgba(0,0,0,.10);
        border: 1px solid #e5e7eb;
        background: #fff;
      }
      canvas {
        display: block;
      }
    </style>
  </head>
  <body>
    <div id="holder">
      <div id="wrap">
        <canvas id="certCanvas"></canvas>
      </div>
    </div>
    <script>
      const STATE = $escapedState;
      const DATA = $escapedData;
      const ASSET_BASE = $escapedAssetBase;
      const SHOW_FRAME = '$showFrame' === '1';
      window.__certCanvas = null;
      window.__certReady = false;
      window.__certDefaultWidth = 1123;
      window.__certDefaultHeight = 794;

      function rewriteAssetUrl(url) {
        if (typeof url !== 'string' || !url) return url;
        return url
          .replace(/^https?:\\/\\/localhost(?::\\d+)?/i, ASSET_BASE)
          .replace(/^https?:\\/\\/127\\.0\\.0\\.1(?::\\d+)?/i, ASSET_BASE)
          .replace(/^https?:\\/\\/10\\.0\\.2\\.2(?::\\d+)?/i, ASSET_BASE);
      }

      function tokenReplace(text) {
        if (typeof text !== 'string') return text;
        var name = String(DATA.participant_name || DATA.name || '').trim();
        var out = text
          .split('{{participant_name}}').join(name)
          .split('{{name}}').join(name)
          .split('{{event}}').join(String(DATA.event || ''))
          .split('{{session}}').join(String(DATA.session || ''))
          .split('{{certificate_code}}').join(String(DATA.certificate_code || ''))
          .split('{{issued_at}}').join(String(DATA.issued_at || ''));
        if (name) {
          out = out.replace(/\\bStudent Name\\b/g, name);
        }
        return out;
      }

      function isCertificateCodeObject(obj) {
        if (!obj || typeof obj.get !== 'function') return false;
        var id = String(obj.get('id') || '').trim().toLowerCase();
        var name = String(obj.get('name') || '').trim().toLowerCase();
        return id === 'certificate_code' || name === 'certificate code';
      }

      function applyTokensToObject(obj) {
        if (!obj) return;
        var type = (typeof obj.get === 'function')
          ? String(obj.get('type') || '')
          : String(obj.type || '');
        type = type.toLowerCase();

        if (type === 'text' || type === 'i-text' || type === 'textbox') {
          if (isCertificateCodeObject(obj)) {
            obj.set('text', String(DATA.certificate_code || ''));
          } else {
            var current = (typeof obj.get === 'function')
              ? obj.get('text')
              : obj.text;
            obj.set('text', tokenReplace(current));
          }
        }

        if (type === 'image') {
          var src = (typeof obj.getSrc === 'function')
            ? obj.getSrc()
            : ((typeof obj.get === 'function') ? obj.get('src') : obj.src);
          var fixed = rewriteAssetUrl(src);
          if (fixed && fixed !== src && typeof obj.setSrc === 'function') {
            obj.setSrc(fixed, function () {}, { crossOrigin: 'anonymous' });
          } else if (fixed && typeof obj.set === 'function') {
            obj.set('src', fixed);
          }
        }

        if (type === 'group' && typeof obj.getObjects === 'function') {
          obj.getObjects().forEach(applyTokensToObject);
        }
      }

      function rewriteStateUrls(node) {
        if (!node || typeof node !== 'object') return;
        if (typeof node.src === 'string') {
          node.src = rewriteAssetUrl(node.src);
        }
        if (Array.isArray(node.objects)) {
          node.objects.forEach(rewriteStateUrls);
        }
      }

      const parsed = (typeof STATE === 'string') ? JSON.parse(STATE) : STATE;
      rewriteStateUrls(parsed);

      const defaultWidth = Number(parsed.width || 1123);
      const defaultHeight = Number(parsed.height || 794);
      window.__certDefaultWidth = defaultWidth;
      window.__certDefaultHeight = defaultHeight;

      const canvas = new fabric.Canvas('certCanvas', {
        selection: false,
        preserveObjectStacking: true,
      });
      window.__certCanvas = canvas;

      canvas.setWidth(defaultWidth);
      canvas.setHeight(defaultHeight);
      if (parsed.backgroundColor) {
        canvas.backgroundColor = parsed.backgroundColor;
      }

      function fitCanvas() {
        const holder = document.getElementById('holder');
        const wrap = document.getElementById('wrap');
        if (!SHOW_FRAME) {
          wrap.style.boxShadow = 'none';
          wrap.style.border = 'none';
        }
        const maxW = holder.clientWidth - 8;
        const maxH = holder.clientHeight - 8;
        const scale = Math.min(maxW / defaultWidth, maxH / defaultHeight);
        wrap.style.width = (defaultWidth * scale) + 'px';
        wrap.style.height = (defaultHeight * scale) + 'px';
        canvas.setZoom(scale);
        canvas.setDimensions({ width: defaultWidth * scale, height: defaultHeight * scale });
        canvas.renderAll();
      }

      canvas.loadFromJSON(parsed, function () {
        canvas.getObjects().forEach(function (obj) {
          applyTokensToObject(obj);
          obj.selectable = false;
          obj.evented = false;
        });
        canvas.renderAll();
        fitCanvas();
        window.__certReady = true;
        if (window.CertBridge && CertBridge.postMessage) {
          CertBridge.postMessage(JSON.stringify({ type: 'ready' }));
        }
      });

      window.__exportCertPng = function () {
        try {
          if (!window.__certCanvas) {
            return JSON.stringify({ ok: false, error: 'missing_canvas' });
          }
          var zoom = canvas.getZoom() || 1;
          var multiplier = zoom > 0 ? (1 / zoom) : 1;
          var dataUrl = canvas.toDataURL({
            format: 'png',
            multiplier: multiplier,
            enableRetinaScaling: false
          });
          return JSON.stringify({ ok: true, data: dataUrl });
        } catch (e) {
          return JSON.stringify({ ok: false, error: String(e) });
        }
      };

      window.addEventListener('resize', fitCanvas);
      setTimeout(fitCanvas, 50);
    </script>
  </body>
</html>
''';
  }

  void _handleBridgeMessage(JavaScriptMessage message) {
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is Map && decoded['type']?.toString() == 'ready') {
        _canvasReady = true;
        widget.onReady?.call();
      }
    } catch (_) {}
  }

  Future<Uint8List?> exportPng() async {
    for (var i = 0; i < 40 && !_canvasReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    try {
      final raw = await _controller.runJavaScriptReturningResult(
        'window.__exportCertPng ? window.__exportCertPng() : JSON.stringify({ok:false,error:"missing_export"})',
      );
      final asString = raw is String ? raw : raw.toString();
      // Android WebView may wrap the JS string result in extra quotes.
      dynamic decoded;
      try {
        decoded = jsonDecode(asString);
        if (decoded is String) {
          decoded = jsonDecode(decoded);
        }
      } catch (_) {
        return null;
      }
      if (decoded is! Map) return null;
      if (decoded['ok'] != true) return null;
      final dataUrl = decoded['data']?.toString() ?? '';
      final comma = dataUrl.indexOf(',');
      if (comma < 0 || comma >= dataUrl.length - 1) return null;
      return base64Decode(dataUrl.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'CertBridge',
        onMessageReceived: _handleBridgeMessage,
      )
      ..loadHtmlString(_buildCanvasHtml(), baseUrl: _assetBaseUrl());
  }

  @override
  void didUpdateWidget(covariant _CertificateCanvasPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload only when the visible name changes — avoid map-identity flicker.
    if (oldWidget.participantName != widget.participantName) {
      _canvasReady = false;
      _controller.loadHtmlString(_buildCanvasHtml(), baseUrl: _assetBaseUrl());
    }
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
