import 'package:flutter/material.dart';
import 'auth/login_screen.dart';
import 'auth/register_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> with TickerProviderStateMixin {
  String _selectedRole = 'Student';

  // Animation Controller - 9s cycle matching the CSS
  late AnimationController _collisionController;
  late AnimationController _gradientController;

  // Flashlight Effect Tracking
  Offset _pointerPosition = const Offset(0, 0);
  bool _pointerActive = false;

  // Animation helper - get value based on controller percentage
  double _lerpPhase(double t, List<List<double>> keyframes) {
    // keyframes: [[percent, value], ...]  percent is 0-100
    for (int i = 0; i < keyframes.length - 1; i++) {
      double startP = keyframes[i][0] / 100.0;
      double endP = keyframes[i + 1][0] / 100.0;
      if (t >= startP && t <= endP) {
        double localT = (t - startP) / (endP - startP);
        return keyframes[i][1] + (keyframes[i + 1][1] - keyframes[i][1]) * localT;
      }
    }
    return keyframes.last[1];
  }

  @override
  void initState() {
    super.initState();

    // 9-second loop matching the CSS exactly
    _collisionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 9000),
    );
    _collisionController.repeat();

    // Gradient animation (matches CSS authGradientFlow - slow movement)
    _gradientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    _gradientController.repeat(reverse: true);
  }

  @override
  void dispose() {
    _collisionController.dispose();
    _gradientController.dispose();
    super.dispose();
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

  // Build spark widget
  Widget _buildSpark(double t, double angle, double dx, double dy) {
    // Sparks appear at 22% and disappear by 25%
    double opacity = 0;
    double scaleY = 0;
    double translateX = 0;
    double translateY = 0;

    if (t >= 0.21 && t < 0.22) {
      double local = (t - 0.21) / 0.01;
      opacity = local;
      scaleY = local * 2;
      translateX = dx * 0.5 * local;
      translateY = dy * 0.5 * local;
    } else if (t >= 0.22 && t < 0.25) {
      double local = (t - 0.22) / 0.03;
      opacity = 1.0 - local;
      scaleY = 2.0 * (1.0 - local);
      translateX = dx * 0.5 + dx * 0.5 * local;
      translateY = dy * 0.5 + dy * 0.5 * local;
    }

    if (opacity <= 0) return const SizedBox.shrink();

    return Transform.translate(
      offset: Offset(translateX, translateY),
      child: Transform.rotate(
        angle: angle,
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.scale(
            scaleY: scaleY,
            child: Container(
              width: 3,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(color: Colors.white, blurRadius: 10),
                  BoxShadow(color: const Color(0xFFFDE047), blurRadius: 20),
                  BoxShadow(color: const Color(0xFFEAB308), blurRadius: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Build lightning bolt
  Widget _buildLightning(double t) {
    double opacity = 0;
    double scaleY = 0;

    if (t >= 0.218 && t < 0.22) {
      opacity = (t - 0.218) / 0.002;
      scaleY = opacity * 1.2;
    } else if (t >= 0.22 && t < 0.23) {
      double local = (t - 0.22) / 0.01;
      opacity = 1.0 - local * 0.8;
      scaleY = 1.2 - local * 0.2;
    } else if (t >= 0.23 && t < 0.235) {
      opacity = 0.8;
      scaleY = 1.1;
    } else if (t >= 0.235 && t < 0.245) {
      double local = (t - 0.235) / 0.01;
      opacity = 0.8 * (1.0 - local);
      scaleY = 1.0;
    }

    if (opacity <= 0) return const SizedBox.shrink();

    return Transform.scale(
      scaleY: scaleY,
      alignment: Alignment.topCenter,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: CustomPaint(
          size: const Size(20, 100),
          painter: _LightningPainter(),
        ),
      ),
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
            // Background Image
            Positioned.fill(
              child: Image.asset(
                'assets/bg.png',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(),
              ),
            ),
            
            // Interactive Flashlight Overlay
            AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: _pointerActive ? 0.85 : 0.0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(
                      (_pointerPosition.dx / size.width) * 2 - 1,
                      (_pointerPosition.dy / size.height) * 2 - 1,
                    ),
                    radius: 0.4,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.8),
                      Colors.black,
                    ],
                    stops: const [0.4, 0.6, 1.0],
                  ),
                ),
              ),
            ),

            // Animated gradient overlay (authGradientFlow CSS)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _gradientController,
                  builder: (context, child) {
                    final t = _gradientController.value;

                    return AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      opacity: _pointerActive ? 0.3 : 1.0,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment(-0.3 + 0.6 * t, -0.5 + 0.3 * t),
                            radius: 1.1 + 0.15 * t,
                            colors: [
                              Color(0xFF6F1D2D).withValues(alpha: 0.82 + 0.08 * t),
                              Color(0xFF15803D).withValues(alpha: 0.5 + 0.15 * t),
                              const Color(0xFF09090B),
                            ],
                            stops: [0.0, 0.35 + 0.1 * t, 0.8],
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
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    const Spacer(flex: 3),

                    // Collision Animation Header
                    SizedBox(
                      height: 200,
                      width: double.infinity,
                      child: AnimatedBuilder(
                          animation: _collisionController,
                          builder: (context, child) {
                            final t = _collisionController.value;
                            final halfW = size.width * 0.6; // how far off-screen logos start

                            // === BSIT Logo (collideLeft CSS) ===
                            double bsitX = -halfW;
                            double bsitOpacity = 0;
                            double bsitScale = 0.8;
                            double bsitRotation = -0.26;

                            if (t < 0.05) {
                              bsitX = -halfW;
                              bsitOpacity = 0;
                            } else if (t < 0.10) {
                              double local = (t - 0.05) / 0.05;
                              bsitX = -halfW * (1.0 - local * 0.15);
                              bsitOpacity = local;
                            } else if (t < 0.22) {
                              double local = (t - 0.10) / 0.12;
                              bsitX = -halfW * 0.85 * (1.0 - local);
                              bsitOpacity = 1.0;
                              bsitScale = 0.8 + 0.3 * local;
                              bsitRotation = -0.26 + 0.44 * local;
                            } else if (t < 0.25) {
                              double local = (t - 0.22) / 0.03;
                              bsitX = 0;
                              bsitOpacity = 1.0 - local;
                              bsitScale = 1.1 + 0.2 * local;
                              bsitRotation = 0.17 + 0.09 * local;
                            }

                            // === CS Logo (collideRight CSS) ===
                            double csX = halfW;
                            double csOpacity = 0;
                            double csScale = 0.8;
                            double csRotation = 0.26;

                            if (t < 0.05) {
                              csX = halfW;
                              csOpacity = 0;
                            } else if (t < 0.10) {
                              double local = (t - 0.05) / 0.05;
                              csX = halfW * (1.0 - local * 0.15);
                              csOpacity = local;
                            } else if (t < 0.22) {
                              double local = (t - 0.10) / 0.12;
                              csX = halfW * 0.85 * (1.0 - local);
                              csOpacity = 1.0;
                              csScale = 0.8 + 0.3 * local;
                              csRotation = 0.26 - 0.44 * local;
                            } else if (t < 0.25) {
                              double local = (t - 0.22) / 0.03;
                              csX = 0;
                              csOpacity = 1.0 - local;
                              csScale = 1.1 + 0.2 * local;
                              csRotation = -0.17 - 0.09 * local;
                            }

                            // === Flash Burst (flashBurst CSS) ===
                            double flashOpacity = 0;
                            double flashScale = 0;
                            if (t >= 0.21 && t < 0.22) {
                              double local = (t - 0.21) / 0.01;
                              flashOpacity = local;
                              flashScale = local * 1.5;
                            } else if (t >= 0.22 && t < 0.28) {
                              double local = (t - 0.22) / 0.06;
                              flashOpacity = 1.0 - local * 0.2;
                              flashScale = 1.5 + local * 1.5; // grow to 3
                            } else if (t >= 0.28 && t < 0.45) {
                              double local = (t - 0.28) / 0.17;
                              flashOpacity = 0.8 * (1.0 - local);
                              flashScale = 3.0 + local; // grow to 4
                            }

                            // === CCS Reveal (revealCCS CSS) ===
                            double ccsOpacity = 0;
                            double ccsScale = 0.5;
                            double ccsTranslateY = 20;

                            if (t < 0.22) {
                              ccsOpacity = 0;
                              ccsScale = 0.5;
                              ccsTranslateY = 20;
                            } else if (t < 0.25) {
                              double local = (t - 0.22) / 0.03;
                              ccsOpacity = local;
                              ccsScale = 0.5 + 0.6 * local; // to 1.1
                              ccsTranslateY = 20 * (1.0 - local);
                            } else if (t < 0.28) {
                              double local = (t - 0.25) / 0.03;
                              ccsOpacity = 1.0;
                              ccsScale = 1.1 - 0.1 * local; // settle to 1.0
                              ccsTranslateY = 0;
                            } else if (t < 0.85) {
                              ccsOpacity = 1.0;
                              ccsScale = 1.0;
                              ccsTranslateY = 0;
                            } else if (t < 0.92) {
                              double local = (t - 0.85) / 0.07;
                              ccsOpacity = 1.0 - local;
                              ccsScale = 1.0 - 0.1 * local; // to 0.9
                              ccsTranslateY = -20 * local;
                            }

                            return Stack(
                              alignment: Alignment.center,
                              clipBehavior: Clip.none,
                              children: [
                                // BSIT Logo (Left)
                                if (bsitOpacity > 0)
                                  Transform.translate(
                                    offset: Offset(bsitX, 0),
                                    child: Transform.rotate(
                                      angle: bsitRotation,
                                      child: Transform.scale(
                                        scale: bsitScale,
                                        child: Opacity(
                                          opacity: bsitOpacity.clamp(0.0, 1.0),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              boxShadow: [BoxShadow(color: const Color(0xFF9F1239).withValues(alpha: 0.5), blurRadius: 20)],
                                            ),
                                            child: Image.asset('assets/BSIT.png', width: 80, height: 80),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                
                                // CS Logo (Right)
                                if (csOpacity > 0)
                                  Transform.translate(
                                    offset: Offset(csX, 0),
                                    child: Transform.rotate(
                                      angle: csRotation,
                                      child: Transform.scale(
                                        scale: csScale,
                                        child: Opacity(
                                          opacity: csOpacity.clamp(0.0, 1.0),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              boxShadow: [BoxShadow(color: const Color(0xFF16A34A).withValues(alpha: 0.5), blurRadius: 20)],
                                            ),
                                            child: Image.asset('assets/CS.png', width: 80, height: 80),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                // Lightning bolt
                                if (t >= 0.218 && t < 0.245)
                                  Positioned(
                                    top: 0,
                                    child: _buildLightning(t),
                                  ),

                                // Spark lines (4 diagonal directions)
                                _buildSpark(t, 0.785, 60, -60),   // top-right 45deg
                                _buildSpark(t, -0.785, -60, -60),  // top-left -45deg
                                _buildSpark(t, 2.356, 60, 60),    // bottom-right 135deg
                                _buildSpark(t, -2.356, -60, 60),   // bottom-left -135deg

                                // Flash Burst
                                if (flashOpacity > 0)
                                  Transform.scale(
                                    scale: flashScale,
                                    child: Opacity(
                                      opacity: flashOpacity.clamp(0.0, 1.0),
                                      child: Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: const Color(0xFFFEF3C7),
                                          boxShadow: [
                                            BoxShadow(color: const Color(0xFFFDE68A).withValues(alpha: 0.9), blurRadius: 60, spreadRadius: 40),
                                            BoxShadow(color: const Color(0xFFF59E0B).withValues(alpha: 0.7), blurRadius: 100, spreadRadius: 60),
                                            BoxShadow(color: const Color(0xFFD97706).withValues(alpha: 0.5), blurRadius: 150, spreadRadius: 80),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),

                                // CCS Final Logo
                                if (ccsOpacity > 0)
                                  Transform.translate(
                                    offset: Offset(0, ccsTranslateY),
                                    child: Transform.scale(
                                      scale: ccsScale,
                                      child: Opacity(
                                        opacity: ccsOpacity.clamp(0.0, 1.0),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            boxShadow: [BoxShadow(color: const Color(0xFFF59E0B).withValues(alpha: 0.4), blurRadius: 30, spreadRadius: 5)],
                                          ),
                                          child: Image.asset('assets/CCS.png', width: 150, height: 150),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                      ),
                    ),

                    const SizedBox(height: 16),
                    
                    // Title
                    const Text(
                      'CCS PULSECONNECT',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 4,
                        color: Color(0xFFA1A1AA),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Event Management\nSystem',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.5,
                        height: 1.2,
                      ),
                    ),

                    const Spacer(flex: 2),

                    // Controls Header (Welcome Back)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('WELCOME BACK', style: TextStyle(fontSize: 10, letterSpacing: 4, color: Color(0xFFA1A1AA), fontWeight: FontWeight.w700)),
                          const SizedBox(height: 6),
                          const Text('Log in', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white)),
                          const SizedBox(height: 4),
                          Text('Choose your role to continue.', style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.6))),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // User Type Selector - Styled like the web form inputs
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF18181B).withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF27272A)),
                      ),
                      child: Row(
                        children: ['Student', 'Teacher'].map((role) {
                          final isSelected = _selectedRole == role;
                          return Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _selectedRole = role),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 250),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF5A0000) // Maroon highlight
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  role,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.white.withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Login Button Matching Web
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            PageRouteBuilder(
                              pageBuilder: (_, __, ___) => LoginScreen(role: _selectedRole),
                              transitionDuration: const Duration(milliseconds: 400),
                              reverseTransitionDuration: const Duration(milliseconds: 400),
                              opaque: true,
                              barrierColor: const Color(0xFF09090B),
                              transitionsBuilder: (context, animation, secondaryAnimation, child) {
                                return FadeTransition(opacity: animation, child: child);
                              },
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF18181B),
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          'Login',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Sign Up Link Mapping
                    if (_selectedRole == 'Student') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          GestureDetector(
                            onTap: () {},
                            child: const Text(
                              'Forgot password?',
                              style: TextStyle(color: Color(0xFFE4E4E7), fontSize: 12),
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                PageRouteBuilder(
                                  pageBuilder: (_, __, ___) => const RegisterScreen(),
                                  transitionDuration: const Duration(milliseconds: 400),
                                  reverseTransitionDuration: const Duration(milliseconds: 400),
                                  opaque: true,
                                  barrierColor: const Color(0xFF09090B),
                                  transitionsBuilder: (context, animation, secondaryAnimation, child) {
                                    return FadeTransition(opacity: animation, child: child);
                                  },
                                ),
                              );
                            },
                            child: const Text(
                              'Create account',
                              style: TextStyle(color: Color(0xFFE4E4E7), fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ] else const SizedBox(height: 18),

                    const Spacer(),

                    // Footer
                    Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: Text(
                        '© ${DateTime.now().year} CCS PulseConnect',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF71717A),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Lightning bolt painter matching the CSS clip-path polygon
class _LightningPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    // Lightning bolt shape matching CSS: polygon(30% 0, 100% 0, 60% 40%, 100% 40%, 10% 100%, 40% 60%, 0% 60%)
    final path = Path()
      ..moveTo(size.width * 0.3, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width * 0.6, size.height * 0.4)
      ..lineTo(size.width, size.height * 0.4)
      ..lineTo(size.width * 0.1, size.height)
      ..lineTo(size.width * 0.4, size.height * 0.6)
      ..lineTo(0, size.height * 0.6)
      ..close();

    // Glow effect
    final glowPaint = Paint()
      ..color = const Color(0xFFFDE047).withValues(alpha: 0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, glowPaint);

    // Main bolt
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
