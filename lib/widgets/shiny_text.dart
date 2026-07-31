import 'package:flutter/material.dart';

import '../services/device_performance_service.dart';

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

class _ShinyTextState extends State<ShinyText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  bool get _shineEnabled =>
      !widget.disabled && DevicePerformance.instance.enableShine;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (widget.speed * 1000).toInt()),
    );
    DevicePerformance.instance.addListener(_onPerfChanged);
    if (_shineEnabled) {
      _controller.repeat();
    }
  }

  void _onPerfChanged() {
    if (!mounted) return;
    setState(() {
      if (_shineEnabled) {
        if (!_controller.isAnimating) _controller.repeat();
      } else {
        _controller.stop();
      }
    });
  }

  @override
  void didUpdateWidget(ShinyText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shineEnabled) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    DevicePerformance.instance.removeListener(_onPerfChanged);
    _controller.dispose();
    super.dispose();
  }

  Widget _staticText({Color? color, List<Shadow>? shadows}) {
    return Text(
      widget.text,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      style: TextStyle(
        fontSize: widget.fontSize,
        fontWeight: widget.fontWeight,
        letterSpacing: 0.5,
        fontFamily: 'Orbitron',
        color: color,
        shadows: shadows,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Low/mid devices: solid text — no ShaderMask loop (big GPU win).
    if (!_shineEnabled) {
      return _staticText(
        color: widget.shineColor,
        shadows: widget.shadows
            ?.map(
              (s) => Shadow(
                color: Colors.black,
                offset: s.offset,
                blurRadius: DevicePerformance.instance.shadowBlur(s.blurRadius),
              ),
            )
            .toList(),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final textWidget = _staticText();

        return Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (widget.shadows != null)
              _staticText(
                color: Colors.transparent,
                shadows: widget.shadows!
                    .map(
                      (s) => Shadow(
                        color: Colors.black,
                        offset: s.offset,
                        blurRadius: s.blurRadius,
                      ),
                    )
                    .toList(),
              ),
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) {
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
