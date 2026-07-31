import 'dart:convert';
import 'dart:io';
import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_backup_service.dart';
import 'offline_scan_store.dart';
import 'offline_sync_service.dart';
import 'mobile_backend_service.dart';

class AuthService {
  final _supabase = Supabase.instance.client;
  final OfflineBackupService _offlineBackupService = OfflineBackupService();
  static final RegExp _emailRegex = RegExp(
    r"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$",
    caseSensitive: false,
  );

  static bool _trustInFlight = false;
  static int _lastTrustAttemptMs = 0;
  static const Duration _trustMinInterval = Duration(seconds: 60);

  static bool isValidEmail(String? value) {
    final email = (value ?? '').trim();
    if (email.isEmpty) return false;
    return _emailRegex.hasMatch(email);
  }

  static bool requiresDailyEmailVerification(Map<String, dynamic>? user) {
    if (user == null) return true;
    final isVerified = user['email_verified'] == true;
    if (!isVerified) return true;

    final verifiedAtRaw = user['email_verified_at']?.toString() ?? '';
    if (verifiedAtRaw.isEmpty) return true;

    final verifiedAt = DateTime.tryParse(verifiedAtRaw)?.toUtc();
    if (verifiedAt == null) return true;

    // Calendar-day reset at 12:00 AM (UTC+8 / Asia-Manila) for all users.
    const tzOffset = Duration(hours: 8);
    final nowLocal = DateTime.now().toUtc().add(tzOffset);
    final verifiedLocal = verifiedAt.add(tzOffset);
    final nowDay = DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
    final verifiedDay = DateTime(
      verifiedLocal.year,
      verifiedLocal.month,
      verifiedLocal.day,
    );
    return nowDay.isAfter(verifiedDay);
  }

  static const String _cachedPublicIpKey = 'trusted_public_ip_cache';
  static const String _cachedPublicIpAtKey = 'trusted_public_ip_cached_at';

  /// Public IP trust key shared across browsers/apps on the same network.
  Future<String?> resolvePublicIpTrustKey({bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (!forceRefresh) {
      final cached = (prefs.getString(_cachedPublicIpKey) ?? '').trim();
      final cachedAtMs = prefs.getInt(_cachedPublicIpAtKey) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - cachedAtMs;
      // Cache briefly — carrier/Wi‑Fi IP can change when switching networks.
      if (cached.isNotEmpty && age >= 0 && age < 5 * 60 * 1000) {
        return cached.startsWith('ip:') ? cached : 'ip:$cached';
      }
    }

    String? ip;

    // Prefer our hosted backend so web + app see the same edge IP.
    if (MobileBackendService.isConfigured) {
      try {
        final res = await MobileBackendService.post(
          '/api/mobile_client_ip.php',
          const {},
          timeout: const Duration(seconds: 8),
        );
        if (res['ok'] == true) {
          final key = (res['device_key']?.toString() ?? '').trim();
          if (key.startsWith('ip:')) {
            await prefs.setString(_cachedPublicIpKey, key);
            await prefs.setInt(
              _cachedPublicIpAtKey,
              DateTime.now().millisecondsSinceEpoch,
            );
            return key;
          }
          ip = (res['ip']?.toString() ?? '').trim();
        }
      } catch (e) {
        debugPrint('AuthService.resolvePublicIpTrustKey backend: $e');
      }
    }

    // Fallback: public IP lookup.
    if (ip == null || ip.isEmpty) {
      try {
        final response = await http
            .get(Uri.parse('https://api.ipify.org?format=json'))
            .timeout(const Duration(seconds: 8));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) {
            ip = (decoded['ip']?.toString() ?? '').trim();
          }
        }
      } catch (e) {
        debugPrint('AuthService.resolvePublicIpTrustKey ipify: $e');
      }
    }

    if (ip == null || ip.isEmpty) return null;
    final key = 'ip:${ip.toLowerCase()}';
    await prefs.setString(_cachedPublicIpKey, key);
    await prefs.setInt(
      _cachedPublicIpAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
    return key;
  }

  /// @deprecated Prefer [resolvePublicIpTrustKey]. Kept for older call sites.
  Future<String> getOrCreateDeviceInstallId() async {
    final key = await resolvePublicIpTrustKey();
    return key ?? 'ip:unknown';
  }

  /// True while [login] (or similar) is writing session state.
  /// Mid-session OTP enforcement must not logout during this window.
  static int _authFlowDepth = 0;
  static bool get isAuthFlowBusy => _authFlowDepth > 0;

