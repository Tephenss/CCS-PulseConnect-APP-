import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:bcrypt/bcrypt.dart';
import 'dart:math';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server/gmail.dart';
import '../../widgets/custom_loader.dart';
import '../../utils/teacher_theme_utils.dart';
import '../../config/env.dart';

class ForgotPasswordScreen extends StatefulWidget {
  final String role;
  const ForgotPasswordScreen({super.key, this.role = 'Student'});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen>
    with TickerProviderStateMixin {
  late AnimationController _logoFloatController;
  late AnimationController _gradientController;
  Offset _pointerPosition = const Offset(0, 0);
  bool _pointerActive = false;

  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  int _currentStep = 0; // 0 = email, 1 = code, 2 = new password, 3 = success
  String? _verifiedUserId;
  String? _resetToken;

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
    )..repeat(reverse: true);

    _gradientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    _logoFloatController.dispose();
    _gradientController.dispose();
    super.dispose();
  }

  Future<void> _sendResetCode() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final email = _emailController.text.toLowerCase().trim();
      final res = await Supabase.instance.client
          .from('users')
          .select('id, email, first_name, last_name')
          .eq('email', email)
          .limit(1);

      if (res.isEmpty) {
        _showError('No account found with that email address.');
        setState(() => _isLoading = false);
        return;
      }

      final userData = res[0];
      final userId = userData['id']?.toString() ?? '';
      if (userId.isEmpty) {
        _showError('Invalid account record.');
        setState(() => _isLoading = false);
        return;
      }

      final code = _generateCode();
      final now = DateTime.now().toUtc();
      final expiresAt = now.add(const Duration(minutes: 10));

      await Supabase.instance.client.from('password_reset_codes').upsert({
        'user_id': userId,
        'code': code,
        'expires_at': expiresAt.toIso8601String(),
        'verified_at': null,
        'reset_token': null,
        'token_expires_at': null,
        'updated_at': now.toIso8601String(),
      });

      final fullName =
          '${userData['first_name'] ?? ''} ${userData['last_name'] ?? ''}'
              .trim();
      final sent = await _sendResetCodeEmail(
        recipientEmail: email,
        fullName: fullName.isEmpty ? 'User' : fullName,
        code: code,
      );
      if (!sent) {
        _showError('Unable to send reset code email. Please try again.');
        setState(() => _isLoading = false);
        return;
      }

      // Identity verified successfully
      setState(() {
        _verifiedUserId = userId;
        _currentStep = 1;
        _isLoading = false;
      });
      _showInfo('Confirmation code sent. Check your email.');
    } catch (e) {
      setState(() => _isLoading = false);
      _showError('Error sending code. Please try again.');
    }
  }

  Future<void> _verifyCode() async {
    if (!_formKey.currentState!.validate()) return;
    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      _showError('Please enter the 6-digit code.');
      return;
    }
    if (_verifiedUserId == null) {
      _showError('No reset session found. Please request a new code.');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final row = await Supabase.instance.client
          .from('password_reset_codes')
          .select('code, expires_at')
          .eq('user_id', _verifiedUserId!)
          .maybeSingle();
      if (row == null) {
        _showError('No reset code found. Please request a new code.');
        setState(() => _isLoading = false);
        return;
      }

      final storedCode = row['code']?.toString() ?? '';
      final expiresAt = DateTime.tryParse(
        row['expires_at']?.toString() ?? '',
      )?.toUtc();
      final now = DateTime.now().toUtc();
      if (storedCode != code) {
        _showError('Invalid confirmation code.');
        setState(() => _isLoading = false);
        return;
      }
      if (expiresAt == null || now.isAfter(expiresAt)) {
        _showError('Code expired. Please request a new code.');
        setState(() => _isLoading = false);
        return;
      }

      final token = _generateResetToken();
      await Supabase.instance.client
          .from('password_reset_codes')
          .update({
            'verified_at': now.toIso8601String(),
            'reset_token': token,
            'token_expires_at': now
                .add(const Duration(minutes: 15))
                .toIso8601String(),
            'updated_at': now.toIso8601String(),
          })
          .eq('user_id', _verifiedUserId!);
      setState(() {
        _resetToken = token;
        _currentStep = 2;
        _isLoading = false;
      });
      _showInfo('Code verified. Set your new password.');
    } catch (_) {
      setState(() => _isLoading = false);
      _showError('Error verifying code. Please try again.');
    }
  }

  Future<void> _updatePassword() async {
    if (!_formKey.currentState!.validate()) return;

    final newPass = _newPasswordController.text;
    final confirmPass = _confirmPasswordController.text;

    if (newPass != confirmPass) {
      _showError('Passwords do not match.');
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (_verifiedUserId == null || _resetToken == null) {
        _showError('Reset session expired. Please verify code again.');
        setState(() => _isLoading = false);
        return;
      }
      final row = await Supabase.instance.client
          .from('password_reset_codes')
          .select('reset_token, token_expires_at')
          .eq('user_id', _verifiedUserId!)
          .maybeSingle();
      final storedToken = row?['reset_token']?.toString() ?? '';
      final tokenExpires = DateTime.tryParse(
        row?['token_expires_at']?.toString() ?? '',
      )?.toUtc();
      final now = DateTime.now().toUtc();
      if (storedToken.isEmpty || storedToken != _resetToken) {
        _showError('Invalid reset session. Please verify code again.');
        setState(() => _isLoading = false);
        return;
      }
      if (tokenExpires == null || now.isAfter(tokenExpires)) {
        _showError('Reset session expired. Please verify code again.');
        setState(() => _isLoading = false);
        return;
      }

      // Hash the new password properly (Bcrypt to match web system schema)
      final newHashedPassword = BCrypt.hashpw(newPass, BCrypt.gensalt());

      // Update Supabase directly based on the verified user id
      if (_verifiedUserId != null) {
        await Supabase.instance.client
            .from('users')
            .update({'password': newHashedPassword})
            .eq('id', _verifiedUserId!);
        await Supabase.instance.client
            .from('password_reset_codes')
            .delete()
            .eq('user_id', _verifiedUserId!);
      }

      setState(() {
        _isLoading = false;
        _currentStep = 3; // Success
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showError('Error updating password. Please try again.');
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: const Color(0xFF7F1D1D)),
      );
    }
  }

  void _showInfo(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: const Color(0xFF15803D)),
      );
    }
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
            // Flashlight effect
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

            // Animated role-aware gradient
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
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: _buildCurrentState(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentState() {
    if (_currentStep == 3) {
      return _buildSuccessView();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),

        // CCS Logo with premium float & glow
        AnimatedBuilder(
          animation: _logoFloatController,
          builder: (context, child) {
            return Transform.translate(
              offset: Offset(
                0,
                12 * Curves.easeInOut.transform(_logoFloatController.value),
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
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                  blurRadius: 65,
                  spreadRadius: 18,
                ),
              ],
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/CCS.png',
                width: 105,
                height: 105,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),

        const SizedBox(height: 32),
        Text(
          _currentStep == 0
              ? 'Forgot\nPassword?'
              : _currentStep == 1
                  ? 'Confirm Code'
              : 'Set New\nPassword',
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _currentStep == 0
              ? 'Enter your registered email to receive a confirmation code.'
              : _currentStep == 1
              ? 'Enter the 6-digit code sent to your email.'
              : 'Please enter your new password below.',
          style: TextStyle(
            fontSize: 14,
            color: Colors.white.withValues(alpha: 0.45),
            height: 1.6,
          ),
        ),
        const SizedBox(height: 40),
        Form(
          key: _formKey,
          child: _currentStep == 0
              ? _buildStep0Form()
              : _currentStep == 1
              ? _buildStep1CodeForm()
              : _buildStep2PasswordForm(),
        ),
      ],
    );
  }

  Widget _buildStep0Form() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Email Address',
          style: TextStyle(
            color: Color(0xFFA1A1AA),
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
          cursorColor: _primaryColor,
          decoration: _inputDecoration('you@gmail.com', Icons.email_outlined),
          validator: (val) {
            if (val == null || val.isEmpty) return 'Email is required';
            if (!val.contains('@')) return 'Enter a valid email';
            return null;
          },
        ),
        const SizedBox(height: 36),
        _buildSubmitButton('Send Confirmation Code', _sendResetCode),
      ],
    );
  }

  Widget _buildStep1CodeForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Confirmation Code',
          style: TextStyle(
            color: Color(0xFFA1A1AA),
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          maxLength: 6,
          style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
          cursorColor: _primaryColor,
          decoration: _inputDecoration(
            '6-digit code',
            Icons.mark_email_read_outlined,
          ),
          validator: (val) {
            if (val == null || val.isEmpty) return 'Code is required';
            return null;
          },
        ),
        const SizedBox(height: 28),
        _buildSubmitButton('Verify Code', _verifyCode),
      ],
    );
  }

  Widget _buildStep2PasswordForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'New Password',
          style: TextStyle(
            color: Color(0xFFA1A1AA),
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _newPasswordController,
          obscureText: true,
          style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
          cursorColor: _primaryColor,
          decoration: _inputDecoration('Min. 8 characters', Icons.lock_outline),
          validator: (val) {
            if (val == null || val.isEmpty) return 'New password is required';
            if (val.length < 8) return 'At least 8 characters required';
            return null;
          },
        ),
        const SizedBox(height: 24),
        const Text(
          'Confirm Password',
          style: TextStyle(
            color: Color(0xFFA1A1AA),
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _confirmPasswordController,
          obscureText: true,
          style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
          cursorColor: _primaryColor,
          decoration: _inputDecoration(
            'Confirm your new password',
            Icons.lock_reset_outlined,
          ),
          validator: (val) {
            if (val == null || val.isEmpty) return 'Please confirm password';
            return null;
          },
        ),
        const SizedBox(height: 36),
        _buildSubmitButton('Update Password', _updatePassword),
      ],
    );
  }

  Widget _buildSuccessView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 80),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _primaryColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.check_circle_rounded,
              size: 64,
              color: _isTeacher
                  ? const Color(0xFF60A5FA)
                  : const Color(0xFFBE123C),
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Password Updated',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Your password has been successfully reset. You can now use your new password to login.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withValues(alpha: 0.5),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 40),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1C1C22),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: Color(0xFF27272A)),
                ),
              ),
              child: const Text(
                'Back to Login',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF52525B), fontSize: 14),
      prefixIcon: Icon(icon, color: const Color(0xFF52525B), size: 20),
      filled: true,
      fillColor: const Color(0xFF1C1C22),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF7F1D1D)),
      ),
      errorStyle: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12),
    );
  }

  Widget _buildSubmitButton(String text, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(colors: [_accentColor, _primaryColor]),
          boxShadow: [
            BoxShadow(
              color: _primaryColor.withValues(alpha: 0.4),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ElevatedButton(
          onPressed: _isLoading ? null : onPressed,
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
                  text,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
      ),
    );
  }

  String _generateCode() {
    final random = Random.secure();
    final code = random.nextInt(1000000);
    return code.toString().padLeft(6, '0');
  }

  String _generateResetToken() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List.generate(48, (_) => chars[random.nextInt(chars.length)]).join();
  }

  Future<bool> _sendResetCodeEmail({
    required String recipientEmail,
    required String fullName,
    required String code,
  }) async {
    final sender = Env.emailSenderAddress.trim();
    final appPassword = Env.emailSenderAppPassword.trim();
    if (sender.isEmpty || appPassword.isEmpty) return false;
    try {
      final smtpServer = gmail(sender, appPassword);
      final message = Message()
        ..from = Address(sender, 'CCS PulseConnect')
        ..recipients.add(recipientEmail.trim())
        ..subject = 'CCS PulseConnect Password Reset Code'
        ..text =
            'Hello $fullName,\n\nUse this code to reset your password: $code\n\nThis code expires in 10 minutes.'
        ..html =
            '<div style="font-family:Arial,sans-serif;"><h2>CCS PulseConnect</h2><p>Hello <b>$fullName</b>,</p><p>Use this code to reset your password:</p><p style="font-size:24px;font-weight:700;letter-spacing:4px;">$code</p><p>This code expires in 10 minutes.</p></div>';
      await send(message, smtpServer);
      return true;
    } catch (_) {
      return false;
    }
  }
}
