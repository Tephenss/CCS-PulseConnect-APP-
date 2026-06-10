import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/env.dart';

class MobileBackendService {
  static bool get isConfigured {
    final uri = _baseUri;
    if (uri == null) return false;
    final host = uri.host.trim().toLowerCase();
    return host.isNotEmpty && host != 'your-web-domain';
  }

  static Uri? get _baseUri {
    final raw = Env.mobilePushApiBaseUrl.trim();
    if (raw.isEmpty || raw.contains('YOUR-WEB-DOMAIN')) {
      return null;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return null;
    }
    return uri;
  }

  static Map<String, String> _headers() {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final key = Env.mobilePushApiKey.trim();
    if (key.isNotEmpty && !key.contains('YOUR_SHARED_KEY')) {
      headers['X-Mobile-Api-Key'] = key;
    }
    return headers;
  }

  static Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (!isConfigured) {
      return {
        'ok': false,
        'error':
            'Hosted backend is not configured. Set mobilePushApiBaseUrl in env.dart.',
      };
    }

    final base = _baseUri!;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = base.replace(path: normalizedPath);

    try {
      final response = await http
          .post(uri, headers: _headers(), body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));

      Map<String, dynamic> data = {};
      if (response.body.trim().isNotEmpty) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          data = decoded;
        }
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return {
          'ok': false,
          'error': data['error']?.toString() ??
              'Request failed (HTTP ${response.statusCode}).',
        };
      }

      if (data['ok'] != true) {
        return {
          'ok': false,
          'error': data['error']?.toString() ?? 'Request failed.',
        };
      }

      return data;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[mobile-backend] $path failed: $e');
      }
      return {
        'ok': false,
        'error': normalizeTransportError(e.toString()),
      };
    }
  }

  static String normalizeTransportError(String raw) {
    final message = raw.trim();
    final lower = message.toLowerCase();
    if (lower.contains('failed host lookup') ||
        lower.contains('socketexception') ||
        lower.contains('network is unreachable') ||
        lower.contains('connection refused') ||
        lower.contains('timed out')) {
      return 'Unable to reach ccspulseconnect.com. Check your internet connection.';
    }
    if (lower.contains('handshake') || lower.contains('certificate')) {
      return 'Secure connection to ccspulseconnect.com failed on this network.';
    }
    if (message.isEmpty) {
      return 'Unable to contact the hosted backend.';
    }
    return message;
  }

  Future<Map<String, dynamic>> sendEmailVerificationCode({
    required String userId,
    required String email,
    required String fullName,
  }) {
    return post('/api/mobile_email_verification_send.php', {
      'user_id': userId,
      'email': email.trim().toLowerCase(),
      'full_name': fullName.trim(),
    });
  }

  Future<Map<String, dynamic>> sendPasswordResetCode({
    required String email,
  }) {
    return post('/api/mobile_password_reset_send.php', {
      'email': email.trim().toLowerCase(),
    });
  }

  Future<Map<String, dynamic>> sendUnderReviewEmail({
    required String userId,
    required String email,
    required String fullName,
  }) {
    return post('/api/mobile_email_under_review_send.php', {
      'user_id': userId,
      'email': email.trim().toLowerCase(),
      'full_name': fullName.trim(),
    });
  }
}