  /// True while the email OTP gate is the active root screen.
  static bool _otpGateActive = false;
  static bool get isOtpGateActive => _otpGateActive;
  static void setOtpGateActive(bool active) => _otpGateActive = active;

  static Future<T> runAuthFlow<T>(Future<T> Function() action) async {
    _authFlowDepth++;
    try {
      return await action();
    } finally {
      _authFlowDepth = (_authFlowDepth - 1).clamp(0, 1 << 30);
    }
  }

  /// `true` trusted, `false` not trusted, `null` could not determine (IP/network).
  Future<bool?> checkDeviceTrust(String userId) async {
    final id = userId.trim();
    if (id.isEmpty) return false;
    try {
      final deviceKey = await resolvePublicIpTrustKey();
      if (deviceKey == null || deviceKey.isEmpty) {
        return null;
      }
      if (!MobileBackendService.isConfigured) {
        return null;
      }
      final res = await MobileBackendService().checkDeviceTrust(
        deviceKey: deviceKey,
      );
      if (res['ok'] != true) return null;
      return res['trusted'] == true;
    } catch (_) {
      return null;
    }
  }

  Future<void> trustCurrentDevice(String userId, {String? label}) async {
    final id = userId.trim();
    if (id.isEmpty) return;
    if (!MobileBackendService.isConfigured) {
      debugPrint('AuthService.trustCurrentDevice skipped: backend not configured');
      return;
    }

    // Debounce: resume/idle was hammering the API and flooding logs on 500s.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_trustInFlight ||
        (nowMs - _lastTrustAttemptMs) < _trustMinInterval.inMilliseconds) {
      return;
    }
    _trustInFlight = true;
    _lastTrustAttemptMs = nowMs;

