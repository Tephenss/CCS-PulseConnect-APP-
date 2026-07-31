import 'dart:async';
import 'package:flutter/material.dart';
import 'custom_loader.dart';
import 'shiny_text.dart';
import '../services/device_performance_service.dart';

class PulseConnectSplashScreen extends StatefulWidget {
  final String? statusMessage;
  final VoidCallback? onFinished;
  final Duration? minimumDuration;

  const PulseConnectSplashScreen({
    super.key,
    this.statusMessage,
    this.onFinished,
    this.minimumDuration,
  });

  @override
  State<PulseConnectSplashScreen> createState() => _PulseConnectSplashScreenState();
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

    // 1. Logo Entrance Animation (Scale + Fade in with elastic feel)
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

    // 2. Continuous Glowing Aura Pulse behind logo
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

    // 3. Shimmer gradient flow
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    if (enableMotion) {
      _shimmerController.repeat();
    }

    _logoEntranceController.forward();

    // Cycle messages periodically if custom statusMessage is not locked
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

    return Scaffold(
      backgroundColor: const Color(0xFF0F0505),
      body: Stack(
        children: [
          // Background Gradient with ambient glows
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF220808),
                    Color(0xFF140505),
                    Color(0xFF090202),
                  ],
                ),
              ),
            ),
          ),

          // Top Right Ambient Crimson Glow
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
                    color: const Color(0xFF7F1D1D).withValues(alpha: 0.25 * _glowOpacityAnimation.value),
                  ),
                );
              },
            ),
          ),

          // Bottom Left Ambient Gold Glow
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
                    color: const Color(0xFFD4A843).withValues(alpha: 0.15 * _glowOpacityAnimation.value),
                  ),
                );
              },
            ),
          ),

          // Center Splash Content
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo with Pulsing Aura Ring
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
                              // Outer Glowing Ring
                              Transform.scale(
                                scale: _glowScaleAnimation.value,
                                child: Container(
                                  width: 140,
                                  height: 140,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        const Color(0xFFD4A843).withValues(
                                          alpha: 0.45 * _glowOpacityAnimation.value,
                                        ),
                                        const Color(0xFF7F1D1D).withValues(
                                          alpha: 0.25 * _glowOpacityAnimation.value,
                                        ),
                                        Colors.transparent,
                                      ],
                                      stops: const [0.2, 0.7, 1.0],
                                    ),
                                  ),
                                ),
                              ),

                              // Inner Glass Backdrop for Logo
                              Container(
                                width: 110,
                                height: 110,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white.withValues(alpha: 0.08),
                                  border: Border.all(
                                    color: const Color(0xFFD4A843).withValues(alpha: 0.4),
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF7F1D1D).withValues(
                                        alpha: DevicePerformance.instance.shadowOpacity(0.5),
                                      ),
                                      blurRadius: DevicePerformance.instance.shadowBlur(24),
                                      spreadRadius: DevicePerformance.instance.enableHeavyShadows ? 2 : 0,
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

                  // Animated Shiny Brand Title
                  const ShinyText(
                    text: 'PulseCONNECT',
                    fontSize: 28,
                    speed: 2.5,
                    fontWeight: FontWeight.w900,
                  ),

                  const SizedBox(height: 6),

                  // Subtitle Badge
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        height: 1,
                        width: 24,
                        color: const Color(0xFFD4A843).withValues(alpha: 0.5),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'CCS EVENT SYSTEM',
                        style: TextStyle(
                          color: const Color(0xFFD4A843).withValues(alpha: 0.9),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        height: 1,
                        width: 24,
                        color: const Color(0xFFD4A843).withValues(alpha: 0.5),
                      ),
                    ],
                  ),

                  const SizedBox(height: 48),

                  // Animated Equalizer Loader with Gold Theme
                  const PulseConnectLoader(
                    size: 22,
                    strokeWidth: 4.5,
                    color: Color(0xFFD4A843),
                  ),

                  const SizedBox(height: 20),

                  // Status Message with Smooth Cross-Fade
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
