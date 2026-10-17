import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NavigationTutorialStep {
  final GlobalKey targetKey;
  final String title;
  final String description;
  final IconData icon;
  final Future<void> Function()? onEnter;
  final Future<bool?> Function()? onBeforeAdvance;
  final Future<void> Function()? onExit;
  final Future<bool?> Function()? onTargetTap;

  const NavigationTutorialStep({
    required this.targetKey,
    required this.title,
    required this.description,
    required this.icon,
    this.onEnter,
    this.onBeforeAdvance,
    this.onExit,
    this.onTargetTap,
  });
}

class NavigationTutorial {
  static Future<void> showOnce({
    required BuildContext context,
    required String role,
    required Color accentColor,
    required List<NavigationTutorialStep> steps,
  }) async {
    if (steps.isEmpty || !context.mounted) return;

    late final SharedPreferences preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }

    final preferenceKey = 'navigation_tutorial_${role}_v2_completed';
    if ((preferences.getBool(preferenceKey) ?? false) || !context.mounted) {
      return;
    }

    final finished = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Navigation tutorial',
      barrierColor: Colors.transparent,
      useRootNavigator: true,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          _NavigationTutorialOverlay(steps: steps, accentColor: accentColor),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          ),
    );

    if (finished == true) {
      try {
        await preferences.setBool(preferenceKey, true);
      } catch (_) {
        // Onboarding should never interrupt normal app use.
      }
    }
  }
}

class _NavigationTutorialOverlay extends StatefulWidget {
  final List<NavigationTutorialStep> steps;
  final Color accentColor;

  const _NavigationTutorialOverlay({
    required this.steps,
    required this.accentColor,
  });

  @override
  State<_NavigationTutorialOverlay> createState() =>
      _NavigationTutorialOverlayState();
}

