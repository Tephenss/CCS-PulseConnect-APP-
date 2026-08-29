import 'dart:async';
import 'package:flutter/material.dart';
import 'custom_loader.dart';
import 'shiny_text.dart';
import '../services/device_performance_service.dart';
import '../utils/course_theme_utils.dart';
import '../utils/teacher_theme_utils.dart';

/// Visual family for the branded loading splash.
enum PulseConnectSplashVariant {
  /// BSIT / default CCS maroon.
  maroon,

  /// BSCS / CS emerald theme.
  cs,

  /// Faculty / teacher sky-blue theme.
  teacher,
}

class PulseConnectSplashScreen extends StatefulWidget {
  final String? statusMessage;
  final VoidCallback? onFinished;
  final Duration? minimumDuration;
  final PulseConnectSplashVariant variant;

  const PulseConnectSplashScreen({
    super.key,
    this.statusMessage,
    this.onFinished,
    this.minimumDuration,
    this.variant = PulseConnectSplashVariant.maroon,
  });

  /// Picks maroon for BSIT/unknown and emerald for BSCS/CS.
  factory PulseConnectSplashScreen.forStudentCourse({
    Key? key,
    dynamic course,
    String? statusMessage,
    VoidCallback? onFinished,
    Duration? minimumDuration,
  }) {
    final isCs = CourseThemeUtils.isComputerScienceCourse(course);
    return PulseConnectSplashScreen(
      key: key,
      statusMessage: statusMessage,
      onFinished: onFinished,
      minimumDuration: minimumDuration,
      variant: isCs
          ? PulseConnectSplashVariant.cs
          : PulseConnectSplashVariant.maroon,
    );
  }

  /// Aligns splash with role theme: teacher → blue, BSCS → green, else maroon.
  factory PulseConnectSplashScreen.aligned({
    Key? key,
    required String role,
    dynamic course,
    String? statusMessage,
    VoidCallback? onFinished,
    Duration? minimumDuration,
  }) {
    if (role.trim().toLowerCase() == 'teacher') {
      return PulseConnectSplashScreen(
        key: key,
        statusMessage: statusMessage,
        onFinished: onFinished,
        minimumDuration: minimumDuration,
        variant: PulseConnectSplashVariant.teacher,
      );
    }
    return PulseConnectSplashScreen.forStudentCourse(
      key: key,
      course: course,
      statusMessage: statusMessage,
      onFinished: onFinished,
      minimumDuration: minimumDuration,
    );
  }

  /// Uses the active MaterialApp theme primary (set by role/course).
  factory PulseConnectSplashScreen.fromTheme(
    BuildContext context, {
    Key? key,
    String? statusMessage,
    VoidCallback? onFinished,
    Duration? minimumDuration,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    late final PulseConnectSplashVariant variant;
    if (primary.toARGB32() == TeacherThemeUtils.primary.toARGB32()) {
      variant = PulseConnectSplashVariant.teacher;
    } else if (CourseThemeUtils.isGreenStudentPrimary(primary)) {
      variant = PulseConnectSplashVariant.cs;
    } else {
      variant = PulseConnectSplashVariant.maroon;
    }
    return PulseConnectSplashScreen(
      key: key,
      statusMessage: statusMessage,
      onFinished: onFinished,
      minimumDuration: minimumDuration,
      variant: variant,
    );
  }

  @override
  State<PulseConnectSplashScreen> createState() =>
      _PulseConnectSplashScreenState();
}

class _SplashPalette {
  final Color scaffold;
  final List<Color> backgroundGradient;
  final Color ambientTop;
  final Color ambientBottom;
  final Color ringBorder;
  final Color logoGlowInner;

  /// Brand chrome — match GitHub splash on every role.
  /// PulseCONNECT uses ShinyText defaults (soft gray + white shine), not solid white/cream.
  /// Tagline + equalizer loader stay gold (#D4A843).
  static const Color brandAccent = Color(0xFFD4A843);
  static const Color brandLoader = Color(0xFFD4A843);

