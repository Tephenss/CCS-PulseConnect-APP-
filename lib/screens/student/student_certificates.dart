import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
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
    final fromCert = _participantName(cert);
    if (fromCert.isNotEmpty) return fromCert;

    try {
      final user = await AuthService().getCurrentUser();
      if (user != null) {
        final composed = _composeUserDisplayName(user);
        if (composed.isNotEmpty) return composed;
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
          if (composed.isNotEmpty) return composed;
        }
      }
    } catch (_) {}

    return '';
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

    final messenger = ScaffoldMessenger.of(context);
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
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Certificate file is unavailable for download.'),
          ),
        );
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
        messenger.showSnackBar(
          SnackBar(content: Text('Saved to Downloads as $savedName')),
        );
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
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to download certificate.')),
      );
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
    _loadCertificates();
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
      final resolvedName = await _resolveParticipantName({
        if (certs.isNotEmpty) ...certs.first,
      });
      final enriched = certs.map((cert) {
        final existing = _participantName(cert);
        if (existing.isNotEmpty) return cert;
        if (resolvedName.isEmpty) return cert;
        return {
          ...cert,
          'participant_name': resolvedName,
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
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: _studentPrimary(context),
        centerTitle: true,
        title: const Text(
          'Certificates',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, color: Colors.white),
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
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
                              prefixIcon: const Icon(Icons.search_rounded),
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
                                  : const Icon(Icons.tune_rounded),
                              filled: true,
                              fillColor: const Color(0xFFFCFCFC),
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 14,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: const Color(0xFFE5E7EB),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: const Color(0xFFE5E7EB),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: _studentPrimary(context),
                                  width: 1.4,
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

    return GestureDetector(
      onTap: () => _showCertificatePreview(cert),
      child: SizedBox(
        width: double.infinity,
        child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          boxShadow: [
            BoxShadow(
              color: const Color(0x1A111827),
              blurRadius: 14,
              offset: const Offset(0, 6),
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
                  top: Radius.circular(15),
                ),
                // Real Fabric preview (same as tap) — replaces baked {{participant_name}} thumbs.
                child: _CertificateListCanvasThumb(
                  cert: cert,
                  participantName: _participantName(cert),
                  title: eventTitle,
                  fallback: _buildCertificateThumbnail(cert),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (seminarLabel != null && seminarLabel.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: const Color(0xFFFBBF24)),
                      ),
                      child: Text(
                        seminarLabel,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF92400E),
                        ),
                      ),
                    ),
                  Text(
                    eventTitle,
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: Color(0xFF1F2937),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    startDate != null
                        ? DateFormat('MMM dd, yyyy').format(startDate)
                        : '--',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: const Color(0xFF6B7280),
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
    );
  }

  void _showCertificatePreview(Map<String, dynamic> cert) async {
    final titleParts = _resolveTitleParts(cert);
    final eventTitle = titleParts.eventTitle;
    final seminarLabel = titleParts.seminarLabel;
    final title = eventTitle;
    final participantName = await _resolveParticipantName(cert);
    var canvasState = _parseCanvasState(cert['template_canvas_state']);
    if (canvasState == null) {
      canvasState = await _eventService.fetchCertificateCanvasState(
        templateId: cert['template_id']?.toString(),
        sessionTemplateId: cert['session_template_id']?.toString(),
      );
      if (canvasState != null) {
        cert = {
          ...cert,
          'template_canvas_state': canvasState,
        };
      }
    }
    final canvasKey = GlobalKey<_CertificateCanvasPreviewState>();

    if (!mounted) return;

    var isSaving = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
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
              // Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        seminarLabel == null || seminarLabel.isEmpty
                            ? eventTitle
                            : '$eventTitle - $seminarLabel',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Color(0xFF1F2937),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: Colors.grey.shade500),
                      onPressed: isSaving ? null : () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              
              // Certificate Preview
              Container(
                height: 340,
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF9FAFB),
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: canvasState != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _CertificateCanvasPreview(
                          key: canvasKey,
                          cert: cert,
                          title: title,
                          participantName: participantName,
                          canvasState: canvasState,
                          showFrame: true,
                        ),
                      )
                    : _hasThumbnail(cert)
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: InteractiveViewer(
                              minScale: 1,
                              maxScale: 4,
                              child: _buildCertificateThumbnail(
                                cert,
                                fit: BoxFit.contain,
                              ),
                            ),
                          )
                    : Stack(
                        alignment: Alignment.center,
                        children: [
                          Column(
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
                                'PROUDLY PRESENTED TO',
                                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                participantName.isNotEmpty
                                    ? participantName
                                    : 'Participant',
                                style: const TextStyle(
                                  fontFamily: 'serif',
                                  fontSize: 24,
                                  fontStyle: FontStyle.italic,
                                  color: Color(0xFF1F2937),
                                ),
                              ),
                              const SizedBox(height: 20),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24),
                                child: Text(
                                  'For successful completion and participation in\n$title',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 10, height: 1.5, color: Colors.grey.shade600),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),

              // Download Button
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: LinearGradient(
                        colors: [_studentDark(context), _studentPrimary(context)],
                      ),
                    ),
                    child: ElevatedButton.icon(
                      onPressed: isSaving
                          ? null
                          : () async {
                              if (isSaving || _isDownloading) return;
                              isSaving = true;
                              _isDownloading = true;
                              setDialogState(() {});
                              try {
                                Uint8List? rendered;
                                final state = canvasKey.currentState;
                                if (state != null) {
                                  rendered = await state.exportPng();
                                }
                                if (!context.mounted) return;
                                await _downloadCertificate(
                                  cert,
                                  renderedImageBytes: rendered,
                                  alreadyLocked: true,
                                );
                              } finally {
                                _isDownloading = false;
                                if (ctx.mounted) {
                                  setDialogState(() => isSaving = false);
                                }
                              }
                            },
                      icon: isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.download_rounded),
                      label: Text(isSaving ? 'SAVING...' : 'DOWNLOAD'),
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
        },
      ),
    );
  }
}

