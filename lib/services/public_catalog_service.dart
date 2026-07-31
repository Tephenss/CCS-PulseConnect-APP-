import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Non-authoritative public published-event catalog + revision signal.
/// Source of truth remains PHP/Supabase for registration, attendance, tickets.
class PublicCatalogService {
  PublicCatalogService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;
  static const String _revisionPrefsKey = 'public_catalog_events_revision';

  static final PublicCatalogService instance = PublicCatalogService();

  int? _memoryRevision;
  List<Map<String, dynamic>>? _memoryEvents;
  DateTime? _memoryLoadedAtUtc;

  Future<int?> readEventsRevision() async {
    try {
      final snap =
          await _db.collection('public_catalog_meta').doc('signals').get();
      if (!snap.exists) return null;
      final data = snap.data();
      if (data == null) return null;
      final raw = data['events_revision'];
      if (raw is int) return raw;
      return int.tryParse('$raw');
    } catch (e) {
      debugPrint('PublicCatalogService.readEventsRevision: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> listPublishedEvents({
    int limit = 120,
  }) async {
    try {
      final snap = await _db
          .collection('public_catalog_events')
          .limit(limit)
          .get(const GetOptions(source: Source.serverAndCache));
      final rows = snap.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] = (data['id'] ?? doc.id).toString();
        data['status'] = (data['status'] ?? 'published').toString();
        return data;
      }).toList();
      rows.sort((a, b) {
        final aStart = (a['start_at'] ?? '').toString();
        final bStart = (b['start_at'] ?? '').toString();
        return aStart.compareTo(bStart);
      });
      _memoryEvents = rows;
      _memoryLoadedAtUtc = DateTime.now().toUtc();
      return rows;
    } catch (e) {
      debugPrint('PublicCatalogService.listPublishedEvents: $e');
      if (_memoryEvents != null) return List<Map<String, dynamic>>.from(_memoryEvents!);
      return [];
    }
  }

  /// Drop local catalog memory so the next load re-checks Firestore / falls back.
  Future<void> invalidateLocal() async {
    _memoryEvents = null;
    _memoryLoadedAtUtc = null;
    _memoryRevision = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_revisionPrefsKey);
    } catch (_) {}
  }

  /// When revision is unchanged and memory is warm, returns null (skip refetch).
  /// Empty list means catalog miss → caller should fall back to Supabase.
  Future<List<Map<String, dynamic>>?> loadIfRevisionChanged({
    int limit = 120,
    bool force = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final localRev = prefs.getInt(_revisionPrefsKey) ?? _memoryRevision ?? 0;
    final remoteRev = await readEventsRevision();

    final warm = _memoryEvents != null &&
        _memoryEvents!.isNotEmpty &&
        _memoryLoadedAtUtc != null &&
        DateTime.now().toUtc().difference(_memoryLoadedAtUtc!) <
            const Duration(minutes: 10);

    if (!force &&
        remoteRev != null &&
        remoteRev == localRev &&
        warm) {
      return null;
    }

    final rows = await listPublishedEvents(limit: limit);
    if (rows.isEmpty) return [];
    if (remoteRev != null) {
      _memoryRevision = remoteRev;
      await prefs.setInt(_revisionPrefsKey, remoteRev);
    }
    return rows;
  }
}
