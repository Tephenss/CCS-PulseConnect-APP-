import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
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
  String _searchQuery = '';

  Color _studentPrimary(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
  Color _studentDark(BuildContext context) =>
      CourseThemeUtils.studentDarkFromPrimary(_studentPrimary(context));

  String _participantName(Map<String, dynamic> cert) {
    final raw = cert['participant_name']?.toString().trim() ?? '';
    return raw.isNotEmpty ? raw : 'Student Name';
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

  Future<void> _downloadCertificate(Map<String, dynamic> cert) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final raw = cert['thumbnail_url']?.toString().trim() ?? '';
      Uint8List? bytes;

      final decoded = _decodeThumbnailBytes(raw);
      if (decoded != null) {
        bytes = decoded;
      } else if (raw.startsWith('http://') || raw.startsWith('https://')) {
        final response = await http.get(Uri.parse(raw));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          bytes = response.bodyBytes;
        }
      }

      if (bytes == null || bytes.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Certificate file is unavailable for download.'),
          ),
        );
        return;
      }

      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'certificate_$ts.png';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          text: 'Your CCS PulseConnect certificate',
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to download certificate.')),
      );
    }
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
      _loadCertificates();
    }
  }

  Future<void> _loadCertificates({bool showLoader = false}) async {
    if (showLoader && mounted) {
      setState(() {
        _isLoading = true;
      });
    }
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    final certs = await _eventService.getMyCertificates(userId);
    if (mounted) {
      setState(() {
        _certificates = certs;
        _isLoading = false;
      });
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
    final sessionTitle = (session['title']?.toString() ?? '').trim();

    String eventTitle = rawTitle;
    String? seminarLabel;

    if (rawTitle.contains(' - ')) {
      final idx = rawTitle.indexOf(' - ');
      eventTitle = rawTitle.substring(0, idx).trim();
      seminarLabel = rawTitle.substring(idx + 3).trim();
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
              onRefresh: _loadCertificates,
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
    final participantName = _participantName(cert);
    final canvasState = _parseCanvasState(cert['template_canvas_state']);
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
                child: canvasState != null
                    ? AbsorbPointer(
                        child: _CertificateCanvasPreview(
                          cert: cert,
                          title: eventTitle,
                          participantName: participantName,
                          canvasState: canvasState,
                          showFrame: false,
                        ),
                      )
                    : _buildCertificateThumbnail(cert),
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
    final participantName = _participantName(cert);
    final canvasState = _parseCanvasState(cert['template_canvas_state']);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
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
                      onPressed: () => Navigator.pop(context),
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
                                participantName,
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
                      onPressed: () {
                        _downloadCertificate(cert);
                      },
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('DOWNLOAD'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: Colors.white,
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
    required this.cert,
    required this.canvasState,
    required this.title,
    required this.participantName,
    this.showFrame = true,
  });

  @override
  State<_CertificateCanvasPreview> createState() => _CertificateCanvasPreviewState();
}

class _CertificateCanvasPreviewState extends State<_CertificateCanvasPreview> {
  late final WebViewController _controller;

  String _buildCanvasHtml() {
    final event = widget.cert['events'] is Map
        ? Map<String, dynamic>.from(widget.cert['events'] as Map)
        : <String, dynamic>{};
    final session = widget.cert['session'] is Map
        ? Map<String, dynamic>.from(widget.cert['session'] as Map)
        : <String, dynamic>{};

    final eventTitle = event['title']?.toString() ?? widget.title;
    final sessionTitle = session['title']?.toString() ?? '';
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
      const SHOW_FRAME = '$showFrame' === '1';

      function tokenReplace(text) {
        if (typeof text !== 'string') return text;
        return text
          .replace(/{{participant_name}}/g, DATA.participant_name || '')
          .replace(/{{name}}/g, DATA.name || DATA.participant_name || '')
          .replace(/{{event}}/g, DATA.event || '')
          .replace(/{{session}}/g, DATA.session || '')
          .replace(/{{certificate_code}}/g, DATA.certificate_code || '')
          .replace(/{{issued_at}}/g, DATA.issued_at || '');
      }

      function walk(obj) {
        if (!obj || typeof obj !== 'object') return;
        if (typeof obj.text === 'string') {
          obj.text = tokenReplace(obj.text);
        }
        if (typeof obj.placeholder === 'string') {
          obj.placeholder = tokenReplace(obj.placeholder);
        }
        if (Array.isArray(obj.objects)) {
          obj.objects.forEach(walk);
        }
        if (Array.isArray(obj._objects)) {
          obj._objects.forEach(walk);
        }
      }

      const parsed = (typeof STATE === 'string') ? JSON.parse(STATE) : STATE;
      walk(parsed);

      const defaultWidth = Number(parsed.width || 1123);
      const defaultHeight = Number(parsed.height || 794);
      const canvas = new fabric.Canvas('certCanvas', {
        selection: false,
        preserveObjectStacking: true,
      });

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
        canvas.forEachObject(function (obj) {
          obj.selectable = false;
          obj.evented = false;
        });
        canvas.renderAll();
        fitCanvas();
      });

      window.addEventListener('resize', fitCanvas);
      setTimeout(fitCanvas, 50);
    </script>
  </body>
</html>
''';
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..loadHtmlString(_buildCanvasHtml());
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
