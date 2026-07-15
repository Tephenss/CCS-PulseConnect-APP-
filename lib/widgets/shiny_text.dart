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
  final int? maxLines;
  final TextOverflow? overflow;

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
    this.maxLines,
    this.overflow,
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
          maxLines: widget.maxLines,
          overflow: widget.overflow,
          style: TextStyle(
            fontSize: widget.fontSize,
            fontWeight: widget.fontWeight,
            letterSpacing: 0.5,
            fontFamily: 'Orbitron',
          ),
        );

        return Stack(
          alignment: Alignment.centerLeft,
          children: [
            // Background Shadow Layer (Solid Black)
            if (widget.shadows != null)
              Text(
                widget.text,
                textAlign: widget.textAlign,
                maxLines: widget.maxLines,
                overflow: widget.overflow,
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

            // Shiny Foreground Layer — horizontal left → right sweep
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) {
                // Slide highlight from left of text to right, then loop
                final double x = -1.6 + (_controller.value * 3.2);
                return LinearGradient(
                  begin: Alignment(x - 0.45, 0),
                  end: Alignment(x + 0.45, 0),
                  colors: [
                    widget.color,
                    widget.color,
                    widget.shineColor,
                    widget.color,
                    widget.color,
                  ],
                  stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
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
