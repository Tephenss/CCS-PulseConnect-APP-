import 'package:flutter/material.dart';

import '../services/device_performance_service.dart';

/// Lightweight push/pop for heavy screens (event details, etc.).
/// Durations / effects auto-scale from [DevicePerformance].
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({
    required WidgetBuilder builder,
    super.settings,
  }) : super(
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionDuration: DevicePerformance.instance.pageForwardDuration,
          reverseTransitionDuration:
              DevicePerformance.instance.pageReverseDuration,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final perf = DevicePerformance.instance;
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );

            // Low-end: fade only (cheaper than slide+fade combo).
            if (perf.tier == PerformanceTier.low) {
              return FadeTransition(opacity: curved, child: child);
            }

            return SlideTransition(
              position: Tween<Offset>(
                begin: Offset(perf.tier == PerformanceTier.high ? 0.06 : 0.04, 0),
                end: Offset.zero,
              ).animate(curved),
              child: FadeTransition(
                opacity: curved,
                child: child,
              ),
            );
          },
        );
}
