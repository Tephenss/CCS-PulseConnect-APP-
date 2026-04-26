import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'offline_backup_service.dart';

class AppCacheService {
  AppCacheService({OfflineBackupService? backupService})
    : _backupService = backupService ?? OfflineBackupService();

  final OfflineBackupService _backupService;

  String _dataKey(String key) => 'app_cache_$key';
  String _updatedAtKey(String key) => 'app_cache_${key}_updated_at';

  Future<void> saveJsonList(String key, List<Map<String, dynamic>> rows) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dataKey(key), jsonEncode(rows));
    await prefs.setString(
      _updatedAtKey(key),
      DateTime.now().toUtc().toIso8601String(),
    );
    await _backupService.autoBackupIfConfigured();
  }

  Future<List<Map<String, dynamic>>> loadJsonList(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = (prefs.getString(_dataKey(key)) ?? '').trim();
    if (raw.isEmpty) return <Map<String, dynamic>>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
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
