import 'package:flutter/material.dart';
import '../services/device_performance_service.dart';

class StaggeredEntrance extends StatefulWidget {
  final Widget child;
  final int index;
  final Duration delayStep;
  final Duration initialDelay;
  final Duration duration;
  final double slideOffset;
  final double initialScale;
  final Axis direction;

  const StaggeredEntrance({
    super.key,
    required this.child,
    this.index = 0,
    this.delayStep = const Duration(milliseconds: 100),
    this.initialDelay = const Duration(milliseconds: 100),
    this.duration = const Duration(milliseconds: 460),
    this.slideOffset = 22.0,
    this.initialScale = 0.94,
    this.direction = Axis.vertical,
  });

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();

    final enableMotion = DevicePerformance.instance.enableDecorativeMotion;

    _controller = AnimationController(
      vsync: this,
      duration: enableMotion ? widget.duration : Duration.zero,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );

    _slideAnimation = Tween<Offset>(
      begin: widget.direction == Axis.vertical
          ? Offset(0, widget.slideOffset / 100.0)
          : Offset(widget.slideOffset / 100.0, 0),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    _scaleAnimation = Tween<double>(
      begin: widget.initialScale,
      end: 1.0,
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    if (enableMotion) {
      final totalDelay = widget.initialDelay + (widget.delayStep * widget.index);
      Future.delayed(totalDelay, () {
        if (mounted) {
          _controller.forward();
        }
      });
    } else {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!DevicePerformance.instance.enableDecorativeMotion) {
      return widget.child;
    }

    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: widget.child,
        ),
      ),
    );
  }
}
