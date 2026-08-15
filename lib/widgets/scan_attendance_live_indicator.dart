import 'package:flutter/material.dart';

/// Online-only live attendance chip for teacher / assist scanners.
class ScanAttendanceLiveIndicator extends StatelessWidget {
  const ScanAttendanceLiveIndicator({
    super.key,
    required this.percent,
    required this.accent,
    this.present,
    this.total,
    this.label = 'Attendance',
  });

  final double percent;
  final Color accent;
  final int? present;
  final int? total;
  final String label;

  @override
  Widget build(BuildContext context) {
    final countLabel = (present != null && total != null && total! >= 0)
        ? '$present / $total'
        : null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Color(0xFF22C55E),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${percent.toStringAsFixed(1)}% $label',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: accent,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (countLabel != null)
            Text(
              countLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: accent.withValues(alpha: 0.78),
              ),
            ),
        ],
      ),
    );
  }
}