  const _SplashPalette({
    required this.scaffold,
    required this.backgroundGradient,
    required this.ambientTop,
    required this.ambientBottom,
    required this.ringBorder,
    required this.logoGlowInner,
  });

  static _SplashPalette forVariant(PulseConnectSplashVariant variant) {
    switch (variant) {
      case PulseConnectSplashVariant.cs:
        return const _SplashPalette(
          scaffold: Color(0xFF021A14),
          backgroundGradient: [
            Color(0xFF065F46),
            Color(0xFF047857),
            Color(0xFF03281F),
            Color(0xFF011510),
          ],
          ambientTop: Color(0xFF10B981),
          ambientBottom: Color(0xFF059669),
          ringBorder: Color(0xFF34D399),
          logoGlowInner: Color(0xFF6EE7B7),
        );
      case PulseConnectSplashVariant.teacher:
        return const _SplashPalette(
          scaffold: Color(0xFF020B14),
          backgroundGradient: [
            Color(0xFF0C4A6E),
            Color(0xFF082F49),
            Color(0xFF041624),
          ],
          ambientTop: Color(0xFF0369A1),
          ambientBottom: Color(0xFFD4A843),
          ringBorder: Color(0xFFD4A843),
          logoGlowInner: Color(0xFFD4A843),
        );
      case PulseConnectSplashVariant.maroon:
        return const _SplashPalette(
          scaffold: Color(0xFF0F0505),
          backgroundGradient: [
            Color(0xFF220808),
            Color(0xFF140505),
            Color(0xFF090202),
          ],
          ambientTop: Color(0xFF7F1D1D),
          ambientBottom: Color(0xFFD4A843),
          ringBorder: Color(0xFFD4A843),
          logoGlowInner: Color(0xFFD4A843),
        );
    }
  }
}

class _PulseConnectSplashScreenState extends State<PulseConnectSplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _logoEntranceController;
  late Animation<double> _logoScaleAnimation;
  late Animation<double> _logoFadeAnimation;

  late AnimationController _glowPulseController;
  late Animation<double> _glowScaleAnimation;
  late Animation<double> _glowOpacityAnimation;

  late AnimationController _shimmerController;

  int _messageIndex = 0;
  Timer? _messageTimer;

  static const List<String> _defaultMessages = [
    'Connecting to PulseCONNECT...',
    'Loading campus events...',
    'Syncing profile & attendance...',
    'Preparing your dashboard...',
  ];

