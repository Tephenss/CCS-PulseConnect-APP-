import 'package:flutter/material.dart';

class PulseConnectLoader extends StatefulWidget {
  final Color? color;
  final double size;
  final double strokeWidth;

  const PulseConnectLoader({
    super.key,
    this.color,
    this.size = 20.0,
    this.strokeWidth = 4.0,
  });

  @override
  State<PulseConnectLoader> createState() => _PulseConnectLoaderState();
}

class _PulseConnectLoaderState extends State<PulseConnectLoader> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // If color is null, use primary color
    final loaderColor = widget.color ?? Theme.of(context).primaryColor;

    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(3, (index) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.strokeWidth / 2),
            child: _AnimatedBar(
              index: index,
              controller: _controller,
              color: loaderColor,
              baseHeight: index == 1 ? widget.size * 1.6 : widget.size,
              width: widget.strokeWidth,
            ),
          );
        }),
      ),
    );
  }
}

class _AnimatedBar extends StatelessWidget {
  final int index;
  final AnimationController controller;
  final Color color;
  final double baseHeight;
  final double width;

  const _AnimatedBar({
    required this.index,
    required this.controller,
    required this.color,
    required this.baseHeight,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    // Stagger delays: 0, 0.2, 0.4
    final double delay = index * 0.2;
    
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        double progress = (controller.value - delay);
        if (progress < 0) progress += 1.0;
        
        double scaleY = 1.0;
        double opacity = 0.4;

        if (progress <= 0.3) {
          double t = progress / 0.3;
          double curve = Curves.easeOut.transform(t);
          scaleY = 1.0 + (0.7 * curve);
          opacity = 0.4 + (0.6 * curve);
        } else if (progress <= 0.6) {
          double t = (progress - 0.3) / 0.3;
          double curve = Curves.easeInOut.transform(t);
          scaleY = 1.7 - (0.7 * curve);
          opacity = 1.0 - (0.6 * curve);
        } else {
          scaleY = 1.0;
          opacity = 0.4;
        }

        return Transform.scale(
          scaleY: scaleY,
          child: Container(
            width: width,
            height: baseHeight,
            decoration: BoxDecoration(
              color: color.withValues(alpha: opacity),
              borderRadius: BorderRadius.circular(width / 2),
              boxShadow: opacity > 0.8 ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.3 * opacity),
                  blurRadius: 8,
                  spreadRadius: 1,
                )
              ] : [],
            ),
          ),
        );
      },
    );
  }
}
