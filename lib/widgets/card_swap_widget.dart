import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────
//  DATA MODEL
// ─────────────────────────────────────────────────────────────
class CardSwapItem {
  final String imagePath;
  final String label;
  const CardSwapItem({required this.imagePath, required this.label});
}

// ─────────────────────────────────────────────────────────────
//  PER-CARD ANIMATED STATE
// ─────────────────────────────────────────────────────────────
class _CardPose {
  final double x;   // local X offset (px)  - i * distX
  final double y;   // local Y offset (px)  - -i * distY
  final double z;   // local Z depth (px)   - -i * distX * 1.5
  final double skewY; // degrees
  final int zIndex;
  final double opacity;

  const _CardPose({
    required this.x,
    required this.y,
    required this.z,
    required this.skewY,
    required this.zIndex,
    this.opacity = 1.0,
  });

  _CardPose copyWith({
    double? x, double? y, double? z, double? skewY,
    int? zIndex, double? opacity,
  }) => _CardPose(
    x: x ?? this.x,
    y: y ?? this.y,
    z: z ?? this.z,
    skewY: skewY ?? this.skewY,
    zIndex: zIndex ?? this.zIndex,
    opacity: opacity ?? this.opacity,
  );
}

// ─────────────────────────────────────────────────────────────
//  WIDGET
// ─────────────────────────────────────────────────────────────
class CardSwapWidget extends StatefulWidget {
  final List<CardSwapItem> items;
  final double cardWidth;
  final double cardHeight;
  /// Horizontal pixel distance between card slots (cardDistance in the JS)
  final double cardDistance;
  /// Vertical pixel distance between card slots (verticalDistance in the JS)
  final double verticalDistance;
  final Duration delay;
  /// skewY in degrees applied to EVERY card (6 deg in the reference)
  final double skewAmount;

  const CardSwapWidget({
    super.key,
    required this.items,
    this.cardWidth  = 260,
    this.cardHeight = 160,
    this.cardDistance     = 40,
    this.verticalDistance = 30,
    this.delay      = const Duration(seconds: 4),
    this.skewAmount = 6,
  });

  @override
  State<CardSwapWidget> createState() => _CardSwapWidgetState();
}

