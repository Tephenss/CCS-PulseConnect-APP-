import 'package:flutter/material.dart';

/// Remounts the whole app tree so Performance Mode (and other boot-time UI)
/// applies without requiring a full process kill.
class AppRestarter extends StatefulWidget {
  const AppRestarter({super.key, required this.child});

  final Widget child;

  static final GlobalKey<_AppRestarterState> _gateKey =
      GlobalKey<_AppRestarterState>();

  static Widget wrap(Widget child) => AppRestarter(key: _gateKey, child: child);

  static void restart() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    _gateKey.currentState?._restart();
  }

  @override
  State<AppRestarter> createState() => _AppRestarterState();
}

class _AppRestarterState extends State<AppRestarter> {
  Key _appKey = UniqueKey();

  void _restart() {
    if (!mounted) return;
    setState(() => _appKey = UniqueKey());
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _appKey,
      child: widget.child,
    );
  }
}
