import 'package:flutter/material.dart';

/// Wraps a ticket card with a smooth, straight vertical float animation
/// (gentle up-and-down bob) plus a diagonal shimmer sweep.
///
/// No internal GestureDetector — all tap handling is left to the parent.
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
  // ── Float (up-down bob) ───────────────────────────────────────────────────
  late final AnimationController _floatCtrl;
  late final Animation<double> _floatY;

  // ── Shimmer sweep ─────────────────────────────────────────────────────────
  late final AnimationController _shimmerCtrl;
  late final Animation<double> _shimmerPos;

  @override
  void initState() {
    super.initState();

    // Float: smooth sine-like oscillation using easeInOut back-and-forth
    _floatCtrl = AnimationController(vsync: this, duration: widget.floatDuration)
      ..repeat(reverse: true);

    _floatY = Tween<double>(begin: 0.0, end: -widget.floatHeight).animate(
      CurvedAnimation(parent: _floatCtrl, curve: Curves.easeInOut),
    );

    // Shimmer: sweeps from off-left to off-right
    _shimmerCtrl = AnimationController(vsync: this, duration: widget.shimmerDuration)
      ..repeat();

    _shimmerPos = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _shimmerCtrl, curve: Curves.linear),
    );
  }

  @override
  void dispose() {
    _floatCtrl.dispose();
    _shimmerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_floatCtrl, _shimmerCtrl]),
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _floatY.value),
          child: Stack(
            children: [
              child!,
              // ── Diagonal shimmer overlay (pointer-transparent) ──────────
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

// ── Shimmer band painter ───────────────────────────────────────────────────
class _ShimmerPainter extends CustomPainter {
  _ShimmerPainter(this.progress);

  /// Ranges from -1.0 (fully off-left) to 2.0 (fully off-right).
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
        stops: [0.0, 0.3, 0.5, 0.7, 1.0],
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