    try {
      final deviceKey = await resolvePublicIpTrustKey(forceRefresh: true);
      if (deviceKey == null || deviceKey.isEmpty) return;
      final platform = Platform.isAndroid
          ? 'android'
          : (Platform.isIOS ? 'ios' : Platform.operatingSystem);
      final res = await MobileBackendService().trustDevice(
        deviceKey: deviceKey,
        platform: platform,
        label: (label ?? deviceKey).trim().isEmpty
            ? deviceKey
            : (label ?? deviceKey).trim(),
      );
      if (res['ok'] != true) {
        debugPrint(
          'AuthService.trustCurrentDevice failed: ${res['error'] ?? 'unknown'}',
        );
      }
    } catch (e) {
      debugPrint('AuthService.trustCurrentDevice failed: $e');
    } finally {
      _trustInFlight = false;
    }
  }

  /// Strict trust check for login OTP gates. Unknown IP ⇒ not trusted.
  Future<bool> isTrustedDevice(String userId) async {
    return (await checkDeviceTrust(userId)) == true;
  }

  /// OTP is required when the Manila day rolled over OR this public IP is new.
  Future<bool> requiresEmailVerification(
    Map<String, dynamic>? user, {
    bool unknownTrustRequiresVerification = true,
  }) async {
    if (requiresDailyEmailVerification(user)) return true;
    final userId = user?['id']?.toString().trim() ?? '';
    if (userId.isEmpty) return true;
    final trusted = await checkDeviceTrust(userId);
    if (trusted == null) return unknownTrustRequiresVerification;
    return !trusted;
  }

  /// Why OTP is required: `unverified` | `daily` | `new_ip` | null (not required).
  Future<String?> emailVerificationGateReason(Map<String, dynamic>? user) async {
    if (user == null) return 'unverified';
    final isVerified = user['email_verified'] == true;
    final verifiedAtRaw = user['email_verified_at']?.toString() ?? '';
    if (!isVerified || verifiedAtRaw.isEmpty) return 'unverified';

    if (requiresDailyEmailVerification(user)) return 'daily';

    final userId = user['id']?.toString().trim() ?? '';
    if (userId.isEmpty) return 'unverified';
    final trusted = await checkDeviceTrust(userId);
    if (trusted != true) return 'new_ip';
    return null;
  }

  static String emailVerificationReasonMessage(String? reason) {
    switch ((reason ?? '').trim().toLowerCase()) {
      case 'daily':
        return 'Daily security check — verification resets every day at 12:00 AM (Manila).';
      case 'new_ip':
      case 'new_device':
        return 'New network/IP detected — verify once to trust this connection.';
      case 'unverified':
        return 'Verify your email to continue.';
      default:
        return 'Enter the 6-digit code sent to your email.';
    }
  }

  /// Fresh signups can stay blocked while `pending` + verified + app pipeline.
  /// Established accounts should never be locked out by stale `pending` rows.
  static const int _adminReviewGateMaxAgeDays = 21;

  static bool _shouldBypassPendingAdminReviewGate(
    Map<String, dynamic> user,
  ) {
    final raw = user['created_at']?.toString().trim() ?? '';
    if (raw.isEmpty) return false;
    final created = DateTime.tryParse(raw)?.toUtc();
    if (created == null) return false;
    final days = DateTime.now().toUtc().difference(created).inDays;
    return days >= _adminReviewGateMaxAgeDays;
  }

  // Check if user is logged in (requires opaque mobile session token).
  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id');
    if (userId == null || userId.isEmpty) return false;
    final token = await MobileBackendService.getSessionToken();
    return token != null && token.isNotEmpty;
  }

  Map<String, dynamic> _stripPassword(Map<String, dynamic> user) {
    final copy = Map<String, dynamic>.from(user);
    copy.remove('password');
    copy.remove('password_hash');
    return copy;
  }

  Future<void> _persistLocalUser(Map<String, dynamic> user) async {
    final prefs = await SharedPreferences.getInstance();
    final safe = _stripPassword(user);
    final role = (safe['role']?.toString() ?? 'student');
    await prefs.setString('user_id', safe['id'].toString());
    await prefs.setString('user_role', role);
    await prefs.setString('user_data', jsonEncode(safe));
  }

  // Get current user data from SharedPreferences
  Future<Map<String, dynamic>?> getCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final userData = prefs.getString('user_data');
    if (userData != null) {
      final parsed = jsonDecode(userData) as Map<String, dynamic>;
      final parsedId = parsed['id']?.toString() ?? '';
      final userId = parsedId.isNotEmpty
          ? parsedId
          : (prefs.getString('user_id') ?? '');
      if (parsedId.isEmpty && userId.isNotEmpty) {
        parsed['id'] = userId;
      }

      final cachedRole =
          (parsed['role']?.toString() ??
                  prefs.getString('user_role') ??
                  'student')
              .trim();
      if (cachedRole.isNotEmpty) {
        parsed['role'] = cachedRole;
      }

      if (userId.isNotEmpty) {
        _mergeAvatarCache(parsed, prefs, userId);
      }

      // Avatars bucket is private (security lockdown). Always refresh via PHP
      // BFF signed URL when we have a storage path + mobile session.
      final photoUrl = (parsed['photo_url'] as String?) ?? '';
      final photoPath =
          (parsed['photo_path'] as String?) ??
          _extractStoragePathFromUrl(photoUrl);
      final hasPath = photoPath != null && photoPath.isNotEmpty;
      if (hasPath) {
        try {
          final freshSigned = await _resolveAvatarUrl(photoPath);
          if (freshSigned != null && freshSigned.isNotEmpty) {
            parsed['photo_url'] = _withCacheBuster(freshSigned);
            parsed['photo_path'] = photoPath;
            if (userId.isNotEmpty) {
              await _saveAvatarCache(
                prefs,
                userId,
                parsed['photo_url'].toString(),
                photoPath: photoPath,
              );
            }
            await prefs.setString('user_data', jsonEncode(parsed));
          }
        } catch (_) {
          // Keep old URL if refresh fails.
        }
      }

      // If we only have a path but URL is empty, rebuild a fresh URL.
      final refreshedPhotoUrl = (parsed['photo_url'] as String?) ?? '';
      final refreshedPhotoPath =
          (parsed['photo_path'] as String?) ??
          _extractStoragePathFromUrl(refreshedPhotoUrl);
      if (refreshedPhotoUrl.isEmpty &&
          refreshedPhotoPath != null &&
          refreshedPhotoPath.isNotEmpty) {
        try {
          final rebuilt = await _resolveAvatarUrl(refreshedPhotoPath);
          if (rebuilt != null && rebuilt.isNotEmpty) {
            final rebuiltWithCache = _withCacheBuster(rebuilt);
            parsed['photo_url'] = rebuiltWithCache;
            parsed['photo_path'] = refreshedPhotoPath;
            if (userId.isNotEmpty) {
              await _saveAvatarCache(
                prefs,
                userId,
                rebuiltWithCache,
                photoPath: refreshedPhotoPath,
              );
            }
            await prefs.setString('user_data', jsonEncode(parsed));
          }
        } catch (_) {
          // Keep current state.
        }
      }

      // Last resort: upload convention is profiles/{userId}.{ext}.
      final stillEmpty =
          ((parsed['photo_url'] as String?) ?? '').trim().isEmpty;
      if (stillEmpty && userId.isNotEmpty) {
        try {
          final guessedPath = await _guessAvatarPath(userId);
          if (guessedPath != null && guessedPath.isNotEmpty) {
            final rebuilt = await _resolveAvatarUrl(guessedPath);
            if (rebuilt != null && rebuilt.isNotEmpty) {
              final rebuiltWithCache = _withCacheBuster(rebuilt);
              parsed['photo_url'] = rebuiltWithCache;
              parsed['photo_path'] = guessedPath;
              await _saveAvatarCache(
                prefs,
                userId,
                rebuiltWithCache,
                photoPath: guessedPath,
              );
              await prefs.setString('user_data', jsonEncode(parsed));
            }
          }
        } catch (_) {}
      }

      return parsed;
    }
    return null;
  }

  // Refresh current logged-in user from PHP session endpoint.
  Future<Map<String, dynamic>?> refreshCurrentUserFromServer() async {
    try {
      if (!MobileBackendService.isConfigured) return null;
      final res = await MobileBackendService().sessionCheck();
      if (res['ok'] != true) return null;
      final userRaw = res['user'];
      if (userRaw is! Map) return null;
      final user = _stripPassword(Map<String, dynamic>.from(userRaw));
      await _persistLocalUser(user);
      await _offlineBackupService.autoBackupIfConfigured();
      return user;
    } catch (_) {
      return null;
    }
  }

  // Login with email and password, checking the expected role
  Future<Map<String, dynamic>> login(
    String email,
    String password,
    String expectedRole,
  ) async {
    return runAuthFlow(() => _loginImpl(email, password, expectedRole));
  }

  Future<Map<String, dynamic>> _loginImpl(
    String email,
    String password,
    String expectedRole,
  ) async {
    try {
      final normalizedEmail = email.toLowerCase().trim();
      if (!isValidEmail(normalizedEmail)) {
        return {'ok': false, 'error': 'Please enter a valid email address.'};
      }
      if (!MobileBackendService.isConfigured) {
        return {
          'ok': false,
          'error':
              'Hosted backend is not configured. Set mobilePushApiBaseUrl in env.dart.',
        };
      }

      final loginRes = await MobileBackendService().login(
        email: normalizedEmail,
        password: password,
        expectedRole: expectedRole,
      );
      if (loginRes['ok'] != true) {
        return {
          'ok': false,
          'error': loginRes['error']?.toString() ?? 'Login failed.',
        };
      }

      final userRaw = loginRes['user'];
      if (userRaw is! Map) {
        return {'ok': false, 'error': 'Invalid login response.'};
      }
      final user = _stripPassword(Map<String, dynamic>.from(userRaw));
      final role = user['role'] as String? ?? 'student';

      final prefs = await SharedPreferences.getInstance();
      final previousUserData = prefs.getString('user_data');
      if (previousUserData != null) {
        try {
          final prev = jsonDecode(previousUserData) as Map<String, dynamic>;
          if (prev['id']?.toString() == user['id']?.toString()) {
            final incomingPhoto = (user['photo_url'] as String?) ?? '';
            final previousPhoto = (prev['photo_url'] as String?) ?? '';
            if (incomingPhoto.isEmpty && previousPhoto.isNotEmpty) {
              user['photo_url'] = previousPhoto;
            }
            final previousPhotoPath = (prev['photo_path'] as String?) ?? '';
            if (previousPhotoPath.isNotEmpty) {
              user['photo_path'] = previousPhotoPath;
            }
          }
        } catch (_) {}
      }

      final userId = user['id']?.toString() ?? '';
      var restoredOfflineQueueCount = 0;
      var syncedOfflineQueueCount = 0;
      var reconciledOfflineQueueCount = 0;
      if (userId.isNotEmpty) {
        _mergeAvatarCache(user, prefs, userId);
      }
      await _persistLocalUser(user);
      if (userId.isNotEmpty) {
        final cachedPhoto = (user['photo_url'] as String?) ?? '';
        final cachedPath =
            (user['photo_path'] as String?) ??
            _extractStoragePathFromUrl(cachedPhoto);
        if (cachedPhoto.isNotEmpty) {
          await _saveAvatarCache(
            prefs,
            userId,
            cachedPhoto,
            photoPath: cachedPath,
          );
        }
      }
      await _offlineBackupService.autoRestoreIfNeeded();
      if (userId.isNotEmpty) {
        try {
          final offlineSyncService = OfflineSyncService();
          final isTeacher = role.toLowerCase() == 'teacher';
          restoredOfflineQueueCount = await offlineSyncService
              .pendingQueueCount(actorId: userId, isTeacher: isTeacher);
          await offlineSyncService
              .syncPendingQueue(actorId: userId, isTeacher: isTeacher)
              .then((result) {
                syncedOfflineQueueCount = (result['synced'] is num)
                    ? (result['synced'] as num).toInt()
                    : int.tryParse(result['synced']?.toString() ?? '') ?? 0;
                reconciledOfflineQueueCount =
                    (result['conflict_resolved'] is num)
                    ? (result['conflict_resolved'] as num).toInt()
                    : int.tryParse(
                            result['conflict_resolved']?.toString() ?? '',
                          ) ??
                          0;
              });
          await offlineSyncService.refreshSnapshotForCurrentScanner(
            actorId: userId,
            isTeacher: isTeacher,
          );
        } catch (_) {}
      }
      await _offlineBackupService.autoBackupIfConfigured(force: true);

      return {
        'ok': true,
        'user': user,
        'restored_offline_queue_count': restoredOfflineQueueCount,
        'synced_offline_queue_count': syncedOfflineQueueCount,
        'reconciled_offline_queue_count': reconciledOfflineQueueCount,
      };
    } catch (e) {
      return {'ok': false, 'error': 'Connection error. Please try again.'};
    }
  }

  // Register new student account via PHP (never writes password via anon key).
  Future<Map<String, dynamic>> register({
    required String firstName,
    required String middleName,
    required String lastName,
    required String suffix,
    required String idNumber,
    required String course,
    required String email,
    required String password,
  }) async {
    try {
      final normalizedEmail = email.toLowerCase().trim();
      if (!isValidEmail(normalizedEmail)) {
        return {'ok': false, 'error': 'Please enter a valid email address.'};
      }
      if (!MobileBackendService.isConfigured) {
        return {
          'ok': false,
          'error':
              'Hosted backend is not configured. Set mobilePushApiBaseUrl in env.dart.',
        };
      }

      final normalizedCourse = course.trim().toUpperCase();
      if (normalizedCourse != 'IT' && normalizedCourse != 'CS') {
        return {
          'ok': false,
          'error': 'Please select a valid course (IT or CS).',
        };
      }

      final result = await MobileBackendService().registerUser({
        'first_name': firstName.trim(),
        'middle_name': middleName.trim(),
        'last_name': lastName.trim(),
        'suffix': suffix.trim(),
        'student_id': idNumber.trim(),
        'course': normalizedCourse,
        'email': normalizedEmail,
        'password': password,
      });

      if (result['ok'] != true) {
        return {
          'ok': false,
          'error': result['error']?.toString() ?? 'Registration failed.',
        };
      }

      final userRaw = result['user'];
      final user = userRaw is Map
          ? _stripPassword(Map<String, dynamic>.from(userRaw))
          : null;
      return {'ok': true, 'user': user};
    } catch (e) {
      return {'ok': false, 'error': 'Registration failed: ${e.toString()}'};
    }
  }

  Future<void> _unregisterDevicePushToken({String? userId}) async {
    try {
      String? token;
      try {
        token = await FirebaseMessaging.instance.getToken();
      } catch (_) {
        token = null;
      }
      await MobileBackendService().secureWrite('fcm_delete', {
        if (token != null && token.isNotEmpty) 'token': token,
      });
    } catch (_) {
      // Non-fatal: logout/session clear must continue.
    }
  }

  // Logout
  Future<void> logout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      await _unregisterDevicePushToken(userId: userId);
      try {
        await MobileBackendService().logout();
      } catch (_) {
        await MobileBackendService.clearSessionToken();
      }
    } catch (e) {
      await MobileBackendService.clearSessionToken();
    }
    final prefs = await SharedPreferences.getInstance();
    final preservedStringLists = <String, List<String>>{};
    final preservedInts = <String, int>{};
    for (final key in prefs.getKeys()) {
      if (key == 'shown_local_interactive_notifications' ||
          key.startsWith('shown_local_interactive_notifications_') ||
          key == 'pwd_changes' ||
          key.startsWith('pwd_changes_')) {
        final value = prefs.getStringList(key);
        if (value != null) {
          preservedStringLists[key] = List<String>.from(value);
        }
      }
      // Keep OTP resend cooldown across logout / back → login so we don't spam.
      if (key.startsWith('email_verify_cooldown_until_')) {
        final value = prefs.getInt(key);
        if (value != null) {
          preservedInts[key] = value;
        }
      }
    }
    await prefs.clear();
    for (final entry in preservedStringLists.entries) {
      await prefs.setStringList(entry.key, entry.value);
    }
    for (final entry in preservedInts.entries) {
      await prefs.setInt(entry.key, entry.value);
    }
    await OfflineScanStore.instance.clearAll();
    await _offlineBackupService.autoBackupIfConfigured();
  }

  /// Clear local login markers so the app is not treated as fully signed-in.
  ///
  /// [keepMobileSession]: OTP gate only — keep the opaque session from login so
  /// post-verify APIs (avatar signed URLs, FCM, inbox, device trust) still work.
  /// Do not unregister push or wipe the offline scan store in that mode.
  Future<void> clearLocalSessionMarkers({bool keepMobileSession = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id');
    if (!keepMobileSession) {
      await _unregisterDevicePushToken(userId: userId);
      await MobileBackendService.clearSessionToken();
      await OfflineScanStore.instance.clearAll();
    }
    await prefs.remove('user_id');
    await prefs.remove('user_role');
    await prefs.remove('user_data');
    await _offlineBackupService.autoBackupIfConfigured();
  }

  /// Persist user after OTP and restore avatar URL from local cache when missing.
  Future<void> persistUserAfterOtp(Map<String, dynamic> user) async {
    final prefs = await SharedPreferences.getInstance();
    final safe = _stripPassword(user);
    final userId = safe['id']?.toString() ?? '';
    if (userId.isNotEmpty) {
      _mergeAvatarCache(safe, prefs, userId);
      final photoUrl = (safe['photo_url'] as String?) ?? '';
      final photoPath =
          (safe['photo_path'] as String?) ??
          _extractStoragePathFromUrl(photoUrl);
      if (photoUrl.isNotEmpty) {
        await _saveAvatarCache(
          prefs,
          userId,
          photoUrl,
          photoPath: photoPath,
        );
      }
    }
    await _persistLocalUser(safe);
  }

  // Simple password hashing (for MVP)
  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  // Proper password verification supporting both SHA-256 (old mobile) and Bcrypt (web)
  bool _verifyBcryptPassword(String password, String storedHash) {
    if (storedHash.startsWith('\$2y\$') ||
        storedHash.startsWith('\$2b\$') ||
        storedHash.startsWith('\$2a\$')) {
      try {
        // Use native Dart bcrypt verification for PHP web hashes
        return BCrypt.checkpw(password, storedHash);
      } catch (e) {
        return false;
      }
    }
    // Fallback for local mobile SHA-256 hashes
    final hash = _hashPassword(password);
    return hash == storedHash;
  }

  // Get student year level derived from active section
  Future<String?> getStudentYearLevel() async {
    try {
      final user = await getCurrentUser();
      if (user == null || user['section_id'] == null) return null;
      final sections = await getSections();
      if (sections.isEmpty) return null;
      final sec = sections.firstWhere(
        (s) => s['id'] == user['section_id'],
        orElse: () => {},
      );
      if (sec.isEmpty) return null;
      final name = sec['name']?.toString().toLowerCase() ?? '';
      if (name.contains('1')) return '1';
      if (name.contains('2')) return '2';
      if (name.contains('3')) return '3';
      if (name.contains('4')) return '4';
      return null;
    } catch (_) {
      return null;
    }
  }

  // Resolve student course code with fallback to section name.
  // Returns 'BSIT', 'BSCS', or null when unknown.
  Future<String?> getStudentCourseCode() async {
    try {
      final user = await getCurrentUser();
      if (user == null) return null;

      final direct = (user['course']?.toString() ?? '').trim().toUpperCase();
      if (direct == 'IT' || direct == 'BSIT') return 'BSIT';
      if (direct == 'CS' || direct == 'BSCS') return 'BSCS';

      final sectionId = user['section_id']?.toString();
      if (sectionId == null || sectionId.isEmpty) return null;

      final sections = await getSections();
      if (sections.isEmpty) return null;
      final sec = sections.firstWhere(
        (s) => s['id']?.toString() == sectionId,
        orElse: () => {},
      );
      if (sec.isEmpty) return null;

      final name = (sec['name']?.toString() ?? '').trim().toUpperCase();
      if (name.startsWith('BSIT') || name.startsWith('IT ')) return 'BSIT';
      if (name.startsWith('BSCS') || name.startsWith('CS ')) return 'BSCS';

      return null;
    } catch (_) {
      return null;
    }
  }

  // Get sections list for section selection
  Future<List<Map<String, dynamic>>> getSections() async {
    try {
      try {
        final response = await _supabase
            .from('sections')
            .select('id, name')
            .eq('status', 'active')
            .order('name');
        return List<Map<String, dynamic>>.from(response);
      } catch (_) {
        // Compatibility fallback for schemas without `status` column.
        final response = await _supabase
            .from('sections')
            .select('id, name')
            .order('name');
        return List<Map<String, dynamic>>.from(response);
      }
    } catch (e) {
      return [];
    }
  }

  // Update User Section
  Future<Map<String, dynamic>> updateSection(String sectionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      if (userId == null) return {'ok': false, 'error': 'Not logged in'};

      final response = await MobileBackendService().updateProfile({
        'section_id': sectionId,
      });
      if (response['ok'] != true) {
        return {
          'ok': false,
          'error': response['error']?.toString() ?? 'Failed to update section',
        };
      }

      final userRaw = response['user'];
      final user = userRaw is Map
          ? _stripPassword(Map<String, dynamic>.from(userRaw))
          : null;
      if (user != null) {
        await _persistLocalUser(user);
      }
      await _offlineBackupService.autoBackupIfConfigured();

      return {'ok': true, 'user': user};
    } catch (e) {
      return {
        'ok': false,
        'error': 'Failed to update section: ${e.toString()}',
      };
    }
  }

  // Update User Photo URL
  Future<Map<String, dynamic>> updatePhotoUrl(
    String photoUrl, {
    String? photoPath,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      if (userId == null) return {'ok': false, 'error': 'Not logged in'};

      String? warning;

      try {
        final response = await MobileBackendService().updateProfile({
          'photo_url': photoUrl,
        });
        if (response['ok'] != true) {
          warning =
              'Photo uploaded, but profile sync failed: ${response['error']}';
        }
      } catch (e) {
        warning =
            'Photo uploaded, but profile sync to users table failed: ${e.toString()}';
      }

      final userDataStr = prefs.getString('user_data');
      final Map<String, dynamic> userData = userDataStr != null
          ? (jsonDecode(userDataStr) as Map<String, dynamic>)
          : <String, dynamic>{'id': userId};
      userData['photo_url'] = photoUrl;
      if (photoPath != null && photoPath.isNotEmpty) {
        userData['photo_path'] = photoPath;
      }
      await prefs.setString('user_data', jsonEncode(_stripPassword(userData)));
      await _saveAvatarCache(
        prefs,
        userId,
        photoUrl,
        photoPath: photoPath ?? _extractStoragePathFromUrl(photoUrl),
      );
      final response = <String, dynamic>{'ok': true, 'user': userData};
      if (warning != null) {
        response['warning'] = warning;
      }
      await _offlineBackupService.autoBackupIfConfigured();
      return response;
    } catch (e) {
      return {'ok': false, 'error': 'Photo update failed: ${e.toString()}'};
    }
  }

  // Upload Avatar to Supabase Storage
  Future<Map<String, dynamic>> uploadAvatar(File file) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      if (userId == null) return {'ok': false, 'error': 'Not logged in'};

      final fileExt = file.path.split('.').last;
      // Use fixed filename (userId) to replace existing photo instead of piling up new files
      final fileName = '$userId.$fileExt';
      final filePath = 'profiles/$fileName';

      // 1. Upload to Supabase Storage (Bucket: avatars) with upsert: true
      await _supabase.storage
          .from('avatars')
          .upload(
            filePath,
            file,
            fileOptions: const FileOptions(
              cacheControl: '0',
              upsert: true,
            ), // Set cacheControl to 0
          );

      // 2. Resolve a usable URL:
      //    - Prefer public URL if avatar bucket is public/readable.
      //    - Fallback to signed URL if public read is blocked.
      final resolvedUrl = await _resolveAvatarUrl(filePath);
      if (resolvedUrl == null || resolvedUrl.isEmpty) {
        return {
          'ok': false,
          'error':
              'Image uploaded to storage, but could not get a readable URL. Check avatars bucket read policy/public access.',
        };
      }

      // 3. Add timestamp for cache busting (so app knows it's a new version)
      final cacheBusterUrl = _withCacheBuster(resolvedUrl);

      // 4. Update profile
      return await updatePhotoUrl(cacheBusterUrl, photoPath: filePath);
    } catch (e) {
      return {'ok': false, 'error': 'Upload failed: ${e.toString()}'};
    }
  }

  Future<String?> _resolveAvatarUrl(String filePath) async {
    final path = filePath.trim().replaceFirst(RegExp(r'^/+'), '');
    if (path.isEmpty) return null;

    // Prefer PHP BFF (service role) — avatars bucket is private; anon cannot sign.
    if (MobileBackendService.isConfigured) {
      try {
        final token = await MobileBackendService.getSessionToken();
        if (token != null && token.isNotEmpty) {
          final res = await MobileBackendService().createSignedStorageUrl(
            bucket: 'avatars',
            path: path,
            expiresIn: 60 * 60 * 12,
          );
          final signed = (res['signed_url']?.toString() ?? '').trim();
          if (res['ok'] == true && signed.isNotEmpty) {
            return signed;
          }
        }
      } catch (_) {}
    }

    final publicUrl = _supabase.storage.from('avatars').getPublicUrl(path);
    if (await _isUrlReachable(publicUrl)) return publicUrl;

    try {
      final signedUrl = await _supabase.storage
          .from('avatars')
          .createSignedUrl(path, 60 * 60 * 24);
      if (signedUrl.isNotEmpty) return signedUrl;
    } catch (_) {}

    return null;
  }

  Future<bool> _isUrlReachable(String url) async {
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 3));
      return res.statusCode >= 200 && res.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  bool _isSupabaseSignedAvatarUrl(String url) {
    return url.contains('/storage/v1/object/sign/avatars/');
  }

  bool _isSupabasePublicAvatarUrl(String url) {
    return url.contains('/storage/v1/object/public/avatars/');
  }

  bool _isMissingPhotoUrlColumn(Object e) {
    final msg = e.toString();
    return msg.contains("Could not find the 'photo_url' column") ||
        msg.contains('PGRST204') ||
        msg.contains('column "photo_url" does not exist');
  }

  String _withCacheBuster(String url) {
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}t=${DateTime.now().millisecondsSinceEpoch}';
  }

  String _avatarUrlKey(String userId) => 'avatar_url_$userId';
  String _avatarPathKey(String userId) => 'avatar_path_$userId';

  Future<void> _saveAvatarCache(
    SharedPreferences prefs,
    String userId,
    String photoUrl, {
    String? photoPath,
  }) async {
    if (userId.isEmpty || photoUrl.isEmpty) return;
    await prefs.setString(_avatarUrlKey(userId), photoUrl);
    if (photoPath != null && photoPath.isNotEmpty) {
      await prefs.setString(_avatarPathKey(userId), photoPath);
    }
  }

  void _mergeAvatarCache(
    Map<String, dynamic> userData,
    SharedPreferences prefs,
    String userId,
  ) {
    if (userId.isEmpty) return;
    final cachedUrl = prefs.getString(_avatarUrlKey(userId)) ?? '';
    final cachedPath = prefs.getString(_avatarPathKey(userId)) ?? '';
    final currentUrl = (userData['photo_url'] as String?) ?? '';
    final currentPath = (userData['photo_path'] as String?) ?? '';

    if (currentUrl.isEmpty && cachedUrl.isNotEmpty) {
      userData['photo_url'] = cachedUrl;
    }
    if (currentPath.isEmpty && cachedPath.isNotEmpty) {
      userData['photo_path'] = cachedPath;
    }
  }

  String? _extractStoragePathFromUrl(String url) {
    if (url.isEmpty) return null;
    final trimmed = url.trim();
    // Already a storage object path (e.g. profiles/{userId}.jpg).
    if (!trimmed.contains('://') &&
        (trimmed.startsWith('profiles/') || trimmed.startsWith('avatars/'))) {
      return trimmed.startsWith('avatars/')
          ? trimmed.substring('avatars/'.length)
          : trimmed;
    }
    try {
      final uri = Uri.parse(trimmed);
      final path =
          uri.path; // /storage/v1/object/(public|sign)/avatars/<filePath>

      final publicMarker = '/storage/v1/object/public/avatars/';
      final signMarker = '/storage/v1/object/sign/avatars/';

      if (path.contains(publicMarker)) {
        return path.split(publicMarker).last;
      }
      if (path.contains(signMarker)) {
        return path.split(signMarker).last;
      }
    } catch (_) {
      // no-op
    }
    return null;
  }

  /// After lockdown, photo_url may be a dead public URL with no photo_path.
  /// Upload convention is profiles/{userId}.{ext}.
  Future<String?> _guessAvatarPath(String userId) async {
    final id = userId.trim();
    if (id.isEmpty) return null;
    for (final ext in ['jpg', 'jpeg', 'png', 'webp']) {
      final path = 'profiles/$id.$ext';
      final url = await _resolveAvatarUrl(path);
      if (url != null &&
          url.isNotEmpty &&
          await _isUrlReachable(url)) {
        return path;
      }
    }
    return null;
  }
}
