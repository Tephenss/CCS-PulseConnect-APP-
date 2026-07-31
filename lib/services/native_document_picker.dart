import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativePickedDocument {
  const NativePickedDocument({
    required this.path,
    required this.name,
    required this.size,
  });

  final String path;
  final String name;
  final int size;

  File get file => File(path);
}

/// Uses Android SAF (ACTION_OPEN_DOCUMENT) via a MethodChannel so Oppo/ColorOS
/// file picks do not go through the heavier file_picker plugin path.
///
/// Results are also persisted natively so a low-RAM process kill while the
/// system picker is open can still recover the selected file on resume.
class NativeDocumentPicker {
  NativeDocumentPicker._();

  static const MethodChannel _channel = MethodChannel(
    'pulseconnect/document_picker',
  );

  static Future<NativePickedDocument?> pickAndroid({
    int maxBytes = 15 * 1024 * 1024,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return null;

    try {
      final raw = await _channel.invokeMethod<dynamic>('pickDocument', {
        'maxBytes': maxBytes,
      });
      final fromLive = _parse(raw);
      if (fromLive != null) return fromLive;
    } on PlatformException catch (error) {
      if (error.code == 'busy') rethrow;
      // Engine may have been recreated mid-pick — fall through to pending.
    } catch (_) {
      // Fall through to pending recovery.
    }

    return takePendingDocument();
  }

  /// Call on app resume after a system file picker — recovers picks that
  /// completed while Flutter was killed / restarted.
  static Future<NativePickedDocument?> takePendingDocument() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<dynamic>('takePendingDocument');
      return _parse(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearPendingDocument() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<dynamic>('clearPendingDocument');
    } catch (_) {}
  }

  static NativePickedDocument? _parse(dynamic raw) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw StateError('Unexpected document picker response.');
    }

    final map = Map<String, dynamic>.from(raw);
    final path = (map['path']?.toString() ?? '').trim();
    final name = (map['name']?.toString() ?? '').trim();
    if (path.isEmpty) return null;

    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('Picked file was not saved to cache.');
    }
    final size = int.tryParse(map['size']?.toString() ?? '') ??
        file.lengthSync();
    if (size <= 0) {
      throw StateError('Picked file is empty.');
    }

    return NativePickedDocument(
      path: path,
      name: name.isNotEmpty ? name : path.split(Platform.pathSeparator).last,
      size: size,
    );
  }
}
