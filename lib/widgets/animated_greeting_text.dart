import 'package:flutter/material.dart';

import '../services/device_performance_service.dart';

class AnimatedGreetingText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color baseColor;
  final Color scanColor;

  const AnimatedGreetingText({
    super.key,
    required this.text,
    required this.style,
    this.baseColor = const Color(0xFFEA580C), // orange-600
    this.scanColor = const Color(0xFFF97316), // orange-500
  });

  @override
  State<AnimatedGreetingText> createState() => _AnimatedGreetingTextState();
}

class _AnimatedGreetingTextState extends State<AnimatedGreetingText> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  bool get _animationEnabled =>
      DevicePerformance.instance.tier == PerformanceTier.high;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    DevicePerformance.instance.addListener(_onPerformanceChanged);
    _syncAnimation();
  }

  void _onPerformanceChanged() {
    if (!mounted) return;
    _syncAnimation();
    setState(() {});
  }

  void _syncAnimation() {
    if (_animationEnabled) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    DevicePerformance.instance.removeListener(_onPerformanceChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Continuous scan-line greeting is reserved for High Quality.
    if (!_animationEnabled) {
      return Text(
        widget.text,
        style: widget.style.copyWith(
          color: widget.baseColor,
          fontStyle: FontStyle.italic,
        ),
        maxLines: 1,
        overflow: TextOverflow.visible,
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        double progress = _controller.value;
        // Same as CSS greet-scan
        // 0% -10px, 25% 100%, 50% -10px, 75% 100%, 100% -10px
        double scanProgress = (progress * 4) % 1.0; 
        bool isGoingDown = (progress < 0.25) || (progress >= 0.50 && progress < 0.75);
        double yPosFactor = isGoingDown ? scanProgress : (1.0 - scanProgress);

        return IntrinsicWidth(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Text with greet-cut clipping effect
              ClipRect(
                clipper: _GreetCutClipper(progress: progress),
                child: Text(
                  widget.text,
                  style: widget.style.copyWith(
                    color: widget.baseColor,
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                ),
              ),

              // Physical Scanning Line
              Positioned(
                left: -4,
                right: -4,
                top: -6 + (yPosFactor * 40), // estimate max text height bounds
                child: Column(
                  children: [
                    Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: widget.scanColor,
                        borderRadius: BorderRadius.circular(4),
                        boxShadow: [
                          BoxShadow(
                            color: widget.scanColor.withValues(alpha: 0.8),
                            blurRadius: 8,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _GreetCutClipper extends CustomClipper<Rect> {
  final double progress;

  _GreetCutClipper({required this.progress});

  @override
  Rect getClip(Size size) {
    double top = -20;
    double bottom = size.height + 20;

    if (progress < 0.25) {
      top = (progress / 0.25) * size.height;
    } else if (progress < 0.50) {
      bottom = (1.0 - ((progress - 0.25) / 0.25)) * size.height;
    } else if (progress < 0.75) {
      top = -20; 
      bottom = size.height + 20;
    } else {
      top = -20;
      bottom = size.height + 20;
    }

    return Rect.fromLTRB(-20, top, size.width + 20, bottom);
  }

  @override
  bool shouldReclip(covariant _GreetCutClipper oldClipper) {
    return oldClipper.progress != progress;
  }
}