  @override
  void initState() {
    super.initState();

    final enableMotion = DevicePerformance.instance.enableDecorativeMotion;

    _logoEntranceController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: enableMotion ? 800 : 300),
    );

    _logoScaleAnimation = CurvedAnimation(
      parent: _logoEntranceController,
      curve: enableMotion ? Curves.elasticOut : Curves.easeOut,
    );

    _logoFadeAnimation = CurvedAnimation(
      parent: _logoEntranceController,
      curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
    );

    _glowPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    if (enableMotion) {
      _glowPulseController.repeat(reverse: true);
    }

    _glowScaleAnimation = Tween<double>(begin: 0.95, end: 1.18).animate(
      CurvedAnimation(parent: _glowPulseController, curve: Curves.easeInOut),
    );

    _glowOpacityAnimation = Tween<double>(begin: 0.35, end: 0.85).animate(
      CurvedAnimation(parent: _glowPulseController, curve: Curves.easeInOut),
    );

    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    if (enableMotion) {
      _shimmerController.repeat();
    }

    _logoEntranceController.forward();

    _messageTimer = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (mounted && widget.statusMessage == null) {
        setState(() {
          _messageIndex = (_messageIndex + 1) % _defaultMessages.length;
        });
      }
    });

    if (widget.minimumDuration != null && widget.onFinished != null) {
      Timer(widget.minimumDuration!, () {
        if (mounted) {
          widget.onFinished!();
        }
      });
    }
  }

  @override
  void dispose() {
    _logoEntranceController.dispose();
    _glowPulseController.dispose();
    _shimmerController.dispose();
    _messageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayMsg = widget.statusMessage ?? _defaultMessages[_messageIndex];
    final palette = _SplashPalette.forVariant(widget.variant);

    return Scaffold(
      backgroundColor: palette.scaffold,
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: palette.backgroundGradient,
                ),
              ),
            ),
          ),

          Positioned(
            top: -80,
            right: -80,
            child: AnimatedBuilder(
              animation: _glowPulseController,
              builder: (context, child) {
                return Container(
                  width: 260 * _glowScaleAnimation.value,
                  height: 260 * _glowScaleAnimation.value,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: palette.ambientTop.withValues(
                      alpha: 0.28 * _glowOpacityAnimation.value,
                    ),
                  ),
                );
              },
            ),
          ),

          Positioned(
            bottom: -100,
            left: -100,
            child: AnimatedBuilder(
              animation: _glowPulseController,
              builder: (context, child) {
                return Container(
                  width: 300 * _glowScaleAnimation.value,
                  height: 300 * _glowScaleAnimation.value,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: palette.ambientBottom.withValues(
                      alpha: 0.22 * _glowOpacityAnimation.value,
                    ),
                  ),
                );
              },
            ),
          ),

          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedBuilder(
                    animation: Listenable.merge([
                      _logoEntranceController,
                      _glowPulseController,
                    ]),
                    builder: (context, child) {
                      return ScaleTransition(
                        scale: _logoScaleAnimation,
                        child: FadeTransition(
                          opacity: _logoFadeAnimation,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Transform.scale(
                                scale: _glowScaleAnimation.value,
                                child: Container(
                                  width: 140,
                                  height: 140,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        palette.logoGlowInner.withValues(
                                          alpha:
                                              0.45 * _glowOpacityAnimation.value,
                                        ),
                                        palette.ambientTop.withValues(
                                          alpha:
                                              0.25 * _glowOpacityAnimation.value,
                                        ),
                                        Colors.transparent,
                                      ],
                                      stops: const [0.2, 0.7, 1.0],
                                    ),
                                  ),
                                ),
                              ),
                              Container(
                                width: 110,
                                height: 110,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white.withValues(alpha: 0.08),
                                  border: Border.all(
                                    color: palette.ringBorder.withValues(
                                      alpha: 0.4,
                                    ),
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: palette.ambientTop.withValues(
                                        alpha: DevicePerformance.instance
                                            .shadowOpacity(0.5),
                                      ),
                                      blurRadius: DevicePerformance.instance
                                          .shadowBlur(24),
                                      spreadRadius: DevicePerformance
                                              .instance.enableHeavyShadows
                                          ? 2
                                          : 0,
                                    ),
                                  ],
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Image.asset(
                                    'assets/CCS.png',
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, _, _) => Image.asset(
                                      'assets/ccs_lock_logo.png',
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, _, _) => Image.asset(
                                        'assets/BSIT.png',
                                        fit: BoxFit.contain,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 32),

                  // Same as GitHub: ShinyText defaults (soft gray + white shine).
                  const ShinyText(
                    text: 'PulseCONNECT',
                    fontSize: 28,
                    speed: 2.5,
                    fontWeight: FontWeight.w900,
                  ),

                  const SizedBox(height: 6),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        height: 1,
                        width: 24,
                        color: _SplashPalette.brandAccent.withValues(alpha: 0.5),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'CCS EVENT SYSTEM',
                        style: TextStyle(
                          color: _SplashPalette.brandAccent.withValues(
                            alpha: 0.9,
                          ),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        height: 1,
                        width: 24,
                        color: _SplashPalette.brandAccent.withValues(alpha: 0.5),
                      ),
                    ],
                  ),

                  const SizedBox(height: 48),

                  const PulseConnectLoader(
                    size: 22,
                    strokeWidth: 4.5,
                    color: _SplashPalette.brandLoader,
                  ),

                  const SizedBox(height: 20),

                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.25),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: Text(
                      displayMsg,
                      key: ValueKey<String>(displayMsg),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
