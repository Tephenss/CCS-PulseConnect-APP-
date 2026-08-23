import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Modern 6-box OTP input with paste support (full code fills all boxes).
class OtpCodeBoxes extends StatefulWidget {
  const OtpCodeBoxes({
    super.key,
    required this.controller,
    this.length = 6,
    this.enabled = true,
    this.autofocus = true,
    this.focusColor = const Color(0xFF9F1239),
    this.onCompleted,
  });

  final TextEditingController controller;
  final int length;
  final bool enabled;
  final bool autofocus;
  final Color focusColor;
  final ValueChanged<String>? onCompleted;

  @override
  State<OtpCodeBoxes> createState() => _OtpCodeBoxesState();
}

class _OtpCodeBoxesState extends State<OtpCodeBoxes> {
  late final List<TextEditingController> _boxControllers;
  late final List<FocusNode> _focusNodes;
  bool _syncingFromParent = false;
  bool _syncingToParent = false;

  @override
  void initState() {
    super.initState();
    _boxControllers = List.generate(widget.length, (_) => TextEditingController());
    _focusNodes = List.generate(widget.length, (i) {
      final node = FocusNode(debugLabel: 'otp-$i');
      node.onKeyEvent = (focus, event) => _onKey(i, event);
      node.addListener(() {
        if (mounted) setState(() {});
      });
      return node;
    });
    widget.controller.addListener(_onParentChanged);
    _applyCodeToBoxes(widget.controller.text, notifyParent: false);
  }

  @override
  void didUpdateWidget(covariant OtpCodeBoxes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onParentChanged);
      widget.controller.addListener(_onParentChanged);
      _applyCodeToBoxes(widget.controller.text, notifyParent: false);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onParentChanged);
    for (final c in _boxControllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  String _digitsOnly(String value) => value.replaceAll(RegExp(r'\D'), '');

  String _readBoxes() {
    return _boxControllers.map((c) {
      final d = _digitsOnly(c.text);
      return d.isEmpty ? '' : d[0];
    }).join();
  }

  void _onParentChanged() {
    if (_syncingToParent) return;
    final next = _digitsOnly(widget.controller.text);
    if (next == _readBoxes()) return;
    _applyCodeToBoxes(next, notifyParent: false);
  }

  void _pushToParent() {
    final code = _readBoxes();
    if (widget.controller.text == code) return;
    _syncingToParent = true;
    widget.controller.value = TextEditingValue(
      text: code,
      selection: TextSelection.collapsed(offset: code.length),
    );
    _syncingToParent = false;
    if (code.length == widget.length) {
      widget.onCompleted?.call(code);
    }
  }

  void _applyCodeToBoxes(String raw, {required bool notifyParent}) {
    final digits = _digitsOnly(raw);
    _syncingFromParent = true;
    for (var i = 0; i < widget.length; i++) {
      final next = i < digits.length ? digits[i] : '';
      if (_boxControllers[i].text != next) {
        _boxControllers[i].value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      }
    }
    _syncingFromParent = false;
    if (notifyParent) _pushToParent();
    if (mounted) setState(() {});
  }

  void _focusIndex(int index) {
    if (!widget.enabled) return;
    final i = index.clamp(0, widget.length - 1);
    _focusNodes[i].requestFocus();
  }

  void _handleChanged(int index, String value) {
    if (_syncingFromParent) return;
    final digits = _digitsOnly(value);

    // Paste / SMS autofill of multiple digits → fill all boxes from the start.
    if (digits.length > 1) {
      _applyCodeToBoxes(digits, notifyParent: true);
      final filled = digits.length.clamp(0, widget.length);
      _focusIndex(filled >= widget.length ? widget.length - 1 : filled);
      return;
    }

    final ch = digits.isEmpty ? '' : digits[0];
    if (_boxControllers[index].text != ch) {
      _boxControllers[index].value = TextEditingValue(
        text: ch,
        selection: TextSelection.collapsed(offset: ch.length),
      );
    }
    _pushToParent();
    if (ch.isNotEmpty && index < widget.length - 1) {
      _focusIndex(index + 1);
    }
    setState(() {});
  }

  KeyEventResult _onKey(int index, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (_boxControllers[index].text.isEmpty && index > 0) {
        _boxControllers[index - 1].clear();
        _pushToParent();
        _focusIndex(index - 1);
        setState(() {});
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft && index > 0) {
      _focusIndex(index - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
        index < widget.length - 1) {
      _focusIndex(index + 1);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(widget.length, (index) {
        final filled = _digitsOnly(_boxControllers[index].text).isNotEmpty;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              left: index == 0 ? 0 : 4,
              right: index == widget.length - 1 ? 0 : 4,
            ),
            child: AspectRatio(
              aspectRatio: 0.92,
              child: TextField(
                controller: _boxControllers[index],
                focusNode: _focusNodes[index],
                enabled: widget.enabled,
                autofocus: widget.autofocus && index == 0,
                keyboardType: TextInputType.number,
                textInputAction: index == widget.length - 1
                    ? TextInputAction.done
                    : TextInputAction.next,
                textAlign: TextAlign.center,
                textAlignVertical: TextAlignVertical.center,
                style: const TextStyle(
                  color: Color(0xFFFAFAFA),
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                  height: 1.1,
                ),
                cursorColor: widget.focusColor,
                // Allow multi-digit paste into a single field; we distribute in onChanged.
                maxLength: widget.length,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: InputDecoration(
                  counterText: '',
                  filled: true,
                  fillColor: filled
                      ? const Color(0xFF111113)
                      : const Color(0xFF09090B),
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFF27272A)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: filled
                          ? const Color(0xFF3F3F46)
                          : const Color(0xFF27272A),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: widget.focusColor,
                      width: 1.6,
                    ),
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFF27272A)),
                  ),
                ),
                onChanged: (value) => _handleChanged(index, value),
                onTap: () {
                  final text = _boxControllers[index].text;
                  _boxControllers[index].selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: text.length,
                  );
                },
              ),
            ),
          ),
        );
      }),
    );
  }
}
