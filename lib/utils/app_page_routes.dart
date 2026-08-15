import 'package:flutter/material.dart';

import '../services/device_performance_service.dart';

/// Custom PageTransitionsBuilder for global ThemeData matching modern shared-axis physics.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final perf = DevicePerformance.instance;
    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    // Low-end devices: fast fade transition without heavy scale math.
    if (perf.tier == PerformanceTier.low) {
      return FadeTransition(
        opacity: curvedAnimation,
        child: child,
      );
    }

    // Entering page: smooth fade in + gentle scale up from 0.96 to 1.0
    final primaryScale = Tween<double>(begin: 0.96, end: 1.0).animate(curvedAnimation);
    final primaryFade = Tween<double>(begin: 0.0, end: 1.0).animate(curvedAnimation);

    // Exiting page: subtle scale down from 1.0 to 0.98
    final secondaryCurved = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final secondaryScale = Tween<double>(begin: 1.0, end: 0.98).animate(secondaryCurved);
    final secondaryFade = Tween<double>(begin: 1.0, end: 0.88).animate(secondaryCurved);

    return FadeTransition(
      opacity: primaryFade,
      child: ScaleTransition(
        scale: primaryScale,
        child: FadeTransition(
          opacity: secondaryFade,
          child: ScaleTransition(
            scale: secondaryScale,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Lightweight push/pop for heavy screens (event details, etc.).
/// Durations / effects auto-scale from [DevicePerformance].
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({
    required WidgetBuilder builder,
    super.settings,
  }) : super(
          opaque: true,
          barrierColor: const Color(0xFF09090B),
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionDuration: DevicePerformance.instance.pageForwardDuration,
          reverseTransitionDuration:
              DevicePerformance.instance.pageReverseDuration,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final perf = DevicePerformance.instance;
            final curvedAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );

            if (perf.tier == PerformanceTier.low) {
              return FadeTransition(
                opacity: curvedAnimation,
                child: child,
              );
            }

            final primaryScale = Tween<double>(begin: 0.96, end: 1.0).animate(curvedAnimation);
            final primaryFade = Tween<double>(begin: 0.0, end: 1.0).animate(curvedAnimation);

            final secondaryCurved = CurvedAnimation(
              parent: secondaryAnimation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            final secondaryScale = Tween<double>(begin: 1.0, end: 0.98).animate(secondaryCurved);
            final secondaryFade = Tween<double>(begin: 1.0, end: 0.88).animate(secondaryCurved);

            return FadeTransition(
              opacity: primaryFade,
              child: ScaleTransition(
                scale: primaryScale,
                child: FadeTransition(
                  opacity: secondaryFade,
                  child: ScaleTransition(
                    scale: secondaryScale,
                    child: child,
                  ),
                ),
              ),
            );
          },
        );
}
