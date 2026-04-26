import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_scan_store.dart';

class OfflineBackupService {
  OfflineBackupService({OfflineScanStore? store})
    : _store = store ?? OfflineScanStore.instance;

  static const MethodChannel _channel = MethodChannel(
    'pulseconnect/offline_backup',
  );
  static const String backupFileName = 'scan_backup_v3.bin';
  static const String _metaBackupExportedAt = 'backup_last_export_at';
  static const String _metaBackupRestoredAt = 'backup_last_restore_at';
  static const Set<String> _criticalPreferenceKeys = <String>{
    'user_id',
    'user_role',
    'user_data',
    'remembered_email',
    'remembered_role',
  };
  static const Duration _autoBackupCooldown = Duration(seconds: 20);

  final OfflineScanStore _store;
  bool _restoreAttempted = false;
  DateTime? _lastBackupAt;
  Future<Map<String, dynamic>>? _backupInFlight;
  Future<bool>? _restoreInFlight;

  Future<Map<String, dynamic>> _exportPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final data = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      final normalizedKey = key.trim();
      if (!_shouldBackupPreference(normalizedKey)) continue;
      final value = prefs.get(key);
      if (value is String ||
          value is bool ||
          value is int ||
          value is double) {
        data[key] = value;
      } else if (value is List<String>) {
        data[key] = List<String>.from(value);
      }
    }
    return data;
  }

  bool _shouldBackupPreference(String key) {
    return _criticalPreferenceKeys.contains(key) ||
        key.startsWith('app_cache_') ||
        key.startsWith('avatar_cache_') ||
        key.startsWith('email_verification_') ||
        key.startsWith('notification_') ||
        key.startsWith('push_') ||
        key.startsWith('scanner_') ||
        key.startsWith('remembered_');
  }

  Future<void> _restorePreferences(Map<String, dynamic> raw) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in raw.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) continue;
      final value = entry.value;
      if (value is String) {
        await prefs.setString(key, value);
      } else if (value is bool) {
        await prefs.setBool(key, value);
      } else if (value is int) {
        await prefs.setInt(key, value);
      } else if (value is double) {
        await prefs.setDouble(key, value);
      } else if (value is List) {
        await prefs.setStringList(
          key,
          value.map((item) => item.toString()).toList(),
        );
      }
    }
  }

  Future<Map<String, dynamic>> _buildBackupPayload() async {
    return {
      'version': 3,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'shared_preferences': await _exportPreferences(),
      'scanner_store': await _store.exportAll(),
    };
  }

  Future<void> _restoreBackupPayload(
    Map<String, dynamic> payload, {
    bool restorePreferences = true,
    bool restoreScannerStore = true,
  }) async {
    final prefsPayload = payload['shared_preferences'] is Map
        ? Map<String, dynamic>.from(payload['shared_preferences'] as Map)
        : <String, dynamic>{};
    final scannerPayload = payload['scanner_store'] is Map
        ? Map<String, dynamic>.from(payload['scanner_store'] as Map)
        : payload;

    if (restorePreferences && prefsPayload.isNotEmpty) {
      await _restorePreferences(prefsPayload);
    }
    if (restoreScannerStore) {
      await _store.importAll(scannerPayload);
    }
  }

  bool _hasMeaningfulAppData(SharedPreferences prefs) {
    final keys = prefs.getKeys();
    for (final key in keys) {
      if (_criticalPreferenceKeys.contains(key)) {
        final value = prefs.get(key);
        if (value is String && value.trim().isNotEmpty) return true;
        if (value is List && value.isNotEmpty) return true;
        if (value is bool && value) return true;
        if (value is num && value != 0) return true;
      }
    }
    return false;
  }

  Future<Map<String, dynamic>> exportNow({bool force = false}) async {
    if (!force &&
        _lastBackupAt != null &&
        DateTime.now().difference(_lastBackupAt!) < _autoBackupCooldown) {
      return {'ok': true, 'skipped': true};
    }
    if (_backupInFlight != null) {
      return _backupInFlight!;
    }

    final future = _exportNowInternal();
    _backupInFlight = future;
    final result = await future;
    _backupInFlight = null;
    return result;
  }

  Future<Map<String, dynamic>> _exportNowInternal() async {
    try {
      final payload = await _buildBackupPayload();
      final bytes = Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(payload))));
      await _channel.invokeMethod('writeBackupFileAuto', {
        'fileName': backupFileName,
        'bytes': bytes,
      });
      _lastBackupAt = DateTime.now();
      await _store.setMeta(
        _metaBackupExportedAt,
        _lastBackupAt!.toUtc().toIso8601String(),
      );
      return {'ok': true};
    } on PlatformException catch (e) {
      return {
        'ok': false,
        'error': e.message?.trim().isNotEmpty == true
            ? e.message
            : 'Automatic backup write failed.',
      };
    } catch (e) {
      return {
        'ok': false,
        'error': 'Automatic backup write failed.',
        'debug': kDebugMode ? e.toString() : '',
      };
    }
  }

  Future<void> autoBackupIfConfigured({bool force = false}) async {
    try {
      await exportNow(force: force);
    } catch (_) {
      // Keep automatic backup silent and best-effort.
    }
  }

  Future<bool> autoRestoreIfNeeded() async {
    if (_restoreAttempted && _restoreInFlight == null) return false;
    if (_restoreInFlight != null) {
      return _restoreInFlight!;
    }

    final future = () async {
      try {
        final hasScannerData = await _store.hasAnyScannerData();
        final prefs = await SharedPreferences.getInstance();
        final hasMeaningfulPrefs = _hasMeaningfulAppData(prefs);
        final shouldRestorePreferences = !hasMeaningfulPrefs;
        final shouldRestoreScannerStore = !hasScannerData;
        if (!shouldRestorePreferences && !shouldRestoreScannerStore) {
          _restoreAttempted = true;
          return false;
        }

        final rawBytes = await _channel.invokeMethod<Uint8List>(
          'readBackupFileAuto',
          {'fileName': backupFileName},
        );
        if (rawBytes == null || rawBytes.isEmpty) {
          _restoreAttempted = true;
          return false;
        }

        final rawJson = utf8.decode(gzip.decode(rawBytes));
        final payloadRaw = jsonDecode(rawJson);
        if (payloadRaw is! Map) {
          _restoreAttempted = true;
          return false;
        }

        await _restoreBackupPayload(
          Map<String, dynamic>.from(payloadRaw),
          restorePreferences: shouldRestorePreferences,
          restoreScannerStore: shouldRestoreScannerStore,
        );
        await _store.setMeta(
          _metaBackupRestoredAt,
          DateTime.now().toUtc().toIso8601String(),
        );
        _restoreAttempted = true;
        return true;
      } catch (_) {
        return false;
      }
    }();

    _restoreInFlight = future;
    final result = await future;
    _restoreInFlight = null;
    return result;
  }

  Future<Map<String, dynamic>> restoreFromBackup() async {
    try {
      final rawBytes = await _channel.invokeMethod<Uint8List>(
        'readBackupFileAuto',
        {'fileName': backupFileName},
      );
      if (rawBytes == null || rawBytes.isEmpty) {
        return {
          'ok': false,
          'error': 'Automatic backup file not found on this device.',
        };
      }

      final rawJson = utf8.decode(gzip.decode(rawBytes));
      final payloadRaw = jsonDecode(rawJson);
      if (payloadRaw is! Map) {
        return {'ok': false, 'error': 'Backup file format is invalid.'};
      }

      await _restoreBackupPayload(Map<String, dynamic>.from(payloadRaw));
      await _store.setMeta(
        _metaBackupRestoredAt,
        DateTime.now().toUtc().toIso8601String(),
      );
      return {'ok': true};
    } on PlatformException catch (e) {
      return {
        'ok': false,
        'error': e.message?.trim().isNotEmpty == true
            ? e.message
            : 'Automatic backup restore failed.',
      };
    } catch (e) {
      return {
        'ok': false,
        'error': 'Automatic backup restore failed.',
        'debug': kDebugMode ? e.toString() : '',
      };
    }
  }
}
