import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/env.dart';

class MobileBackendService {
  static const Duration _defaultTimeout = Duration(seconds: 15);
  static const Duration _registrationTimeout = Duration(seconds: 45);
  static const Duration _requirementsTimeout = Duration(seconds: 12);
  static const Duration _emailTimeout = Duration(seconds: 45);
  static const String _sessionStorageKey = 'mobile_session_token';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String? _memorySessionToken;

  static bool get isConfigured {
    final uri = _baseUri;
    if (uri == null) return false;
    final host = uri.host.trim().toLowerCase();
    return host.isNotEmpty && host != 'your-web-domain';
  }

  /// True when the hosted PHP base URL answers within [timeout].
  /// Any HTTP response (including 404) counts as reachable; timeouts /
  /// socket failures mean the device should use offline scan mode.
  static Future<bool> probeReachable({
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    final base = _baseUri;
    if (base == null || !isConfigured) return false;

    final uri = base.replace(path: '/api/mobile_ping.php');

    try {
      final response = await http.get(uri).timeout(timeout);
      // Any response from the host means the network path works.
      return response.statusCode > 0;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } on http.ClientException {
      return false;
    } catch (_) {
      return false;
    }
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

  static Future<String?> getSessionToken() async {
    if (_memorySessionToken != null && _memorySessionToken!.isNotEmpty) {
      return _memorySessionToken;
    }
    try {
      final token = await _secureStorage.read(key: _sessionStorageKey);
      _memorySessionToken = (token ?? '').trim();
      if (_memorySessionToken!.isEmpty) return null;
      return _memorySessionToken;
    } catch (_) {
      return _memorySessionToken;
    }
  }

  static Future<void> setSessionToken(String? token) async {
    final cleaned = (token ?? '').trim();
    _memorySessionToken = cleaned.isEmpty ? null : cleaned;
    try {
      if (cleaned.isEmpty) {
        await _secureStorage.delete(key: _sessionStorageKey);
      } else {
        await _secureStorage.write(key: _sessionStorageKey, value: cleaned);
      }
    } catch (e) {
      debugPrint('MobileBackendService.setSessionToken: $e');
    }
  }

  static Future<void> clearSessionToken() => setSessionToken(null);

  static Future<Map<String, String>> _headers({bool withSession = true}) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final key = Env.mobilePushApiKey.trim();
    if (key.isNotEmpty && !key.contains('YOUR_SHARED_KEY')) {
      headers['X-Mobile-Api-Key'] = key;
    }
    if (withSession) {
      final session = await getSessionToken();
      if (session != null && session.isNotEmpty) {
        headers['Authorization'] = 'Bearer $session';
        headers['X-Mobile-Session'] = session;
      }
    }
    return headers;
  }

  static Map<String, dynamic>? _tryDecodeJsonResponse(String body) {
    final trimmed = body.trim();
    // Empty body is not valid JSON — callers must treat null as a transport/server fault.
    // (Previously returned {} which surfaced as the useless "Request failed (HTTP 500)".)
    if (trimmed.isEmpty) {
      return null;
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
    Map<String, dynamic> body, {
    Duration? timeout,
    bool withSession = true,
  }) async {
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
          .post(
            uri,
            headers: await _headers(withSession: withSession),
            body: jsonEncode(body),
          )
          .timeout(timeout ?? _defaultTimeout);

      final parsed = _tryDecodeJsonResponse(response.body);
      if (parsed == null) {
        if (_isEndpointUnavailable(response)) {
          return {
            'ok': false,
            'endpoint_unavailable': true,
            'error': 'Registration service is temporarily unavailable.',
          };
        }

        if (response.body.trim().isEmpty && response.statusCode >= 500) {
          return {
            'ok': false,
            'error':
                'Server crashed (HTTP ${response.statusCode}, empty body). Redeploy missing PHP includes (curl_ssl.php / mobile_session.php) on Hostinger.',
          };
        }

        return {
          'ok': false,
          'error': response.statusCode >= 500
              ? 'Server error (HTTP ${response.statusCode}).'
              : 'Invalid server response.',
        };
      }

      final data = parsed;

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final err = data['error']?.toString().trim();
        final msg = data['message']?.toString().trim();
        return {
          ...data,
          'ok': false,
          'error': (err != null && err.isNotEmpty)
              ? err
              : ((msg != null && msg.isNotEmpty)
                  ? msg
                  : 'Request failed (HTTP ${response.statusCode}).'),
        };
      }

      if (data['ok'] != true) {
        return {
          ...data,
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
    if (lower.contains('timeoutexception') ||
        lower.contains('future not completed') ||
        lower.contains('timed out')) {
      return 'The server is taking longer than expected. Check your connection and try again.';
    }
    if (lower.contains('failed host lookup') ||
        lower.contains('socketexception') ||
        lower.contains('network is unreachable') ||
        lower.contains('connection refused')) {
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

  static Map<String, dynamic> _stripPassword(Map<String, dynamic> user) {
    final copy = Map<String, dynamic>.from(user);
    copy.remove('password');
    copy.remove('password_hash');
    return copy;
  }

  Future<Map<String, dynamic>> login({
    required String identifier,
    required String password,
    required String expectedRole,
  }) async {
    final id = identifier.trim();
    final useEmail = id.contains('@');
    final result = await post(
      '/api/mobile_login.php',
      {
        if (useEmail) 'email': id.toLowerCase(),
        if (!useEmail) 'student_no': id,
        'identifier': id,
        'password': password,
        'role': expectedRole.trim().toLowerCase(),
        'platform': Platform.isAndroid
            ? 'android'
            : (Platform.isIOS ? 'ios' : Platform.operatingSystem),
      },
      withSession: false,
      timeout: const Duration(seconds: 20),
    );
    if (result['ok'] == true) {
      final token = result['session_token']?.toString() ?? '';
      if (token.isNotEmpty) {
        await setSessionToken(token);
      }
      final userRaw = result['user'];
      if (userRaw is Map) {
        result['user'] = _stripPassword(Map<String, dynamic>.from(userRaw));
      }
    }
    return result;
  }

  Future<Map<String, dynamic>> lookupStudentRoster(String studentNo) {
    return post(
      '/api/mobile_roster_lookup.php',
      {'student_no': studentNo.trim()},
      withSession: false,
      timeout: const Duration(seconds: 20),
    );
  }

  Future<Map<String, dynamic>> logout() async {
    final result = await post('/api/mobile_logout.php', {});
    await clearSessionToken();
    return result;
  }

  Future<Map<String, dynamic>> sessionCheck() {
    return post('/api/mobile_session_check.php', {});
  }

  Future<Map<String, dynamic>> registerUser(Map<String, dynamic> payload) {
    return post(
      '/api/mobile_register_user.php',
      payload,
      withSession: false,
      timeout: const Duration(seconds: 30),
    );
  }

  Future<Map<String, dynamic>> parseRegistrationFormPdf({
    required String fileName,
    String? filePath,
    List<int>? bytes,
  }) {
    return _postPdfMultipart(
      path: '/api/mobile_schedule_parse.php',
      fileName: fileName,
      filePath: filePath,
      bytes: bytes,
      withSession: false,
      timeout: const Duration(seconds: 45),
    );
  }

  Future<Map<String, dynamic>> registerUserWithSchedule({
    required String studentId,
    required String email,
    required String password,
    required String fileName,
    String? filePath,
    List<int>? bytes,
  }) {
    return _postPdfMultipart(
      path: '/api/mobile_register_user.php',
      fileName: fileName,
      filePath: filePath,
      bytes: bytes,
      withSession: false,
      fields: {
        'student_id': studentId.trim(),
        'email': email.trim().toLowerCase(),
        'password': password,
      },
      timeout: const Duration(seconds: 60),
    );
  }

  Future<Map<String, dynamic>> fetchClassSchedule() {
    return post('/api/mobile_schedule_get.php', {});
  }

  Future<Map<String, dynamic>> uploadClassSchedulePdf({
    required String fileName,
    String? filePath,
    List<int>? bytes,
  }) {
    return _postPdfMultipart(
      path: '/api/mobile_schedule_upload.php',
      fileName: fileName,
      filePath: filePath,
      bytes: bytes,
      withSession: true,
      timeout: const Duration(seconds: 90),
    );
  }

  Future<Map<String, dynamic>> _postPdfMultipart({
    required String path,
    required String fileName,
    String? filePath,
    List<int>? bytes,
    Map<String, String>? fields,
    bool withSession = true,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (!isConfigured) {
      return {
        'ok': false,
        'error':
            'Hosted backend is not configured. Set mobilePushApiBaseUrl in env.dart.',
      };
    }
    final diskPath = (filePath ?? '').trim();
    final hasPath = diskPath.isNotEmpty;
    final hasBytes = bytes != null && bytes.isNotEmpty;
    if (!hasPath && !hasBytes) {
      return {'ok': false, 'error': 'Select your LU registration form PDF.'};
    }

    final uri = _baseUri!.replace(path: path);
    final request = http.MultipartRequest('POST', uri);
    final key = Env.mobilePushApiKey.trim();
    if (key.isNotEmpty && !key.contains('YOUR_SHARED_KEY')) {
      request.headers['X-Mobile-Api-Key'] = key;
    }
    if (withSession) {
      final session = await getSessionToken();
      if (session != null && session.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $session';
        request.headers['X-Mobile-Session'] = session;
      }
    }
    if (fields != null) {
      request.fields.addAll(fields);
    }
    final safeName =
        fileName.trim().isNotEmpty ? fileName.trim() : 'registration.pdf';
    if (hasPath) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'schedule_file',
          diskPath,
          filename: safeName,
        ),
      );
    } else {
      request.files.add(
        http.MultipartFile.fromBytes(
          'schedule_file',
          bytes!,
          filename: safeName,
        ),
      );
    }

    try {
      final streamed = await request.send().timeout(timeout);
      final response = await http.Response.fromStream(streamed);
      final parsed = _tryDecodeJsonResponse(response.body);
      if (parsed == null) {
        final status = response.statusCode;
        final body = response.body.trim().toLowerCase();
        if (status == 404 || body.contains('not found')) {
          return {
            'ok': false,
            'error':
                'Schedule upload is not on the server yet. Redeploy the latest PHP files and try again.',
          };
        }
        if (status == 413) {
          return {
            'ok': false,
            'error':
                'PDF is too large. Use the original LU Form No. 1 file (8 MB max).',
          };
        }
        return {
          'ok': false,
          'error':
              'Could not read the server reply (HTTP $status). Try again, or ask admin if migration 059 is applied.',
        };
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return {
          'ok': false,
          'error': parsed['error']?.toString() ??
              'Upload failed (HTTP ${response.statusCode}).',
        };
      }
      if (parsed['ok'] != true) {
        return {
          'ok': false,
          'error': parsed['error']?.toString() ?? 'Upload failed.',
        };
      }
      return parsed;
    } catch (e) {
      return {'ok': false, 'error': normalizeTransportError(e.toString())};
    }
  }

  Future<Map<String, dynamic>> verifyPasswordResetCode({
    required String email,
    required String code,
  }) {
    return post(
      '/api/mobile_password_reset_verify.php',
      {
        'email': email.trim().toLowerCase(),
        'code': code.trim(),
      },
      withSession: false,
    );
  }

  Future<Map<String, dynamic>> updatePasswordWithResetToken({
    required String email,
    required String resetToken,
    required String newPassword,
  }) {
    return post(
      '/api/mobile_password_reset_update.php',
      {
        'email': email.trim().toLowerCase(),
        'reset_token': resetToken,
        'new_password': newPassword,
      },
      withSession: false,
    );
  }

  Future<Map<String, dynamic>> verifyEmailCode({
    required String code,
    String? userId,
    String? deviceKey,
    String? platform,
    String? deviceLabel,
  }) {
    final body = <String, dynamic>{'code': code.trim()};
    final id = (userId ?? '').trim();
    if (id.isNotEmpty) body['user_id'] = id;
    final key = (deviceKey ?? '').trim();
    if (key.isNotEmpty) body['device_key'] = key;
    final plat = (platform ?? '').trim();
    if (plat.isNotEmpty) body['platform'] = plat;
    final label = (deviceLabel ?? '').trim();
    if (label.isNotEmpty) body['device_label'] = label;
    return post('/api/mobile_email_verification_verify.php', body);
  }

  Future<Map<String, dynamic>> trustDevice({
    String? deviceKey,
    String? platform,
    String? label,
  }) {
    return post('/api/mobile_trust_device.php', {
      if (deviceKey != null && deviceKey.isNotEmpty) 'device_key': deviceKey,
      if (platform != null && platform.isNotEmpty) 'platform': platform,
      if (label != null && label.isNotEmpty) 'label': label,
    });
  }

  Future<Map<String, dynamic>> checkDeviceTrust({String? deviceKey}) {
    return post('/api/mobile_device_trust_check.php', {
      if (deviceKey != null && deviceKey.isNotEmpty) 'device_key': deviceKey,
    });
  }

  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> fields) {
    return post('/api/mobile_profile_update.php', fields);
  }

  /// Signed URL via PHP BFF (service role). Required after avatars bucket lockdown.
  Future<Map<String, dynamic>> createSignedStorageUrl({
    required String bucket,
    required String path,
    int expiresIn = 3600,
  }) {
    return post('/api/mobile_signed_url.php', {
      'bucket': bucket.trim(),
      'path': path.trim(),
      'expires_in': expiresIn.clamp(60, 86400),
    });
  }

  /// Resolve the logged-in user's avatar via PHP (no anon Storage probing).
  Future<Map<String, dynamic>> resolveOwnAvatar({int expiresIn = 3600}) {
    return post('/api/mobile_signed_url.php', {
      'bucket': 'avatars',
      'find_user_avatar': true,
      'expires_in': expiresIn.clamp(60, 86400),
    });
  }

  Future<Map<String, dynamic>> secureWrite(
    String action,
    Map<String, dynamic> payload,
  ) {
    return post('/api/mobile_secure_write.php', {
      'action': action,
      ...payload,
    });
  }

  Future<Map<String, dynamic>> scanTicket({
    required String ticketPayload,
    bool dryRun = false,
    String? scannedAtIso,
    String? expectedEventId,
  }) {
    return post('/api/mobile_scan_ticket.php', {
      'ticket_payload': ticketPayload,
      'dry_run': dryRun,
      if (scannedAtIso != null && scannedAtIso.trim().isNotEmpty)
        'scanned_at': scannedAtIso.trim(),
      if (expectedEventId != null && expectedEventId.trim().isNotEmpty)
        'expected_event_id': expectedEventId.trim(),
    });
  }

  /// Teacher / student-assistant scan window (opens_at, closes_at, scan_mode).
  /// Prefer this over anon context so offline warm matches mobile_scan_ticket.php.
  Future<Map<String, dynamic>> getScanContext({bool fresh = false}) {
    return post('/api/mobile_scan_context.php', {
      if (fresh) 'fresh': true,
    });
  }

  Future<Map<String, dynamic>> selfCheckInViaEventQr({
    required String eventQrPayload,
    String? scannedAtIso,
  }) {
    return post('/api/mobile_event_self_checkin.php', {
      'event_qr_payload': eventQrPayload.trim(),
      if (scannedAtIso != null && scannedAtIso.trim().isNotEmpty)
        'scanned_at': scannedAtIso.trim(),
    });
  }

  Future<Map<String, dynamic>> getScanAttendanceStats({
    required String eventId,
    String? sessionId,
    String mode = 'check_in',
  }) {
    return post('/api/mobile_scan_attendance_stats.php', {
      'event_id': eventId.trim(),
      if (sessionId != null && sessionId.trim().isNotEmpty)
        'session_id': sessionId.trim(),
      'mode': mode.trim().toLowerCase() == 'check_out'
          ? 'check_out'
          : 'check_in',
    });
  }

  Future<Map<String, dynamic>> improveEventDescription({
    required String rawText,
  }) {
    return post(
      '/api/mobile_ai_improve.php',
      {'raw_text': rawText.trim()},
      timeout: _emailTimeout,
    );
  }

  Future<Map<String, dynamic>> setEventEarlyOut({
    required String eventId,
    String? sessionId,
    required bool enabled,
  }) {
    return post('/api/mobile_event_early_out.php', {
      'event_id': eventId.trim(),
      'action': 'set',
      'enabled': enabled,
      if (sessionId != null && sessionId.trim().isNotEmpty)
        'session_id': sessionId.trim(),
    });
  }

  Future<Map<String, dynamic>> getEventEarlyOutStatus({
    required String eventId,
    String? sessionId,
  }) {
    return post('/api/mobile_event_early_out.php', {
      'event_id': eventId.trim(),
      'action': 'status',
      if (sessionId != null && sessionId.trim().isNotEmpty)
        'session_id': sessionId.trim(),
    });
  }

  Future<Map<String, dynamic>> sendChangePasswordOtp() {
    return post(
      '/api/mobile_change_password.php',
      {'action': 'send_otp'},
      timeout: _emailTimeout,
    );
  }

  Future<Map<String, dynamic>> verifyChangePasswordOtp({
    required String code,
  }) {
    return post('/api/mobile_change_password.php', {
      'action': 'verify_otp',
      'code': code.trim(),
    });
  }

  Future<Map<String, dynamic>> changePassword({
    required String changeToken,
    required String newPassword,
  }) {
    return post('/api/mobile_change_password.php', {
      'action': 'update',
      'change_token': changeToken,
      'new_password': newPassword,
    });
  }

  Future<Map<String, dynamic>> createEventSecure(Map<String, dynamic> payload) {
    return post('/api/mobile_secure_write.php', {
      'action': 'event_create',
      'payload': payload,
    });
  }

  Future<Map<String, dynamic>> assignAssistantSecure({
    required String eventId,
    required String studentId,
    required bool allowScan,
  }) {
    return post('/api/mobile_secure_write.php', {
      'action': 'assistant_assign',
      'event_id': eventId,
      'student_id': studentId,
      'allow_scan': allowScan,
    });
  }

  Future<Map<String, dynamic>> updateAssistantAccessSecure({
    required String eventId,
    String? assistantId,
    String? studentId,
    required bool allowScan,
  }) {
    return post('/api/mobile_secure_write.php', {
      'action': 'assistant_update_access',
      'event_id': eventId,
      'allow_scan': allowScan,
      if (assistantId != null && assistantId.isNotEmpty)
        'assistant_id': assistantId,
      if (studentId != null && studentId.isNotEmpty) 'student_id': studentId,
    });
  }

  Future<Map<String, dynamic>> submitProposalReviewSecure({
    required String eventId,
  }) {
    return post('/api/mobile_secure_write.php', {
      'action': 'proposal_submit_review',
      'event_id': eventId,
    });
  }

  Future<Map<String, dynamic>> uploadAvatarFile({
    required List<int> bytes,
    required String fileName,
  }) async {
    if (!isConfigured) {
      return {
        'ok': false,
        'error':
            'Hosted backend is not configured. Set mobilePushApiBaseUrl in env.dart.',
      };
    }
    if (bytes.isEmpty) {
      return {'ok': false, 'error': 'Selected image is empty.'};
    }

    final base = _baseUri!;
    final uri = base.replace(path: '/api/mobile_avatar_upload.php');
    final request = http.MultipartRequest('POST', uri);

    final key = Env.mobilePushApiKey.trim();
    if (key.isNotEmpty && !key.contains('YOUR_SHARED_KEY')) {
      request.headers['X-Mobile-Api-Key'] = key;
    }
    final session = await getSessionToken();
    if (session != null && session.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $session';
      request.headers['X-Mobile-Session'] = session;
    }

    final safeName = fileName.trim().isNotEmpty ? fileName.trim() : 'avatar.jpg';
    request.files.add(
      http.MultipartFile.fromBytes(
        'avatar_file',
        bytes,
        filename: safeName,
      ),
    );

    try {
      final streamed =
          await request.send().timeout(const Duration(seconds: 45));
      final response = await http.Response.fromStream(streamed);
      final parsed = _tryDecodeJsonResponse(response.body);
      if (parsed == null) {
        return {'ok': false, 'error': 'Invalid server response.'};
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return {
          'ok': false,
          'error': parsed['error']?.toString() ??
              'Upload failed (HTTP ${response.statusCode}).',
        };
      }
      if (parsed['ok'] != true) {
        return {
          'ok': false,
          'error': parsed['error']?.toString() ?? 'Upload failed.',
        };
      }
      return parsed;
    } catch (e) {
      return {
        'ok': false,
        'error': normalizeTransportError(e.toString()),
      };
    }
  }

  Future<Map<String, dynamic>> uploadEventCoverFile({
    required String eventId,
    required List<int> bytes,
    required String fileName,
  }) async {
    if (!isConfigured) {
      return {
        'ok': false,
        'error':
            'Hosted backend is not configured. Set mobilePushApiBaseUrl in env.dart.',
      };
    }
    if (bytes.isEmpty) {
      return {'ok': false, 'error': 'Selected cover image is empty.'};
    }

    final base = _baseUri!;
    final uri = base.replace(path: '/api/mobile_event_cover_upload.php');
    final request = http.MultipartRequest('POST', uri);

    final key = Env.mobilePushApiKey.trim();
    if (key.isNotEmpty && !key.contains('YOUR_SHARED_KEY')) {
      request.headers['X-Mobile-Api-Key'] = key;
    }
    final session = await getSessionToken();
    if (session != null && session.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $session';
      request.headers['X-Mobile-Session'] = session;
    }

    request.fields['event_id'] = eventId.trim();
    request.files.add(
      http.MultipartFile.fromBytes(
        'cover_file',
        bytes,
        filename: fileName,
      ),
    );

    try {
      final streamed = await request.send().timeout(const Duration(seconds: 45));
      final response = await http.Response.fromStream(streamed);
      final parsed = _tryDecodeJsonResponse(response.body);
      if (parsed == null) {
        return {'ok': false, 'error': 'Invalid server response.'};
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return {
          'ok': false,
          'error': parsed['error']?.toString() ??
              'Upload failed (HTTP ${response.statusCode}).',
        };
      }
      if (parsed['ok'] != true) {
        return {
          'ok': false,
          'error': parsed['error']?.toString() ?? 'Upload failed.',
        };
      }
      return parsed;
    } catch (e) {
      return {
        'ok': false,
        'error': normalizeTransportError(e.toString()),
      };
    }
  }

  Future<Map<String, dynamic>> uploadProposalDocumentFile({
    required String eventId,
    required String requirementId,
    required List<int> bytes,
    required String fileName,
  }) async {
    if (!isConfigured) {
      return {
        'ok': false,
        'error':
            'Hosted backend is not configured. Set mobilePushApiBaseUrl in env.dart.',
      };
    }

    final base = _baseUri!;
    final uri =
        base.replace(path: '/api/mobile_proposal_document_upload.php');
    final request = http.MultipartRequest('POST', uri);

    final key = Env.mobilePushApiKey.trim();
    if (key.isNotEmpty && !key.contains('YOUR_SHARED_KEY')) {
      request.headers['X-Mobile-Api-Key'] = key;
    }
    final session = await getSessionToken();
    if (session != null && session.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $session';
      request.headers['X-Mobile-Session'] = session;
    }

    request.fields['event_id'] = eventId.trim();
    request.fields['requirement_id'] = requirementId.trim();
    request.files.add(
      http.MultipartFile.fromBytes(
        'proposal_file',
        bytes,
        filename: fileName,
      ),
    );

    try {
      final streamed =
          await request.send().timeout(const Duration(seconds: 45));
      final response = await http.Response.fromStream(streamed);
      final parsed = _tryDecodeJsonResponse(response.body);
      if (parsed == null) {
        return {'ok': false, 'error': 'Invalid server response.'};
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return {
          'ok': false,
          'error': parsed['error']?.toString() ??
              'Upload failed (HTTP ${response.statusCode}).',
        };
      }
      if (parsed['ok'] != true) {
        return {
          'ok': false,
          'error': parsed['error']?.toString() ?? 'Upload failed.',
        };
      }
      return parsed;
    } catch (e) {
      return {
        'ok': false,
        'error': normalizeTransportError(e.toString()),
      };
    }
  }

  Future<Map<String, dynamic>> getMyTicketsSecure() {
    return post('/api/mobile_my_tickets.php', {}, timeout: _registrationTimeout);
  }

  Future<Map<String, dynamic>> getSelfAttendancePack() {
    return post(
      '/api/mobile_self_attendance_pack.php',
      {},
      timeout: _registrationTimeout,
    );
  }

  Future<Map<String, dynamic>> getTeacherBlocksSecure() {
    return post('/api/mobile_teacher_blocks.php', {});
  }

  Future<Map<String, dynamic>> getTeacherBlockStudentsSecure({
    required String sectionId,
  }) {
    return post('/api/mobile_teacher_blocks.php', {
      'section_id': sectionId.trim(),
    });
  }

  Future<Map<String, dynamic>> getEventRosterSecure({
    required String eventId,
    required String type,
  }) {
    return post(
      '/api/mobile_event_roster.php',
      {
        'event_id': eventId.trim(),
        'type': type.trim(),
      },
      timeout: _registrationTimeout,
    );
  }

  Future<Map<String, dynamic>> secureRead({
    required String table,
    String select = '*',
    Map<String, dynamic>? filters,
    int limit = 100,
  }) {
    return post('/api/mobile_secure_read.php', {
      'table': table,
      'select': select,
      'filters': filters ?? {},
      'limit': limit,
    });
  }

  Future<Map<String, dynamic>> sendEmailVerificationCode({
    required String userId,
    required String email,
    required String fullName,
  }) {
    return post(
      '/api/mobile_email_verification_send.php',
      {
        'user_id': userId,
        'email': email.trim().toLowerCase(),
        'full_name': fullName.trim(),
      },
      timeout: _emailTimeout,
    );
  }

  Future<Map<String, dynamic>> sendPasswordResetCode({
    required String email,
  }) {
    return post(
      '/api/mobile_password_reset_send.php',
      {
        'email': email.trim().toLowerCase(),
      },
      withSession: false,
      timeout: _emailTimeout,
    );
  }

  Future<Map<String, dynamic>> sendUnderReviewEmail({
    required String userId,
    required String email,
    required String fullName,
  }) {
    return post(
      '/api/mobile_email_under_review_send.php',
      {
        'user_id': userId,
        'email': email.trim().toLowerCase(),
        'full_name': fullName.trim(),
      },
      timeout: _emailTimeout,
    );
  }

  Future<Map<String, dynamic>> registerForEvent({
    required String eventId,
    required String userId,
  }) {
    return post(
      '/api/mobile_register_event.php',
      {
        'event_id': eventId.trim(),
        'user_id': userId.trim(),
      },
      timeout: _registrationTimeout,
    );
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
    return post(
      '/api/mobile_event_registration_info.php',
      payload,
      timeout: _requirementsTimeout,
    );
  }

  Future<Map<String, dynamic>> getStudentRequirementsInfo({
    required String eventId,
    required String userId,
  }) {
    return post(
      '/api/mobile_student_requirements_info.php',
      {
        'event_id': eventId.trim(),
        'user_id': userId.trim(),
      },
      timeout: _requirementsTimeout,
    );
  }

  Future<Map<String, dynamic>> submitStudentRequirements({
    required String eventId,
    required String userId,
  }) {
    return post(
      '/api/mobile_student_requirements_submit.php',
      {
        'event_id': eventId.trim(),
        'user_id': userId.trim(),
      },
      timeout: _requirementsTimeout,
    );
  }

  Future<Map<String, dynamic>> uploadStudentRequirementFile({
    required String eventId,
    required String requirementId,
    required String userId,
    required String fileName,
    required String mimeType,
    List<int>? bytes,
    String? filePath,
  }) async {
    if (!isConfigured) {
      return {
        'ok': false,
        'error':
            'Hosted backend is not configured. Set mobilePushApiBaseUrl in env.dart.',
      };
    }

    final path = (filePath ?? '').trim();
    final hasPath = path.isNotEmpty;
    final hasBytes = bytes != null && bytes.isNotEmpty;
    if (!hasPath && !hasBytes) {
      return {'ok': false, 'error': 'No file selected.'};
    }

    final base = _baseUri!;
    final uri =
        base.replace(path: '/api/mobile_student_requirement_document_upload.php');
    final request = http.MultipartRequest('POST', uri);

    final key = Env.mobilePushApiKey.trim();
    if (key.isNotEmpty && !key.contains('YOUR_SHARED_KEY')) {
      request.headers['X-Mobile-Api-Key'] = key;
    }
    final session = await getSessionToken();
    if (session != null && session.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $session';
      request.headers['X-Mobile-Session'] = session;
    }

    request.fields['event_id'] = eventId.trim();
    request.fields['requirement_id'] = requirementId.trim();
    request.fields['user_id'] = userId.trim();

    // Prefer streaming from disk — avoids loading full PDFs into RAM on low-end phones.
    if (hasPath) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'student_file',
          path,
          filename: fileName,
        ),
      );
    } else {
      request.files.add(
        http.MultipartFile.fromBytes(
          'student_file',
          bytes!,
          filename: fileName,
        ),
      );
    }

    try {
      final streamed = await request.send().timeout(const Duration(seconds: 90));
      final response = await http.Response.fromStream(streamed);
      final parsed = _tryDecodeJsonResponse(response.body);
      if (parsed == null) {
        return {'ok': false, 'error': 'Invalid server response.'};
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return {
          'ok': false,
          'error': parsed['error']?.toString() ??
              'Upload failed (HTTP ${response.statusCode}).',
        };
      }
      if (parsed['ok'] != true) {
        return {
          'ok': false,
          'error': parsed['error']?.toString() ?? 'Upload failed.',
        };
      }
      return parsed;
    } catch (e) {
      return {
        'ok': false,
        'error': normalizeTransportError(e.toString()),
      };
    }
  }
}
