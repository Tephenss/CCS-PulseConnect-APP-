import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import 'forgot_password_screen.dart';
import '../../services/push_notification_service.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/app_snackbar.dart';
import '../../main.dart';
import '../../utils/teacher_theme_utils.dart';
import '../../utils/app_page_routes.dart';

class LoginScreen extends StatefulWidget {
  final String role;
  const LoginScreen({super.key, required this.role});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with TickerProviderStateMixin {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _authService = AuthService();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  bool get _isTeacher => widget.role.toLowerCase() == 'teacher';
  Color get _primaryColor => _isTeacher ? TeacherThemeUtils.primary : const Color(0xFF9F1239);
  Color get _accentColor => _isTeacher ? TeacherThemeUtils.mid : const Color(0xFFBE123C);
  late AnimationController _floatController;
  Offset _pointerPosition = const Offset(0, 0);
  bool _pointerActive = false;

  @override
  void initState() {
    super.initState();
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _floatController.dispose();
    super.dispose();
  }

  void _updatePointer(PointerEvent details) {
    if (details.kind != PointerDeviceKind.mouse) {
      if (_pointerActive) {
        setState(() => _pointerActive = false);
      }
      return;
    }
    setState(() {
      _pointerPosition = details.position;
      _pointerActive = true;
    });
  }

  void _hidePointer(PointerEvent details) {
    if (_pointerActive) {
      setState(() => _pointerActive = false);
    }
  }
  void _showOfflineRecoveryNotices({
    required int restoredCount,
    required int syncedCount,
    required int reconciledCount,
  }) {
    final ctx = PulseConnectApp.navigatorKey.currentContext;
    if (ctx == null) return;
    if (restoredCount > 0) AppSnackBar.info(ctx, 'Restored $restoredCount offline scan${restoredCount == 1 ? '' : 's'} from backup.');
    if (syncedCount > 0) AppSnackBar.success(ctx, '$syncedCount queued scan${syncedCount == 1 ? '' : 's'} synced successfully.');
    if (reconciledCount > 0) AppSnackBar.warning(ctx, '$reconciledCount restored scan${reconciledCount == 1 ? '' : 's'} already existed and were reconciled.');
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await _authService.login(
        _emailController.text,
        _passwordController.text,
        widget.role,
      );

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (result['ok'] == true) {
        final userData = result['user'] as Map<String, dynamic>;
        final currentRole = userData['role'] as String? ?? 'student';
        final gateReason =
            await _authService.emailVerificationGateReason(userData);
        final needsVerification = gateReason != null;
        if (!mounted) return;

        debugPrint(
          '[Login] ok role=$currentRole gate=$gateReason needsOtp=$needsVerification',
        );

        final restoredOfflineQueueCount =
            (result['restored_offline_queue_count'] is num)
                ? (result['restored_offline_queue_count'] as num).toInt()
                : int.tryParse(
                        result['restored_offline_queue_count']?.toString() ?? '',
                      ) ??
                    0;
        final syncedOfflineQueueCount =
            (result['synced_offline_queue_count'] is num)
                ? (result['synced_offline_queue_count'] as num).toInt()
                : int.tryParse(
                        result['synced_offline_queue_count']?.toString() ?? '',
                      ) ??
                    0;
        final reconciledOfflineQueueCount =
            (result['reconciled_offline_queue_count'] is num)
                ? (result['reconciled_offline_queue_count'] as num).toInt()
                : int.tryParse(
                        result['reconciled_offline_queue_count']?.toString() ??
                            '',
                      ) ??
                    0;
        // Root navigator hard-replace — MaterialApp.home alone won't move
        // after Welcome→Login has already pushed routes.
        if (needsVerification) {
          PulseConnectApp.of(context).showEmailVerificationGate(
            userData,
            gateReason: gateReason,
          );
          return;
        }

        await PushNotificationService().updateToken();
        if (!mounted) return;
        _showOfflineRecoveryNotices(
          restoredCount: restoredOfflineQueueCount,
          syncedCount: syncedOfflineQueueCount,
          reconciledCount: reconciledOfflineQueueCount,
        );
        if (!mounted) return;
        PulseConnectApp.of(context).enterAppAfterAuth(
          role: currentRole,
          course: userData['course']?.toString(),
        );
      } else {
        if (!mounted) return;
        setState(() => _errorMessage = result['error'] as String?);
      }
    } catch (e, st) {
      debugPrint('[Login] error: $e\n$st');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Something went wrong. Please try again.';
      });
    }
  }

  void _goToWelcome() {
    PulseConnectApp.of(context).exitEmailVerificationToWelcome();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final keyboardOpen = mq.viewInsets.bottom > 0;

    return PopScope(
      // IME hide / predictive-back on Oppo fires a false pop after Sign In.
      // Never auto-leave from system back — only the UI back control may.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: Scaffold(
      backgroundColor: const Color(0xFF09090B),
      body: Listener(
        onPointerDown: _updatePointer,
        onPointerMove: _updatePointer,
        onPointerUp: _hidePointer,
        onPointerCancel: _hidePointer,
        child: Stack(
          children: [
            // Background Image — full screen, gradient handles the fade
            Positioned.fill(
              child: Image.asset(
                'assets/bg.png',
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const SizedBox(),
              ),
            ),

            // Smooth dark fade overlay — gradual from top to bottom
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x0009090B),  // 0% alpha
                      Color(0x1009090B),  // ~6%
                      Color(0x2509090B),  // ~15%
                      Color(0x4009090B),  // ~25%
                      Color(0x6609090B),  // ~40%
                      Color(0x9909090B),  // ~60%
                      Color(0xCC09090B),  // ~80%
                      Color(0xE609090B),  // ~90%
                      Color(0xF509090B),  // ~96%
                      Color(0xFF09090B),  // 100%
                    ],
                    stops: [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.65, 0.8, 0.9, 1.0],
                  ),
                ),
              ),
            ),

            // Flashlight effect — bake opacity into gradient colors (no Opacity widget).
            if (_pointerActive)
              IgnorePointer(
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
                        Colors.black.withValues(alpha: 0.85 * 0.85),
                        Colors.black.withValues(alpha: 0.85),
                      ],
                      stops: const [0.3, 0.55, 1.0],
                    ),
                  ),
                ),
              ),

            // Animated maroon/green gradient — top area only.
            // Bake alpha into colors (no Opacity widget) — Impeller rejects
            // SetInheritedOpacity on some gradient contents.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: size.height,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-0.35, -0.58),
                      radius: 1.25,
                      colors: [
                        (_isTeacher
                                ? TeacherThemeUtils.dark
                                : const Color(0xFF6F1D2D))
                            .withValues(
                              alpha: 0.82 * (_pointerActive ? 0.3 : 0.92),
                            ),
                        (_isTeacher
                                ? const Color(0xFF1D4ED8)
                                : const Color(0xFF7F1D1D))
                            .withValues(
                              alpha: 0.44 * (_pointerActive ? 0.3 : 0.92),
                            ),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.48, 1.0],
                    ),
                  ),
                ),
              ),
            ),

            // Content
            SafeArea(
              child: Column(
                children: [
                  // App Bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: _goToWelcome,
                          child: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                            ),
                            child: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white70, size: 18),
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                          decoration: BoxDecoration(
                            color: _primaryColor,
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: _primaryColor.withValues(alpha: 0.4),
                                blurRadius: 8,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _isTeacher ? Icons.school_rounded : Icons.person_rounded,
                                color: Colors.white,
                                size: 15,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                widget.role,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Scrollable content
                  Expanded(
                    child: SingleChildScrollView(
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          28,
                          0,
                          28,
                          (keyboardOpen ? 12 : 0) + mq.viewInsets.bottom + 16,
                        ),
                        child: Column(
                          children: [
                            SizedBox(height: keyboardOpen ? 10 : size.height * 0.04),

                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 240),
                              switchInCurve: Curves.easeOut,
                              switchOutCurve: Curves.easeIn,
                              child: keyboardOpen
                                  ? const SizedBox(key: ValueKey('logo-hidden'), height: 0)
                                  : AnimatedBuilder(
                                      key: const ValueKey('logo-visible'),
                                      animation: _floatController,
                                      builder: (context, child) {
                                        return Transform.translate(
                                          offset: Offset(0, 12 * Curves.easeInOut.transform(_floatController.value)),
                                          child: child,
                                        );
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: _primaryColor.withValues(alpha: 0.35),
                                              blurRadius: 18,
                                              spreadRadius: 2,
                                            ),
                                            BoxShadow(
                                              color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                                              blurRadius: 28,
                                              spreadRadius: 4,
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
                            ),
                            SizedBox(height: keyboardOpen ? 12 : 28),

                            // Header Text
                            const Text(
                              'CCS PULSECONNECT',
                              style: TextStyle(
                                fontSize: 10,
                                letterSpacing: 5,
                                color: Color(0xFFA1A1AA),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Welcome Back',
                              style: TextStyle(
                                fontSize: keyboardOpen ? 25 : 30,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                letterSpacing: -0.8,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Sign in to your account',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.white.withValues(alpha: 0.4),
                              ),
                            ),

                            const SizedBox(height: 36),

                            // Form Card - solid dark with subtle border
                            Container(
                              padding: const EdgeInsets.fromLTRB(22, 28, 22, 22),
                              decoration: BoxDecoration(
                                color: const Color(0xFF141418),
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(
                                  color: const Color(0xFF27272A),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.4),
                                    blurRadius: 16,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                              ),
                              child: Form(
                                key: _formKey,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Error
                                    if (_errorMessage != null)
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(14),
                                        margin: const EdgeInsets.only(bottom: 22),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF450A0A),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(color: const Color(0xFF7F1D1D)),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(Icons.error_outline, color: Color(0xFFFCA5A5), size: 18),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                _errorMessage!,
                                                style: const TextStyle(
                                                  color: Color(0xFFFCA5A5),
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                    // Student number only (teachers still use email)
                                    Text(
                                      _isTeacher
                                          ? 'Email Address'
                                          : 'Student Number',
                                      style: const TextStyle(
                                        color: Color(0xFFA1A1AA),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    TextFormField(
                                      controller: _emailController,
                                      keyboardType: _isTeacher
                                          ? TextInputType.emailAddress
                                          : TextInputType.text,
                                      style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                      cursorColor: _primaryColor,
                                      decoration: InputDecoration(
                                        hintText: _isTeacher
                                            ? 'you@gmail.com'
                                            : 'e.g. 231-0001',
                                        hintStyle: const TextStyle(color: Color(0xFF52525B), fontSize: 14),
                                        prefixIcon: Icon(
                                          _isTeacher
                                              ? Icons.email_outlined
                                              : Icons.badge_outlined,
                                          color: const Color(0xFF52525B),
                                          size: 20,
                                        ),
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
                                        focusedErrorBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(14),
                                          borderSide: const BorderSide(color: Color(0xFF7F1D1D), width: 1.5),
                                        ),
                                        errorStyle: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12),
                                      ),
                                      validator: (val) {
                                        final trimmed = (val ?? '').trim();
                                        if (trimmed.isEmpty) {
                                          return _isTeacher
                                              ? 'Email is required'
                                              : 'Student number is required';
                                        }
                                        if (_isTeacher) {
                                          if (!AuthService.isValidEmail(trimmed)) {
                                            return 'Enter a valid email';
                                          }
                                          return null;
                                        }
                                        if (trimmed.contains('@')) {
                                          return 'Use your student number, not email';
                                        }
                                        if (trimmed.length < 5) {
                                          return 'Enter a valid student number';
                                        }
                                        return null;
                                      },
                                    ),

                                    const SizedBox(height: 22),

                                    // Password
                                    const Text(
                                      'Password',
                                      style: TextStyle(
                                        color: Color(0xFFA1A1AA),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    TextFormField(
                                      controller: _passwordController,
                                      obscureText: _obscurePassword,
                                      style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                      cursorColor: _primaryColor,
                                      decoration: InputDecoration(
                                        hintText: '********',
                                        hintStyle: const TextStyle(color: Color(0xFF52525B), fontSize: 14, letterSpacing: 2),
                                        prefixIcon: const Icon(Icons.lock_outline_rounded, color: Color(0xFF52525B), size: 20),
                                        suffixIcon: IconButton(
                                          icon: Icon(
                                            _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                            color: const Color(0xFF52525B),
                                            size: 20,
                                          ),
                                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                        ),
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
                                        focusedErrorBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(14),
                                          borderSide: const BorderSide(color: Color(0xFF7F1D1D), width: 1.5),
                                        ),
                                        errorStyle: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12),
                                      ),
                                      validator: (val) {
                                        if (val == null || val.isEmpty) return 'Password is required';
                                        return null;
                                      },
                                    ),

                                    // Forgot Password
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton(
                                        onPressed: () {
                                          Navigator.push(
                                            context,
                                            AppPageRoute(builder: (_) => ForgotPasswordScreen(role: widget.role)),
                                          );
                                        },
                                        style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(vertical: 10),
                                        ),
                                        child: Text(
                                          'Forgot Password?',
                                          style: TextStyle(
                                            color: _primaryColor,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ),

                                    const SizedBox(height: 6),

                                    // Sign In Button — gradient with glow
                                    SizedBox(
                                      width: double.infinity,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(16),
                                          gradient: LinearGradient(
                                            colors: [_accentColor, _primaryColor],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: _primaryColor.withValues(alpha: 0.45),
                                              blurRadius: 14,
                                              offset: const Offset(0, 8),
                                            ),
                                          ],
                                        ),
                                        child: ElevatedButton(
                                          onPressed: _isLoading ? null : _handleLogin,
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
                                              : const Row(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Text(
                                                      'Sign In',
                                                      style: TextStyle(
                                                        fontSize: 16,
                                                        fontWeight: FontWeight.w800,
                                                        letterSpacing: 0.5,
                                                      ),
                                                    ),
                                                    SizedBox(width: 8),
                                                    Icon(Icons.arrow_forward_rounded, size: 20),
                                                  ],
                                                ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            const SizedBox(height: 24),

                            // Bottom secure text
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.lock_rounded, size: 13, color: Colors.white.withValues(alpha: 0.2)),
                                const SizedBox(width: 6),
                                Text(
                                  'Secured with encryption',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withValues(alpha: 0.2),
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 20),
                          ],
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
    );
  }
}


