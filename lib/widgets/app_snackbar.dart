// lib/widgets/app_snackbar.dart

import 'dart:async';
import 'package:flutter/material.dart';

enum SnackBarType { success, error, warning, info }

/// Premium floating notification utility.
/// Uses an OverlayEntry on the ROOT navigator so it always appears
/// above bottom sheets, dialogs, and other modals.
class AppSnackBar {
  // Active overlay entry — only one toast at a time.
  static OverlayEntry? _currentEntry;
  static Timer? _dismissTimer;

  // ─── Primary entry points ───────────────────────────────────────────────────

  static void success(BuildContext context, String message, {String? title}) =>
      _show(context, message,
          type: SnackBarType.success, title: title ?? 'Success');

  static void error(BuildContext context, String message, {String? title}) =>
      _show(context, message,
          type: SnackBarType.error, title: title ?? 'Error');

  static void warning(BuildContext context, String message, {String? title}) =>
      _show(context, message,
          type: SnackBarType.warning, title: title ?? 'Warning');

  static void info(BuildContext context, String message, {String? title}) =>
      _show(context, message,
          type: SnackBarType.info, title: title ?? 'Info');

  static void show(BuildContext context, String message,
      {SnackBarType type = SnackBarType.info, String? title}) {
    _show(context, message, type: type, title: title);
  }

  // ─── Internal ────────────────────────────────────────────────────────────────

  static void _show(
    BuildContext context,
    String message, {
    required SnackBarType type,
    String? title,
  }) {
    // Resolve the root overlay (above modals/sheets).
    OverlayState? overlay;
    try {
      overlay = Navigator.of(context, rootNavigator: true).overlay;
    } catch (_) {
      // If root navigator is not reachable, fall back to local navigator.
      try {
        overlay = Navigator.of(context).overlay;
      } catch (_) {
        return;
      }
    }
    if (overlay == null) return;

    // Dismiss any currently showing toast immediately.
    _dismiss();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _AppSnackBarOverlay(
        message: message,
        type: type,
        title: title,
        onDismiss: () {
          if (_currentEntry == entry) _dismiss();
        },
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);

    // Auto-dismiss after 4 seconds.
    _dismissTimer = Timer(const Duration(seconds: 4), _dismiss);
  }

  static void _dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _currentEntry?.remove();
    _currentEntry = null;
  }
}

// ─── Animated Overlay Widget ──────────────────────────────────────────────────

class _AppSnackBarOverlay extends StatefulWidget {
  final String message;
  final SnackBarType type;
  final String? title;
  final VoidCallback onDismiss;

  const _AppSnackBarOverlay({
    required this.message,
    required this.type,
    this.title,
    required this.onDismiss,
  });

  @override
  State<_AppSnackBarOverlay> createState() => _AppSnackBarOverlayState();
}

class _AppSnackBarOverlayState extends State<_AppSnackBarOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;

    return Positioned(
      left: 16,
      right: 16,
      bottom: bottom + 24,
      child: SafeArea(
        top: false,
        child: SlideTransition(
          position: _slide,
          child: FadeTransition(
            opacity: _fade,
            child: Material(
              color: Colors.transparent,
              child: GestureDetector(
                onTap: widget.onDismiss,
                child: _SnackBarContent(
                  message: widget.message,
                  type: widget.type,
                  title: widget.title,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── UI Card ──────────────────────────────────────────────────────────────────

class _SnackBarContent extends StatelessWidget {
  final String message;
  final SnackBarType type;
  final String? title;

  const _SnackBarContent({
    required this.message,
    required this.type,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    final cfg = _typeConfig(type);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: cfg.bgColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cfg.borderColor, width: 1),
        boxShadow: [
          BoxShadow(
            color: cfg.shadowColor.withValues(alpha: 0.30),
            blurRadius: 28,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.20),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Icon pill
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: cfg.iconBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(cfg.icon, color: cfg.iconColor, size: 20),
          ),
          const SizedBox(width: 14),

          // Text block
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null && title!.isNotEmpty)
                  Text(
                    title!,
                    style: TextStyle(
                      color: cfg.titleColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                if (title != null && title!.isNotEmpty)
                  const SizedBox(height: 2),
                Text(
                  message,
                  style: TextStyle(
                    color: cfg.messageColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Accent bar on the right
          Container(
            width: 4,
            height: 36,
            decoration: BoxDecoration(
              color: cfg.accentColor,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }

  _TypeConfig _typeConfig(SnackBarType type) {
    switch (type) {
      case SnackBarType.success:
        return _TypeConfig(
          bgColor: const Color(0xFF0F2318),
          borderColor: const Color(0xFF16A34A).withValues(alpha: 0.5),
          shadowColor: const Color(0xFF16A34A),
          icon: Icons.check_circle_rounded,
          iconBg: const Color(0xFF16A34A).withValues(alpha: 0.2),
          iconColor: const Color(0xFF4ADE80),
          accentColor: const Color(0xFF22C55E),
          titleColor: const Color(0xFF4ADE80),
          messageColor: const Color(0xFFD1FAE5),
        );
      case SnackBarType.error:
        return _TypeConfig(
          bgColor: const Color(0xFF1A0A0A),
          borderColor: const Color(0xFFDC2626).withValues(alpha: 0.5),
          shadowColor: const Color(0xFFDC2626),
          icon: Icons.error_rounded,
          iconBg: const Color(0xFFDC2626).withValues(alpha: 0.2),
          iconColor: const Color(0xFFF87171),
          accentColor: const Color(0xFFEF4444),
          titleColor: const Color(0xFFF87171),
          messageColor: const Color(0xFFFECACA),
        );
      case SnackBarType.warning:
        return _TypeConfig(
          bgColor: const Color(0xFF1A1200),
          borderColor: const Color(0xFFD97706).withValues(alpha: 0.5),
          shadowColor: const Color(0xFFD97706),
          icon: Icons.warning_rounded,
          iconBg: const Color(0xFFD97706).withValues(alpha: 0.2),
          iconColor: const Color(0xFFFBBF24),
          accentColor: const Color(0xFFF59E0B),
          titleColor: const Color(0xFFFBBF24),
          messageColor: const Color(0xFFFEF3C7),
        );
      case SnackBarType.info:
        return _TypeConfig(
          bgColor: const Color(0xFF080F1A),
          borderColor: const Color(0xFF2563EB).withValues(alpha: 0.5),
          shadowColor: const Color(0xFF2563EB),
          icon: Icons.info_rounded,
          iconBg: const Color(0xFF2563EB).withValues(alpha: 0.2),
          iconColor: const Color(0xFF60A5FA),
          accentColor: const Color(0xFF3B82F6),
          titleColor: const Color(0xFF60A5FA),
          messageColor: const Color(0xFFDBEAFE),
        );
    }
  }
}

class _TypeConfig {
  final Color bgColor;
  final Color borderColor;
  final Color shadowColor;
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final Color accentColor;
  final Color titleColor;
  final Color messageColor;

  const _TypeConfig({
    required this.bgColor,
    required this.borderColor,
    required this.shadowColor,
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.accentColor,
    required this.titleColor,
    required this.messageColor,
  });
}