// ─────────────────────────────────────────────────────────────
//  STATE
// ─────────────────────────────────────────────────────────────
class _CardSwapWidgetState extends State<CardSwapWidget>
    with TickerProviderStateMixin {

  // Current logical order: order[0] = index of the FRONT card
  late List<int> _order;

  // Per-card animation controllers (one per card item, not slot)
  late List<AnimationController> _ctls;
  late List<Animation<double>> _xAnims;
  late List<Animation<double>> _yAnims;
  late List<Animation<double>> _zAnims;
  late List<Animation<double>> _skewAnims;
  late List<Animation<double>> _opacityAnims;

  // Current "target" pose per card (used as the FROM when we start the next anim)
  late List<_CardPose> _poses;

  bool _swapping = false;
  bool _introFinished = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final n = widget.items.length;

    _order = List.generate(n, (i) => i);

    _ctls        = List.generate(n, (_) => AnimationController(vsync: this, duration: const Duration(milliseconds: 750)));
    _xAnims      = List.generate(n, (i) => _ctls[i].drive(Tween(begin: 0.0, end: 0.0)));
    _yAnims      = List.generate(n, (i) => _ctls[i].drive(Tween(begin: 0.0, end: 0.0)));
    _zAnims      = List.generate(n, (i) => _ctls[i].drive(Tween(begin: 0.0, end: 0.0)));
    _skewAnims   = List.generate(n, (i) => _ctls[i].drive(Tween(begin: widget.skewAmount, end: widget.skewAmount)));
    _opacityAnims= List.generate(n, (i) => _ctls[i].drive(Tween(begin: 1.0, end: 1.0)));

    _poses = List.generate(n, (i) => _slotPose(i, n));

    // Initialize all cards at a "starting" position (hidden at bottom)
    for (int i = 0; i < n; i++) {
      final slotIdx = _order.indexOf(i);
      final finalPose = _slotPose(slotIdx, n);
      _commitPose(i, finalPose.copyWith(y: finalPose.y - 150, opacity: 0.0));
    }

    _runIntro();
  }

  Future<void> _runIntro() async {
    final n = widget.items.length;
    // Staggered entrance from back to front or front to back? 
    // Reference usually enters front to back (0, 1, 2)
    for (int i = 0; i < n; i++) {
      if (!mounted) return;
      final cardIdx = _order[i];
      _animateTo(cardIdx, _slotPose(i, n), 
        duration: const Duration(milliseconds: 1200),
        curve: const _ElasticOutEntrance(),
      );
      await Future.delayed(const Duration(milliseconds: 80));
    }

    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) {
      _introFinished = true;
      _scheduleNext();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in _ctls) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Build slot pose for card at depth `slot` (slot 0 = front) ──
  _CardPose _slotPose(int slot, int total) {
    return _CardPose(
      x:      slot * widget.cardDistance,
      y:      -slot * widget.verticalDistance,
      z:      -slot * widget.cardDistance * 1.5,
      skewY:  widget.skewAmount,          // ALL cards skewY
      zIndex: total - slot,
      opacity: 1.0,
    );
  }

  // ── Commit static pose (no animation, just set begin=end) ──
  void _commitPose(int cardIdx, _CardPose pose) {
    _xAnims[cardIdx]       = _ctls[cardIdx].drive(Tween(begin: pose.x, end: pose.x));
    _yAnims[cardIdx]       = _ctls[cardIdx].drive(Tween(begin: pose.y, end: pose.y));
    _zAnims[cardIdx]       = _ctls[cardIdx].drive(Tween(begin: pose.z, end: pose.z));
    _skewAnims[cardIdx]    = _ctls[cardIdx].drive(Tween(begin: pose.skewY, end: pose.skewY));
    _opacityAnims[cardIdx] = _ctls[cardIdx].drive(Tween(begin: pose.opacity, end: pose.opacity));
    _poses[cardIdx] = pose;
  }

  // ── Animate cardIdx FROM its current pose TO target pose ──
  void _animateTo(int cardIdx, _CardPose target, {
    Duration duration = const Duration(milliseconds: 750),
    Curve curve = const _ElasticOut(),
    Curve opacityCurve = Curves.easeOut,
  }) {
    final from = _poses[cardIdx];
    _ctls[cardIdx].duration = duration;
    _ctls[cardIdx].reset();

    _xAnims[cardIdx]       = _ctls[cardIdx].drive(CurveTween(curve: curve)).drive(Tween(begin: from.x, end: target.x));
    _yAnims[cardIdx]       = _ctls[cardIdx].drive(CurveTween(curve: curve)).drive(Tween(begin: from.y, end: target.y));
    _zAnims[cardIdx]       = _ctls[cardIdx].drive(CurveTween(curve: curve)).drive(Tween(begin: from.z, end: target.z));
    _skewAnims[cardIdx]    = _ctls[cardIdx].drive(CurveTween(curve: curve)).drive(Tween(begin: from.skewY, end: target.skewY));
    _opacityAnims[cardIdx] = _ctls[cardIdx].drive(CurveTween(curve: opacityCurve)).drive(Tween(begin: from.opacity, end: target.opacity));

    _poses[cardIdx] = target;
    _ctls[cardIdx].forward();
  }

  void _scheduleNext() {
    if (!_introFinished) return;
    _timer?.cancel();
    _timer = Timer(widget.delay, _swap);
  }

  // ─────────────────────────────────────────────────────────────
  //  SWAP — mirrors the GSAP timeline exactly:
  //   1. Front card drops off-screen fast (durDrop=0.8s, ease=power1)
  //   2. ~45% into drop, others promote one slot (elastic)
  //   3. After promote, dropped card jumps to back slot with elastic
  // ─────────────────────────────────────────────────────────────
  Future<void> _swap() async {
    if (_swapping || !mounted || !_introFinished) return;
    _swapping = true;

    final total   = _order.length;
    final front   = _order[0];
    final rest    = _order.sublist(1);

    // 1. Drop front card off-screen (fast, no elastic)
    _animateTo(front,
      _poses[front].copyWith(y: _poses[front].y + 500, opacity: 0.0),
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeIn,
      opacityCurve: Curves.easeIn,
    );

    // 2. ~45% into drop, start promoting rest
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;

    setState(() {}); // trigger zIndex re-sort

    for (int i = 0; i < rest.length; i++) {
      final cardIdx = rest[i];
      _animateTo(cardIdx, _slotPose(i, total),
        duration: const Duration(milliseconds: 1400),
        curve: const _ElasticOut(),
      );
    }

    // 3. After promote gets going, return dropped card to back
    await Future.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;

    final backPose = _slotPose(total - 1, total);
    // Snap to: far right + top + back but invisible first
    _commitPose(front, backPose.copyWith(y: backPose.y + 400, opacity: 0.0));
    // Then animate it in
    _animateTo(front, backPose,
      duration: const Duration(milliseconds: 1400),
      curve: const _ElasticOut(),
      opacityCurve: Curves.easeOut,
    );

    // 4. Update logical order
    _order = [...rest, front];
    _swapping = false;
    _scheduleNext();
  }

  // ─────────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final n = widget.items.length;

    // Container must fit the fully expanded stack
    final totalW = widget.cardWidth  + widget.cardDistance    * (n - 1) + 40;
    final totalH = widget.cardHeight + widget.verticalDistance * (n - 1) + 20;

    // Draw in z-order (back cards first so front card renders on top)
    final drawOrder = List.generate(n, (i) => i)
      ..sort((a, b) => _poses[a].zIndex.compareTo(_poses[b].zIndex));

    return SizedBox(
      width: totalW,
      height: totalH,
      child: AnimatedBuilder(
        animation: Listenable.merge(_ctls),
        builder: (context, _) {
          return Stack(
            clipBehavior: Clip.none,
            children: drawOrder.map((cardIdx) {
              final item     = widget.items[cardIdx];
              final xVal     = _xAnims[cardIdx].value;
              final yVal     = _yAnims[cardIdx].value;
              final zVal     = _zAnims[cardIdx].value;
              final skewVal  = _skewAnims[cardIdx].value;
              final opVal    = _opacityAnims[cardIdx].value;
              final isFront  = _order[0] == cardIdx;

              return Positioned(
                // anchor point: top-left of container is slot 0 position
                left: xVal,
                top:  totalH - widget.cardHeight - widget.verticalDistance * (widget.items.length - 1) - yVal,
                child: Transform(
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 1 / 900.0)    // perspective: 900px
                    ..translateByDouble(0.0, 0.0, zVal, 1.0)
                    ..multiply(_skewYMatrix(skewVal)),
                  alignment: Alignment.center,
                  child: Opacity(
                    opacity: opVal.clamp(0.0, 1.0),
                    child: _buildCard(item, isFront),
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  Widget _buildCard(CardSwapItem item, bool isFront) {
    return Container(
      width:  widget.cardWidth,
      height: widget.cardHeight,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isFront ? 0.5 : 0.3),
            blurRadius: isFront ? 24 : 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background image
          Image.asset(
            item.imagePath,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFea580c), Color(0xFF7c2d12)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          ),
          // Overlay  (darker on back cards)
          Container(
            color: Colors.black.withValues(alpha: isFront ? 0.3 : 0.5),
          ),
          // Label gradient backdrop + text — visible on ALL cards
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 20, 10, 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.transparent, Colors.black.withValues(alpha: 0.85)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: Text(
                item.label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: isFront ? 1.0 : 0.75),
                  fontSize: isFront ? 13 : 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                  shadows: const [
                    Shadow(color: Color(0xDD000000), blurRadius: 6, offset: Offset(0, 2)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  HELPERS
// ─────────────────────────────────────────────────────────────

// Build a skewY matrix (in degrees)
Matrix4 _skewYMatrix(double degrees) {
  final rad = degrees * math.pi / 180.0;
  return Matrix4(
    1, math.tan(rad), 0, 0,
    0, 1,             0, 0,
    0, 0,             1, 0,
    0, 0,             0, 1,
  );
}

// Elastic-out curve mirroring GSAP elastic.out(1, 0.5) specifically for entrance
class _ElasticOutEntrance extends Curve {
  const _ElasticOutEntrance();
  @override
  double transformInternal(double t) {
    if (t == 0 || t == 1) return t;
    const period   = 0.5;
    const amplitude = 1.0;
    final s = period / (2 * math.pi) * math.asin(1 / amplitude);
    return amplitude *
        math.pow(2, -10 * t) *
        math.sin((t - s) * (2 * math.pi) / period) +
        1;
  }
}

// Elastic-out curve mirroring GSAP elastic.out(0.6, 0.9)
class _ElasticOut extends Curve {
  const _ElasticOut();
  @override
  double transformInternal(double t) {
    if (t == 0 || t == 1) return t;
    const period   = 0.4;
    const amplitude = 1.0;
    final s = period / (2 * math.pi) * math.asin(1 / amplitude);
    return amplitude *
        math.pow(2, -10 * t) *
        math.sin((t - s) * (2 * math.pi) / period) +
        1;
  }
}
