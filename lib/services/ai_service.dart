import 'mobile_backend_service.dart';

class AiService {
  final MobileBackendService _backend = MobileBackendService();

  Future<Map<String, dynamic>> improveText(String rawText) async {
    if (rawText.trim().isEmpty) {
      return {'ok': false, 'error': 'No text provided.'};
    }

    if (!MobileBackendService.isConfigured) {
      return {
        'ok': false,
        'error':
            'Hosted backend is not configured. Set mobilePushApiBaseUrl in env.dart.',
      };
    }

    try {
      final res = await _backend.improveEventDescription(rawText: rawText);
      if (res['ok'] == true) {
        final improved = (res['improved_text']?.toString() ?? '').trim();
        if (improved.isEmpty) {
          return {
            'ok': false,
            'error': 'AI returned an empty response. Please try again.',
          };
        }
        return {
          'ok': true,
          'improved_text': _sanitizeImprovedText(
            rawText: rawText,
            improvedText: improved,
          ),
        };
      }
      final error = (res['error']?.toString() ?? '').trim();
      return {
        'ok': false,
        'error': error.isNotEmpty
            ? error
            : 'AI formatting failed. Please try again.',
      };
    } catch (_) {
      return {
        'ok': false,
        'error':
            'No internet connection. Please check your network and try again.',
      };
    }
  }

  String _sanitizeImprovedText({
    required String rawText,
    required String improvedText,
  }) {
    if (_mentionsPulseConnect(rawText)) {
      return improvedText;
    }

    String cleaned = improvedText;
    final List<RegExp> brandPatterns = <RegExp>[
      RegExp(r'\bCCS\s+PulseConnect\b', caseSensitive: false),
      RegExp(r'\bPulse\s*Connect\b', caseSensitive: false),
      RegExp(r'\bPulseConnect\b', caseSensitive: false),
    ];

    for (final RegExp pattern in brandPatterns) {
      cleaned = cleaned.replaceAll(pattern, '');
    }

    cleaned = cleaned
        .replaceAll(RegExp(r' {2,}'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .replaceAll(RegExp(r' ,'), ',')
        .replaceAll(RegExp(r' \.'), '.')
        .trim();

    return cleaned;
  }

  bool _mentionsPulseConnect(String text) {
    final String lower = text.toLowerCase();
    return lower.contains('pulseconnect') || lower.contains('pulse connect');
  }
}
