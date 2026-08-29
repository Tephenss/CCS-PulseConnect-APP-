import 'package:shared_preferences/shared_preferences.dart';

import 'mobile_backend_service.dart';
import 'auth_service.dart';

class EmailVerificationService {
  final _mobileBackend = MobileBackendService();
  static const Duration codeTtl = Duration(minutes: 5);
  static const Duration resendCooldown = Duration(seconds: 60);
  /// Prevents double-mount (home+route) from sending two different codes.
  static final Map<String, Future<Map<String, dynamic>>> _inFlightSend = {};

  /// Cooldown is per user+purpose so signup OTP never blocks login OTP.
  String _cooldownKey(String userId, String purpose) =>
      'email_verify_cooldown_until_${purpose}_$userId';

  String _flightKey(String userId, String purpose) => '$purpose:$userId';

  String normalizePurpose(String? raw) {
    final p = (raw ?? '').trim().toLowerCase();
    if (p == 'signup' ||
        p == 'register' ||
        p == 'registration' ||
        p == 'create') {
      return 'signup';
    }
    return 'login';
  }

  Future<int> getRemainingCooldownSeconds(
    String userId, {
    String purpose = 'login',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _cooldownKey(userId, normalizePurpose(purpose));
    final untilMs = prefs.getInt(key) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (untilMs <= now) return 0;
    return ((untilMs - now) / 1000).ceil();
  }

  Future<void> _setCooldown(
    String userId, {
    required String purpose,
    int? seconds,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final wait =
        Duration(seconds: (seconds ?? resendCooldown.inSeconds).clamp(1, 300));
    final until = DateTime.now().add(wait).millisecondsSinceEpoch;
    await prefs.setInt(_cooldownKey(userId, purpose), until);
  }

  Future<Map<String, dynamic>> sendCode({
    required String userId,
    required String email,
    required String fullName,
    required bool forceResend,
    String purpose = 'login',
  }) async {
    final resolvedPurpose = normalizePurpose(purpose);
    final remaining = await getRemainingCooldownSeconds(
      userId,
      purpose: resolvedPurpose,
    );
    if (remaining > 0) {
      if (forceResend) {
        return {
          'ok': false,
          'error': 'Please wait ${remaining}s before resending.',
          'cooldown_seconds': remaining,
        };
      }
      // Auto-send on screen open: don't fire a second email while cooldown runs.
      return {
        'ok': true,
        'cooldown_seconds': remaining,
        'skipped': true,
        'purpose': resolvedPurpose,
      };
    }

    // Coalesce concurrent auto-sends for the same user+purpose.
    final flightKey = _flightKey(userId, resolvedPurpose);
    final existing = _inFlightSend[flightKey];
    if (existing != null && !forceResend) {
      return existing;
    }

    final future = () async {
      final delivery = await _mobileBackend.sendEmailVerificationCode(
        userId: userId,
        email: email,
        fullName: fullName,
        purpose: resolvedPurpose,
      );
      if (delivery['ok'] != true) {
        return {
          'ok': false,
          'error': delivery['error']?.toString() ??
              'Failed to deliver verification email. Please try again.',
        };
      }

      final serverCooldown = delivery['cooldown_seconds'];
      final cooldownSecs = serverCooldown is num
          ? serverCooldown.toInt()
          : int.tryParse(serverCooldown?.toString() ?? '') ??
              resendCooldown.inSeconds;
      await _setCooldown(
        userId,
        purpose: resolvedPurpose,
        seconds: cooldownSecs,
      );
      final skipped = delivery['skipped'] == true;
      final expiresAtRaw = delivery['expires_at']?.toString() ?? '';
      final expiresAt = DateTime.tryParse(expiresAtRaw)?.toUtc();
      return {
        'ok': true,
        'skipped': skipped,
        'purpose': resolvedPurpose,
        'cooldown_seconds': cooldownSecs,
        'expires_at': (expiresAt ?? DateTime.now().toUtc().add(codeTtl))
            .toIso8601String(),
      };
    }();

    _inFlightSend[flightKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightSend[flightKey], future)) {
        _inFlightSend.remove(flightKey);
      }
    }
  }

  Future<bool> sendUnderReviewEmail({
    required String email,
    required String fullName,
    String? userId,
  }) async {
    final resolvedUserId = (userId ?? '').trim();
    if (resolvedUserId.isEmpty) {
      return false;
    }

    final result = await _mobileBackend.sendUnderReviewEmail(
      userId: resolvedUserId,
      email: email,
      fullName: fullName,
    );
    return result['ok'] == true;
  }

  Future<Map<String, dynamic>> verifyCode({
    required String userId,
    required String enteredCode,
    bool persistLocalUser = true,
    String purpose = 'login',
  }) async {
    final trimmed = enteredCode.trim();
    if (trimmed.length != 6 || int.tryParse(trimmed) == null) {
      return {'ok': false, 'error': 'Verification code must be 6 digits.'};
    }

    final resolvedPurpose = normalizePurpose(purpose);
    final result = await _mobileBackend.verifyEmailCode(
      code: trimmed,
      userId: userId,
      purpose: resolvedPurpose,
    );
    if (result['ok'] != true) {
      return {
        'ok': false,
        'error': result['error']?.toString() ?? 'Invalid verification code.',
      };
    }

    Map<String, dynamic>? updatedUser;
    final userRaw = result['user'];
    if (userRaw is Map) {
      updatedUser = Map<String, dynamic>.from(userRaw);
      updatedUser.remove('password');
      updatedUser.remove('password_hash');
    }

    try {
      await AuthService().trustCurrentDevice(userId, force: true);
    } catch (_) {}

    if (persistLocalUser && updatedUser != null) {
      await AuthService().persistUserAfterOtp(updatedUser);
    }

    return {'ok': true, 'user': updatedUser, 'purpose': resolvedPurpose};
  }
}
