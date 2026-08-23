import 'dart:async';

import 'package:flutter/material.dart';
import '../../widgets/app_snackbar.dart';
import '../../services/auth_service.dart';
import '../../services/mobile_backend_service.dart';
import '../../services/notification_service.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/otp_code_boxes.dart';
import '../../utils/teacher_theme_utils.dart';
import '../../services/device_performance_service.dart';

class ChangePasswordScreen extends StatefulWidget {
  final String role;
  const ChangePasswordScreen({super.key, this.role = 'Student'});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen>
    with TickerProviderStateMixin {
  late AnimationController _logoFloatController;
  late AnimationController _gradientController;
  Offset _pointerPosition = const Offset(0, 0);
  bool _pointerActive = false;

  final _codeController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  Timer? _cooldownTimer;

  bool _isLoading = false;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  int _step = 0; // 0 = OTP, 1 = new password
  bool _codeSent = false;
  int _cooldownSeconds = 0;
  String? _changeToken;
  String _emailMasked = '';

  bool get _isTeacher => widget.role.toLowerCase() == 'teacher';
  Color get _primaryColor =>
      _isTeacher ? TeacherThemeUtils.primary : const Color(0xFF9F1239);
  Color get _accentColor =>
      _isTeacher ? TeacherThemeUtils.mid : const Color(0xFFBE123C);

  @override
  void initState() {
    super.initState();
    _logoFloatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    _gradientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    if (DevicePerformance.instance.enableDecorativeMotion) {
      _logoFloatController.repeat(reverse: true);
      _gradientController.repeat(reverse: true);
    }

    _loadMaskedEmail();
  }

  Future<void> _loadMaskedEmail() async {
    try {
      final user = await AuthService().getCurrentUser();
      final email = (user?['email']?.toString() ?? '').trim().toLowerCase();
      if (!mounted || email.isEmpty || !email.contains('@')) return;
      setState(() => _emailMasked = _maskEmail(email));
    } catch (_) {}
  }

  String _maskEmail(String email) {
    final parts = email.split('@');
    if (parts.length != 2) return '';
    final local = parts[0];
    final domain = parts[1];
    final keep = local.length <= 2 ? 1 : (local.length == 3 ? 1 : 2);
    return '${local.substring(0, keep)}***@$domain';
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _codeController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    _logoFloatController.dispose();
    _gradientController.dispose();
    super.dispose();
  }

  void _startCooldown(int seconds) {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSeconds = seconds < 0 ? 0 : seconds);
    if (_cooldownSeconds <= 0) return;
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_cooldownSeconds <= 1) {
        timer.cancel();
        setState(() => _cooldownSeconds = 0);
        return;
      }
      setState(() => _cooldownSeconds -= 1);
    });
  }

  Future<void> _sendOtp({required bool forceResend}) async {
    if (!MobileBackendService.isConfigured) {
      _showError('Secure backend is required to change password.');
      return;
    }
    if (_isLoading) return;

    setState(() => _isLoading = true);
    try {
      final user = await AuthService().getCurrentUser();
      if (user == null) throw Exception('User not logged in');

      final result = await MobileBackendService().sendChangePasswordOtp();
      if (result['ok'] != true) {
        _showError(
          result['error']?.toString() ?? 'Unable to send verification code.',
        );
        return;
      }

      final masked = result['email_masked']?.toString().trim() ?? '';
      final cooldown =
          int.tryParse(result['cooldown_seconds']?.toString() ?? '') ?? 60;
      if (mounted) {
        setState(() {
          _codeSent = true;
          if (masked.isNotEmpty) _emailMasked = masked;
        });
        _startCooldown(cooldown);
      }
      if (forceResend || result['skipped'] != true) {
        _showInfo(
          masked.isNotEmpty
              ? 'Code sent to $masked'
              : 'Verification code sent. Check your email.',
        );
      }
    } catch (_) {
      _showError('Error sending code. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyOtp() async {
    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      _showError('Please enter the 6-digit code.');
      return;
    }
    if (!MobileBackendService.isConfigured) {
      _showError('Secure backend is required to change password.');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final result = await MobileBackendService().verifyChangePasswordOtp(
        code: code,
      );
      if (result['ok'] != true) {
        _showError(result['error']?.toString() ?? 'Invalid verification code.');
        return;
      }

      final token = result['change_token']?.toString() ?? '';
      if (token.isEmpty) {
        _showError('Invalid verification session. Please request a new code.');
        return;
      }

      if (!mounted) return;
      setState(() {
        _changeToken = token;
        _step = 1;
      });
      _showInfo('Code verified. Set your new password.');
    } catch (_) {
      _showError('Error verifying code. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _submitPassword() async {
    final newPassword = _newController.text.trim();
    final confirmPassword = _confirmController.text.trim();
    final token = (_changeToken ?? '').trim();

    if (token.isEmpty) {
      _showError('Please verify the code first.');
      setState(() => _step = 0);
      return;
    }
    if (newPassword.isEmpty || confirmPassword.isEmpty) {
      _showError('Please fill missing fields.');
      return;
    }
    if (newPassword != confirmPassword) {
      _showError('New passwords do not match.');
      return;
    }
    if (newPassword.length < 8) {
      _showError('Password must be at least 8 characters.');
      return;
    }
    if (!MobileBackendService.isConfigured) {
      _showError('Secure backend is required to change password.');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final user = await AuthService().getCurrentUser();
      if (user == null) throw Exception('User not logged in');

      final result = await MobileBackendService().changePassword(
        changeToken: token,
        newPassword: newPassword,
      );
      if (result['ok'] != true) {
        _showError(result['error']?.toString() ?? 'Failed to update password.');
        return;
      }

      await NotificationService().addPasswordChangeNotification();
      if (mounted) {
        AppSnackBar.success(context, 'Password changed successfully!');
        Navigator.pop(context);
      }
    } catch (_) {
      _showError('Error updating password. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    AppSnackBar.error(context, message);
  }

  void _showInfo(String message) {
    if (!mounted) return;
    AppSnackBar.success(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: const Color(0xFF09090B),
      body: Listener(
        onPointerDown: (e) => setState(() {
          _pointerPosition = e.position;
          _pointerActive = true;
        }),
        onPointerMove: (e) => setState(() {
          _pointerPosition = e.position;
        }),
        onPointerUp: (e) => setState(() {
          _pointerActive = false;
        }),
        onPointerCancel: (e) => setState(() {
          _pointerActive = false;
        }),
        child: Stack(
          children: [
            if (_pointerActive)
              AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: 0.85,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(
                        (_pointerPosition.dx / size.width) * 2 - 1,
                        (_pointerPosition.dy / size.height) * 2 - 1,
                      ),
                      radius: 0.35,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.85),
                        Colors.black,
                      ],
                      stops: const [0.3, 0.55, 1.0],
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _gradientController,
                  builder: (context, child) {
                    final t = _gradientController.value;
                    return Opacity(
                      opacity: _pointerActive ? 0.3 : 0.95,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment(-0.9 + 1.8 * t, -0.6 + 1.2 * t),
                            radius: 1.4 + 0.4 * t,
                            colors: [
                              (_isTeacher
                                      ? TeacherThemeUtils.dark
                                      : const Color(0xFF6F1D2D))
                                  .withValues(alpha: 0.85 + 0.1 * t),
                              (_isTeacher
                                      ? const Color(0xFF1D4ED8)
                                      : const Color(0xFF7F1D1D))
                                  .withValues(alpha: 0.5 + 0.2 * t),
                              Colors.transparent,
                            ],
                            stops: [0.0, 0.45 + 0.2 * t, 1.0],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Column(
              children: [
                AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  leading: IconButton(
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.arrow_back_ios_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                    onPressed: () {
                      if (_step == 1) {
                        setState(() => _step = 0);
                        return;
                      }
                      Navigator.pop(context);
                    },
                  ),
                  title: const Text(
                    'Security',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  centerTitle: true,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 18),
                        AnimatedBuilder(
                          animation: _logoFloatController,
                          builder: (context, child) {
                            return Transform.translate(
                              offset: Offset(
                                0,
                                12 *
                                    Curves.easeInOut.transform(
                                      _logoFloatController.value,
                                    ),
                              ),
                              child: child,
                            );
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: _primaryColor.withValues(alpha: 0.35),
                                  blurRadius: 45,
                                  spreadRadius: 10,
                                ),
                                BoxShadow(
                                  color: const Color(
                                    0xFFF59E0B,
                                  ).withValues(alpha: 0.15),
                                  blurRadius: 65,
                                  spreadRadius: 18,
                                ),
                              ],
                            ),
                            child: ClipOval(
                              child: Image.asset(
                                'assets/ccs_lock_logo.png',
                                width: 105,
                                height: 105,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Image.asset(
                                  'assets/CCS.png',
                                  width: 105,
                                  height: 105,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          _step == 0
                              ? (_codeSent ? 'Verify OTP' : 'Change Password')
                              : 'New Password',
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _step == 0
                              ? (!_codeSent
                                    ? (_emailMasked.isNotEmpty
                                          ? 'Tap Send to receive a 6-digit code at $_emailMasked.'
                                          : 'Tap Send to receive a 6-digit code on your email.')
                                    : (_emailMasked.isNotEmpty
                                          ? 'Enter the 6-digit code sent to $_emailMasked.'
                                          : 'Enter the 6-digit code sent to your email.'))
                              : 'Enter and confirm your new password.',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withValues(alpha: 0.45),
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 40),
                        if (_step == 0) _buildOtpStep() else _buildPasswordStep(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOtpStep() {
    if (!_codeSent) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPrimaryButton(
            'Send Code',
            _isLoading ? null : () => _sendOtp(forceResend: false),
          ),
        ],
      );
    }

    final canResend = !_isLoading && _cooldownSeconds <= 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Confirmation Code',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFFA1A1AA),
          ),
        ),
        const SizedBox(height: 10),
        OtpCodeBoxes(
          controller: _codeController,
          focusColor: _primaryColor,
          enabled: !_isLoading,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: canResend ? () => _sendOtp(forceResend: true) : null,
            child: Text(
              canResend
                  ? 'Resend Code'
                  : 'Resend available in ${_cooldownSeconds}s',
              style: TextStyle(
                color: canResend
                    ? _primaryColor
                    : Colors.white.withValues(alpha: 0.35),
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        _buildPrimaryButton('Verify Code', _isLoading ? null : _verifyOtp),
      ],
    );
  }

  Widget _buildPasswordStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPasswordField(
          'New Password',
          _newController,
          _obscureNew,
          (v) => setState(() => _obscureNew = v),
        ),
        const SizedBox(height: 22),
        _buildPasswordField(
          'Confirm Password',
          _confirmController,
          _obscureConfirm,
          (v) => setState(() => _obscureConfirm = v),
        ),
        const SizedBox(height: 36),
        _buildPrimaryButton(
          'Update Password',
          _isLoading ? null : _submitPassword,
        ),
      ],
    );
  }

  Widget _buildPrimaryButton(String label, VoidCallback? onPressed) {
    return SizedBox(
      width: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(colors: [_accentColor, _primaryColor]),
          boxShadow: [
            BoxShadow(
              color: _primaryColor.withValues(alpha: 0.45),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: _isLoading
              ? const PulseConnectLoader(size: 18, color: Colors.white)
              : Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildPasswordField(
    String label,
    TextEditingController ctrl,
    bool obscure,
    Function(bool) toggle,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFFA1A1AA),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
          cursorColor: _primaryColor,
          decoration: InputDecoration(
            hintText: '••••••••',
            hintStyle: const TextStyle(
              color: Color(0xFF52525B),
              fontSize: 14,
              letterSpacing: 2,
            ),
            prefixIcon: const Icon(
              Icons.lock_outline_rounded,
              color: Color(0xFF52525B),
              size: 20,
            ),
            suffixIcon: IconButton(
              icon: Icon(
                obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: const Color(0xFF52525B),
                size: 20,
              ),
              onPressed: () => toggle(!obscure),
            ),
            filled: true,
            fillColor: const Color(0xFF1C1C22),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF27272A)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF27272A)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: _primaryColor, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
