import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/notification_service.dart';
import '../../widgets/custom_loader.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:bcrypt/bcrypt.dart';

class ChangePasswordScreen extends StatefulWidget {
  final String role;
  const ChangePasswordScreen({super.key, this.role = 'Student'});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> with TickerProviderStateMixin {
  late AnimationController _logoFloatController;
  late AnimationController _gradientController;
  Offset _pointerPosition = const Offset(0, 0);
  bool _pointerActive = false;
  final _oldController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  
  bool _isLoading = false;
  bool _obscureOld = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  bool get _isTeacher => widget.role.toLowerCase() == 'teacher';
  Color get _primaryColor => _isTeacher ? const Color(0xFF064E3B) : const Color(0xFF9F1239);
  Color get _accentColor => _isTeacher ? const Color(0xFF059669) : const Color(0xFFBE123C);

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
    _oldController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    _logoFloatController.dispose();
    _gradientController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final oldPassword = _oldController.text.trim();
    final newPassword = _newController.text.trim();
    final confirmPassword = _confirmController.text.trim();

    if (oldPassword.isEmpty || newPassword.isEmpty || confirmPassword.isEmpty) {
      _showError('Please fill missing fields.');
      return;
    }

    if (newPassword != confirmPassword) {
      _showError('New passwords do not match.');
      return;
    }

    if (newPassword.length < 6) {
      _showError('Password must be at least 6 characters.');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final user = await AuthService().getCurrentUser();
      if (user == null) throw Exception('User not logged in');

      // Verify old password securely using centralized AuthService
      final authCheck = await AuthService().login(user['email'], oldPassword, user['role'] ?? 'student');
      if (authCheck['ok'] != true) {
        _showError('Incorrect current password.');
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      // Hash the new password properly (Bcrypt to match web system schema)
      final newHashedPassword = BCrypt.hashpw(newPassword, BCrypt.gensalt());

      // Update Supabase directly, completely decoupling from the insecure PHP API
      await Supabase.instance.client
          .from('users')
          .update({'password': newHashedPassword})
          .eq('id', user['id']);

      // Trigger local notification!
      await NotificationService().addPasswordChangeNotification();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: const Text('Password changed successfully!'), backgroundColor: _primaryColor),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      _showError('Error updating password. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: const Color(0xFF7F1D1D)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: const Color(0xFF09090B),
      body: Listener(
        onPointerDown: (e) => setState(() { _pointerPosition = e.position; _pointerActive = true; }),
        onPointerMove: (e) => setState(() { _pointerPosition = e.position; }),
        onPointerUp: (e) => setState(() { _pointerActive = false; }),
        onPointerCancel: (e) => setState(() { _pointerActive = false; }),
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
                              (_isTeacher ? const Color(0xFF064E3B) : const Color(0xFF6F1D2D)).withValues(alpha: 0.85 + 0.1 * t),
                              (_isTeacher ? const Color(0xFF15803D) : const Color(0xFF7F1D1D)).withValues(alpha: 0.5 + 0.2 * t),
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
                      child: const Icon(Icons.arrow_back_ios_rounded, size: 16, color: Colors.white),
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                  title: const Text(
                    'Security',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
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
                        
                        // CCS Logo with premium float & glow
                        AnimatedBuilder(
                          animation: _logoFloatController,
                          builder: (context, child) {
                            return Transform.translate(
                              offset: Offset(0, 12 * Curves.easeInOut.transform(_logoFloatController.value)),
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
                        const Text(
                          'Update Password',
                          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Keep your account secure by updating your credentials regularly.',
                          style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.45), height: 1.5),
                        ),
                        const SizedBox(height: 40),
                        _buildPasswordField('Current Password', _oldController, _obscureOld, (v) => setState(() => _obscureOld = v)),
                        const SizedBox(height: 22),
                        _buildPasswordField('New Password', _newController, _obscureNew, (v) => setState(() => _obscureNew = v)),
                        const SizedBox(height: 22),
                        _buildPasswordField('Confirm Password', _confirmController, _obscureConfirm, (v) => setState(() => _obscureConfirm = v)),
                        const SizedBox(height: 36),
                        SizedBox(
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
                              onPressed: _isLoading ? null : _submit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 18),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                              child: _isLoading 
                                ? const PulseConnectLoader(size: 18, color: Colors.white)
                                : const Text('Update Credentials', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                            ),
                          ),
                        ),
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

  Widget _buildPasswordField(String label, TextEditingController ctrl, bool obscure, Function(bool) toggle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFFA1A1AA))),
        const SizedBox(height: 10),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
          cursorColor: _primaryColor,
          decoration: InputDecoration(
            hintText: '••••••••',
            hintStyle: const TextStyle(color: Color(0xFF52525B), fontSize: 14, letterSpacing: 2),
            prefixIcon: const Icon(Icons.lock_outline_rounded, color: Color(0xFF52525B), size: 20),
            suffixIcon: IconButton(
              icon: Icon(obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: const Color(0xFF52525B), size: 20),
              onPressed: () => toggle(!obscure),
            ),
            filled: true,
            fillColor: const Color(0xFF1C1C22),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF27272A))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF27272A))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _primaryColor, width: 1.5)),
          ),
        ),
      ],
    );
  }
}
