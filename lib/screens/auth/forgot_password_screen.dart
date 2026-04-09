import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:bcrypt/bcrypt.dart';
import '../../widgets/custom_loader.dart';

class ForgotPasswordScreen extends StatefulWidget {
  final String role;
  const ForgotPasswordScreen({super.key, this.role = 'Student'});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> with TickerProviderStateMixin {
  late AnimationController _logoFloatController;
  late AnimationController _gradientController;
  Offset _pointerPosition = const Offset(0, 0);
  bool _pointerActive = false;
  
  final _emailController = TextEditingController();
  final _idNumberController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  
  int _currentStep = 0; // 0 = verify identity, 1 = new password, 2 = success
  String? _verifiedUserId;

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
    _emailController.dispose();
    _idNumberController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    _logoFloatController.dispose();
    _gradientController.dispose();
    super.dispose();
  }

  Future<void> _verifyIdentity() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final email = _emailController.text.toLowerCase().trim();
      final idNumber = _idNumberController.text.trim();

      // Check if user exists in our users table and matches the ID Number
      final res = await Supabase.instance.client
          .from('users')
          .select('id, email, student_id')
          .eq('email', email)
          .limit(1);

      if (res.isEmpty) {
        _showError('No account found with that email address.');
        setState(() => _isLoading = false);
        return;
      }

      final userData = res[0];
      final dbIdNumber = userData['student_id']?.toString().trim() ?? '';
      
      // We check if the provided ID number correctly matches the stored student_id
      if (dbIdNumber.toLowerCase() != idNumber.toLowerCase()) {
         _showError('The provided ID Number does not match our records.');
         setState(() => _isLoading = false);
         return;
      }

      // Identity verified successfully
      setState(() {
        _verifiedUserId = userData['id'].toString();
        _currentStep = 1;
        _isLoading = false;
      });

    } catch (e) {
      setState(() => _isLoading = false);
      _showError('Error verifying identity. Please try again.');
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
      // Hash the new password properly (Bcrypt to match web system schema)
      final newHashedPassword = BCrypt.hashpw(newPass, BCrypt.gensalt());

      // Update Supabase directly based on the verified user id
      if (_verifiedUserId != null) {
        await Supabase.instance.client
            .from('users')
            .update({'password': newHashedPassword})
            .eq('id', _verifiedUserId!);
      }

      setState(() {
        _isLoading = false;
        _currentStep = 2; // Success
      });

    } catch (e) {
      setState(() => _isLoading = false);
      _showError('Error updating password. Please try again.');
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: const Color(0xFF7F1D1D),
        ),
      );
    }
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
    if (_currentStep == 2) {
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
        Text(
          _currentStep == 0 ? 'Forgot\nPassword?' : 'Set New\nPassword',
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
           ? 'Verify your identity by entering your registered email and ID Number.'
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
          child: _currentStep == 0 ? _buildStep0Form() : _buildStep1Form(),
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
          style: TextStyle(color: Color(0xFFA1A1AA), fontWeight: FontWeight.w600, fontSize: 13),
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
        const SizedBox(height: 24),
        const Text(
          'ID Number',
          style: TextStyle(color: Color(0xFFA1A1AA), fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _idNumberController,
          keyboardType: TextInputType.text,
          style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
          cursorColor: _primaryColor,
          decoration: _inputDecoration('e.g. 2021-0000', Icons.badge_outlined),
          validator: (val) {
            if (val == null || val.isEmpty) return 'ID Number is required';
            return null;
          },
        ),
        const SizedBox(height: 36),
        _buildSubmitButton('Verify Identity', _verifyIdentity),
      ],
    );
  }

  Widget _buildStep1Form() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'New Password',
          style: TextStyle(color: Color(0xFFA1A1AA), fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _newPasswordController,
          obscureText: true,
          style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
          cursorColor: _primaryColor,
          decoration: _inputDecoration('Min. 6 characters', Icons.lock_outline),
          validator: (val) {
            if (val == null || val.isEmpty) return 'New password is required';
            if (val.length < 6) return 'At least 6 characters required';
            return null;
          },
        ),
        const SizedBox(height: 24),
        const Text(
          'Confirm Password',
          style: TextStyle(color: Color(0xFFA1A1AA), fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _confirmPasswordController,
          obscureText: true,
          style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
          cursorColor: _primaryColor,
          decoration: _inputDecoration('Confirm your new password', Icons.lock_reset_outlined),
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
            child: Icon(Icons.check_circle_rounded, size: 64, color: _isTeacher ? const Color(0xFF10B981) : const Color(0xFFBE123C)),
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
              child: const Text('Back to Login', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
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
          gradient: LinearGradient(
            colors: [_accentColor, _primaryColor],
          ),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          child: _isLoading
              ? const PulseConnectLoader(size: 18, color: Colors.white)
              : Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }
}
