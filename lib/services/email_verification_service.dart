import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'mobile_backend_service.dart';

class EmailVerificationService {
  final _supabase = Supabase.instance.client;
  final _mobileBackend = MobileBackendService();
  static const Duration codeTtl = Duration(minutes: 5);
  static const Duration resendCooldown = Duration(seconds: 60);

  String _cooldownKey(String userId) => 'email_verify_cooldown_until_$userId';

  Future<int> getRemainingCooldownSeconds(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final untilMs = prefs.getInt(_cooldownKey(userId)) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (untilMs <= now) return 0;
    return ((untilMs - now) / 1000).ceil();
  }

  Future<void> _setCooldown(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final until = DateTime.now().add(resendCooldown).millisecondsSinceEpoch;
    await prefs.setInt(_cooldownKey(userId), until);
  }

  Future<Map<String, dynamic>> sendCode({
    required String userId,
    required String email,
    required String fullName,
    required bool forceResend,
  }) async {
    final remaining = await getRemainingCooldownSeconds(userId);
    if (forceResend && remaining > 0) {
      return {
        'ok': false,
        'error': 'Please wait ${remaining}s before resending.',
        'cooldown_seconds': remaining,
      };
    }

    final delivery = await _mobileBackend.sendEmailVerificationCode(
      userId: userId,
      email: email,
      fullName: fullName,
    );
    if (delivery['ok'] != true) {
      return {
        'ok': false,
        'error': delivery['error']?.toString() ??
            'Failed to deliver verification email. Please try again.',
      };
    }

    await _setCooldown(userId);
    final expiresAtRaw = delivery['expires_at']?.toString() ?? '';
    final expiresAt = DateTime.tryParse(expiresAtRaw)?.toUtc();
    return {
      'ok': true,
      'expires_at': (expiresAt ?? DateTime.now().toUtc().add(codeTtl))
          .toIso8601String(),
    };
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
  }) async {
    final trimmed = enteredCode.trim();
    if (trimmed.length != 6 || int.tryParse(trimmed) == null) {
      return {'ok': false, 'error': 'Verification code must be 6 digits.'};
    }

    final row = await _supabase
        .from('email_verification_codes')
        .select('code, expires_at')
        .eq('user_id', userId)
        .maybeSingle();

    if (row == null) {
      return {
        'ok': false,
        'error': 'No verification code found. Please resend.',
      };
    }

    final storedCode = row['code']?.toString() ?? '';
    final expiresAtRaw = row['expires_at']?.toString();
    final expiresAt = DateTime.tryParse(expiresAtRaw ?? '')?.toUtc();
    final now = DateTime.now().toUtc();

    if (expiresAt == null || now.isAfter(expiresAt)) {
      return {
        'ok': false,
        'error': 'Verification code expired. Please resend.',
      };
    }

    if (storedCode != trimmed) {
      return {'ok': false, 'error': 'Invalid verification code.'};
    }

    final updatedUser = await _supabase
        .from('users')
        .update({
          'email_verified': true,
          'email_verified_at': now.toIso8601String(),
          'account_status': 'pending',
        })
        .eq('id', userId)
        .select()
        .single();

    await _supabase
        .from('email_verification_codes')
        .delete()
        .eq('user_id', userId);

    if (persistLocalUser) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'user_id',
        (updatedUser['id']?.toString() ?? userId),
      );
      await prefs.setString(
        'user_role',
        (updatedUser['role']?.toString() ?? 'student').toLowerCase(),
      );
      await prefs.setString('user_data', jsonEncode(updatedUser));
    }

    return {'ok': true, 'user': updatedUser};
  }
}
