import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/env.dart';

class AiService {
  static const List<String> _preferredModels = <String>[
    'gemini-2.5-flash',
    'gemini-2.0-flash',
    'gemini-2.0-flash-lite',
  ];

  static const int _maxAttemptsPerModel = 2;
  static List<String>? _cachedModels;

  Future<Map<String, dynamic>> improveText(String rawText) async {
    if (rawText.trim().isEmpty) {
      return {'ok': false, 'error': 'No text provided.'};
    }

    if (Env.geminiApiKey.trim().isEmpty ||
        Env.geminiApiKey == 'YOUR_GEMINI_API_KEY') {
      return {
        'ok': false,
        'error': 'Gemini API key is missing. Please set Env.geminiApiKey.',
      };
    }

    final String systemPrompt =
        "You are an expert event copywriter and AI editor for the College of Computer Studies (CCS). "
        "Your job is to POLISH and EXPAND the user's raw notes into an engaging event description while STRICTLY PRESERVING their identity and specific context.\n"
        "REQUIREMENTS:\n"
        "1. IDENTITY PRESERVATION: If the user provides their name or introduces themselves (for example, 'Hi, I am Mark...'), you MUST retain this in the final output. Polish it into a professional opening but NEVER remove the name.\n"
        "2. DO NOT MENTION PULSECONNECT: Do NOT mention the system/platform PulseConnect anywhere in your response unless the user explicitly types it in their raw text.\n"
        "3. INTELLIGENT EXPANSION: Analyze the user's core idea and expand it significantly into a professional, engaging announcement. Add relevant highlights, goals, or what to expect if they fit the context of a university IT event.\n"
        "4. FIX AND POLISH: Correct typos, mixed Taglish, and grammar. Make the tone sophisticated and exciting but grounded in the user's original intent.\n"
        "5. CRITICAL LAYOUT: Format the output nicely using multiple short paragraphs. You may use dashes '-' for key highlights.\n"
        "6. CRITICAL RAW TEXT CONSTRAINT: DO NOT use markdown formatting. No asterisks (**), no markdown bolding, no markdown italics. Output must be plain text.\n"
        "7. Output ONLY the final polished text with no introductory phrases (like 'Here is the improved text:').";

    final Map<String, dynamic> payload = <String, dynamic>{
      'contents': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'parts': <Map<String, String>>[
            <String, String>{
              'text': '$systemPrompt\n\nRAW TEXT TO FORMAT:\n$rawText',
            },
          ],
        },
      ],
    };

    final List<String> models = await _resolveModels();
    String lastError = 'AI service is currently busy. Please try again.';

    for (final String model in models) {
      for (int attempt = 1; attempt <= _maxAttemptsPerModel; attempt++) {
        final String url =
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=${Env.geminiApiKey}';

        try {
          final http.Response response = await http
              .post(
                Uri.parse(url),
                headers: const <String, String>{
                  'Content-Type': 'application/json',
                },
                body: jsonEncode(payload),
              )
              .timeout(const Duration(seconds: 45));

          if (response.statusCode == 200) {
            final dynamic jsonRes = jsonDecode(response.body);
            final String formattedText =
                jsonRes['candidates']?[0]?['content']?['parts']?[0]?['text']
                        ?.toString() ??
                    '';

            if (formattedText.trim().isEmpty) {
              lastError = 'AI returned an empty response. Please try again.';
            } else {
              final String cleanedText = _sanitizeImprovedText(
                rawText: rawText,
                improvedText: formattedText,
              );
              return {'ok': true, 'improved_text': cleanedText.trim()};
            }
          } else {
            final String apiMsg = _extractApiError(response.body);

            if (response.statusCode == 404) {
              // Model not available for this key/version. Try next discovered model.
              lastError = 'AI model "$model" is not available for this project.';
              break;
            }

            if (response.statusCode == 429 || response.statusCode == 503) {
              lastError =
                  'AI is busy right now (${response.statusCode}). Please wait a few seconds and try again.';
              if (attempt < _maxAttemptsPerModel) {
                await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
                continue;
              }
              break;
            }

            if (response.statusCode == 401 || response.statusCode == 403) {
              return {
                'ok': false,
                'error': 'AI key is invalid or restricted. Check Gemini key settings.',
              };
            }

            return {
              'ok': false,
              'error': 'API Error ${response.statusCode}: $apiMsg',
            };
          }
        } on TimeoutException {
          lastError = 'AI request timed out. Please try again.';
          if (attempt < _maxAttemptsPerModel) {
            await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
            continue;
          }
          break;
        } on SocketException {
          return {
            'ok': false,
            'error':
                'No internet connection. Please check your network and try again.',
          };
        } catch (e) {
          return {'ok': false, 'error': 'Connection Error: $e'};
        }
      }
    }

    return {'ok': false, 'error': lastError};
  }

  Future<List<String>> _resolveModels() async {
    if (_cachedModels != null && _cachedModels!.isNotEmpty) {
      return _cachedModels!;
    }

    final List<String> discovered = await _fetchAvailableModels();
    final List<String> ordered =
        _orderModels(discovered.isNotEmpty ? discovered : _preferredModels);
    _cachedModels = ordered;
    return ordered;
  }

  Future<List<String>> _fetchAvailableModels() async {
    try {
      final String url =
          'https://generativelanguage.googleapis.com/v1beta/models?key=${Env.geminiApiKey}';
      final http.Response response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return <String>[];

      final dynamic decoded = jsonDecode(response.body);
      final List<dynamic> items =
          (decoded is Map && decoded['models'] is List)
              ? List<dynamic>.from(decoded['models'] as List)
              : const <dynamic>[];

      final Set<String> out = <String>{};
      for (final dynamic item in items) {
        if (item is! Map) continue;
        final String name = item['name']?.toString() ?? '';
        final List<String> methods = item['supportedGenerationMethods'] is List
            ? List<String>.from(
                (item['supportedGenerationMethods'] as List<dynamic>)
                    .map((dynamic e) => e.toString()),
              )
            : const <String>[];

        if (!name.startsWith('models/')) continue;
        if (!methods.contains('generateContent')) continue;

        final String shortName = name.substring('models/'.length);
        final String lower = shortName.toLowerCase();
        if (!lower.contains('gemini')) continue;
        if (lower.contains('embedding') || lower.contains('aqa')) continue;

        out.add(shortName);
      }

      return out.toList();
    } catch (_) {
      return <String>[];
    }
  }

  List<String> _orderModels(List<String> models) {
    final Set<String> remaining = models.toSet();
    final List<String> ordered = <String>[];

    for (final String preferred in _preferredModels) {
      if (remaining.remove(preferred)) {
        ordered.add(preferred);
      }
    }

    final List<String> rest = remaining.toList()..sort();
    ordered.addAll(rest);
    return ordered;
  }

  String _extractApiError(String body) {
    try {
      final dynamic decoded = jsonDecode(body);
      final dynamic error = decoded['error'];
      if (error is Map && error['message'] != null) {
        return error['message'].toString();
      }
    } catch (_) {
      // Fallback below.
    }
    return body.isEmpty ? 'Unknown API error' : body;
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
