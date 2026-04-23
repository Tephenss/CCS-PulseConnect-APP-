import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../widgets/custom_loader.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _authService = AuthService();

  final _firstNameCtrl = TextEditingController();
  final _middleNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _suffixCtrl = TextEditingController();
  final _idNumberCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();

  String? _selectedCourse;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _errorMessage;
  String? _successMessage;

  late AnimationController _gradientController;
  late AnimationController _logoFloatController;
  late ScrollController _scrollController;
  double _scrollDim = 0.0; // 0.0 = top, 1.0 = fully scrolled
  Offset _pointerPosition = const Offset(0, 0);
  bool _pointerActive = false;

  @override
  void initState() {
    super.initState();
    _gradientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat(reverse: true);
    
    _logoFloatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    final maxScroll = 250.0; // px scrolled before fully dim
    final offset = _scrollController.offset.clamp(0.0, maxScroll);
    setState(() => _scrollDim = offset / maxScroll);
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _middleNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _suffixCtrl.dispose();
    _idNumberCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    _gradientController.dispose();
    _logoFloatController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // _loadSections is no longer used during registration

  Future<void> _handleRegister() async {
    if (!_formKey.currentState!.validate()) return;

    if (_passwordCtrl.text != _confirmPasswordCtrl.text) {
      setState(() => _errorMessage = 'Passwords do not match.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    final result = await _authService.register(
      firstName: _firstNameCtrl.text,
      middleName: _middleNameCtrl.text,
      lastName: _lastNameCtrl.text,
      suffix: _suffixCtrl.text,
      idNumber: _idNumberCtrl.text,
      course: _selectedCourse ?? '',
      email: _emailCtrl.text,
      password: _passwordCtrl.text,
    );

    setState(() => _isLoading = false);

    if (result['ok'] == true) {
      setState(() => _successMessage = 'Account created! You can now sign in.');
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) Navigator.pop(context);
      });
    } else {
      setState(() => _errorMessage = result['error'] as String?);
    }
  }

  void _updatePointer(PointerEvent details) {
    setState(() {
      _pointerPosition = details.position;
      _pointerActive = true;
    });
  }

  void _hidePointer(PointerEvent details) {
    setState(() => _pointerActive = false);
  }

  InputDecoration _inputDeco({required String hint, IconData? icon, Widget? suffix}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF71717A), fontSize: 14),
      prefixIcon: icon != null ? Icon(icon, color: const Color(0xFFA1A1AA), size: 20) : null,
      suffixIcon: suffix,
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
        borderSide: const BorderSide(color: Color(0xFF9F1239), width: 1.5),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFF09090B),
      body: Listener(
        onPointerDown: _updatePointer,
        onPointerMove: _updatePointer,
        onPointerUp: _hidePointer,
        onPointerCancel: _hidePointer,
        child: Stack(
          children: [
            // Background Image — dims on scroll
            Positioned.fill(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 100),
                opacity: (1.0 - _scrollDim * 0.85).clamp(0.15, 1.0),
                child: Transform.translate(
                  offset: Offset(0, -_scrollDim * 40),
                  child: Image.asset(
                    'assets/bg.png',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => const SizedBox(),
                  ),
                ),
              ),
            ),

            // Smooth dark fade — gets stronger on scroll
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFF09090B).withValues(alpha: 0.0 + _scrollDim * 0.4),
                      Color(0xFF09090B).withValues(alpha: 0.03 + _scrollDim * 0.2),
                      Color(0xFF09090B).withValues(alpha: 0.08 + _scrollDim * 0.2),
                      Color(0xFF09090B).withValues(alpha: 0.18 + _scrollDim * 0.15),
                      Color(0xFF09090B).withValues(alpha: 0.35 + _scrollDim * 0.15),
                      Color(0xFF09090B).withValues(alpha: 0.55 + _scrollDim * 0.1),
                      Color(0xFF09090B).withValues(alpha: 0.72 + _scrollDim * 0.08),
                      Color(0xFF09090B).withValues(alpha: 0.85 + _scrollDim * 0.05),
                      Color(0xFF09090B).withValues(alpha: 0.94 + _scrollDim * 0.03),
                      const Color(0xFF09090B),
                    ],
                    stops: const [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.65, 0.8, 0.9, 1.0],
                  ),
                ),
              ),
            ),

            // Flashlight
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

            // Animated gradient — dims on scroll
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: size.height,
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
                              const Color(0xFF6F1D2D).withValues(alpha: 0.85 + 0.1 * t),
                              const Color(0xFF7F1D1D).withValues(alpha: 0.5 + 0.2 * t),
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
                          onTap: () => Navigator.pop(context),
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
                            color: const Color(0xFF15803D),
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF15803D).withValues(alpha: 0.4),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.person_add_rounded, color: Colors.white, size: 15),
                              SizedBox(width: 6),
                              Text(
                                'Sign Up',
                                style: TextStyle(
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

                  // Scrollable form
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Column(
                          children: [
                            SizedBox(height: size.height * 0.02),

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
                                      color: const Color(0xFF9F1239).withValues(alpha: 0.35),
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
                            const SizedBox(height: 28),

                            // Header
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
                            const Text(
                              'Create Account',
                              style: TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                letterSpacing: -0.8,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Fill in your details to get started',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.white.withValues(alpha: 0.4),
                              ),
                            ),

                            const SizedBox(height: 28),

                            // Form Card — seamless blend
                            Container(
                              padding: const EdgeInsets.fromLTRB(22, 28, 22, 22),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0E0E12),
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 40,
                                    offset: const Offset(0, 12),
                                  ),
                                ],
                              ),
                              child: Form(
                                key: _formKey,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Messages
                                    if (_errorMessage != null) _buildMessage(_errorMessage!, false),
                                    if (_successMessage != null) _buildMessage(_successMessage!, true),

                                    // Full Name
                                    _buildLabel('First Name'),
                                    const SizedBox(height: 8),
                                    TextFormField(
                                      controller: _firstNameCtrl,
                                      style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                      cursorColor: const Color(0xFF9F1239),
                                      decoration: _inputDeco(hint: 'First Name', icon: Icons.person_outlined),
                                      validator: (v) => v == null || v.trim().length < 2 ? 'Required' : null,
                                    ),
                                    const SizedBox(height: 14),

                                    Row(
                                      children: [
                                        Expanded(
                                          flex: 3,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              _buildLabel('Middle Name'),
                                              const SizedBox(height: 8),
                                              TextFormField(
                                                controller: _middleNameCtrl,
                                                style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                                cursorColor: const Color(0xFF9F1239),
                                                decoration: _inputDeco(hint: 'Optional'),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          flex: 2,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              _buildLabel('Suffix'),
                                              const SizedBox(height: 8),
                                              TextFormField(
                                                controller: _suffixCtrl,
                                                style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                                cursorColor: const Color(0xFF9F1239),
                                                decoration: _inputDeco(hint: 'Jr, III'),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 14),

                                    _buildLabel('Last Name'),
                                    const SizedBox(height: 8),
                                    TextFormField(
                                      controller: _lastNameCtrl,
                                      style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                      cursorColor: const Color(0xFF9F1239),
                                      decoration: _inputDeco(hint: 'Last Name', icon: Icons.person_outlined),
                                      validator: (v) => v == null || v.trim().length < 2 ? 'Required' : null,
                                    ),

                                    const SizedBox(height: 20),

                                    // ID Number
                                    _buildLabel('School ID Number'),
                                    const SizedBox(height: 8),
                                    TextFormField(
                                      controller: _idNumberCtrl, // added new controller
                                      style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                      cursorColor: const Color(0xFF9F1239),
                                      decoration: _inputDeco(hint: 'e.g. 231-*****', icon: Icons.badge_outlined),
                                      validator: (v) => v == null || v.trim().isEmpty ? 'ID Number is required' : null,
                                    ),

                                    const SizedBox(height: 20),

                                    _buildLabel('Course'),
                                    const SizedBox(height: 8),
                                    DropdownButtonFormField<String>(
                                      initialValue: _selectedCourse,
                                      dropdownColor: const Color(0xFF1C1C22),
                                      iconEnabledColor: const Color(0xFFA1A1AA),
                                      hint: const Text(
                                        'Select Course',
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Color(0xFF71717A),
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: Color(0xFFF4F4F5),
                                        fontWeight: FontWeight.w600,
                                      ),
                                      decoration: _inputDeco(
                                        hint: '',
                                        icon: Icons.school_outlined,
                                      ),
                                      items: const [
                                        DropdownMenuItem(
                                          value: 'IT',
                                          child: Text(
                                            'BSIT (IT)',
                                            style: TextStyle(
                                              color: Color(0xFFF4F4F5),
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        DropdownMenuItem(
                                          value: 'CS',
                                          child: Text(
                                            'BSCS (CS)',
                                            style: TextStyle(
                                              color: Color(0xFFF4F4F5),
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                      onChanged: (value) {
                                        setState(() => _selectedCourse = value);
                                      },
                                      validator: (value) {
                                        if (value == null || value.isEmpty) {
                                          return 'Course is required';
                                        }
                                        return null;
                                      },
                                    ),

                                    const SizedBox(height: 20),

                                    // Email
                                    _buildLabel('Email Address'),
                                    const SizedBox(height: 8),
                                    TextFormField(
                                      controller: _emailCtrl,
                                      keyboardType: TextInputType.emailAddress,
                                      style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                      cursorColor: const Color(0xFF9F1239),
                                      decoration: _inputDeco(hint: 'you@gmail.com', icon: Icons.email_outlined),
                                      validator: (v) {
                                        if (v == null || v.isEmpty) return 'Required';
                                        if (!v.contains('@')) return 'Invalid email';
                                        return null;
                                      },
                                    ),

                                    const SizedBox(height: 20),

// Section dropdown removed 

                                    // Password
                                    _buildLabel('Password'),
                                    const SizedBox(height: 8),
                                    TextFormField(
                                      controller: _passwordCtrl,
                                      obscureText: _obscurePassword,
                                      style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                      cursorColor: const Color(0xFF9F1239),
                                      decoration: _inputDeco(
                                        hint: 'Minimum 8 characters',
                                        icon: Icons.lock_outline_rounded,
                                        suffix: IconButton(
                                          icon: Icon(
                                            _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                            color: const Color(0xFF52525B), size: 20,
                                          ),
                                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                        ),
                                      ),
                                      validator: (v) {
                                        if (v == null || v.length < 8) return 'At least 8 characters';
                                        return null;
                                      },
                                    ),

                                    const SizedBox(height: 14),

                                    // Confirm Password
                                    _buildLabel('Confirm Password'),
                                    const SizedBox(height: 8),
                                    TextFormField(
                                      controller: _confirmPasswordCtrl,
                                      obscureText: _obscureConfirm,
                                      style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                      cursorColor: const Color(0xFF9F1239),
                                      decoration: _inputDeco(
                                        hint: 'Re-enter password',
                                        icon: Icons.lock_outline,
                                        suffix: IconButton(
                                          icon: Icon(
                                            _obscureConfirm ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                            color: const Color(0xFF52525B), size: 20,
                                          ),
                                          onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                                        ),
                                      ),
                                      validator: (v) {
                                        if (v != _passwordCtrl.text) return 'Passwords do not match';
                                        return null;
                                      },
                                    ),

                                    const SizedBox(height: 28),

                                    // Register Button
                                    SizedBox(
                                      width: double.infinity,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(16),
                                          gradient: const LinearGradient(
                                            colors: [Color(0xFFBE123C), Color(0xFF9F1239)],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: const Color(0xFF9F1239).withValues(alpha: 0.45),
                                              blurRadius: 24,
                                              offset: const Offset(0, 8),
                                            ),
                                          ],
                                        ),
                                        child: ElevatedButton(
                                          onPressed: _isLoading ? null : _handleRegister,
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
                                                      'Create Account',
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

                            // Login link
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Already have an account? ',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.4),
                                    fontSize: 13,
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => Navigator.pop(context),
                                  child: const Text(
                                    'Sign In',
                                    style: TextStyle(
                                      color: Color(0xFFBE123C),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 30),
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
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: 13,
        color: Color(0xFFA1A1AA),
      ),
    );
  }

  Widget _buildMessage(String msg, bool isSuccess) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: isSuccess ? const Color(0xFF052E16) : const Color(0xFF450A0A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSuccess ? const Color(0xFF166534) : const Color(0xFF7F1D1D),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isSuccess ? Icons.check_circle_outline : Icons.error_outline,
            color: isSuccess ? const Color(0xFF86EFAC) : const Color(0xFFFCA5A5),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(
                color: isSuccess ? const Color(0xFF86EFAC) : const Color(0xFFFCA5A5),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
