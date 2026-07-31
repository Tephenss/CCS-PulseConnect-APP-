import 'package:flutter/material.dart';

import '../main.dart';
import '../services/device_performance_service.dart';
import '../utils/app_restarter.dart';

Future<void> showPerformanceModeSheet(
  BuildContext context, {
  required Color accent,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      return _PerformanceModeSheet(accent: accent);
    },
  );
}

class _PerformanceModeSheet extends StatefulWidget {
  const _PerformanceModeSheet({required this.accent});

  final Color accent;

  @override
  State<_PerformanceModeSheet> createState() => _PerformanceModeSheetState();
}

class _PerformanceModeSheetState extends State<_PerformanceModeSheet> {
  late PerformanceModePreference _selected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _selected = DevicePerformance.instance.preference;
  }

  Future<void> _select(PerformanceModePreference mode) async {
    if (_busy) return;
    if (mode == DevicePerformance.instance.preference) {
      Navigator.of(context).pop();
      return;
    }

    final confirmed = await _confirmRestart(mode);
    if (!confirmed || !mounted) return;

    setState(() {
      _selected = mode;
      _busy = true;
    });

    await DevicePerformance.instance.setPreference(mode);
    if (!mounted) return;

    // Close the sheet first, then remount UI so the new mode applies.
    // Session stays in prefs — PulseConnectApp rehydrates login on remount.
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PulseConnectApp.rotateRootKeys();
      AppRestarter.restart();
    });
  }

  Future<bool> _confirmRestart(PerformanceModePreference mode) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'Restart required',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 18,
              color: Color(0xFF111827),
            ),
          ),
          content: Text(
            'To apply ${mode.title}, the app needs to restart.\n\n'
            'Continue?',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4B5563),
              height: 1.4,
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text(
                'No',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF6B7280),
                ),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: widget.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
              ),
              child: const Text(
                'Yes',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final perf = DevicePerformance.instance;
    final suggested = perf.suggestedTier;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFE5E7EB),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: widget.accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.speed_rounded,
                  color: widget.accent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Performance Mode',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111827),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Pick how heavy the visuals should be',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              perf.ramMb != null
                  ? 'This device · ~${(perf.ramMb! / 1024).toStringAsFixed(1)} GB RAM · ${perf.cores} cores\n'
                      'Suggested for this phone: ${suggested.label}'
                  : 'Suggested for this phone: ${suggested.label}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF9CA3AF),
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: 4),
          _modeTile(
            mode: PerformanceModePreference.batterySaver,
            recommended: suggested == PerformanceTier.low,
          ),
          _modeTile(
            mode: PerformanceModePreference.balanced,
            recommended: suggested == PerformanceTier.medium,
          ),
          _modeTile(
            mode: PerformanceModePreference.highQuality,
            recommended: suggested == PerformanceTier.high,
          ),
        ],
      ),
    );
  }

  Widget _modeTile({
    required PerformanceModePreference mode,
    required bool recommended,
  }) {
    final selected = _selected == mode;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? widget.accent.withValues(alpha: 0.08)
            : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: _busy ? null : () => _select(mode),
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected
                    ? widget.accent.withValues(alpha: 0.45)
                    : const Color(0xFFE5E7EB),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    color: selected ? widget.accent : const Color(0xFFD1D5DB),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              mode.title,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: selected
                                    ? widget.accent
                                    : const Color(0xFF111827),
                              ),
                            ),
                          ),
                          if (recommended) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: widget.accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                'For this device',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: widget.accent,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        mode.shortDescription,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF6B7280),
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
