import 'package:flutter/material.dart';

import '../services/device_performance_service.dart';

/// Wraps a ticket card with a smooth, straight vertical float animation
/// (gentle up-and-down bob) plus a diagonal shimmer sweep.
///
/// No internal GestureDetector — all tap handling is left to the parent.
/// On low-end devices, motion is skipped automatically.
class AnimatedTicketCard extends StatefulWidget {
  const AnimatedTicketCard({
    super.key,
    required this.child,
    this.floatDuration = const Duration(milliseconds: 2400),
    this.floatHeight = 8.0,
    this.shimmerDuration = const Duration(seconds: 3),
  });

  final Widget child;

  /// Duration of one full up-down float cycle.
  final Duration floatDuration;

  /// How many logical pixels the card rises and falls.
  final double floatHeight;

  /// Duration of the diagonal shimmer sweep.
  final Duration shimmerDuration;

  @override
  State<AnimatedTicketCard> createState() => _AnimatedTicketCardState();
}

class _AnimatedTicketCardState extends State<AnimatedTicketCard>
    with TickerProviderStateMixin {
  late final AnimationController _floatCtrl;
  late final Animation<double> _floatY;
  late final AnimationController _shimmerCtrl;
  late final Animation<double> _shimmerPos;
  late final bool _motionEnabled;

  @override
  void initState() {
    super.initState();
    _motionEnabled = DevicePerformance.instance.enableDecorativeMotion;

    _floatCtrl =
        AnimationController(vsync: this, duration: widget.floatDuration);
    _floatY = Tween<double>(begin: 0.0, end: -widget.floatHeight).animate(
      CurvedAnimation(parent: _floatCtrl, curve: Curves.easeInOut),
    );

    _shimmerCtrl =
        AnimationController(vsync: this, duration: widget.shimmerDuration);
    _shimmerPos = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _shimmerCtrl, curve: Curves.linear),
    );

    if (_motionEnabled) {
      _floatCtrl.repeat(reverse: true);
      // Shimmer only on high-end — float alone is enough for medium.
      if (DevicePerformance.instance.enableShine) {
        _shimmerCtrl.repeat();
      }
    }
  }

  @override
  void dispose() {
    _floatCtrl.dispose();
    _shimmerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_motionEnabled) {
      return widget.child;
    }

    final shimmerOn = DevicePerformance.instance.enableShine;

    return AnimatedBuilder(
      animation: Listenable.merge([
        _floatCtrl,
        if (shimmerOn) _shimmerCtrl,
      ]),
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _floatY.value),
          child: Stack(
            children: [
              child!,
              if (shimmerOn)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _ShimmerPainter(_shimmerPos.value),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _ShimmerPainter extends CustomPainter {
  _ShimmerPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final bandHalf = size.width * 0.15;
    final cx = size.width * progress;

    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.transparent,
          Colors.white.withValues(alpha: 0.14),
          Colors.white.withValues(alpha: 0.26),
          Colors.white.withValues(alpha: 0.14),
          Colors.transparent,
        ],
        stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
        transform: _ShiftTransform(cx - bandHalf, size),
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) => old.progress != progress;
}

class _ShiftTransform extends GradientTransform {
  const _ShiftTransform(this.shiftX, this.size);
  final double shiftX;
  final Size size;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(shiftX, 0, 0);
  }
}
