import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'offline_backup_service.dart';

class _MemoryCacheEntry {
  final dynamic data;
  final DateTime cachedAt;

  const _MemoryCacheEntry(this.data, this.cachedAt);
}

/// Lightweight TTL cache (memory + optional disk lists) for mobile data.
class AppCacheService {
  AppCacheService._internal();

  static final AppCacheService _instance = AppCacheService._internal();

  factory AppCacheService({OfflineBackupService? backupService}) {
    if (backupService != null) {
      _instance._backupService = backupService;
    }
    return _instance;
  }

  OfflineBackupService _backupService = OfflineBackupService();
  final Map<String, _MemoryCacheEntry> _memory = {};
  final Map<String, Future<dynamic>> _inFlight = {};

  String _dataKey(String key) => 'app_cache_$key';
  String _updatedAtKey(String key) => 'app_cache_${key}_updated_at';

  T? readMemory<T>(String key, Duration ttl, {bool forceFresh = false}) {
    if (forceFresh) {
      _memory.remove(key);
      return null;
    }

    final entry = _memory[key];
    if (entry == null) {
      return null;
    }

    if (DateTime.now().difference(entry.cachedAt) > ttl) {
      return null;
    }

    return entry.data as T?;
  }

  T? readMemoryStale<T>(
    String key,
    Duration maxAge, {
    bool forceFresh = false,
  }) {
    if (forceFresh) {
      _memory.remove(key);
      return null;
    }

    final entry = _memory[key];
    if (entry == null) {
      return null;
    }

    if (DateTime.now().difference(entry.cachedAt) > maxAge) {
      _memory.remove(key);
      return null;
    }

    return entry.data as T?;
  }

  void writeMemory(String key, dynamic data) {
    _memory[key] = _MemoryCacheEntry(data, DateTime.now());
  }

  void invalidateMemory([String? key]) {
    if (key == null || key.trim().isEmpty) {
      _memory.clear();
      return;
    }

    _memory.remove(key);
  }

  void invalidateMemoryPrefix(String prefix) {
    if (prefix.trim().isEmpty) {
      _memory.clear();
      return;
    }

    _memory.removeWhere((key, _) => key.startsWith(prefix));
  }

  /// Drop in-flight loaders so a force refresh cannot wait on a stale request.
  void cancelInFlightPrefix(String prefix) {
    if (prefix.trim().isEmpty) {
      _inFlight.clear();
      return;
    }
    _inFlight.removeWhere((key, _) => key.startsWith(prefix));
  }

  /// Runs [loader] once per key while in flight; optional memory TTL cache.
  Future<T> fetchOnce<T>(
    String key,
    Future<T> Function() loader, {
    Duration? ttl,
    bool forceFresh = false,
  }) async {
    if (!forceFresh && ttl != null) {
      final cached = readMemory<T>(key, ttl, forceFresh: forceFresh);
      if (cached != null) {
        return cached;
      }
    }

    if (!forceFresh) {
      final pending = _inFlight[key];
      if (pending != null) {
        return await (pending as Future<T>);
      }
    }

    final future = loader().whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    final result = await future;
    if (ttl != null) {
      writeMemory(key, result);
    }
    return result;
  }

  Future<void> saveJsonList(
    String key,
    List<Map<String, dynamic>> rows, {
    bool preserveNonEmptyOnEmpty = false,
  }) async {
    if (preserveNonEmptyOnEmpty && rows.isEmpty) {
      final existing = await loadJsonList(key);
      if (existing.isNotEmpty) {
        // Keep prior offline/warm data when a refresh returns empty.
        writeMemory(key, List<Map<String, dynamic>>.from(existing));
        return;
      }
    }

    writeMemory(key, List<Map<String, dynamic>>.from(rows));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dataKey(key), jsonEncode(rows));
    await prefs.setString(
      _updatedAtKey(key),
      DateTime.now().toUtc().toIso8601String(),
    );
    await _backupService.autoBackupIfConfigured();
  }

  Future<List<Map<String, dynamic>>> loadJsonList(String key) async {
    final cached = readMemoryStale<List<Map<String, dynamic>>>(
      key,
      const Duration(hours: 24),
    );
    if (cached != null) {
      return List<Map<String, dynamic>>.from(cached);
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = (prefs.getString(_dataKey(key)) ?? '').trim();
    if (raw.isEmpty) return <Map<String, dynamic>>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      final rows = decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      writeMemory(key, rows);
      return rows;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<DateTime?> lastUpdatedAt(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = (prefs.getString(_updatedAtKey(key)) ?? '').trim();
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }
}
