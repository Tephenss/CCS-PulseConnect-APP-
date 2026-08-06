import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../services/auth_service.dart';
import '../../services/email_verification_service.dart';
import '../../services/push_notification_service.dart';
import '../../utils/teacher_theme_utils.dart';
import '../../widgets/custom_loader.dart';

class EmailVerificationScreen extends StatefulWidget {
  final Map<String, dynamic> user;
  final bool postRegistrationReviewFlow;
  /// `unverified` | `daily` | `new_ip` — controls helper copy.
  final String? gateReason;

  const EmailVerificationScreen({
    super.key,
    required this.user,
    this.postRegistrationReviewFlow = false,
    this.gateReason,
  });

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  final _service = EmailVerificationService();
  final _authService = AuthService();
  final _codeController = TextEditingController();
  Timer? _cooldownTimer;
  bool _isSending = false;
  bool _isVerifying = false;
  int _cooldownSeconds = 0;
  String? _message;
  String? _error;
  bool _isLeavingToLogin = false;

  String get _userId => widget.user['id']?.toString() ?? '';
  String get _email => widget.user['email']?.toString() ?? '';
  String get _name =>
      '${widget.user['first_name'] ?? ''} ${widget.user['last_name'] ?? ''}'
          .trim();
  bool get _isTeacher =>
      (widget.user['role']?.toString().toLowerCase() ?? 'student') == 'teacher';
  Color get _primaryColor =>
      _isTeacher ? TeacherThemeUtils.primary : const Color(0xFF9F1239);
  Color get _accentColor =>
      _isTeacher ? TeacherThemeUtils.mid : const Color(0xFFBE123C);

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    // Keep verification as a pre-login step, but keep the login session token
    // so avatar/FCM/inbox work after OTP (clearing the token caused "Mobile session required").
    await _authService.clearLocalSessionMarkers(keepMobileSession: true);
    if (!mounted) return;
    if (_userId.isEmpty || _email.isEmpty) {
      setState(() => _error = 'Missing account email. Please login again.');
      return;
    }
    await _refreshCooldown();
    if (!mounted) return;
    await _sendCode(forceResend: false);
  }

  Future<void> _refreshCooldown() async {
    final remaining = await _service.getRemainingCooldownSeconds(_userId);
    if (!mounted) return;
    setState(() => _cooldownSeconds = remaining);
    _startCooldownTicker();
  }

  void _startCooldownTicker() {
    _cooldownTimer?.cancel();
    if (_cooldownSeconds <= 0) return;
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_cooldownSeconds <= 1) {
        timer.cancel();
        setState(() => _cooldownSeconds = 0);
        return;
      }
      setState(() => _cooldownSeconds -= 1);
    });
  }

  void _backToLogin() {
    if (_isLeavingToLogin || !mounted) return;
    _isLeavingToLogin = true;
    FocusManager.instance.primaryFocus?.unfocus();
    final roleLabel = _isTeacher ? 'Teacher' : 'Student';
    PulseConnectApp.of(context).exitEmailVerificationToLogin(roleLabel);
  }

  Future<void> _showAccountCreatedSuccessDialog({
    required bool pendingAdminReview,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF18181B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: _primaryColor.withValues(alpha: 0.35)),
          ),
          title: const Text(
            'Account Created Successfully',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          content: Text(
            pendingAdminReview
                ? 'Your email is verified. Your account is under admin review. Please wait for approval, then sign in from the login page.'
                : 'Your account was created successfully. Please sign in with your student number and password.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                'Go to Sign In',
                style: TextStyle(
                  color: _primaryColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _sendCode({required bool forceResend}) async {
    if (!mounted) return;
    setState(() {
      _isSending = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await _service.sendCode(
        userId: _userId,
        email: _email,
        fullName: _name.isEmpty ? 'User' : _name,
        forceResend: forceResend,
      );
      if (!mounted) return;
      if (result['ok'] == true) {
        final skipped = result['skipped'] == true;
        setState(
          () => _message = skipped
              ? 'Code already sent — check your inbox (including spam).'
              : 'Verification code sent to $_email',
        );
        await _refreshCooldown();
      } else {
        setState(
          () => _error = result['error']?.toString() ?? 'Failed to send code.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to send code. Please try again.');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _verify() async {
    if (_isVerifying || _isLeavingToLogin) return;
    FocusScope.of(context).unfocus();
    final code = _codeController.text.trim();
    if (code.length != 6 || int.tryParse(code) == null) {
      setState(() => _error = 'Please enter the 6-digit code.');
      return;
    }

    setState(() {
      _isVerifying = true;
      _error = null;
    });
    try {
      final result = await _service.verifyCode(
        userId: _userId,
        enteredCode: code,
        persistLocalUser: !widget.postRegistrationReviewFlow,
      );
      if (!mounted) return;
      if (result['ok'] == true) {
        final updatedUser = Map<String, dynamic>.from(result['user'] as Map);
        if (widget.postRegistrationReviewFlow) {
          final status = (updatedUser['account_status']?.toString() ?? '')
              .toLowerCase()
              .trim();
          final pendingAdminReview = status == 'pending';
          if (pendingAdminReview) {
            await _service.sendUnderReviewEmail(
              userId: _userId,
              email: _email,
              fullName: _name,
            );
          }
          // Force a real login next — do not keep the signup session.
          await _authService.logout();
          if (!mounted) return;
          await _showAccountCreatedSuccessDialog(
            pendingAdminReview: pendingAdminReview,
          );
          if (!mounted) return;
          final roleLabel = _isTeacher ? 'Teacher' : 'Student';
          PulseConnectApp.of(context).exitEmailVerificationToLogin(roleLabel);
          return;
        }
        final role = updatedUser['role']?.toString().toLowerCase() ?? 'student';
        // Session is persisted only after OTP — register this device for pushes now.
        await PushNotificationService().updateToken();
        if (!mounted) return;
        PulseConnectApp.of(context).enterAppAfterAuth(
          role: role,
          course: updatedUser['course']?.toString(),
        );
      } else {
        setState(
          () => _error = result['error']?.toString() ?? 'Verification failed.',
        );
      }
    } finally {
      if (mounted) setState(() => _isVerifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canResend = !_isSending && _cooldownSeconds <= 0;
    return PopScope(
      // Block Android predictive/IME back from leaving OTP mid-send.
      // Users leave via the explicit "Back to Sign In" button only.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF09090B),
        body: Stack(
          children: [
            Positioned.fill(
              child: Image.asset(
                'assets/bg.png',
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(),
              ),
            ),
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x5509090B),
                      Color(0xAA09090B),
                      Color(0xFF09090B),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Stack(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight - 24,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 460),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _primaryColor,
                                      borderRadius: BorderRadius.circular(999),
                                      boxShadow: [
                                        BoxShadow(
                                          color: _primaryColor.withValues(
                                            alpha: 0.35,
                                          ),
                                          blurRadius: 12,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: const Text(
                                      'EMAIL VERIFICATION',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 12,
                                        letterSpacing: 0.6,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.fromLTRB(
                                      20,
                                      20,
                                      20,
                                      16,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.06,
                                      ),
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.08,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Check Your Email',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 20,
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          'We sent a 6-digit code to:',
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.75,
                                            ),
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _email,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14,
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          AuthService
                                              .emailVerificationReasonMessage(
                                            widget.gateReason,
                                          ),
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.7,
                                            ),
                                            fontSize: 12,
                                            height: 1.35,
                                          ),
                                        ),
                                        const SizedBox(height: 14),
                                        TextField(
                                          controller: _codeController,
                                          keyboardType: TextInputType.number,
                                          maxLength: 6,
                                          style: const TextStyle(
                                            color: Color(0xFFF4F4F5),
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 2,
                                          ),
                                          cursorColor: _primaryColor,
                                          decoration: InputDecoration(
                                            labelText: 'Verification Code',
                                            labelStyle: const TextStyle(
                                              color: Color(0xFFA1A1AA),
                                            ),
                                            hintText: '123456',
                                            counterText: '',
                                            prefixIcon: const Icon(
                                              Icons.mark_email_read_outlined,
                                              color: Color(0xFF52525B),
                                              size: 20,
                                            ),
                                            filled: true,
                                            fillColor: const Color(0xFF1C1C22),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              borderSide: const BorderSide(
                                                color: Color(0xFF27272A),
                                              ),
                                            ),
                                            enabledBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              borderSide: const BorderSide(
                                                color: Color(0xFF27272A),
                                              ),
                                            ),
                                            focusedBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              borderSide: BorderSide(
                                                color: _primaryColor,
                                                width: 1.5,
                                              ),
                                            ),
                                          ),
                                        ),
                                        if (_error != null) ...[
                                          const SizedBox(height: 8),
                                          Text(
                                            _error!,
                                            style: const TextStyle(
                                              color: Color(0xFFFCA5A5),
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                        if (_message != null) ...[
                                          const SizedBox(height: 8),
                                          Text(
                                            _message!,
                                            style: const TextStyle(
                                              color: Color(0xFF86EFAC),
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 10),
                                        SizedBox(
                                          width: double.infinity,
                                          child: AbsorbPointer(
                                            absorbing: _isVerifying,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                gradient: LinearGradient(
                                                  colors: [
                                                    _accentColor,
                                                    _primaryColor,
                                                  ],
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                ),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: _primaryColor
                                                        .withValues(alpha: 0.4),
                                                    blurRadius: 20,
                                                    offset: const Offset(0, 8),
                                                  ),
                                                ],
                                              ),
                                              child: ElevatedButton(
                                                onPressed: _verify,
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor:
                                                      Colors.transparent,
                                                  shadowColor:
                                                      Colors.transparent,
                                                  foregroundColor: Colors.white,
                                                  disabledForegroundColor:
                                                      Colors.white,
                                                  disabledBackgroundColor:
                                                      Colors.transparent,
                                                  padding: const EdgeInsets
                                                      .symmetric(vertical: 16),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      16,
                                                    ),
                                                  ),
                                                ),
                                                child: _isVerifying
                                                    ? const PulseConnectLoader(
                                                        size: 18,
                                                        color: Colors.white,
                                                      )
                                                    : Text(
                                                        widget.postRegistrationReviewFlow
                                                            ? 'Verify Account'
                                                            : 'Verify and Continue',
                                                        style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.w800,
                                                          fontSize: 15,
                                                        ),
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Align(
                                          alignment: Alignment.center,
                                          child: TextButton(
                                            onPressed: canResend
                                                ? () => _sendCode(
                                                      forceResend: true,
                                                    )
                                                : () {},
                                            style: TextButton.styleFrom(
                                              foregroundColor: canResend
                                                  ? _primaryColor
                                                  : Colors.white.withValues(
                                                      alpha: 0.45,
                                                    ),
                                            ),
                                            child: Text(
                                              canResend
                                                  ? 'Resend Code'
                                                  : 'Resend available in ${_cooldownSeconds}s',
                                              style: TextStyle(
                                                color: canResend
                                                    ? _primaryColor
                                                    : Colors.white.withValues(
                                                        alpha: 0.45,
                                                      ),
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  Positioned(
                    top: 4,
                    left: 12,
                    child: TextButton.icon(
                      onPressed: _isLeavingToLogin || _isVerifying
                          ? null
                          : _backToLogin,
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      label: const Text(
                        'Back to Sign In',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: const Color(0xE0121216),
                        disabledForegroundColor: const Color(0x73FFFFFF),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: const BorderSide(color: Color(0x66FFFFFF)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
