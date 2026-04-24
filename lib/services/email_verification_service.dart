import 'dart:math';
import 'dart:convert';

import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server/gmail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

class EmailVerificationService {
  final _supabase = Supabase.instance.client;
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

  String _generateCode() {
    final random = Random.secure();
    final code = random.nextInt(1000000);
    return code.toString().padLeft(6, '0');
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

    final code = _generateCode();
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(codeTtl);

    await _supabase.from('email_verification_codes').upsert({
      'user_id': userId,
      'code': code,
      'expires_at': expiresAt.toIso8601String(),
      'created_at': now.toIso8601String(),
      'last_sent_at': now.toIso8601String(),
    });

    await _setCooldown(userId);

    final deliveryOk = await _deliverEmailCode(
      email: email,
      fullName: fullName,
      code: code,
    );
    if (!deliveryOk) {
      return {
        'ok': false,
        'error':
            'Failed to deliver verification email. Please check sender SMTP settings.',
      };
    }

    return {'ok': true, 'expires_at': expiresAt.toIso8601String()};
  }

  Future<bool> _deliverEmailCode({
    required String email,
    required String fullName,
    required String code,
  }) async {
    final displayName = fullName.trim().isEmpty
        ? 'CCS PulseConnect User'
        : fullName.trim();
    return _sendEmail(
      recipientEmail: email,
      subject: 'CCS PulseConnect Email Verification Code',
      textBody:
          '''
Hello $displayName,

Your verification code is: $code

This code expires in ${codeTtl.inMinutes} minutes.
If you did not request this, please ignore this email.
''',
      htmlBody:
          '''
<div style="font-family: Arial, sans-serif; color: #111827;">
  <h2 style="margin:0 0 8px 0;">CCS PulseConnect</h2>
  <p>Hello <strong>$displayName</strong>,</p>
  <p>Your verification code is:</p>
  <p style="font-size:28px; font-weight:700; letter-spacing:4px; margin:12px 0;">$code</p>
  <p>This code expires in ${codeTtl.inMinutes} minutes.</p>
  <p style="color:#6B7280;">If you did not request this, please ignore this email.</p>
</div>
''',
    );
  }

  Future<bool> sendUnderReviewEmail({
    required String email,
    required String fullName,
  }) {
    final displayName = fullName.trim().isEmpty
        ? 'CCS PulseConnect User'
        : fullName.trim();
    return _sendEmail(
      recipientEmail: email,
      subject: 'CCS PulseConnect Application Under Review',
      textBody:
          '''
Hello $displayName,

Your student registration has been received.
Your account is now under admin review.

Please wait for another email once your application is approved or rejected.
''',
      htmlBody:
          '''
<div style="font-family: Arial, sans-serif; color: #111827;">
  <h2 style="margin:0 0 8px 0;">CCS PulseConnect</h2>
  <p>Hello <strong>$displayName</strong>,</p>
  <p>Your student registration has been received.</p>
  <p>Your account is now <strong>under admin review</strong>.</p>
  <p>Please wait for another email once your application is approved or rejected.</p>
</div>
''',
    );
  }

  Future<bool> _sendEmail({
    required String recipientEmail,
    required String subject,
    required String textBody,
    required String htmlBody,
  }) async {
    final sender = Env.emailSenderAddress.trim();
    final appPassword = Env.emailSenderAppPassword.trim();
    if (sender.isEmpty || appPassword.isEmpty) {
      return false;
    }
    try {
      final smtpServer = gmail(sender, appPassword);
      final message = Message()
        ..from = Address(sender, 'CCS PulseConnect')
        ..recipients.add(recipientEmail.trim())
        ..subject = subject
        ..text = textBody
        ..html = htmlBody;
      await send(message, smtpServer);
      return true;
    } catch (_) {
      return false;
    }
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
