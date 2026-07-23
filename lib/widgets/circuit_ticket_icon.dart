import 'package:flutter/material.dart';

class CircuitTicketIcon extends StatefulWidget {
  final Widget child;
  const CircuitTicketIcon({super.key, required this.child});

  @override
  State<CircuitTicketIcon> createState() => _CircuitTicketIconState();
}

class _CircuitTicketIconState extends State<CircuitTicketIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      height: 70,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: CircuitPainter(_controller.value),
            child: Center(
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.6),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.1),
                      blurRadius: 1,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Center(child: widget.child),
              ),
            ),
          );
        },
      ),
    );
  }
}

class CircuitPainter extends CustomPainter {
  final double progress;
  CircuitPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const chipWidth = 48.0;
    
    // Draw pins
    final pinPaint = Paint()
      ..color = const Color(0xFF666666)
      ..style = PaintingStyle.fill;
      
    const int pinsPerSide = 3;
    const double pinSpacing = 12.0;
    final double startY = center.dy - ((pinsPerSide - 1) * pinSpacing) / 2;
    
    for (int i = 0; i < pinsPerSide; i++) {
      final y = startY + (i * pinSpacing);
      // Left pins
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(center.dx - chipWidth / 2 - 2, y),
            width: 8,
            height: 4,
          ),
          const Radius.circular(1),
        ),
        pinPaint,
      );
      // Right pins
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(center.dx + chipWidth / 2 + 2, y),
            width: 8,
            height: 4,
          ),
          const Radius.circular(1),
        ),
        pinPaint,
      );
    }
    
    // Define trace paths
    final bgPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    List<Path> paths = [];
    List<Color> colors = const [
      Color(0xFF00CCFF), // blue
      Color(0xFFFFEA00), // yellow
      Color(0xFF00FF15), // green
      Color(0xFF9900FF), // purple
      Color(0xFF00CCFF), // blue
      Color(0xFFFF3300), // red
    ];
    
    Path createPath(Offset start, Offset mid, Offset end) {
      final p = Path();
      p.moveTo(start.dx, start.dy);
      p.lineTo(mid.dx, mid.dy);
      p.lineTo(end.dx, end.dy);
      return p;
    }

    final leftEdge = center.dx - chipWidth / 2 - 6;
    final rightEdge = center.dx + chipWidth / 2 + 6;

    // Left traces
    paths.add(createPath(
        Offset(leftEdge, startY), Offset(12, startY), Offset(12, 10)));
    paths.add(createPath(
        Offset(leftEdge, startY + pinSpacing),
        Offset(4, startY + pinSpacing),
        Offset(4, startY + pinSpacing)));
    paths.add(createPath(
        Offset(leftEdge, startY + pinSpacing * 2),
        Offset(18, startY + pinSpacing * 2),
        Offset(18, size.height - 10)));
    
    // Right traces
    paths.add(createPath(
        Offset(rightEdge, startY),
        Offset(size.width - 20, startY),
        Offset(size.width - 20, 15)));
    paths.add(createPath(
        Offset(rightEdge, startY + pinSpacing),
        Offset(size.width - 4, startY + pinSpacing),
        Offset(size.width - 4, startY + pinSpacing)));
    paths.add(createPath(
        Offset(rightEdge, startY + pinSpacing * 2),
        Offset(size.width - 15, startY + pinSpacing * 2),
        Offset(size.width - 15, size.height - 15)));

    // Draw trace backgrounds and dots
    final dotPaint = Paint()..style = PaintingStyle.fill;
    for (int i = 0; i < paths.length; i++) {
      canvas.drawPath(paths[i], bgPaint);
      
      // Draw end dot
      final metrics = paths[i].computeMetrics().first;
      final endPos = metrics.getTangentForOffset(metrics.length)?.position ?? Offset.zero;
      dotPaint.color = bgPaint.color;
      canvas.drawCircle(endPos, 2.5, dotPaint);
    }
    
    // Draw animated dashed flows
    for (int i = 0; i < paths.length; i++) {
      final color = colors[i % colors.length];
      final metrics = paths[i].computeMetrics().first;
      final length = metrics.length;
      
      final flowPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 2);

      const dashLength = 24.0;
      // Animate dash flowing towards the chip (end of path to start)
      final currentOffset = (length + dashLength) * (1.0 - progress) - dashLength;
      
      final pathSegment = Path();
      double start = currentOffset;
      double end = currentOffset + dashLength;
      
      if (start < 0) start = 0;
      if (end > length) end = length;
      
      if (start < end) {
        pathSegment.addPath(metrics.extractPath(start, end), Offset.zero);
        canvas.drawPath(pathSegment, flowPaint);
      }
    }
  }

  @override
  bool shouldRepaint(CircuitPainter oldDelegate) => oldDelegate.progress != progress;
}
