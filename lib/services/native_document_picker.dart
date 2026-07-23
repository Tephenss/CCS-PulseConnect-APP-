import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativePickedDocument {
  const NativePickedDocument({
    required this.path,
    required this.name,
    required this.bytes,
  });

  final String path;
  final String name;
  final Uint8List bytes;
}

/// Uses Android SAF (ACTION_OPEN_DOCUMENT) via a MethodChannel so Oppo/ColorOS
/// file picks do not go through the heavier file_picker plugin path.
class NativeDocumentPicker {
  NativeDocumentPicker._();

  static const MethodChannel _channel = MethodChannel(
    'pulseconnect/document_picker',
  );

  static Future<NativePickedDocument?> pickAndroid({
    int maxBytes = 15 * 1024 * 1024,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return null;

    final raw = await _channel.invokeMethod<dynamic>('pickDocument', {
      'maxBytes': maxBytes,
    });
    if (raw == null) return null;
    if (raw is! Map) {
      throw StateError('Unexpected document picker response.');
    }

    final map = Map<String, dynamic>.from(raw);
    final path = (map['path']?.toString() ?? '').trim();
    final name = (map['name']?.toString() ?? '').trim();
    if (path.isEmpty) return null;

    final file = File(path);
    if (!await file.exists()) {
      throw StateError('Picked file was not saved to cache.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw StateError('Picked file is empty.');
    }
    if (bytes.length > maxBytes) {
      throw StateError('File is too large. Max 15 MB.');
    }

    return NativePickedDocument(
      path: path,
      name: name.isNotEmpty ? name : path.split(Platform.pathSeparator).last,
      bytes: bytes,
    );
  }
}
