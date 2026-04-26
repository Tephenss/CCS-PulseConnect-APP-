import 'dart:io';

import 'package:flutter/material.dart';

class SafeCircleAvatar extends StatelessWidget {
  const SafeCircleAvatar({
    super.key,
    required this.size,
    required this.imagePathOrUrl,
    required this.fallbackText,
    required this.backgroundColor,
    required this.textColor,
    this.borderColor,
    this.borderWidth = 0,
    this.textStyle,
    this.fit = BoxFit.cover,
  });

  final double size;
  final String? imagePathOrUrl;
  final String fallbackText;
  final Color backgroundColor;
  final Color textColor;
  final Color? borderColor;
  final double borderWidth;
  final TextStyle? textStyle;
  final BoxFit fit;

  bool _isRemoteUrl(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.startsWith('http://') || normalized.startsWith('https://');
  }

  Widget _buildFallback() {
    return Container(
      width: size,
      height: size,
      color: backgroundColor,
      alignment: Alignment.center,
      child: Text(
        fallbackText.trim().isEmpty ? '?' : fallbackText.trim(),
        style:
            textStyle ??
            TextStyle(
              color: textColor,
              fontSize: size * 0.36,
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }

  Widget _buildImage() {
    final value = (imagePathOrUrl ?? '').trim();
    if (value.isEmpty) return _buildFallback();

    if (_isRemoteUrl(value)) {
      return Image.network(
        value,
        width: size,
        height: size,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => _buildFallback(),
      );
    }

    final file = File(value);
    if (!file.existsSync()) {
      return _buildFallback();
    }

    return Image.file(
      file,
      width: size,
      height: size,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => _buildFallback(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final child = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: _buildImage(),
      ),
    );

    if (borderColor == null || borderWidth <= 0) {
      return child;
    }

    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(borderWidth),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: borderColor!, width: borderWidth),
      ),
      child: child,
    );
  }
}
