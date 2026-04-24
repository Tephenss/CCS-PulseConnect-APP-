import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../services/auth_service.dart';
import '../../services/email_verification_service.dart';
import '../../utils/teacher_theme_utils.dart';
import '../../widgets/custom_loader.dart';
import 'login_screen.dart';
import '../student/student_home.dart';
import '../teacher/teacher_home.dart';

class EmailVerificationScreen extends StatefulWidget {
  final Map<String, dynamic> user;
  final bool postRegistrationReviewFlow;

  const EmailVerificationScreen({
    super.key,
    required this.user,
    this.postRegistrationReviewFlow = false,
  });

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen>
    with WidgetsBindingObserver {
  final _service = EmailVerificationService();
  final _authService = AuthService();
  final _codeController = TextEditingController();
  Timer? _cooldownTimer;
  bool _isSending = false;
  bool _isVerifying = false;
  int _cooldownSeconds = 0;
  String? _message;
  String? _error;
  bool _hasGoneBackground = false;

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
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cooldownTimer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    // Keep verification as a pre-login step.
    await _authService.clearLocalSessionMarkers();
    if (_userId.isEmpty || _email.isEmpty) {
      setState(() => _error = 'Missing account email. Please login again.');
      return;
    }
    await _refreshCooldown();
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
    final roleLabel = _isTeacher ? 'Teacher' : 'Student';
    Navigator.pushAndRemoveUntil(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final slide = Tween<Offset>(
            begin: const Offset(-0.06, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
          final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
          return FadeTransition(
            opacity: fade,
            child: SlideTransition(position: slide, child: child),
          );
        },
        pageBuilder: (context, animation, secondaryAnimation) =>
            LoginScreen(role: roleLabel),
      ),
      (route) => false,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _hasGoneBackground = true;
      return;
    }
    if (state == AppLifecycleState.resumed && _hasGoneBackground && mounted) {
      _hasGoneBackground = false;
      _backToLogin();
    }
  }

  Future<void> _sendCode({required bool forceResend}) async {
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
        setState(() => _message = 'Verification code sent to $_email');
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
          await _service.sendUnderReviewEmail(email: _email, fullName: _name);
          if (!mounted) return;
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const LoginScreen(role: 'Student')),
            (route) => false,
          );
          return;
        }
        final role = updatedUser['role']?.toString().toLowerCase() ?? 'student';
        PulseConnectApp.of(
          context,
        ).updateTheme(role, course: updatedUser['course']?.toString());
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) =>
                role == 'teacher' ? const TeacherHome() : const StudentHome(),
          ),
          (route) => false,
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
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _backToLogin();
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
              child: LayoutBuilder(
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
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                    const SizedBox(height: 18),
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
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          borderSide: const BorderSide(
                                            color: Color(0xFF27272A),
                                          ),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          borderSide: const BorderSide(
                                            color: Color(0xFF27272A),
                                          ),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
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
                                    const SizedBox(height: 16),
                                    SizedBox(
                                      width: double.infinity,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
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
                                              color: _primaryColor.withValues(
                                                alpha: 0.4,
                                              ),
                                              blurRadius: 20,
                                              offset: const Offset(0, 8),
                                            ),
                                          ],
                                        ),
                                        child: ElevatedButton(
                                          onPressed: _isVerifying
                                              ? null
                                              : _verify,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.transparent,
                                            shadowColor: Colors.transparent,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 16,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                          ),
                                          child: _isVerifying
                                              ? const PulseConnectLoader(
                                                  size: 18,
                                                  color: Colors.white,
                                                )
                                              : const Text(
                                                  'Verify and Continue',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: 15,
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Align(
                                      alignment: Alignment.center,
                                      child: TextButton(
                                        onPressed: canResend
                                            ? () => _sendCode(forceResend: true)
                                            : null,
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
            ),
          ],
        ),
      ),
    );
  }
}
