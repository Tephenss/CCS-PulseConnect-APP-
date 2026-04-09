import 'package:flutter/material.dart';

class ShinyText extends StatefulWidget {
  final String text;
  final double speed; // seconds
  final Color color;
  final Color shineColor;
  final double spread;
  final bool disabled;
  final double fontSize;
  final FontWeight fontWeight;
  final TextAlign textAlign;
  final List<Shadow>? shadows;

  const ShinyText({
    super.key,
    required this.text,
    this.speed = 2.0,
    this.color = const Color(0xFFB5B5B5),
    this.shineColor = Colors.white,
    this.spread = 120.0,
    this.disabled = false,
    this.fontSize = 16,
    this.fontWeight = FontWeight.w800,
    this.textAlign = TextAlign.left,
    this.shadows,
  });

  @override
  State<ShinyText> createState() => _ShinyTextState();
}

class _ShinyTextState extends State<ShinyText> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (widget.speed * 1000).toInt()),
    );
    if (!widget.disabled) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(ShinyText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.disabled != oldWidget.disabled) {
      if (widget.disabled) {
        _controller.stop();
      } else {
        _controller.repeat();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final textWidget = Text(
          widget.text,
          textAlign: widget.textAlign,
          style: TextStyle(
            fontSize: widget.fontSize,
            fontWeight: widget.fontWeight,
            letterSpacing: 0.5,
            fontFamily: 'Orbitron',
          ),
        );

        return Stack(
          alignment: Alignment.center,
          children: [
            // Background Shadow Layer (Solid Black)
            if (widget.shadows != null)
              Text(
                widget.text,
                textAlign: widget.textAlign,
                style: TextStyle(
                  fontSize: widget.fontSize,
                  fontWeight: widget.fontWeight,
                  letterSpacing: 0.5,
                  fontFamily: 'Orbitron',
                  color: Colors.transparent, // Don't show text, just shadows
                  shadows: widget.shadows!.map((s) => Shadow(
                    color: Colors.black, // Force shadow to be black
                    offset: s.offset,
                    blurRadius: s.blurRadius,
                  )).toList(),
                ),
              ),

            // Shiny Foreground Layer
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) {
                final double slideRotation = _controller.value * 2 - 1.0; // from -1 to 1
                return LinearGradient(
                  begin: Alignment(-1.0 - slideRotation, -1.0),
                  end: Alignment(1.0 - slideRotation, 1.0),
                  colors: [
                    widget.color,
                    widget.color,
                    widget.shineColor,
                    widget.color,
                    widget.color,
                  ],
                  stops: const [0.0, 0.4, 0.5, 0.6, 1.0],
                ).createShader(bounds);
              },
              child: textWidget,
            ),
          ],
        );
      },
    );
  }
}

class _GradientRotation extends GradientTransform {
  final double progress;
  const _GradientRotation(this.progress);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final double center = bounds.width * progress;
    return Matrix4.identity()..translate(-center, 0.0);
  }
}
