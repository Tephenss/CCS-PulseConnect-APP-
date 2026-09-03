import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// App Clip-style circular plate that still encodes a real QR payload.
class PulseQrCode extends StatelessWidget {
  const PulseQrCode({
    super.key,
    required this.data,
    this.size = 200,
    this.showLogo = true,
    this.semanticsLabel = 'QR code',
  });

  final String data;
  final double size;
  final bool showLogo;
  final String semanticsLabel;

  static const Color plateColor = Color(0xFF1C1C1E);
  static const String logoAsset = 'assets/CCS.png';

  static QrImage? _qrImageFor(String payload) {
    try {
      final qr = QrCode.fromData(
        data: payload,
        errorCorrectLevel: QrErrorCorrectLevel.H,
      );
      return QrImage(qr);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final useLogo = showLogo && size >= 110;
    final qrImage = _qrImageFor(data);
    final logoBox = size * (useLogo ? 0.28 : 0.0);

    return Semantics(
      label: semanticsLabel,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: Size.square(size),
              painter: _ScannableClipPainter(
                qrImage: qrImage,
                payload: data,
                showLogoDisc: useLogo,
              ),
            ),
            if (useLogo && logoBox > 0)
              SizedBox(
                width: logoBox,
                height: logoBox,
                child: ClipOval(
                  child: Image.asset(
                    logoAsset,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ScannableClipPainter extends CustomPainter {
  _ScannableClipPainter({
    required this.qrImage,
    required this.payload,
    required this.showLogoDisc,
  });

  final QrImage? qrImage;
  final String payload;
  final bool showLogoDisc;

  static const _plate = Color(0xFF1C1C1E);
  static const _white = Color(0xFFFFFFFF);
  static const _gray = Color(0xFF8E8E93);

  bool _inFinder(int r, int c, int n) {
    return (r <= 7 && c <= 7) ||
        (r <= 7 && c >= n - 8) ||
        (r >= n - 8 && c <= 7);
  }

  int _hashBit(int i) {
    var h = 2166136261;
    for (final unit in payload.codeUnits) {
      h ^= unit;
      h = (h * 16777619) & 0xFFFFFFFF;
    }
    var x = (h + i * 9973) & 0xFFFFFFFF;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    return (x & 1);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final R = size.shortestSide / 2;
    final center = Offset(cx, cy);
    final qr = qrImage;
    final n = qr?.moduleCount ?? 0;

    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: R)));
    canvas.drawCircle(center, R, Paint()..color = _plate);

    final logoR = R * (showLogoDisc ? 0.30 : 0.16);
    final pad = size.shortestSide * 0.16;
    final qrSize = size.shortestSide - pad * 2;
    final cell = n > 0 ? qrSize / n : 0.0;
    final origin = pad;

    bool qrDark(int r, int c) {
      if (qr == null || r < 0 || c < 0 || r >= n || c >= n) return false;
      return qr.isDark(r, c);
    }

    bool inLogo(double x, double y) {
      return math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) <
          logoR + cell * 0.35;
    }

    if (qr != null && cell > 0) {
      final dotPaint = Paint()..color = _white;
      for (var r = 0; r < n; r++) {
        for (var c = 0; c < n; c++) {
          if (!qrDark(r, c) || _inFinder(r, c, n)) continue;
          final x = origin + c * cell + cell / 2;
          final y = origin + r * cell + cell / 2;
          if (inLogo(x, y)) continue;
          canvas.drawCircle(Offset(x, y), cell * 0.32, dotPaint);
        }
      }

      void drawRoundedRect(Rect rect, double radius, Color color) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(radius)),
          Paint()..color = color,
        );
      }

      void drawFinder(int row, int col) {
        final x = origin + col * cell;
        final y = origin + row * cell;
        final s = cell * 7;
        drawRoundedRect(Rect.fromLTWH(x, y, s, s), cell * 1.15, _white);
        drawRoundedRect(
          Rect.fromLTWH(x + cell, y + cell, cell * 5, cell * 5),
          cell * 0.85,
          _plate,
        );
        drawRoundedRect(
          Rect.fromLTWH(x + cell * 2, y + cell * 2, cell * 3, cell * 3),
          cell * 0.65,
          _white,
        );
      }

      drawFinder(0, 0);
      drawFinder(0, n - 7);
      drawFinder(n - 7, 0);
    }

    final innerR = logoR + R * 0.05;
    final outerR = R * 0.97;
    const rings = 7;
    final pitch = (outerR - innerR) / rings;
    final stroke = pitch * 0.38;

    for (var i = 0; i < rings; i++) {
      final r = innerR + pitch * (i + 0.5);
      const slots = 64;
      final slot = (2 * math.pi) / slots;
      var s = 0;
      while (s < slots) {
        var run = 0;
        var decorate = false;
        while (s + run < slots) {
          final ang = (s + run + 0.5) * slot;
          final px = cx + r * math.cos(ang);
          final py = cy + r * math.sin(ang);
          final inQr = px >= origin &&
              py >= origin &&
              px < origin + qrSize &&
              py < origin + qrSize;
          var on = false;
          if (inQr && n > 0) {
            final c = ((px - origin) / cell).floor();
            final row = ((py - origin) / cell).floor();
            if (!_inFinder(row, c, n) && qrDark(row, c) && !inLogo(px, py)) {
              on = true;
            }
          } else if (!inQr) {
            on = _hashBit(i * 64 + s + run) == 1;
            decorate = true;
          }
          if (!on) break;
          run++;
        }
        if (run > 0) {
          final start = s * slot + slot * 0.12;
          final sweep = run * slot - slot * 0.24;
          if (sweep > 0.01) {
            canvas.drawArc(
              Rect.fromCircle(center: center, radius: r),
              start,
              sweep,
              false,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeCap = StrokeCap.round
                ..strokeWidth = stroke
                ..color = decorate && run == 1 ? _gray : _white,
            );
          }
          s += run;
        } else {
          s++;
        }
      }
    }

    if (showLogoDisc) {
      canvas.drawCircle(center, logoR, Paint()..color = _white);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScannableClipPainter oldDelegate) {
    return oldDelegate.payload != payload ||
        oldDelegate.showLogoDisc != showLogoDisc;
  }
}
