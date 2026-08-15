import 'dart:io';
import 'dart:ui' show PointerDeviceKind;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../main.dart';
import '../../services/auth_service.dart';
import '../../services/native_document_picker.dart';
import '../../utils/class_schedule_format.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _authService = AuthService();

  final _idNumberCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();

  /// null = enter student no; map = roster matched, show email/password.
  Map<String, dynamic>? _rosterMatch;
  bool _isLookingUp = false;
  bool _isLoading = false;
  bool _isParsingSchedule = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _errorMessage;
  String? _successMessage;
  String? _scheduleFileName;
  String? _scheduleFilePath;
  List<int>? _scheduleBytes;
  List<Map<String, dynamic>> _scheduleSubjects = [];

  late AnimationController _logoFloatController;
  Offset _pointerPosition = const Offset(0, 0);
  bool _pointerActive = false;

  @override
  void initState() {
    super.initState();
    _logoFloatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _idNumberCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    _logoFloatController.dispose();
    super.dispose();
  }

  Future<void> _handleLookup() async {
    final studentNo = _idNumberCtrl.text.trim();
    if (studentNo.isEmpty) {
      setState(() => _errorMessage = 'Enter your student number.');
      return;
    }
    setState(() {
      _isLookingUp = true;
      _errorMessage = null;
      _successMessage = null;
    });
    final result = await _authService.lookupStudentRoster(studentNo);
    if (!mounted) return;
    setState(() => _isLookingUp = false);
    if (result['ok'] == true && result['roster'] is Map) {
      setState(() {
        _rosterMatch = Map<String, dynamic>.from(result['roster'] as Map);
        _errorMessage = null;
      });
    } else {
      setState(() {
        _rosterMatch = null;
        _errorMessage = result['error'] as String? ?? 'No matching student record.';
      });
    }
  }

  Future<void> _handleRegister() async {
    if (_rosterMatch == null) {
      await _handleLookup();
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    if (_scheduleSubjects.isEmpty) {
      setState(() => _errorMessage = 'Upload your LU registration form PDF first.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    final result = await _authService.register(
      idNumber: _idNumberCtrl.text,
      email: _emailCtrl.text,
      password: _passwordCtrl.text,
      scheduleFileName: _scheduleFileName,
      scheduleFilePath: _scheduleFilePath,
      scheduleBytes: _scheduleBytes,
    );

    setState(() => _isLoading = false);

    if (result['ok'] == true) {
      final user = result['user'];
      if (user is Map<String, dynamic>) {
        if (!mounted) return;
        PulseConnectApp.of(context).showEmailVerificationGate(
          user,
          gateReason: 'unverified',
          // After OTP: success dialog → login (do not enter app automatically).
          postRegistrationReviewFlow: true,
        );
        return;
      }
      setState(
        () => _errorMessage = 'Account created but verification data is missing.',
      );
    } else {
      setState(() => _errorMessage = result['error'] as String?);
    }
  }

  void _clearRosterMatch() {
    setState(() {
      _rosterMatch = null;
      _emailCtrl.clear();
      _passwordCtrl.clear();
      _confirmPasswordCtrl.clear();
      _errorMessage = null;
      _scheduleFileName = null;
      _scheduleFilePath = null;
      _scheduleBytes = null;
      _scheduleSubjects = [];
    });
  }

  Future<void> _pickRegistrationForm() async {
    if (_isParsingSchedule || _isLoading) return;
    setState(() {
      _isParsingSchedule = true;
      _errorMessage = null;
    });
    try {
      String? fileName;
      String? filePath;
      List<int>? bytes;
      if (Platform.isAndroid) {
        final native = await NativeDocumentPicker.pickAndroid(
          maxBytes: 8 * 1024 * 1024,
        );
        if (native == null) {
          if (mounted) setState(() => _isParsingSchedule = false);
          return;
        }
        fileName = native.name;
        filePath = native.path;
        // Keep bytes so Create Account still works if the temp path is gone.
        try {
          bytes = await File(native.path).readAsBytes();
        } catch (_) {
          bytes = null;
        }
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
          allowMultiple: false,
          withData: !Platform.isIOS,
        );
        if (result == null || result.files.isEmpty) {
          if (mounted) setState(() => _isParsingSchedule = false);
          return;
        }
        final picked = result.files.first;
        fileName = picked.name;
        filePath = picked.path;
        bytes = picked.bytes;
      }
      final ext = (fileName ?? '').toLowerCase();
      if (!ext.endsWith('.pdf')) {
        if (!mounted) return;
        setState(() {
          _isParsingSchedule = false;
          _errorMessage = 'Please choose the PDF registration form.';
        });
        return;
      }
      final parsed = await _authService.parseRegistrationForm(
        fileName: fileName ?? 'registration.pdf',
        filePath: filePath,
        bytes: bytes,
      );
      if (!mounted) return;
      if (parsed['ok'] != true) {
        setState(() {
          _isParsingSchedule = false;
          _scheduleFileName = null;
          _scheduleFilePath = null;
          _scheduleBytes = null;
          _scheduleSubjects = [];
          _errorMessage = parsed['error']?.toString() ?? 'Could not read that PDF.';
        });
        return;
      }
      final raw = parsed['subjects'];
      final subjects = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final row in raw) {
          if (row is Map) {
            subjects.add(Map<String, dynamic>.from(row));
          }
        }
      }
      setState(() {
        _isParsingSchedule = false;
        _scheduleFileName = fileName;
        _scheduleFilePath = filePath;
        _scheduleBytes = bytes;
        _scheduleSubjects = subjects;
        _errorMessage = subjects.isEmpty ? 'No subjects found in that PDF.' : null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _isParsingSchedule = false;
        _errorMessage = (error.message ?? error.code).trim().isEmpty
            ? 'Unable to open file picker.'
            : (error.message ?? error.code);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isParsingSchedule = false;
        _errorMessage = 'Unable to open file picker: $error';
      });
    }
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

  bool _hasUppercase(String value) => RegExp(r'[A-Z]').hasMatch(value);
  bool _hasLowercase(String value) => RegExp(r'[a-z]').hasMatch(value);
  bool _hasDigit(String value) => RegExp(r'\d').hasMatch(value);
  bool _hasSpecial(String value) => RegExp(r'[^A-Za-z0-9]').hasMatch(value);

  int _passwordStrengthScore(String value) {
    var score = 0;
    if (value.length >= 8) score++;
    if (_hasUppercase(value)) score++;
    if (_hasLowercase(value)) score++;
    if (_hasDigit(value)) score++;
    if (_hasSpecial(value)) score++;
    return score;
  }

  bool _isStrongPassword(String value) {
    return value.length >= 8 &&
        _hasUppercase(value) &&
        _hasLowercase(value) &&
        _hasDigit(value) &&
        _hasSpecial(value);
  }

  Color _strengthColor(int score) {
    if (score >= 5) return const Color(0xFF16A34A);
    if (score >= 3) return const Color(0xFFD97706);
    return const Color(0xFFDC2626);
  }

  String _strengthLabel(int score) {
    if (score >= 5) return 'Strong';
    if (score >= 3) return 'Medium';
    return 'Weak';
  }

  Widget _buildPasswordRule({
    required String text,
    required bool met,
  }) {
    final color = met ? const Color(0xFF22C55E) : const Color(0xFF71717A);
    return Row(
      children: [
        Icon(
          met ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
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
              child: Image.asset(
                'assets/bg.png',
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const SizedBox(),
              ),
            ),

            // Smooth dark fade — gets stronger on scroll
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x0009090B),
                      Color(0x0809090B),
                      Color(0x1409090B),
                      Color(0x2E09090B),
                      Color(0x5909090B),
                      Color(0x8009090B),
                      Color(0xB809090B),
                      Color(0xD809090B),
                      Color(0xEF09090B),
                      Color(0xFF09090B),
                    ],
                    stops: [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.65, 0.8, 0.9, 1.0],
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
                child: Opacity(
                  opacity: _pointerActive ? 0.3 : 0.92,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.35, -0.58),
                        radius: 1.25,
                        colors: [
                          const Color(0xFF6F1D2D).withValues(alpha: 0.82),
                          const Color(0xFF7F1D1D).withValues(alpha: 0.44),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.48, 1.0],
                      ),
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
                                blurRadius: 8,
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
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                              _rosterMatch == null
                                  ? 'Enter your student number to continue'
                                  : 'Confirm your details, then set email & password',
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
                                    blurRadius: 18,
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

                                    _buildLabel('Student Number'),
                                    const SizedBox(height: 8),
                                    TextFormField(
                                      controller: _idNumberCtrl,
                                      enabled: _rosterMatch == null,
                                      style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                      cursorColor: const Color(0xFF9F1239),
                                      keyboardType: TextInputType.text,
                                      inputFormatters: [
                                        FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z-]')),
                                      ],
                                      decoration: _inputDeco(hint: 'e.g. 231-*****', icon: Icons.badge_outlined),
                                      validator: (v) {
                                        final value = (v ?? '').trim();
                                        if (value.isEmpty) return 'Student number is required';
                                        return null;
                                      },
                                    ),

                                    if (_rosterMatch != null) ...[
                                      const SizedBox(height: 16),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(14),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF14532D).withValues(alpha: 0.35),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(color: const Color(0xFF166534)),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Matched school record',
                                              style: TextStyle(
                                                color: Color(0xFF86EFAC),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.6,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              (_rosterMatch!['name'] ?? '').toString(),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 15,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              [
                                                (_rosterMatch!['program_label'] ?? '').toString(),
                                                if (_rosterMatch!['is_irregular'] == true)
                                                  'IRREGULAR'
                                                else ...[
                                                  if ((_rosterMatch!['year_level'] ?? '').toString().isNotEmpty)
                                                    'Year ${_rosterMatch!['year_level']}',
                                                  if ((_rosterMatch!['block'] ?? '').toString().isNotEmpty)
                                                    'Block ${_rosterMatch!['block']}',
                                                ],
                                              ].where((e) => e.toString().trim().isNotEmpty).join(' · '),
                                              style: const TextStyle(
                                                color: Color(0xFFA1A1AA),
                                                fontSize: 12,
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: _clearRosterMatch,
                                              style: TextButton.styleFrom(
                                                foregroundColor: const Color(0xFF86EFAC),
                                                padding: EdgeInsets.zero,
                                              ),
                                              child: const Text('Change student number'),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 20),
                                      _buildLabel('Registration Form (PDF)'),
                                      const SizedBox(height: 8),
                                      OutlinedButton(
                                        onPressed: _isParsingSchedule ? null : _pickRegistrationForm,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: const Color(0xFFF4F4F5),
                                          side: const BorderSide(color: Color(0xFF3F3F46)),
                                          minimumSize: const Size.fromHeight(48),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(14),
                                          ),
                                        ),
                                        child: _isParsingSchedule
                                            ? const SizedBox(
                                                width: 18,
                                                height: 18,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Color(0xFFF4F4F5),
                                                ),
                                              )
                                            : Text(
                                                _scheduleFileName == null
                                                    ? 'Upload LU Form No. 1 PDF'
                                                    : _scheduleFileName!,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                      ),
                                      if (_scheduleSubjects.isNotEmpty) ...[
                                        const SizedBox(height: 10),
                                        Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF18181B),
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: const Color(0xFF27272A)),
                                          ),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${_scheduleSubjects.length} subject(s) found',
                                                style: const TextStyle(
                                                  color: Color(0xFFA1A1AA),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              ..._scheduleSubjects.take(8).map((s) {
                                                final code = (s['course_code'] ?? '').toString().trim();
                                                final desc = (s['course_description'] ?? '').toString().trim();
                                                final days = (s['days'] ?? '').toString().trim();
                                                final time = classScheduleFormatTimeLabel(
                                                  (s['time_label'] ?? '').toString(),
                                                );
                                                final when = [
                                                  if (days.isNotEmpty) days,
                                                  if (time.isNotEmpty) time,
                                                ].join(' · ');
                                                return Padding(
                                                  padding: const EdgeInsets.only(bottom: 8),
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                        [
                                                          if (code.isNotEmpty) code,
                                                          if (desc.isNotEmpty) desc,
                                                        ].join('  '),
                                                        style: const TextStyle(
                                                          color: Color(0xFFF4F4F5),
                                                          fontSize: 12,
                                                          fontWeight: FontWeight.w600,
                                                        ),
                                                      ),
                                                      if (when.isNotEmpty) ...[
                                                        const SizedBox(height: 2),
                                                        Text(
                                                          when,
                                                          style: const TextStyle(
                                                            color: Color(0xFFA1A1AA),
                                                            fontSize: 11,
                                                            fontWeight: FontWeight.w500,
                                                          ),
                                                        ),
                                                      ],
                                                    ],
                                                  ),
                                                );
                                              }),
                                            ],
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 20),
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
                                          if (!AuthService.isValidEmail(v)) return 'Invalid email';
                                          return null;
                                        },
                                      ),
                                      const SizedBox(height: 20),
                                      _buildLabel('Password'),
                                      const SizedBox(height: 8),
                                      TextFormField(
                                        controller: _passwordCtrl,
                                        obscureText: _obscurePassword,
                                        style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                        cursorColor: const Color(0xFF9F1239),
                                        onChanged: (_) => setState(() {}),
                                        decoration: _inputDeco(
                                          hint: 'Minimum 8 characters',
                                          icon: Icons.lock_outline_rounded,
                                          suffix: IconButton(
                                            icon: Icon(
                                              _obscurePassword
                                                  ? Icons.visibility_outlined
                                                  : Icons.visibility_off_outlined,
                                              color: const Color(0xFFA1A1AA),
                                              size: 20,
                                            ),
                                            onPressed: () =>
                                                setState(() => _obscurePassword = !_obscurePassword),
                                          ),
                                        ),
                                        validator: (v) {
                                          if (v == null || v.isEmpty) return 'Required';
                                          if (!_isStrongPassword(v)) {
                                            return 'Password does not meet requirements';
                                          }
                                          return null;
                                        },
                                      ),
                                      const SizedBox(height: 10),
                                      Builder(builder: (_) {
                                        final pwd = _passwordCtrl.text;
                                        final score = _passwordStrengthScore(pwd);
                                        return Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            LinearProgressIndicator(
                                              value: score / 5,
                                              minHeight: 4,
                                              backgroundColor: const Color(0xFF27272A),
                                              color: _strengthColor(score),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              _strengthLabel(score),
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: _strengthColor(score),
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            _buildPasswordRule(text: 'At least 8 characters', met: pwd.length >= 8),
                                            _buildPasswordRule(text: 'Uppercase letter', met: _hasUppercase(pwd)),
                                            _buildPasswordRule(text: 'Lowercase letter', met: _hasLowercase(pwd)),
                                            _buildPasswordRule(text: 'Number', met: _hasDigit(pwd)),
                                            _buildPasswordRule(text: 'Special character', met: _hasSpecial(pwd)),
                                          ],
                                        );
                                      }),
                                      const SizedBox(height: 16),
                                      _buildLabel('Confirm Password'),
                                      const SizedBox(height: 8),
                                      TextFormField(
                                        controller: _confirmPasswordCtrl,
                                        obscureText: _obscureConfirm,
                                        style: const TextStyle(fontSize: 14, color: Color(0xFFF4F4F5)),
                                        cursorColor: const Color(0xFF9F1239),
                                        decoration: _inputDeco(
                                          hint: 'Re-enter password',
                                          icon: Icons.lock_outline_rounded,
                                          suffix: IconButton(
                                            icon: Icon(
                                              _obscureConfirm
                                                  ? Icons.visibility_outlined
                                                  : Icons.visibility_off_outlined,
                                              color: const Color(0xFFA1A1AA),
                                              size: 20,
                                            ),
                                            onPressed: () =>
                                                setState(() => _obscureConfirm = !_obscureConfirm),
                                          ),
                                        ),
                                        validator: (v) {
                                          if (v != _passwordCtrl.text) return 'Passwords do not match';
                                          return null;
                                        },
                                      ),
                                    ],

                                    const SizedBox(height: 24),

                                    SizedBox(
                                      width: double.infinity,
                                      height: 52,
                                      child: ElevatedButton(
                                        onPressed: (_isLoading || _isLookingUp || _isParsingSchedule)
                                            ? null
                                            : () {
                                                if (_rosterMatch == null) {
                                                  _handleLookup();
                                                } else {
                                                  _handleRegister();
                                                }
                                              },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF9F1239),
                                          disabledBackgroundColor: const Color(0xFF9F1239).withValues(alpha: 0.5),
                                          foregroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(14),
                                          ),
                                          elevation: 0,
                                        ),
                                        child: (_isLoading || _isLookingUp || _isParsingSchedule)
                                            ? const SizedBox(
                                                width: 22,
                                                height: 22,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2.5,
                                                  color: Colors.white,
                                                ),
                                              )
                                            : Text(
                                                _rosterMatch == null ? 'Find my record' : 'Create Account',
                                                style: const TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w700,
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
