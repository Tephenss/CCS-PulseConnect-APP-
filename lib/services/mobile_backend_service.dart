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

  static Map<String, dynamic>? _tryDecodeJsonResponse(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return {};
    }

    final lower = trimmed.toLowerCase();
    if (lower.startsWith('<!doctype') ||
        lower.startsWith('<html') ||
        lower.startsWith('<')) {
      return null;
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  static bool _isEndpointUnavailable(http.Response response) {
    if (response.statusCode == 404 || response.statusCode == 405) {
      return true;
    }

    final body = response.body.trim().toLowerCase();
    return body.startsWith('<!doctype') || body.startsWith('<html');
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

      final parsed = _tryDecodeJsonResponse(response.body);
      if (parsed == null) {
        if (_isEndpointUnavailable(response)) {
          return {
            'ok': false,
            'endpoint_unavailable': true,
            'error': 'Registration service is temporarily unavailable.',
          };
        }

        return {
          'ok': false,
          'error': 'Invalid server response.',
        };
      }

      final data = parsed;

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
    } on FormatException {
      return {
        'ok': false,
        'endpoint_unavailable': true,
        'error': 'Registration service is temporarily unavailable.',
      };
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
    if (lower.contains('formatexception') ||
        lower.contains('<!doctype html>') ||
        lower.contains('unexpected character')) {
      return 'Registration service is temporarily unavailable.';
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

  Future<Map<String, dynamic>> registerForEvent({
    required String eventId,
    required String userId,
  }) {
    return post('/api/mobile_register_event.php', {
      'event_id': eventId.trim(),
      'user_id': userId.trim(),
    });
  }

  Future<Map<String, dynamic>> getEventRegistrationInfo({
    required String eventId,
    String? userId,
  }) {
    final payload = <String, dynamic>{'event_id': eventId.trim()};
    final trimmedUserId = userId?.trim() ?? '';
    if (trimmedUserId.isNotEmpty) {
      payload['user_id'] = trimmedUserId;
    }
    return post('/api/mobile_event_registration_info.php', payload);
  }
}