/// List-card certificate preview: loads canvas once and renders like modal preview.
class _CertificateListCanvasThumb extends StatefulWidget {
  const _CertificateListCanvasThumb({
    required this.cert,
    required this.participantName,
    required this.title,
    required this.fallback,
  });

  final Map<String, dynamic> cert;
  final String participantName;
  final String title;
  final Widget fallback;

  @override
  State<_CertificateListCanvasThumb> createState() =>
      _CertificateListCanvasThumbState();
}

class _CertificateListCanvasThumbState extends State<_CertificateListCanvasThumb> {
  final _eventService = EventService();
  Map<String, dynamic>? _canvasState;
  bool _loading = true;
  bool _failed = false;

  Map<String, dynamic>? _parseCanvasState(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
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

  @override
  void initState() {
    super.initState();
    unawaited(_loadCanvas());
  }

  @override
  void didUpdateWidget(covariant _CertificateListCanvasThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.cert['id']?.toString() ?? '';
    final nextId = widget.cert['id']?.toString() ?? '';
    if (oldId != nextId) {
      _canvasState = null;
      _failed = false;
      _loading = true;
      unawaited(_loadCanvas());
    }
  }

  Future<void> _loadCanvas() async {
    var canvas = _parseCanvasState(widget.cert['template_canvas_state']);
    if (canvas == null) {
      try {
        canvas = await _eventService.fetchCertificateCanvasState(
          templateId: widget.cert['template_id']?.toString(),
          sessionTemplateId: widget.cert['session_template_id']?.toString(),
        );
      } catch (_) {
        canvas = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _canvasState = canvas;
      _failed = canvas == null;
      _loading = false;
    });
    if (canvas != null) {
      widget.cert['template_canvas_state'] = canvas;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Stack(
        fit: StackFit.expand,
        children: [
          widget.fallback,
          const ColoredBox(
            color: Color(0x66FFFFFF),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ],
      );
    }

    if (_failed || _canvasState == null) {
      return widget.fallback;
    }

    // IgnorePointer so the parent card GestureDetector still receives taps.
    return IgnorePointer(
      child: _CertificateCanvasPreview(
        cert: widget.cert,
        canvasState: _canvasState!,
        title: widget.title,
        participantName: widget.participantName,
        showFrame: false,
      ),
    );
  }
}

class _CertificateCanvasPreview extends StatefulWidget {
  final Map<String, dynamic> cert;
  final Map<String, dynamic> canvasState;
  final String title;
  final String participantName;
  final bool showFrame;

  const _CertificateCanvasPreview({
    super.key,
    required this.cert,
    required this.canvasState,
    required this.title,
    required this.participantName,
    this.showFrame = true,
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
    if (oldWidget.participantName != widget.participantName ||
        oldWidget.canvasState != widget.canvasState) {
      _canvasReady = false;
      _controller.loadHtmlString(_buildCanvasHtml(), baseUrl: _assetBaseUrl());
    }
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