class _NavigationTutorialOverlayState
    extends State<_NavigationTutorialOverlay> {
  final GlobalKey _overlayKey = GlobalKey();
  int _stepIndex = 0;
  Rect? _targetRect;
  RectTween _targetTween = RectTween(begin: null, end: null);
  bool _isAdvancing = false;

  @override
  void initState() {
    super.initState();
    _scheduleTargetMeasurement();
  }

  void _scheduleTargetMeasurement() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final overlayObject = _overlayKey.currentContext?.findRenderObject();
      final targetObject = widget.steps[_stepIndex].targetKey.currentContext
          ?.findRenderObject();
      if (overlayObject is! RenderBox ||
          targetObject is! RenderBox ||
          !overlayObject.hasSize ||
          !targetObject.hasSize) {
        return;
      }

      final targetTopLeft = targetObject.localToGlobal(Offset.zero);
      final targetBottomRight = targetObject.localToGlobal(
        targetObject.size.bottomRight(Offset.zero),
      );
      final rect = Rect.fromPoints(
        overlayObject.globalToLocal(targetTopLeft),
        overlayObject.globalToLocal(targetBottomRight),
      ).inflate(6);
      if (rect == _targetRect) return;
      setState(() {
        _targetTween = RectTween(begin: _targetRect ?? rect, end: rect);
        _targetRect = rect;
      });
    });
  }

  Future<void> _advance({bool skipBeforeAdvance = false}) async {
    if (_isAdvancing) return;
    if (_stepIndex == widget.steps.length - 1) {
      await widget.steps[_stepIndex].onExit?.call();
      if (mounted) Navigator.of(context, rootNavigator: true).pop(true);
      return;
    }

    setState(() => _isAdvancing = true);
    try {
      final currentStep = widget.steps[_stepIndex];
      if (!skipBeforeAdvance && currentStep.onBeforeAdvance != null) {
        final shouldContinue = await currentStep.onBeforeAdvance!.call();
        if (!mounted || shouldContinue != true) return;
      }
      await currentStep.onExit?.call();
      if (!mounted) return;

      final nextStepIndex = _stepIndex + 1;
      await widget.steps[nextStepIndex].onEnter?.call();
      if (!mounted) return;

      setState(() {
        _stepIndex = nextStepIndex;
      });
      await WidgetsBinding.instance.endOfFrame;
      _scheduleTargetMeasurement();
    } finally {
      if (mounted) setState(() => _isAdvancing = false);
    }
  }

  Future<void> _skip() async {
    if (_isAdvancing) return;
    setState(() => _isAdvancing = true);
    try {
      await widget.steps[_stepIndex].onExit?.call();
      if (mounted) Navigator.of(context, rootNavigator: true).pop(true);
    } finally {
      if (mounted) setState(() => _isAdvancing = false);
    }
  }

  Future<void> _handleTargetTap(TapUpDetails details) async {
    final targetRect = _targetRect;
    final action = widget.steps[_stepIndex].onTargetTap;
    if (_isAdvancing ||
        action == null ||
        targetRect == null ||
        !targetRect.contains(details.localPosition)) {
      return;
    }

    var shouldAdvance = false;
    setState(() => _isAdvancing = true);
    try {
      shouldAdvance = await action() == true;
    } finally {
      if (mounted) setState(() => _isAdvancing = false);
    }
    if (mounted && shouldAdvance) {
      await _advance(skipBeforeAdvance: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_stepIndex];
    final isLast = _stepIndex == widget.steps.length - 1;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final safePadding = MediaQuery.paddingOf(context);
        final safeTop = safePadding.top + 12;
        final safeBottom = safePadding.bottom + 12;
        final availableHeight = (height - safeTop - safeBottom)
            .clamp(0.0, height)
            .toDouble();
        final cardMaxHeight = math.min(250.0, availableHeight);
        final maxTop = math.max(safeTop, height - safeBottom - cardMaxHeight);
        final target = _targetRect;
        final suggestedAbove =
            (target?.top ?? height * 0.66) - cardMaxHeight - 12;
        final suggestedBelow = (target?.bottom ?? 0) + 12;
        final targetIsNearTop = target != null && target.top < height * 0.38;
        final cardTop =
            (targetIsNearTop && suggestedBelow <= maxTop
                    ? suggestedBelow
                    : suggestedAbove)
                .clamp(safeTop, maxTop)
                .toDouble();

        return SizedBox.expand(
          key: _overlayKey,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _handleTargetTap,
                  child: TweenAnimationBuilder<Rect?>(
                    tween: _targetTween,
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeInOutCubic,
                    builder: (context, targetRect, child) => CustomPaint(
                      painter: _TutorialSpotlightPainter(
                        targetRect: targetRect,
                        accentColor: widget.accentColor,
                      ),
                      size: Size(width, height),
                    ),
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeInOutCubic,
                left: math.max(12.0, safePadding.left + 12),
                right: math.max(12.0, safePadding.right + 12),
                top: cardTop,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.025),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: Material(
                    key: ValueKey(_stepIndex),
                    color: Colors.transparent,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: Colors.black.withValues(alpha: 0.06),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.22),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: cardMaxHeight),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: widget.accentColor.withValues(
                                        alpha: 0.10,
                                      ),
                                      borderRadius: BorderRadius.circular(13),
                                    ),
                                    child: Icon(
                                      step.icon,
                                      color: widget.accentColor,
                                      size: 21,
                                    ),
                                  ),
                                  const SizedBox(width: 11),
                                  const Expanded(
                                    child: Text(
                                      'QUICK TOUR',
                                      style: TextStyle(
                                        color: Color(0xFF71717A),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 1.1,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${_stepIndex + 1} of ${widget.steps.length}',
                                    style: const TextStyle(
                                      color: Color(0xFF71717A),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 15),
                              Text(
                                step.title,
                                style: const TextStyle(
                                  color: Color(0xFF18181B),
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                step.description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF52525B),
                                  fontSize: 14,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  TextButton(
                                    onPressed: _skip,
                                    child: const Text('Skip tour'),
                                  ),
                                  FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: widget.accentColor,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 17,
                                        vertical: 12,
                                      ),
                                    ),
                                    onPressed: _isAdvancing ? null : _advance,
                                    icon: Icon(
                                      isLast
                                          ? Icons.check_rounded
                                          : Icons.arrow_forward_rounded,
                                      size: 18,
                                    ),
                                    label: Text(isLast ? 'Finish' : 'Next'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TutorialSpotlightPainter extends CustomPainter {
  final Rect? targetRect;
  final Color accentColor;

  const _TutorialSpotlightPainter({
    required this.targetRect,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final target = targetRect?.intersect(bounds);
    if (target == null || target.isEmpty) {
      canvas.drawRect(
        bounds,
        Paint()..color = Colors.black.withValues(alpha: 0.52),
      );
      return;
    }

    final roundedTarget = RRect.fromRectAndRadius(
      target,
      const Radius.circular(18),
    );
    final outsidePath = Path.combine(
      PathOperation.difference,
      Path()..addRect(bounds),
      Path()..addRRect(roundedTarget),
    );
    canvas.drawPath(
      outsidePath,
      Paint()..color = Colors.black.withValues(alpha: 0.52),
    );
    canvas.drawRRect(
      roundedTarget,
      Paint()
        ..color = accentColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant _TutorialSpotlightPainter oldDelegate) =>
      oldDelegate.targetRect != targetRect ||
      oldDelegate.accentColor != accentColor;
}
