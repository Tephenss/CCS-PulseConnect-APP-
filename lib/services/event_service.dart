import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/env.dart';
import '../utils/event_time_utils.dart';
import 'auth_service.dart';
import 'mobile_backend_service.dart';
import 'app_cache_service.dart';
import 'public_catalog_service.dart';

class EventService {
  final _supabase = Supabase.instance.client;
  final AppCacheService _appCache = AppCacheService();
  static final Connectivity _connectivity = Connectivity();
  static const Duration _manilaOffset = Duration(hours: 8);
  final Map<String, bool> _eventSessionColumnSupport = {};
  final Map<String, bool> _attendanceColumnSupport = {};
  bool? _eventSessionAttendanceTableSupported;
  DateTime? _eventSessionAttendanceSupportCheckedAtUtc;
  static final Map<String, DateTime> _absenceSyncAttemptedAtUtc = {};
  static const Duration _absenceSyncCooldown = Duration(minutes: 10);
  static final Map<String, Map<String, String>> _studentTargetScopeCache = {};
  static final Map<String, _CachedStudentRequirements> _studentRequirementsCache =
      {};
  static final Map<String, _ListCacheEntry> _listCache = {};
  static const Duration _activeEventsTtl = Duration(seconds: 45);
  static const Duration _teacherEventsTtl = Duration(seconds: 45);
  static const Duration _expiredEvalTtl = Duration(seconds: 120);
  static const Duration _ticketsTtl = Duration(seconds: 45);
  static const Duration _myCertificatesTtl = Duration(seconds: 90);
  static const Duration _eventByIdTtl = Duration(seconds: 60);
  static const Duration _eventSessionsTtl = Duration(seconds: 60);
  static const Duration _eventRegistrationSettingsTtl = Duration(seconds: 30);
  static const String _eventListColumns =
      'id,title,start_at,end_at,status,updated_at,created_at,created_by,proposal_stage,requirements_requested_at,requirements_submitted_at,description,event_structure,event_mode,event_for,allow_registration,cover_image_url,location,event_type,event_span,grace_time,registration_limit,is_free_event,event_fee,registration_close_weeks,registration_close_extend_days';
  static const String _eventListColumnsFallback =
      'id,title,start_at,end_at,status,updated_at,created_at,created_by,proposal_stage,requirements_requested_at,requirements_submitted_at,description,event_mode,event_for,cover_image_url,location,event_type,event_span,is_free_event,event_fee';
  static const String _eventListColumnsMinimal =
      'id,title,start_at,end_at,status,updated_at,created_at,created_by,proposal_stage,requirements_requested_at,requirements_submitted_at,description,event_mode,event_for';

  static const Duration _studentRequirementsCacheTtl = Duration(minutes: 2);

  static Future<void> invalidateEventListCache({String? prefix}) async {
    final cache = AppCacheService();
    if (prefix == null || prefix.trim().isEmpty) {
      _listCache.clear();
      cache.invalidateMemoryPrefix('active:');
      cache.invalidateMemoryPrefix('teacher_accessible:');
      cache.invalidateMemoryPrefix('expired_eval:');
      cache.invalidateMemoryPrefix('tickets:');
      cache.invalidateMemoryPrefix('fetch:');
      cache.invalidateMemoryPrefix('event_by_id:');
      cache.invalidateMemoryPrefix('event_sessions:');
      cache.invalidateMemoryPrefix('event_reg_settings:');
      cache.cancelInFlightPrefix('fetch:');
      // Await disk clears so live UI refresh cannot rehydrate stale prefs.
      await Future.wait([
        cache.clearJsonListByPrefix('active:'),
        cache.clearJsonListByPrefix('teacher_accessible:'),
        cache.clearJsonListByPrefix('expired_eval:'),
        cache.clearJsonListByPrefix('tickets:'),
        // Do not clear certs: here — event list pulses must not force a cold
        // Certificates page load. Certs invalidate on certificates realtime.
        cache.clearJsonListByPrefix('teacher_accessible_events_'),
        cache.clearJsonListByPrefix('teacher_home_upcoming_events_'),
      ]);
      return;
    }
    final p = prefix.trim();
    _listCache.removeWhere((key, _) => key.startsWith(p));
    cache.invalidateMemoryPrefix(p);
    cache.cancelInFlightPrefix('fetch:$p');
    await cache.clearJsonListByPrefix(p);
  }

  /// Link-level offline check. On errors, assume offline so we keep caches.
  static Future<bool> isLikelyOffline() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return results.isEmpty ||
          results.every((result) => result == ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  Future<List<Map<String, dynamic>>> _preferExistingCacheIfEmpty(
    String cacheKey,
    List<Map<String, dynamic>> fresh,
  ) async {
    if (fresh.isNotEmpty) return fresh;

    final staleMem = _readListCache(
      cacheKey,
      const Duration(days: 7),
      allowStale: true,
      staleTtl: const Duration(days: 7),
    );
    if (staleMem != null && staleMem.isNotEmpty) {
      return staleMem;
    }

    final disk = await _appCache.loadJsonList(cacheKey);
    if (disk.isNotEmpty) {
      _writeListCache(cacheKey, disk);
      return disk;
    }
    return fresh;
  }

  void invalidateEventDetailCache(String eventId) {
    final id = eventId.trim();
    if (id.isEmpty) return;
    _appCache.invalidateMemory('event_by_id:$id');
    _appCache.invalidateMemory('event_sessions:$id');
    _appCache.invalidateMemory('event_reg_settings:$id');
  }

  /// Clears tickets list cache so Tickets tab shows newly issued tickets.
  Future<void> invalidateMyTicketsCache([String? userId]) async {
    var uid = (userId ?? '').trim();
    if (uid.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        uid = (prefs.getString('user_id') ?? '').trim();
      } catch (_) {}
    }
    if (uid.isNotEmpty) {
      final cacheKey = 'tickets:$uid';
      await _appCache.clearJsonList(cacheKey);
      _appCache.cancelInFlightPrefix('fetch:$cacheKey');
      return;
    }
    _appCache.invalidateMemoryPrefix('tickets:');
    _appCache.cancelInFlightPrefix('fetch:tickets:');
  }

  /// Clears certificates list cache (issued/updated certs realtime).
  static Future<void> invalidateCertificatesCache([String? userId]) async {
    final cache = AppCacheService();
    var uid = (userId ?? '').trim();
    if (uid.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        uid = (prefs.getString('user_id') ?? '').trim();
      } catch (_) {}
    }
    if (uid.isNotEmpty) {
      final cacheKey = 'certs:v2:$uid';
      _listCache.remove(cacheKey);
      cache.invalidateMemory(cacheKey);
      cache.cancelInFlightPrefix('fetch:$cacheKey');
      await cache.clearJsonList(cacheKey);
      return;
    }
    _listCache.removeWhere((key, _) => key.startsWith('certs:'));
    cache.invalidateMemoryPrefix('certs:');
    cache.cancelInFlightPrefix('fetch:certs:');
    await cache.clearJsonListByPrefix('certs:');
  }

  List<Map<String, dynamic>>? _readListCache(
    String key,
    Duration ttl, {
    bool allowStale = false,
    Duration staleTtl = const Duration(minutes: 30),
  }) {
    final entry = _listCache[key];
    if (entry == null) {
      return null;
    }
    final age = DateTime.now().difference(entry.cachedAt);
    if (age <= ttl) {
      return List<Map<String, dynamic>>.from(entry.data);
    }
    if (allowStale && age <= staleTtl) {
      return List<Map<String, dynamic>>.from(entry.data);
    }
    _listCache.remove(key);
    return null;
  }

  void _writeListCache(String key, List<Map<String, dynamic>> data) {
    _listCache[key] = _ListCacheEntry(
      List<Map<String, dynamic>>.from(data),
      DateTime.now(),
    );
  }

  List<Map<String, dynamic>>? _readCachedStudentRequirements(String eventId) {
    final cached = _studentRequirementsCache[eventId];
    if (cached == null) {
      return null;
    }
    if (DateTime.now().difference(cached.cachedAt) > _studentRequirementsCacheTtl) {
      _studentRequirementsCache.remove(eventId);
      return null;
    }
    return List<Map<String, dynamic>>.from(cached.items);
  }

  void _writeCachedStudentRequirements(
    String eventId,
    List<Map<String, dynamic>> items,
  ) {
    _studentRequirementsCache[eventId] = _CachedStudentRequirements(
      items: List<Map<String, dynamic>>.from(items),
      cachedAt: DateTime.now(),
    );
  }

  void clearStudentRequirementsCache([String? eventId]) {
    if (eventId == null || eventId.trim().isEmpty) {
      _studentRequirementsCache.clear();
      return;
    }
    _studentRequirementsCache.remove(eventId.trim());
  }

  String _approvedRegistrationCacheKey(String userId) =>
      'approved_registration_events_${userId.trim()}';

  Future<void> cacheApprovedRegistrationAccess(
    String userId,
    String eventId,
  ) async {
    final trimmedUserId = userId.trim();
    final trimmedEventId = eventId.trim();
    if (trimmedUserId.isEmpty || trimmedEventId.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final key = _approvedRegistrationCacheKey(trimmedUserId);
    final values = <String>{
      ...(prefs.getStringList(key) ?? const <String>[]),
      trimmedEventId,
    };
    await prefs.setStringList(key, values.toList());
  }

  Future<bool> hasCachedApprovedRegistrationAccess(
    String userId,
    String eventId,
  ) async {
    final trimmedUserId = userId.trim();
    final trimmedEventId = eventId.trim();
    if (trimmedUserId.isEmpty || trimmedEventId.isEmpty) return false;

    final prefs = await SharedPreferences.getInstance();
    final values =
        prefs.getStringList(_approvedRegistrationCacheKey(trimmedUserId)) ??
        const <String>[];
    return values.contains(trimmedEventId);
  }

  Future<bool> _hasServerApprovedRegistrationSignal(
    String userId,
    String eventId,
  ) async {
    final trimmedUserId = userId.trim();
    final trimmedEventId = eventId.trim();
    if (trimmedUserId.isEmpty || trimmedEventId.isEmpty) return false;

    try {
      if (MobileBackendService.isConfigured) {
        final res = await _mobileBackend.secureRead(
          table: 'user_notification_reads',
          select: 'notification_id',
          filters: {
            'user_id': trimmedUserId,
            'notification_id': 'reg_access_approved_$trimmedEventId',
          },
          limit: 1,
        );
        final rows = (res['ok'] == true && res['rows'] is List)
            ? (res['rows'] as List)
            : const [];
        return rows.isNotEmpty;
      }
      final row = await _supabase
          .from('user_notification_reads')
          .select('notification_id')
          .eq('user_id', trimmedUserId)
          .eq('notification_id', 'reg_access_approved_$trimmedEventId')
          .maybeSingle();
      return row != null;
    } catch (_) {
      return false;
    }
  }

  bool _isMissingAssistantsTableError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('pgrst201') || msg.contains('ambiguous')) return false;
    return (msg.contains('event_assistants') &&
            msg.contains('does not exist')) ||
        msg.contains('42p01') ||
        msg.contains('pgrst205');
  }

  bool _isMissingTeacherAssignmentsTableError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('pgrst201') || msg.contains('ambiguous')) return false;
    return (msg.contains('event_teacher_assignments') &&
            msg.contains('does not exist')) ||
        msg.contains('42p01') ||
        msg.contains('pgrst205');
  }

  bool _isMissingRelationError(Object error, {String? relation}) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('pgrst201') || msg.contains('ambiguous')) return false;
    if (relation != null && relation.trim().isNotEmpty) {
      final rel = relation.toLowerCase().trim();
      if (msg.contains(rel) && msg.contains('does not exist')) {
        return true;
      }
      if (msg.contains('relation') &&
          msg.contains(rel) &&
          msg.contains('not found')) {
        return true;
      }
    }
    return msg.contains('42p01') || msg.contains('pgrst205');
  }

  bool _isMissingColumnError(Object error, {String? relation, String? column}) {
    final msg = error.toString().toLowerCase();
    final mentionsColumn = column == null || column.trim().isEmpty
        ? true
        : msg.contains(column.toLowerCase().trim());
    final mentionsRelation = relation == null || relation.trim().isEmpty
        ? true
        : msg.contains(relation.toLowerCase().trim());
    if (!mentionsColumn || !mentionsRelation) return false;
    return msg.contains('42703') ||
        msg.contains('pgrst204') ||
        (msg.contains('column') && msg.contains('does not exist')) ||
        msg.contains('could not find the') ||
        msg.contains('schema cache');
  }

  bool _isMissingAssistantAssignedByTeacherColumnError(Object error) {
    return _isMissingColumnError(
      error,
      relation: 'event_assistants',
      column: 'assigned_by_teacher_id',
    );
  }

  bool _isUniqueViolationError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('23505') ||
        msg.contains('duplicate key') ||
        msg.contains('unique constraint') ||
        msg.contains('already exists');
  }

  bool _isAccessPolicyError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('permission denied') ||
        msg.contains('row level security') ||
        msg.contains('42501') ||
        msg.contains('not allowed');
  }

  bool _isEventSessionAttendanceUnavailableError(Object error) {
    return _isMissingRelationError(
          error,
          relation: 'event_session_attendance',
        ) ||
        _isMissingColumnError(error, relation: 'event_session_attendance');
  }

  bool _isAbsenceReasonsTableUnavailableError(Object error) {
    return _isMissingRelationError(
          error,
          relation: 'attendance_absence_reasons',
        ) ||
        _isMissingColumnError(error, relation: 'attendance_absence_reasons');
  }

  bool _isCheckedInStatus(dynamic rawStatus) {
    final status = (rawStatus?.toString() ?? '').toLowerCase();
    return status == 'scanned' ||
        status == 'present' ||
        status == 'late' ||
        status == 'early';
  }

  bool _looksLikeUuid(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return false;
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    return uuid.hasMatch(value);
  }

  Future<String> _resolveUserUuidFromStudentRef(String rawStudentRef) async {
    final normalized = rawStudentRef.trim();
    if (normalized.isEmpty) return '';
    // users table is locked from anon — cannot resolve student_id → uuid here.
    return normalized;
  }

  bool _attendanceRecordCountsAsPresent(Map<String, dynamic>? row) {
    if (row == null || row.isEmpty) return false;
    if ((row['check_in_at']?.toString().trim().isNotEmpty ?? false)) {
      return true;
    }
    return _isCheckedInStatus(row['status']);
  }

  String _normalizedScanTimestampIso(
    String? rawIso, {
    required String fallbackIso,
  }) {
    final parsed = _toUtcDate(rawIso);
    if (parsed == null) return fallbackIso;
    return parsed.toIso8601String();
  }

  bool _shouldApplyIncomingCheckIn({
    required String incomingScanAtIso,
    dynamic recordedCheckInAt,
  }) {
    final incoming = _toUtcDate(incomingScanAtIso);
    if (incoming == null) return false;

    final existingRaw = recordedCheckInAt?.toString().trim() ?? '';
    if (existingRaw.isEmpty) return true;

    final existing = _toUtcDate(existingRaw);
    if (existing == null) return true;

    return incoming.isBefore(existing);
  }

  bool _eventUsesSessions(Map<String, dynamic> event) {
    final embeddedSessions = event['sessions'];
    if (embeddedSessions is List && embeddedSessions.isNotEmpty) {
      return true;
    }

    final usesSessionsRaw = event['uses_sessions'];
    if (usesSessionsRaw == true ||
        (usesSessionsRaw?.toString().toLowerCase().trim() == 'true')) {
      return true;
    }

    final sessionCount = int.tryParse(event['session_count']?.toString() ?? '') ?? 0;
    if (sessionCount > 0) return true;

    final eventMode = (event['event_mode']?.toString() ?? '')
        .toLowerCase()
        .trim();
    if (eventMode == 'seminar_based') return true;

    final eventStructure = (event['event_structure']?.toString() ?? '')
        .toLowerCase()
        .trim();
    return eventStructure == 'one_seminar' || eventStructure == 'two_seminars';
  }

  DateTime? _toUtcDate(dynamic raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final dt = DateTime.tryParse(text);
    if (dt == null) return null;

    final hasExplicitOffset = RegExp(
      r'(z|[+-]\d{2}:\d{2}|[+-]\d{4})$',
      caseSensitive: false,
    ).hasMatch(text);
    if (hasExplicitOffset) {
      return dt.toUtc();
    }

    // Legacy values without timezone are interpreted as Manila wall time.
    return DateTime.utc(
      dt.year,
      dt.month,
      dt.day,
      dt.hour,
      dt.minute,
      dt.second,
      dt.millisecond,
      dt.microsecond,
    ).subtract(_manilaOffset);
  }

  String composeParticipantDisplayName(Map<String, dynamic>? user) {
    return _composeDisplayName(user);
  }

  String _composeDisplayName(Map<String, dynamic>? user) {
    if (user == null || user.isEmpty) return '';

    final firstName = (user['first_name']?.toString() ?? '').trim();
    final middleName = (user['middle_name']?.toString() ?? '').trim();
    final lastName = (user['last_name']?.toString() ?? '').trim();
    final suffix = (user['suffix']?.toString() ?? '').trim();

    final parts = <String>[];
    if (firstName.isNotEmpty) parts.add(firstName);
    if (middleName.isNotEmpty) parts.add(middleName);
    if (lastName.isNotEmpty) parts.add(lastName);
    var fullName = parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (suffix.isNotEmpty) {
      fullName = fullName.isEmpty ? suffix : '$fullName $suffix';
    }
    return fullName.trim();
  }

  Map<String, dynamic>? _extractEmbeddedMap(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    if (raw is List && raw.isNotEmpty && raw.first is Map) {
      return Map<String, dynamic>.from(raw.first as Map);
    }
    return null;
  }

  String _extractAvatarStoragePath(String rawPhotoUrl) {
    final raw = rawPhotoUrl.trim();
    if (raw.isEmpty) return '';

    if (!raw.toLowerCase().startsWith('http')) {
      var normalized = raw.replaceAll('\\', '/').trim();
      if (normalized.startsWith('/')) {
        normalized = normalized.substring(1);
      }
      if (normalized.startsWith('avatars/')) {
        normalized = normalized.substring('avatars/'.length);
      }
      return normalized;
    }

    final uri = Uri.tryParse(raw);
    if (uri == null) return '';
    final path = uri.path;
    const publicMarker = '/storage/v1/object/public/avatars/';
    const signMarker = '/storage/v1/object/sign/avatars/';
    if (path.contains(publicMarker)) {
      return path.split(publicMarker).last;
    }
    if (path.contains(signMarker)) {
      return path.split(signMarker).last;
    }
    return '';
  }

  Future<String> _resolveAvatarDisplayUrl(String rawPhotoUrl) async {
    final raw = rawPhotoUrl.trim();
    if (raw.isEmpty) return '';

    final avatarPath = _extractAvatarStoragePath(raw);
    if (avatarPath.isEmpty) return raw;

    // Private avatars bucket — sign via PHP BFF (service role).
    if (MobileBackendService.isConfigured) {
      try {
        final token = await MobileBackendService.getSessionToken();
        if (token != null && token.isNotEmpty) {
          final res = await MobileBackendService().createSignedStorageUrl(
            bucket: 'avatars',
            path: avatarPath,
            expiresIn: 60 * 60 * 12,
          );
          final signed = (res['signed_url']?.toString() ?? '').trim();
          if (res['ok'] == true && signed.isNotEmpty) {
            return signed;
          }
        }
      } catch (_) {}
    }

    try {
      final signed = await _supabase.storage
          .from('avatars')
          .createSignedUrl(avatarPath, 60 * 60 * 24);
      if (signed.trim().isNotEmpty) {
        return signed.trim();
      }
    } catch (_) {}

    return raw;
  }

  /// Public wrapper for scanner overlays (private bucket paths need signing).
  Future<String> resolveAvatarDisplayUrl(String rawPhotoUrl) {
    return _resolveAvatarDisplayUrl(rawPhotoUrl);
  }

  Future<Map<String, String>> _resolveParticipantIdentityForRegistration(
    String registrationId,
  ) async {
    final trimmedRegistrationId = registrationId.trim();
    if (trimmedRegistrationId.isEmpty) {
      return {'name': '', 'photo_url': '', 'student_id': ''};
    }

    String studentId = '';
    String participantName = '';
    String participantPhotoUrl = '';

    try {
      final regRows = await _supabase
          .from('event_registrations')
          .select('student_id')
          .eq('id', trimmedRegistrationId)
          .limit(1);

      if (regRows.isNotEmpty) {
        final row = Map<String, dynamic>.from(regRows.first);
        studentId = (row['student_id']?.toString() ?? '').trim();
      }
    } catch (_) {
      // Leave empty — scan BFF should supply participant identity.
    }

    // Never SELECT users via anon (locked in 048).
    return {
      'name': participantName.trim(),
      'photo_url': participantPhotoUrl.trim(),
      'student_id': studentId.trim(),
    };
  }

  Future<String> _resolveParticipantNameForUser(String userId) async {
    final targetId = userId.trim();
    if (targetId.isEmpty) return '';

    // users table is locked from anon — use cached session profile first.
    try {
      final auth = AuthService();
      final current = await auth.getCurrentUser();
      final currentId = (current?['id']?.toString() ?? '').trim();
      if (current != null && (currentId.isEmpty || currentId == targetId)) {
        final composed = _composeDisplayName(current);
        if (composed.isNotEmpty) return composed;
        final display = (current['display_name']?.toString() ?? '').trim();
        if (display.isNotEmpty) return display;
        final full = (current['full_name']?.toString() ?? '').trim();
        if (full.isNotEmpty) return full;
      }
    } catch (_) {
      // Fall through.
    }

    // SharedPreferences backup (same cache AuthService writes).
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user_data');
      if (raw != null && raw.trim().isNotEmpty) {
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          final map = Map<String, dynamic>.from(parsed);
          final cachedId = (map['id']?.toString() ?? prefs.getString('user_id') ?? '')
              .trim();
          if (cachedId.isEmpty || cachedId == targetId) {
            final composed = _composeDisplayName(map);
            if (composed.isNotEmpty) return composed;
            final display = (map['display_name']?.toString() ?? '').trim();
            if (display.isNotEmpty) return display;
            final full = (map['full_name']?.toString() ?? '').trim();
            if (full.isNotEmpty) return full;
          }
        }
      }
    } catch (_) {
      // Ignore.
    }

    return '';
  }

  Future<List<Map<String, dynamic>>> _fetchTeacherScanAssignmentRows(
    String teacherId,
  ) async {
    List<Map<String, dynamic>> filterAssignments(
      List<Map<String, dynamic>> rows,
    ) {
      return rows.where((row) {
        final scan = row['can_scan'] == true;
        final manage = row['can_manage_assistants'] == true;
        return scan || manage;
      }).toList();
    }

    try {
      final rows = await _supabase
          .from('event_teacher_assignments')
          .select(
            'event_id, can_scan, can_manage_assistants, events(id,title,status,start_at,end_at,location,event_mode,event_structure,grace_time,early_out_enabled_at)',
          )
          .eq('teacher_id', teacherId)
          .limit(200);
      return filterAssignments(List<Map<String, dynamic>>.from(rows));
    } catch (_) {
      try {
        final rows = await _supabase
            .from('event_teacher_assignments')
            .select(
              'event_id, can_scan, events(id,title,status,start_at,end_at,location,event_structure,grace_time,early_out_enabled_at)',
            )
            .eq('teacher_id', teacherId)
            .eq('can_scan', true)
            .limit(200);
        return List<Map<String, dynamic>>.from(rows);
      } catch (_) {
        final rows = await _supabase
            .from('event_teacher_assignments')
            .select(
              'event_id, can_scan, events(id,title,status,start_at,end_at,location,grace_time)',
            )
            .eq('teacher_id', teacherId)
            .eq('can_scan', true)
            .limit(200);
        return List<Map<String, dynamic>>.from(rows);
      }
    }
  }

  String _sessionDisplayName(Map<String, dynamic> session) {
    final title = (session['title']?.toString() ?? '').trim();
    if (title.isNotEmpty) return title;
    final topic = (session['topic']?.toString() ?? '').trim();
    if (topic.isNotEmpty) return topic;
    return 'Seminar';
  }

  Map<String, dynamic> _asStringMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, mapValue) => MapEntry(key.toString(), mapValue));
    }
    return <String, dynamic>{};
  }

  Future<List<Map<String, dynamic>>> _getSessionCertificatesFallback(
    String userId,
  ) async {
    final sessionResponse = await _supabase
        .from('event_session_certificates')
        .select(
          'id, session_id, event_id, student_id, template_id, session_template_id, certificate_code, issued_at, event_title, session_title',
        )
        .eq('student_id', userId)
        .order('issued_at', ascending: false);

    final rawSessionCerts = List<Map<String, dynamic>>.from(sessionResponse);
    final sessionIds = rawSessionCerts
        .map((row) => row['session_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();

    final sessionMap = <String, Map<String, dynamic>>{};
    final eventIds = <String>{};
    for (final row in rawSessionCerts) {
      final snapEventId = (row['event_id']?.toString() ?? '').trim();
      if (snapEventId.isNotEmpty) eventIds.add(snapEventId);
    }
    if (sessionIds.isNotEmpty) {
      dynamic sessionRows;
      try {
        sessionRows = await _supabase
            .from('event_sessions')
            .select('id, event_id, title, topic, start_at')
            .inFilter('id', sessionIds);
      } catch (_) {
        sessionRows = await _supabase
            .from('event_sessions')
            .select('id, event_id, title, start_at')
            .inFilter('id', sessionIds);
      }

      for (final row in List<Map<String, dynamic>>.from(sessionRows)) {
        final sessionId = row['id']?.toString() ?? '';
        if (sessionId.isEmpty) continue;
        sessionMap[sessionId] = row;
        final eventId = row['event_id']?.toString() ?? '';
        if (eventId.isNotEmpty) {
          eventIds.add(eventId);
        }
      }
    }

    final eventMap = <String, Map<String, dynamic>>{};
    if (eventIds.isNotEmpty) {
      final eventRows = await _supabase
          .from('events')
          .select('id, title, start_at')
          .inFilter('id', eventIds.toList());
      for (final row in List<Map<String, dynamic>>.from(eventRows)) {
        final eventId = row['id']?.toString() ?? '';
        if (eventId.isNotEmpty) {
          eventMap[eventId] = row;
        }
      }
    }

    return rawSessionCerts.map((row) {
      final sessionId = row['session_id']?.toString() ?? '';
      final session = Map<String, dynamic>.from(
        sessionMap[sessionId] ?? <String, dynamic>{},
      );
      final sessionEventId = (session['event_id']?.toString() ?? '').trim();
      final rowEventId = (row['event_id']?.toString() ?? '').trim();
      final eventId =
          sessionEventId.isNotEmpty ? sessionEventId : rowEventId;
      final event = Map<String, dynamic>.from(
        eventMap[eventId] ?? <String, dynamic>{},
      );
      final liveSessionName = _sessionDisplayName(session);
      final snapSessionName = (row['session_title']?.toString() ?? '').trim();
      final sessionName = liveSessionName.isNotEmpty &&
              liveSessionName.toLowerCase() != 'seminar'
          ? liveSessionName
          : (snapSessionName.isNotEmpty ? snapSessionName : liveSessionName);
      final liveEventTitle = (event['title']?.toString() ?? '').trim();
      final snapEventTitle = (row['event_title']?.toString() ?? '').trim();
      final eventTitle = liveEventTitle.isNotEmpty
          ? liveEventTitle
          : (snapEventTitle.isNotEmpty ? snapEventTitle : 'Event');
      if ((event['title']?.toString() ?? '').trim().isEmpty) {
        event['title'] = eventTitle;
      }
      return {
        ...row,
        'event_id': eventId,
        'events': event,
        'session': session,
        'certificate_scope': 'session',
        'display_title': sessionName.isNotEmpty
            ? '$eventTitle - $sessionName'
            : eventTitle,
      };
    }).toList();
  }

  int _sessionWindowMinutes(Map<String, dynamic> session) {
    final fromScan = int.tryParse(
      session['scan_window_minutes']?.toString() ?? '',
    );
    if (fromScan != null && fromScan > 0) return fromScan;
    final fromAttendance = int.tryParse(
      session['attendance_window_minutes']?.toString() ?? '',
    );
    if (fromAttendance != null && fromAttendance > 0) return fromAttendance;
    return 30;
  }

  int _eventGraceMinutes(Map<String, dynamic> event) {
    final parsed = int.tryParse(event['grace_time']?.toString() ?? '');
    if (parsed != null && parsed > 0) return parsed;
    return 30;
  }

  bool _isHostedMobilePushConfiguredBaseUrl(String rawBaseUrl) {
    final raw = rawBaseUrl.trim();
    if (raw.isEmpty) return false;
    if (raw.contains('YOUR-WEB-DOMAIN')) return false;
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    if (!(uri.scheme == 'http' || uri.scheme == 'https')) return false;
    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty || host == 'your-web-domain') return false;
    return true;
  }

  /// Production schema from migrations — do NOT probe missing columns with
  /// SELECT (each failure is a Postgres ERROR in Supabase metrics).
  static const List<String> _eventSessionPreferredColumns = [
    'id',
    'event_id',
    'title',
    'start_at',
    'topic',
    'description',
    'location',
    'end_at',
    'scan_window_minutes',
    'sort_order',
    'early_out_enabled_at',
  ];

  static const List<String> _eventSessionBaseColumns = [
    'id',
    'event_id',
    'title',
    'start_at',
  ];

  Future<List<String>> _eventSessionsSupportedColumns() async {
    final supported = <String>[];
    for (final column in _eventSessionPreferredColumns) {
      if (_eventSessionColumnSupport[column] == false) continue;
      supported.add(column);
      _eventSessionColumnSupport.putIfAbsent(column, () => true);
    }
    return supported.isEmpty ? List<String>.from(_eventSessionBaseColumns) : supported;
  }

  Future<List<Map<String, dynamic>>> _queryEventSessions(
    String eventId,
    List<String> columns,
  ) async {
    dynamic query = _supabase
        .from('event_sessions')
        .select(columns.join(','))
        .eq('event_id', eventId);

    if (columns.contains('sort_order')) {
      query = query.order('sort_order', ascending: true);
    } else if (columns.contains('session_no')) {
      query = query.order('session_no', ascending: true);
    }
    query = query.order('start_at', ascending: true);

    final rows = await query;
    return _normalizeEventSessions(
      List<Map<String, dynamic>>.from(rows),
      eventId,
    );
  }

  Future<bool> _supportsAttendanceColumn(String column) async {
    // Production `attendance` has no session_id (sessions live in
    // event_session_attendance). Claiming session_id caused 42703 ERROR spam.
    const known = {
      'last_scanned_at',
      'ticket_id',
      'status',
      'check_in_at',
      'check_out_at',
    };
    final cached = _attendanceColumnSupport[column];
    if (cached != null) return cached;
    final ok = known.contains(column);
    _attendanceColumnSupport[column] = ok;
    return ok;
  }

  Future<bool> _supportsEventSessionAttendanceTable() async {
    // Assume present in production; probing SELECT failures still count as ERROR.
    if (_eventSessionAttendanceTableSupported == false) {
      final checkedAt = _eventSessionAttendanceSupportCheckedAtUtc;
      if (checkedAt != null &&
          DateTime.now().toUtc().difference(checkedAt).inMinutes < 60) {
        return false;
      }
    }
    _eventSessionAttendanceTableSupported = true;
    return true;
  }

  List<Map<String, dynamic>> _ticketRowsFromParticipant(
    Map<String, dynamic> participant,
  ) {
    final ticketsRaw = participant['tickets'];
    if (ticketsRaw is List) {
      return ticketsRaw
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
    }
    if (ticketsRaw is Map) {
      return <Map<String, dynamic>>[Map<String, dynamic>.from(ticketsRaw)];
    }
    return <Map<String, dynamic>>[];
  }

  Future<Map<String, dynamic>?> _loadEventForAttendanceMaterialization(
    String eventId,
  ) async {
    final trimmedId = eventId.trim();
    if (trimmedId.isEmpty) return null;

    try {
      final rows = await _supabase
          .from('events')
          .select(
            'id,title,status,start_at,end_at,location,event_mode,event_structure,grace_time',
          )
          .eq('id', trimmedId)
          .limit(1);
      if (rows.isNotEmpty) {
        return Map<String, dynamic>.from(rows.first);
      }
    } catch (_) {
      try {
        final rows = await _supabase
            .from('events')
            .select(
              'id,title,status,start_at,end_at,location,grace_time',
            )
            .eq('id', trimmedId)
            .limit(1);
        if (rows.isNotEmpty) {
          return Map<String, dynamic>.from(rows.first);
        }
      } catch (_) {
        try {
          final rows = await _supabase
              .from('events')
              .select('id,title,status,start_at,end_at,location,grace_time')
              .eq('id', trimmedId)
              .limit(1);
          if (rows.isNotEmpty) {
            return Map<String, dynamic>.from(rows.first);
          }
        } catch (_) {
          return null;
        }
      }
    }

    return null;
  }

  Future<Map<String, dynamic>?> _secureAttendanceWrite({
    required String eventId,
    required String table,
    required String method,
    required Map<String, dynamic> payload,
    String filter = '',
  }) async {
    if (!MobileBackendService.isConfigured || eventId.trim().isEmpty) {
      return null;
    }
    try {
      final res = await _mobileBackend.secureWrite('attendance_upsert', {
        'event_id': eventId,
        'table': table,
        'method': method,
        if (filter.isNotEmpty) 'filter': filter,
        'payload': payload,
      });
      if (res['ok'] != true) return null;
      final rows = res['rows'];
      if (rows is List && rows.isNotEmpty && rows.first is Map) {
        return Map<String, dynamic>.from(rows.first as Map);
      }
      return payload;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _patchSimpleAttendanceAbsent({
    required String eventId,
    required String ticketId,
    required Map<String, dynamic>? existingRow,
    required String nowIso,
  }) async {
    Map<String, dynamic>? updatedRow;
    final existingId = (existingRow?['id']?.toString() ?? '').trim();
    final payload = <String, dynamic>{
      'status': 'absent',
      'last_scanned_at': nowIso,
    };

    if (MobileBackendService.isConfigured && eventId.trim().isNotEmpty) {
      if (existingId.isNotEmpty) {
        updatedRow = await _secureAttendanceWrite(
          eventId: eventId,
          table: 'attendance',
          method: 'PATCH',
          filter: 'id=eq.$existingId&check_in_at=is.null',
          payload: payload,
        );
      }
      updatedRow ??= await _secureAttendanceWrite(
        eventId: eventId,
        table: 'attendance',
        method: 'PATCH',
        filter: 'ticket_id=eq.$ticketId&check_in_at=is.null',
        payload: payload,
      );
      updatedRow ??= await _secureAttendanceWrite(
        eventId: eventId,
        table: 'attendance',
        method: 'POST',
        payload: {
          'ticket_id': ticketId,
          'status': 'absent',
          'last_scanned_at': nowIso,
        },
      );
      if (updatedRow != null) return updatedRow;
    }

    // Anon writes revoked (051) — fail closed; do not spam Postgres ERROR.
    return updatedRow;
  }

  Future<Map<String, dynamic>?> _patchSessionAttendanceAbsent({
    required String eventId,
    required String sessionId,
    required String registrationId,
    required String ticketId,
    required Map<String, dynamic>? existingRow,
    required String nowIso,
  }) async {
    final prefersSessionAttendance =
        await _supportsEventSessionAttendanceTable();
    final table = prefersSessionAttendance
        ? 'event_session_attendance'
        : 'attendance';
    Map<String, dynamic>? updatedRow;
    final existingId = (existingRow?['id']?.toString() ?? '').trim();
    final absentPayload = <String, dynamic>{
      'status': 'absent',
      'last_scanned_at': nowIso,
    };

    if (MobileBackendService.isConfigured && eventId.trim().isNotEmpty) {
      if (existingId.isNotEmpty) {
        updatedRow = await _secureAttendanceWrite(
          eventId: eventId,
          table: table,
          method: 'PATCH',
          filter: 'id=eq.$existingId&check_in_at=is.null',
          payload: absentPayload,
        );
      }
      if (updatedRow == null && prefersSessionAttendance) {
        updatedRow = await _secureAttendanceWrite(
          eventId: eventId,
          table: table,
          method: 'PATCH',
          filter:
              'session_id=eq.$sessionId&registration_id=eq.$registrationId&check_in_at=is.null',
          payload: absentPayload,
        );
      }
      updatedRow ??= await _secureAttendanceWrite(
        eventId: eventId,
        table: table,
        method: 'PATCH',
        filter:
            'session_id=eq.$sessionId&ticket_id=eq.$ticketId&check_in_at=is.null',
        payload: absentPayload,
      );
      updatedRow ??= await _secureAttendanceWrite(
        eventId: eventId,
        table: table,
        method: 'POST',
        payload: prefersSessionAttendance
            ? {
                'session_id': sessionId,
                'registration_id': registrationId,
                'ticket_id': ticketId,
                'status': 'absent',
                'last_scanned_at': nowIso,
              }
            : {
                'session_id': sessionId,
                'ticket_id': ticketId,
                'status': 'absent',
                'last_scanned_at': nowIso,
              },
      );
      if (updatedRow != null) return updatedRow;
    }

    // Anon writes revoked (051) — fail closed; do not spam Postgres ERROR.
    return updatedRow;
  }

  Future<bool> _materializeSimpleEventAbsences({
    required Map<String, dynamic> event,
    required List<Map<String, dynamic>> participants,
  }) async {
    final startAt = _toUtcDate(event['start_at']);
    if (startAt == null) return false;

    final nowUtc = DateTime.now().toUtc();
    var closesAt = startAt.add(Duration(minutes: _eventGraceMinutes(event)));
    final endAt = _toUtcDate(event['end_at']);
    if (endAt != null && endAt.isBefore(closesAt)) {
      closesAt = endAt;
    }
    if (!nowUtc.isAfter(closesAt)) return false;

    final ticketIds = <String>[];
    final registrationByTicket = <String, String>{};
    for (final participant in participants) {
      final registrationId = (participant['id']?.toString() ?? '').trim();
      if (registrationId.isEmpty) continue;
      for (final ticket in _ticketRowsFromParticipant(participant)) {
        final ticketId = (ticket['id']?.toString() ?? '').trim();
        if (ticketId.isEmpty) continue;
        ticketIds.add(ticketId);
        registrationByTicket[ticketId] = registrationId;
      }
    }
    if (ticketIds.isEmpty) return false;

    final existingByTicket = <String, Map<String, dynamic>>{};
    try {
      final rows = await _supabase
          .from('attendance')
          .select('id,ticket_id,session_id,status,check_in_at,last_scanned_at')
          .inFilter('ticket_id', ticketIds)
          .limit(1000);
      for (final raw in List<Map<String, dynamic>>.from(rows)) {
        final sessionId = (raw['session_id']?.toString() ?? '').trim();
        if (sessionId.isNotEmpty) continue;
        final ticketId = (raw['ticket_id']?.toString() ?? '').trim();
        if (ticketId.isEmpty) continue;
        existingByTicket[ticketId] = raw;
      }
    } catch (_) {}

    final nowIso = nowUtc.toIso8601String();
    var changed = false;
    for (final ticketId in ticketIds) {
      final existing = existingByTicket[ticketId];
      if (_attendanceRecordCountsAsPresent(existing)) continue;
      final status = (existing?['status']?.toString() ?? '')
          .trim()
          .toLowerCase();
      if (status == 'absent') continue;
      final updated = await _patchSimpleAttendanceAbsent(
        eventId: (event['id']?.toString() ?? '').trim(),
        ticketId: ticketId,
        existingRow: existing,
        nowIso: nowIso,
      );
      if (updated != null) {
        changed = true;
      }
    }

    return changed;
  }

  Future<bool> _materializeSessionAbsences({
    required String eventId,
    required List<Map<String, dynamic>> participants,
  }) async {
    final sessions = await _fetchSessionsForEvent(eventId);
    if (sessions.isEmpty) return false;

    final nowUtc = DateTime.now().toUtc();
    final closedSessions = <Map<String, dynamic>>[];
    for (final session in sessions) {
      final sessionId = (session['id']?.toString() ?? '').trim();
      final startAt = _toUtcDate(session['start_at']);
      if (sessionId.isEmpty || startAt == null) continue;

      var closesAt = startAt.add(
        Duration(minutes: _sessionWindowMinutes(session)),
      );
      final sessionEndAt = _toUtcDate(session['end_at']);
      if (sessionEndAt != null && sessionEndAt.isBefore(closesAt)) {
        closesAt = sessionEndAt;
      }
      if (!nowUtc.isAfter(closesAt)) continue;
      closedSessions.add(session);
    }
    if (closedSessions.isEmpty) return false;

    final pairs = <Map<String, String>>[];
    final ticketIds = <String>[];
    for (final participant in participants) {
      final registrationId = (participant['id']?.toString() ?? '').trim();
      if (registrationId.isEmpty) continue;
      for (final ticket in _ticketRowsFromParticipant(participant)) {
        final ticketId = (ticket['id']?.toString() ?? '').trim();
        if (ticketId.isEmpty) continue;
        pairs.add({'registration_id': registrationId, 'ticket_id': ticketId});
        ticketIds.add(ticketId);
      }
    }
    if (pairs.isEmpty) return false;

    final existingByKey = <String, Map<String, dynamic>>{};
    final closedSessionIds = closedSessions
        .map((session) => (session['id']?.toString() ?? '').trim())
        .where((id) => id.isNotEmpty)
        .toList();
    if (closedSessionIds.isEmpty) return false;

    if (await _supportsEventSessionAttendanceTable()) {
      try {
        final rows = await _supabase
            .from('event_session_attendance')
            .select(
              'id,session_id,registration_id,ticket_id,status,check_in_at,last_scanned_at',
            )
            .inFilter('session_id', closedSessionIds)
            .limit(2000);
        for (final raw in List<Map<String, dynamic>>.from(rows)) {
          final sessionId = (raw['session_id']?.toString() ?? '').trim();
          final registrationId = (raw['registration_id']?.toString() ?? '')
              .trim();
          final ticketId = (raw['ticket_id']?.toString() ?? '').trim();
          if (sessionId.isEmpty) continue;
          if (registrationId.isNotEmpty) {
            existingByKey['$registrationId|$sessionId'] = raw;
          } else if (ticketId.isNotEmpty) {
            existingByKey['$ticketId|$sessionId'] = raw;
          }
        }
      } catch (_) {}
    } else {
      try {
        final rows = await _supabase
            .from('attendance')
            .select(
              'id,session_id,ticket_id,status,check_in_at,last_scanned_at',
            )
            .inFilter('session_id', closedSessionIds)
            .limit(2000);
        for (final raw in List<Map<String, dynamic>>.from(rows)) {
          final sessionId = (raw['session_id']?.toString() ?? '').trim();
          final ticketId = (raw['ticket_id']?.toString() ?? '').trim();
          if (sessionId.isEmpty || ticketId.isEmpty) continue;
          existingByKey['$ticketId|$sessionId'] = raw;
        }
      } catch (_) {}
    }

    final nowIso = nowUtc.toIso8601String();
    var changed = false;
    for (final session in closedSessions) {
      final sessionId = (session['id']?.toString() ?? '').trim();
      if (sessionId.isEmpty) continue;
      for (final pair in pairs) {
        final registrationId = pair['registration_id'] ?? '';
        final ticketId = pair['ticket_id'] ?? '';
        if (registrationId.isEmpty || ticketId.isEmpty) continue;
        final existing =
            existingByKey['$registrationId|$sessionId'] ??
            existingByKey['$ticketId|$sessionId'];
        if (_attendanceRecordCountsAsPresent(existing)) continue;
        final status = (existing?['status']?.toString() ?? '')
            .trim()
            .toLowerCase();
        if (status == 'absent') continue;
        final updated = await _patchSessionAttendanceAbsent(
          eventId: eventId,
          sessionId: sessionId,
          registrationId: registrationId,
          ticketId: ticketId,
          existingRow: existing,
          nowIso: nowIso,
        );
        if (updated != null) {
          changed = true;
        }
      }
    }

    return changed;
  }

  Future<bool> _materializeMissedAttendanceForEvent(
    String eventId, {
    List<Map<String, dynamic>> participants = const <Map<String, dynamic>>[],
  }) async {
    try {
      final event = await _loadEventForAttendanceMaterialization(eventId);
      if (event == null) return false;

      final sourceParticipants = participants
          .where((item) => item.isNotEmpty)
          .toList();
      if (sourceParticipants.isEmpty) return false;

      if (_eventUsesSessions(event)) {
        return _materializeSessionAbsences(
          eventId: eventId,
          participants: sourceParticipants,
        );
      }
      return _materializeSimpleEventAbsences(
        event: event,
        participants: sourceParticipants,
      );
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _recordSessionAttendance({
    required String ticketId,
    required String registrationId,
    required String sessionId,
    required String teacherId,
    required String nowIso,
    String? scannedAtIso,
    required Map<String, dynamic> session,
    required String participantName,
    required String participantPhotoUrl,
    required String participantStudentId,
    required bool dryRun,
  }) async {
    final effectiveScanAtIso = _normalizedScanTimestampIso(
      scannedAtIso,
      fallbackIso: nowIso,
    );
    final displayName = session['display_name']?.toString().trim();
    final sessionName = (displayName?.isNotEmpty ?? false)
        ? displayName!
        : _sessionDisplayName(session);

    Map<String, dynamic> successResponse() {
      final responseStatus = dryRun ? 'ready_for_confirmation' : 'present';
      final responseMessage = dryRun
          ? 'Review participant, then confirm check-in for $sessionName.'
          : 'Checked in for $sessionName.';
      return {
        'ok': true,
        'ticket_id': ticketId,
        'status': responseStatus,
        'participant_name': participantName,
        'participant_photo_url': participantPhotoUrl,
        'participant_student_id': participantStudentId,
        'message': responseMessage,
      };
    }

    Map<String, dynamic> alreadyRecordedResponse() {
      return {
        'ok': false,
        'error': 'This ticket is already recorded for the active seminar.',
        'status': 'already_checked_in',
        'participant_name': participantName,
        'participant_photo_url': participantPhotoUrl,
        'participant_student_id': participantStudentId,
      };
    }

    if (await _supportsEventSessionAttendanceTable()) {
      try {
        final existing = await _supabase
            .from('event_session_attendance')
            .select('id,status,check_in_at')
            .eq('session_id', sessionId)
            .eq('ticket_id', ticketId)
            .limit(1);
        if (existing.isNotEmpty) {
          final attendance = Map<String, dynamic>.from(existing.first);
          final alreadyCheckedIn = _attendanceRecordCountsAsPresent(attendance);
          if (alreadyCheckedIn) {
            if (!dryRun &&
                _shouldApplyIncomingCheckIn(
                  incomingScanAtIso: effectiveScanAtIso,
                  recordedCheckInAt: attendance['check_in_at'],
                )) {
              final eventId = (session['event_id']?.toString() ?? '').trim();
              if (eventId.isEmpty || !MobileBackendService.isConfigured) {
                return {
                  'ok': false,
                  'error': 'Check-in requires a secure backend connection.',
                  'status': 'error',
                };
              }
              final updated = await _secureAttendanceWrite(
                eventId: eventId,
                table: 'event_session_attendance',
                method: 'PATCH',
                filter: 'id=eq.${attendance['id']}',
                payload: {
                  'status': 'present',
                  'check_in_at': effectiveScanAtIso,
                  'updated_at': nowIso,
                },
              );
              if (updated == null) {
                return {
                  'ok': false,
                  'error': 'Check-in failed. Please try again.',
                  'status': 'error',
                };
              }
              return successResponse();
            }
            return alreadyRecordedResponse();
          }

          if (dryRun) {
            return successResponse();
          }

          final eventId = (session['event_id']?.toString() ?? '').trim();
          if (eventId.isEmpty || !MobileBackendService.isConfigured) {
            return {
              'ok': false,
              'error': 'Check-in requires a secure backend connection.',
              'status': 'error',
            };
          }
          final updated = await _secureAttendanceWrite(
            eventId: eventId,
            table: 'event_session_attendance',
            method: 'PATCH',
            filter: 'id=eq.${attendance['id']}',
            payload: {
              'status': 'present',
              'check_in_at': effectiveScanAtIso,
              'last_scanned_by': teacherId,
              'last_scanned_at': effectiveScanAtIso,
              'updated_at': nowIso,
            },
          );
          if (updated == null) {
            return {
              'ok': false,
              'error': 'Check-in failed. Please try again.',
              'status': 'error',
            };
          }
          return successResponse();
        }

        if (dryRun) {
          return successResponse();
        }

        final eventId = (session['event_id']?.toString() ?? '').trim();
        if (eventId.isEmpty || !MobileBackendService.isConfigured) {
          return {
            'ok': false,
            'error': 'Check-in requires a secure backend connection.',
            'status': 'error',
          };
        }
        final inserted = await _secureAttendanceWrite(
          eventId: eventId,
          table: 'event_session_attendance',
          method: 'POST',
          payload: {
            'session_id': sessionId,
            'registration_id': registrationId,
            'ticket_id': ticketId,
            'status': 'present',
            'check_in_at': effectiveScanAtIso,
            'last_scanned_by': teacherId,
            'last_scanned_at': effectiveScanAtIso,
            'updated_at': nowIso,
          },
        );
        if (inserted == null) {
          return {
            'ok': false,
            'error': 'Check-in failed. Please try again.',
            'status': 'error',
          };
        }
        return successResponse();
      } catch (e) {
        if (_isEventSessionAttendanceUnavailableError(e) ||
            _isAccessPolicyError(e)) {
          // Fall through to fail-closed message below.
        } else {
          rethrow;
        }
      }
    }

    // No attendance.session_id in production — do not probe (42703 ERROR).
    return {
      'ok': false,
      'error':
          'Seminar attendance storage is not available yet. Please apply the latest seminar attendance migration first.',
      'status': 'error',
    };
  }

  List<Map<String, dynamic>> _normalizeEventSessions(
    List<Map<String, dynamic>> rows,
    String eventId,
  ) {
    final normalized = <Map<String, dynamic>>[];

    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final startAt = row['start_at']?.toString().trim() ?? '';
      if (startAt.isEmpty) continue;

      var endAt = row['end_at']?.toString().trim() ?? '';
      if (endAt.isEmpty) {
        final parsedStart = _toUtcDate(startAt);
        endAt = parsedStart != null
            ? parsedStart.add(const Duration(hours: 1)).toIso8601String()
            : startAt;
      }

      final topic = row['topic']?.toString().trim();
      final rawTitle = row['title']?.toString().trim() ?? '';
      final sessionNo =
          int.tryParse(row['session_no']?.toString() ?? '') ?? (index + 1);
      final sortOrder =
          int.tryParse(row['sort_order']?.toString() ?? '') ?? (sessionNo - 1);

      normalized.add({
        'id': row['id']?.toString() ?? '',
        'event_id': row['event_id']?.toString() ?? eventId,
        'title': rawTitle.isNotEmpty
            ? rawTitle
            : (topic?.isNotEmpty == true ? topic : 'Seminar $sessionNo'),
        'topic': topic,
        'description': row['description']?.toString(),
        'location': row['location']?.toString(),
        'start_at': startAt,
        'end_at': endAt,
        'scan_window_minutes': _sessionWindowMinutes(row),
        'sort_order': sortOrder < 0 ? index : sortOrder,
        'session_no': sessionNo <= 0 ? (index + 1) : sessionNo,
        // Required for Early Out → time-out scanner open on seminar events.
        'early_out_enabled_at': row['early_out_enabled_at'],
      });
    }

    normalized.sort((a, b) {
      final sortA = int.tryParse(a['sort_order']?.toString() ?? '') ?? 0;
      final sortB = int.tryParse(b['sort_order']?.toString() ?? '') ?? 0;
      final compare = sortA.compareTo(sortB);
      if (compare != 0) return compare;
      return (a['start_at']?.toString() ?? '').compareTo(
        b['start_at']?.toString() ?? '',
      );
    });

    return normalized;
  }

  bool usesEventSessions(Map<String, dynamic> event) =>
      _eventUsesSessions(event);

  String getSessionDisplayName(Map<String, dynamic> session) =>
      _sessionDisplayName(session);

  Future<List<Map<String, dynamic>>> getEventSessions(
    String eventId, {
    bool forceFresh = false,
  }) async {
    if (eventId.trim().isEmpty) return [];
    final key = 'event_sessions:$eventId';
    final cached = await _appCache.fetchOnce<List<Map<String, dynamic>>>(
      key,
      () async => _fetchSessionsForEvent(eventId),
      ttl: _eventSessionsTtl,
      forceFresh: forceFresh,
    );
    return List<Map<String, dynamic>>.from(cached);
  }

  DateTime? _effectiveEventEndAt(
    Map<String, dynamic> event, [
    List<Map<String, dynamic>> sessions = const [],
  ]) {
    DateTime? effectiveEnd =
        _toUtcDate(event['end_at']) ?? _toUtcDate(event['start_at']);

    if (!_eventUsesSessions(event) && sessions.isEmpty) {
      return effectiveEnd;
    }

    for (final session in sessions) {
      final sessionEnd =
          _toUtcDate(session['end_at']) ?? _toUtcDate(session['start_at']);
      if (sessionEnd == null) continue;
      if (effectiveEnd == null || sessionEnd.isAfter(effectiveEnd)) {
        effectiveEnd = sessionEnd;
      }
    }

    return effectiveEnd;
  }

  Future<List<Map<String, dynamic>>> _enrichParticipantsWithSeminarAttendance(
    String eventId,
    List<Map<String, dynamic>> participants,
  ) async {
    if (participants.isEmpty) return participants;

    final sessions = await _fetchSessionsForEvent(eventId);
    if (sessions.isEmpty) {
      return participants
          .map(
            (p) => {...p, 'session_attendance': const <Map<String, dynamic>>[]},
          )
          .toList();
    }

    final sessionById = <String, Map<String, dynamic>>{};
    for (final session in sessions) {
      final sessionId = session['id']?.toString() ?? '';
      if (sessionId.isNotEmpty) {
        sessionById[sessionId] = session;
      }
    }

    final ticketIds = <String>{};
    final registrationIds = <String>{};
    final ticketToRegistration = <String, String>{};
    final nestedAttendanceRows = <Map<String, dynamic>>[];

    for (final participant in participants) {
      final registrationId = participant['id']?.toString() ?? '';
      if (registrationId.isNotEmpty) {
        registrationIds.add(registrationId);
      }

      final tickets = participant['tickets'];
      if (tickets is List) {
        for (final rawTicket in tickets) {
          if (rawTicket is! Map) continue;
          final ticket = Map<String, dynamic>.from(rawTicket);
          final ticketId = ticket['id']?.toString() ?? '';
          if (ticketId.isEmpty) continue;
          ticketIds.add(ticketId);
          if (registrationId.isNotEmpty) {
            ticketToRegistration[ticketId] = registrationId;
          }

          final nestedAttendance = ticket['attendance'];
          if (nestedAttendance is List) {
            for (final rawAttendance in nestedAttendance) {
              if (rawAttendance is! Map) continue;
              final attendanceItem = Map<String, dynamic>.from(rawAttendance);
              if ((attendanceItem['ticket_id']?.toString().trim().isEmpty ??
                  true)) {
                attendanceItem['ticket_id'] = ticketId;
              }
              if ((attendanceItem['registration_id']
                          ?.toString()
                          .trim()
                          .isEmpty ??
                      true) &&
                  registrationId.isNotEmpty) {
                attendanceItem['registration_id'] = registrationId;
              }
              nestedAttendanceRows.add(attendanceItem);
            }
          }
        }
      }
    }

    final rowsByTicket = <String, List<Map<String, dynamic>>>{};
    final rowsByRegistration = <String, List<Map<String, dynamic>>>{};

    void putDedupe(
      Map<String, List<Map<String, dynamic>>> bucket,
      String key,
      Map<String, dynamic> item,
    ) {
      if (key.trim().isEmpty) return;
      final list = bucket.putIfAbsent(key, () => <Map<String, dynamic>>[]);
      final sessionId = item['session_id']?.toString() ?? '';
      final idx = list.indexWhere(
        (row) => (row['session_id']?.toString() ?? '') == sessionId,
      );
      if (idx < 0) {
        list.add(item);
        return;
      }

      final existing = list[idx];
      final newIsPresent = _attendanceRecordCountsAsPresent(item);
      final oldIsPresent = _attendanceRecordCountsAsPresent(existing);
      if (newIsPresent && !oldIsPresent) {
        list[idx] = item;
        return;
      }
      if (!newIsPresent && oldIsPresent) {
        return;
      }

      final existingCheckIn = existing['check_in_at']?.toString() ?? '';
      final newCheckIn = item['check_in_at']?.toString() ?? '';
      if (existingCheckIn.trim().isEmpty && newCheckIn.trim().isNotEmpty) {
        list[idx] = item;
      }
    }

    Map<String, dynamic>? normalizeAttendanceItem(Map<String, dynamic> raw) {
      final sessionId = raw['session_id']?.toString() ?? '';
      if (sessionId.isEmpty) return null;
      final session = sessionById[sessionId];
      if (session == null) return null;
      return {
        ...raw,
        'session_no': session['session_no'],
        'title': session['title'],
        'display_name': session['display_name'],
        'start_at': session['start_at'],
      };
    }

    for (final raw in nestedAttendanceRows) {
      final item = normalizeAttendanceItem(raw);
      if (item == null) continue;

      final ticketId = item['ticket_id']?.toString() ?? '';
      final registrationId = item['registration_id']?.toString() ?? '';
      if (ticketId.isNotEmpty) {
        putDedupe(rowsByTicket, ticketId, item);
      }
      if (registrationId.isNotEmpty) {
        putDedupe(rowsByRegistration, registrationId, item);
      }
    }

    // Primary fetch path: read-only RPC snapshot per event (aligned with web data).
    // This avoids client-side table support/permission drift while keeping app fetch-only.
    try {
      final rpcRows = await _supabase.rpc(
        'get_event_session_attendance_snapshot',
        params: {'p_event_id': eventId},
      );
      for (final raw in List<Map<String, dynamic>>.from(rpcRows)) {
        final item = normalizeAttendanceItem(raw);
        if (item == null) continue;

        final ticketId = item['ticket_id']?.toString() ?? '';
        final registrationId = item['registration_id']?.toString() ?? '';
        if (ticketId.isNotEmpty) {
          putDedupe(rowsByTicket, ticketId, item);
        }
        if (registrationId.isNotEmpty) {
          putDedupe(rowsByRegistration, registrationId, item);
        }
      }
    } catch (_) {
      // Fallback to direct table query for older deployments without RPC.
      try {
        dynamic query = _supabase
            .from('event_session_attendance')
            .select(
              'session_id,ticket_id,registration_id,status,check_in_at,last_scanned_at',
            );

        if (registrationIds.isNotEmpty) {
          query = query.inFilter('registration_id', registrationIds.toList());
        } else if (ticketIds.isNotEmpty) {
          query = query.inFilter('ticket_id', ticketIds.toList());
        } else {
          query = query.limit(0);
        }

        final rows = await query;
        for (final raw in List<Map<String, dynamic>>.from(rows)) {
          final item = normalizeAttendanceItem(raw);
          if (item == null) continue;

          final ticketId = item['ticket_id']?.toString() ?? '';
          final registrationId = item['registration_id']?.toString() ?? '';
          if (ticketId.isNotEmpty) {
            putDedupe(rowsByTicket, ticketId, item);
          }
          if (registrationId.isNotEmpty) {
            putDedupe(rowsByRegistration, registrationId, item);
          }
        }
      } catch (_) {}
    }

    if (ticketIds.isNotEmpty && await _supportsAttendanceColumn('session_id')) {
      try {
        final rows = await _supabase
            .from('attendance')
            .select('ticket_id,session_id,status,check_in_at,last_scanned_at')
            .inFilter('ticket_id', ticketIds.toList());

        for (final raw in List<Map<String, dynamic>>.from(rows)) {
          final ticketId = raw['ticket_id']?.toString() ?? '';
          if (ticketId.isEmpty) continue;
          final item = normalizeAttendanceItem({
            ...raw,
            'registration_id': ticketToRegistration[ticketId] ?? '',
          });
          if (item == null) continue;
          putDedupe(rowsByTicket, ticketId, item);
          final registrationId = item['registration_id']?.toString() ?? '';
          if (registrationId.isNotEmpty) {
            putDedupe(rowsByRegistration, registrationId, item);
          }
        }
      } catch (_) {}
    }

    return participants.map((participant) {
      final registrationId = participant['id']?.toString() ?? '';
      final combined = <Map<String, dynamic>>[];

      if (registrationId.isNotEmpty &&
          rowsByRegistration.containsKey(registrationId)) {
        combined.addAll(
          List<Map<String, dynamic>>.from(
            rowsByRegistration[registrationId] ??
                const <Map<String, dynamic>>[],
          ),
        );
      }

      final tickets = participant['tickets'];
      if (tickets is List) {
        for (final rawTicket in tickets) {
          if (rawTicket is! Map) continue;
          final ticket = Map<String, dynamic>.from(rawTicket);
          final ticketId = ticket['id']?.toString() ?? '';
          if (ticketId.isEmpty) continue;
          combined.addAll(
            List<Map<String, dynamic>>.from(
              rowsByTicket[ticketId] ?? const <Map<String, dynamic>>[],
            ),
          );
        }
      }

      final dedupedBySession = <String, Map<String, dynamic>>{};
      for (final item in combined) {
        final sessionId = item['session_id']?.toString() ?? '';
        if (sessionId.isEmpty) continue;
        final existing = dedupedBySession[sessionId];
        if (existing == null) {
          dedupedBySession[sessionId] = item;
          continue;
        }
        final newIsPresent = _attendanceRecordCountsAsPresent(item);
        final oldIsPresent = _attendanceRecordCountsAsPresent(existing);
        if (newIsPresent && !oldIsPresent) {
          dedupedBySession[sessionId] = item;
        } else if (newIsPresent == oldIsPresent) {
          final oldCheckIn = existing['check_in_at']?.toString() ?? '';
          final newCheckIn = item['check_in_at']?.toString() ?? '';
          if (oldCheckIn.trim().isEmpty && newCheckIn.trim().isNotEmpty) {
            dedupedBySession[sessionId] = item;
          }
        }
      }

      final sessionAttendance = dedupedBySession.values.toList()
        ..sort((a, b) {
          final aNo = int.tryParse(a['session_no']?.toString() ?? '') ?? 999;
          final bNo = int.tryParse(b['session_no']?.toString() ?? '') ?? 999;
          if (aNo != bNo) return aNo.compareTo(bNo);
          final aStart = a['start_at']?.toString() ?? '';
          final bStart = b['start_at']?.toString() ?? '';
          return aStart.compareTo(bStart);
        });

      return {...participant, 'session_attendance': sessionAttendance};
    }).toList();
  }

  Future<List<Map<String, dynamic>>> _fetchSessionsForEvent(
    String eventId,
  ) async {
    try {
      final supportedColumns = await _eventSessionsSupportedColumns();
      return await _queryEventSessions(eventId, supportedColumns);
    } catch (_) {
      // One-shot fallback if a preferred column is missing — mark extras false.
      for (final column in _eventSessionPreferredColumns) {
        if (!_eventSessionBaseColumns.contains(column)) {
          _eventSessionColumnSupport[column] = false;
        }
      }
      try {
        return await _queryEventSessions(eventId, _eventSessionBaseColumns);
      } catch (_) {
        return [];
      }
    }
  }

  String _manilaClockLabel(DateTime utc) {
    final local = utc.toUtc().add(_manilaOffset);
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  bool _sameManilaDay(DateTime aUtc, DateTime bUtc) {
    final a = aUtc.toUtc().add(_manilaOffset);
    final b = bUtc.toUtc().add(_manilaOffset);
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Map<String, dynamic> _resolveEventWindowContext(
    Map<String, dynamic> eventSummary,
    dynamic startRaw,
    dynamic endRaw,
    DateTime nowUtc, {
    String source = 'event',
    String missingMessage = 'Event start time is missing.',
    String waitingMessage = 'Waiting for event scan window.',
    String openMessage = 'Event scanning is open.',
    String closedMessage = 'Event scan window has closed.',
    dynamic earlyOutEnabledAt,
  }) {
    final startAt = _toUtcDate(startRaw);
    if (startAt == null) {
      return {
        'status': 'missing_schedule',
        'source': source,
        'event': eventSummary,
        'session': null,
        'opens_at': null,
        'closes_at': null,
        'window_minutes': 30,
        'message': missingMessage,
      };
    }

    final windowMinutes =
        int.tryParse(eventSummary['grace_time']?.toString() ?? '') ?? 30;
    var closesAt = startAt.add(Duration(minutes: windowMinutes));
    final endAt = _toUtcDate(endRaw);
    if (endAt != null && endAt.isBefore(closesAt)) {
      closesAt = endAt;
    }
    if (nowUtc.isBefore(startAt)) {
      final earlyMessage = waitingMessage == 'Waiting for event scan window.'
          ? (_sameManilaDay(nowUtc, startAt)
              ? 'Too early to time in. Wait for the scheduled start (${_manilaClockLabel(startAt)}).'
              : 'Too early to time in. Wait for the scheduled start.')
          : waitingMessage;
      return {
        'status': 'waiting',
        'source': 'event',
        'event': eventSummary,
        'session': null,
        'opens_at': startAt.toIso8601String(),
        'closes_at': closesAt.toIso8601String(),
        'window_minutes': windowMinutes,
        'message': earlyMessage,
      };
    }

    if (!nowUtc.isAfter(closesAt)) {
      final openLabel = openMessage == 'Event scanning is open.'
          ? 'Time-in is open until ${_manilaClockLabel(closesAt)}.'
          : openMessage;
      return {
        'status': 'open',
        'source': source,
        'event': eventSummary,
        'session': null,
        'opens_at': startAt.toIso8601String(),
        'closes_at': closesAt.toIso8601String(),
        'window_minutes': windowMinutes,
        'scan_mode': 'check_in',
        'message': openLabel,
      };
    }

    // Time-in grace ended — keep scanner open for Early Out / end+1h time-out.
    final checkOutOpen = _resolveCheckOutScanOpen(
      eventSummary: eventSummary,
      endRaw: endRaw ?? eventSummary['end_at'],
      earlyOutEnabledAt: earlyOutEnabledAt ?? eventSummary['early_out_enabled_at'],
      nowUtc: nowUtc,
      source: source,
      session: null,
    );
    if (checkOutOpen != null) {
      return checkOutOpen;
    }

    final resolvedEnd = _toUtcDate(endRaw ?? eventSummary['end_at']);
    final earlyOutRaw = earlyOutEnabledAt ?? eventSummary['early_out_enabled_at'];
    if (_toUtcDate(earlyOutRaw) == null &&
        resolvedEnd != null &&
        nowUtc.isBefore(resolvedEnd)) {
      return {
        'status': 'closed',
        'source': source,
        'event': eventSummary,
        'session': null,
        'opens_at': resolvedEnd.toIso8601String(),
        'closes_at': resolvedEnd.add(const Duration(hours: 1)).toIso8601String(),
        'window_minutes': windowMinutes,
        'scan_mode': 'check_out',
        'message':
            'Too early to time out. Early Out is not enabled — time-out opens at the scheduled end ('
            '${_manilaClockLabel(resolvedEnd)}).',
      };
    }

    final graceClosedMessage =
        closedMessage == 'Event scan window has closed.'
            ? 'Time-in grace ended at ${_manilaClockLabel(closesAt)}. You can no longer time in for this schedule.'
            : closedMessage;
    return {
      'status': 'closed',
      'source': source,
      'event': eventSummary,
      'session': null,
      'opens_at': startAt.toIso8601String(),
      'closes_at': closesAt.toIso8601String(),
      'window_minutes': windowMinutes,
      'message': graceClosedMessage,
    };
  }

  /// Opens teacher/assistant scanner for time-out when Early Out is ON
  /// (enabled_at → +1h, independent of event end_at), or during the normal
  /// end_at → end_at+1h window when Early Out was never triggered.
  Map<String, dynamic>? _resolveCheckOutScanOpen({
    required Map<String, dynamic> eventSummary,
    required dynamic endRaw,
    required dynamic earlyOutEnabledAt,
    required DateTime nowUtc,
    required String source,
    Map<String, dynamic>? session,
  }) {
    final enabledAt = _toUtcDate(earlyOutEnabledAt);
    if (enabledAt != null) {
      final expiresAt = enabledAt.add(const Duration(hours: 1));
      if (!nowUtc.isBefore(enabledAt) && !nowUtc.isAfter(expiresAt)) {
        return {
          'status': 'open',
          'source': source,
          'event': eventSummary,
          'session': session,
          'opens_at': enabledAt.toIso8601String(),
          'closes_at': expiresAt.toIso8601String(),
          'window_minutes': 60,
          'scan_mode': 'check_out',
          'early_out': true,
          'message': 'Early time-out is open. Scan tickets to time out.',
        };
      }
      // Early Out was used — do not also open the normal end_at window.
      return null;
    }

    final endAt = _toUtcDate(endRaw);
    if (endAt == null) return null;
    final closesAt = endAt.add(const Duration(hours: 1));
    if (nowUtc.isBefore(endAt) || nowUtc.isAfter(closesAt)) {
      return null;
    }
    return {
      'status': 'open',
      'source': source,
      'event': eventSummary,
      'session': session,
      'opens_at': endAt.toIso8601String(),
      'closes_at': closesAt.toIso8601String(),
      'window_minutes': 60,
      'scan_mode': 'check_out',
      'message': 'Time-out is open. Scan tickets to time out.',
    };
  }

  Future<Map<String, dynamic>> _resolveSingleEventScanContext(
    Map<String, dynamic> event,
    DateTime nowUtc,
  ) async {
    final eventId = event['id']?.toString() ?? '';
    final eventSummary = {
      'id': eventId,
      'title': event['title']?.toString() ?? 'Event',
      'location': event['location']?.toString() ?? '',
      'start_at': event['start_at']?.toString() ?? '',
      'end_at': event['end_at']?.toString() ?? '',
      'grace_time': event['grace_time'],
      'early_out_enabled_at': event['early_out_enabled_at'],
    };

    if (eventId.isEmpty) {
      return {
        'status': 'missing_schedule',
        'source': 'event',
        'event': eventSummary,
        'session': null,
        'opens_at': null,
        'closes_at': null,
        'window_minutes': 30,
        'message': 'Event ID is missing.',
      };
    }

    final sessionsRaw = await _fetchSessionsForEvent(eventId);
    final sessions = _sessionsWithEarlyOutMerged(sessionsRaw, event);
    final shouldUseSessions = _eventUsesSessions(event) || sessions.isNotEmpty;

    if (shouldUseSessions) {
      if (sessions.isEmpty) {
        return _resolveEventWindowContext(
          eventSummary,
          event['start_at'],
          event['end_at'],
          nowUtc,
          missingMessage: 'No seminar schedule found for this event.',
          waitingMessage: 'Waiting for event scan window.',
          openMessage: 'Scanning is open for this event.',
          closedMessage: 'Event scan window has closed.',
        );
      }

      final open = <Map<String, dynamic>>[];
      final waiting = <Map<String, dynamic>>[];
      final closed = <Map<String, dynamic>>[];

      for (final session in sessions) {
        final startAt = _toUtcDate(session['start_at']);
        if (startAt == null) continue;

        final windowMinutes = _sessionWindowMinutes(session);
        var closesAt = startAt.add(Duration(minutes: windowMinutes));
        final sessionEndAt = _toUtcDate(session['end_at']);
        if (sessionEndAt != null && sessionEndAt.isBefore(closesAt)) {
          closesAt = sessionEndAt;
        }
        final payload = {
          'session': session,
          'opens_at': startAt.toIso8601String(),
          'closes_at': closesAt.toIso8601String(),
          'window_minutes': windowMinutes,
        };

        if (nowUtc.isBefore(startAt)) {
          waiting.add(payload);
        } else if (nowUtc.isAfter(closesAt)) {
          closed.add(payload);
        } else {
          open.add(payload);
        }
      }

      // Early Out / end+1h time-out on ANY seminar must open the scanner
      // (do not only look at the latest closed seminar).
      final anyCheckOutOpen = _findOpenSessionCheckOut(
        eventSummary: eventSummary,
        sessions: closed.map((c) => Map<String, dynamic>.from(c['session'] as Map)).toList(),
        nowUtc: nowUtc,
      );
      // Also allow Early Out while that seminar's check-in row is still classified
      // oddly — scan all sessions that have an early_out stamp.
      final eoSessions = sessions
          .where((s) => (s['early_out_enabled_at']?.toString() ?? '').trim().isNotEmpty)
          .toList();
      final eoCheckOutOpen = eoSessions.isEmpty
          ? null
          : _findOpenSessionCheckOut(
              eventSummary: eventSummary,
              sessions: eoSessions,
              nowUtc: nowUtc,
            );
      final preferCheckOut = eoCheckOutOpen ?? anyCheckOutOpen;

      if (open.length > 1) {
        return {
          'status': 'conflict',
          'source': 'session',
          'event': eventSummary,
          'session': null,
          'opens_at': null,
          'closes_at': null,
          'window_minutes': null,
          'message':
              'Multiple seminars are open right now. Ask admin to fix overlap.',
        };
      }

      // Prefer Early Out checkout when active — even if another seminar's
      // time-in window overlaps (should be rare with normal schedules).
      if (preferCheckOut != null && preferCheckOut['early_out'] == true) {
        return preferCheckOut;
      }

      if (open.length == 1) {
        final item = open.first;
        final session = Map<String, dynamic>.from(item['session']);
        return {
          'status': 'open',
          'source': 'session',
          'event': eventSummary,
          'session': {
            'id': session['id']?.toString() ?? '',
            'title': session['title']?.toString() ?? '',
            'topic': session['topic']?.toString() ?? '',
            'display_name': _sessionDisplayName(session),
            'start_at': session['start_at']?.toString() ?? '',
            'end_at': session['end_at']?.toString() ?? '',
            'scan_window_minutes': item['window_minutes'],
            'early_out_enabled_at': session['early_out_enabled_at'],
          },
          'opens_at': item['opens_at'],
          'closes_at': item['closes_at'],
          'window_minutes': item['window_minutes'],
          'scan_mode': 'check_in',
          'message': 'Seminar scanning is open.',
        };
      }

      if (preferCheckOut != null) {
        return preferCheckOut;
      }

      // Gap between seminars: do NOT sync absences on every context poll.
      // That RPC was revoked for anon and was flooding API Gateway + ERROR %.
      if (waiting.isNotEmpty) {
        final lastSync = _absenceSyncAttemptedAtUtc[eventId];
        final nowForSync = DateTime.now().toUtc();
        final shouldSync = lastSync == null ||
            nowForSync.difference(lastSync) >= _absenceSyncCooldown;
        if (shouldSync && MobileBackendService.isConfigured) {
          _absenceSyncAttemptedAtUtc[eventId] = nowForSync;
          try {
            await _mobileBackend.secureWrite('sync_closed_session_absences', {
              'event_id': eventId,
            });
          } catch (e) {
            debugPrint('[scanContext] sync_closed_session_absences failed: $e');
          }
        }

        waiting.sort(
          (a, b) => (a['opens_at']?.toString() ?? '').compareTo(
            b['opens_at']?.toString() ?? '',
          ),
        );
        final item = waiting.first;
        final session = Map<String, dynamic>.from(item['session']);

        return {
          'status': 'waiting',
          'source': 'session',
          'event': eventSummary,
          'session': {
            'id': session['id']?.toString() ?? '',
            'title': session['title']?.toString() ?? '',
            'topic': session['topic']?.toString() ?? '',
            'display_name': _sessionDisplayName(session),
            'start_at': session['start_at']?.toString() ?? '',
            'end_at': session['end_at']?.toString() ?? '',
            'scan_window_minutes': item['window_minutes'],
          },
          'opens_at': item['opens_at'],
          'closes_at': item['closes_at'],
          'window_minutes': item['window_minutes'],
          'message': 'Waiting for seminar scan window.',
        };
      }

      if (open.isEmpty && waiting.isEmpty && closed.isEmpty) {
        return _resolveEventWindowContext(
          eventSummary,
          event['start_at'],
          event['end_at'],
          nowUtc,
          missingMessage: 'Seminar schedule is unavailable for this event.',
          waitingMessage: 'Waiting for event scan window.',
          openMessage: 'Scanning is open for this event.',
          closedMessage: 'Event scan window has closed.',
          earlyOutEnabledAt: event['early_out_enabled_at'],
        );
      }

      closed.sort(
        (a, b) => (b['closes_at']?.toString() ?? '').compareTo(
          a['closes_at']?.toString() ?? '',
        ),
      );
      final last = closed.isNotEmpty ? closed.first : null;
      final session = last != null
          ? Map<String, dynamic>.from(last['session'] as Map<String, dynamic>)
          : <String, dynamic>{};
      final sessionSummary = last == null
          ? null
          : {
              'id': session['id']?.toString() ?? '',
              'title': session['title']?.toString() ?? '',
              'topic': session['topic']?.toString() ?? '',
              'display_name': _sessionDisplayName(session),
              'start_at': session['start_at']?.toString() ?? '',
              'end_at': session['end_at']?.toString() ?? '',
              'scan_window_minutes': last['window_minutes'],
              'early_out_enabled_at': session['early_out_enabled_at'],
            };
      return {
        'status': 'closed',
        'source': 'session',
        'event': eventSummary,
        'session': sessionSummary,
        'opens_at': last?['opens_at'],
        'closes_at': last?['closes_at'],
        'window_minutes': last?['window_minutes'] ?? 30,
        'scan_mode': 'check_out',
        'message':
            'Too early to time out. Early Out is not enabled — time-out opens at the scheduled end.',
      };
    }

    return _resolveEventWindowContext(
      eventSummary,
      event['start_at'],
      event['end_at'],
      nowUtc,
      earlyOutEnabledAt: event['early_out_enabled_at'],
    );
  }

  String _normalizeEventTargetCourse(String? rawCourse) {
    final normalized = (rawCourse ?? '').trim().toUpperCase();
    if (normalized.isEmpty) return 'ALL';

    final compact = normalized.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (compact == 'BSITSD') return 'BSIT-SD';
    if (compact == 'BSITBA') return 'BSIT-BA';
    if (normalized == 'BSIT-SD' || normalized == 'BSIT_SD') return 'BSIT-SD';
    if (normalized == 'BSIT-BA' || normalized == 'BSIT_BA') return 'BSIT-BA';
    if (compact == 'BSIT' || compact == 'IT') return 'BSIT';
    if (compact == 'BSCS' || compact == 'CS') return 'BSCS';
    if (compact == 'ALL' ||
        compact == 'NONE' ||
        compact == 'ALLLEVELS' ||
        compact == 'ALLYEARLEVEL' ||
        compact == 'ALLYEARLEVELS' ||
        compact == 'ALLCOURSES') {
      return 'ALL';
    }

    return compact;
  }

  String _normalizeStudentCourse(String? rawCourse) {
    final normalized = (rawCourse ?? '').trim().toUpperCase();
    if (normalized.isEmpty) return 'ALL';

    final compact = normalized.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (compact.isEmpty) return 'ALL';
    if (compact == 'ALL' ||
        compact == 'NONE' ||
        compact == 'ALLLEVELS' ||
        compact == 'ALLYEARLEVEL' ||
        compact == 'ALLYEARLEVELS' ||
        compact == 'ALLCOURSES') {
      return 'ALL';
    }

    if (compact == 'BSIT' || compact == 'IT' || compact.contains('BSIT')) {
      return 'BSIT';
    }
    if (compact == 'BSCS' || compact == 'CS' || compact.contains('BSCS')) {
      return 'BSCS';
    }

    return compact;
  }

  String _extractStudentSpecialization(String? sectionName) {
    final name = (sectionName ?? '').trim().toUpperCase();
    if (name.isEmpty) return '';
    if (RegExp(r'\bBSIT\s*[-_]?\s*SD\b').hasMatch(name)) return 'SD';
    if (RegExp(r'\bBSIT\s*[-_]?\s*BA\b').hasMatch(name)) return 'BA';
    return '';
  }

  bool _studentCourseMatchesTarget({
    required String studentCourse,
    required String studentSpec,
    required String targetCourse,
  }) {
    final target = _normalizeEventTargetCourse(targetCourse);
    if (target == 'ALL') return true;
    if (target == 'BSIT-SD') {
      return studentCourse == 'BSIT' && studentSpec == 'SD';
    }
    if (target == 'BSIT-BA') {
      return studentCourse == 'BSIT' && studentSpec == 'BA';
    }
    if (target == 'BSIT') return studentCourse == 'BSIT';
    if (target == 'BSCS') return studentCourse == 'BSCS';
    return studentCourse.isNotEmpty && studentCourse == target;
  }

  String _normalizeTargetCourse(String? rawCourse) {
    return _normalizeStudentCourse(rawCourse);
  }

  String _normalizeTargetYear(String? rawYear) {
    final normalized = (rawYear ?? '').trim();
    if (['1', '2', '3', '4'].contains(normalized)) return normalized;
    return 'ALL';
  }

  Map<String, dynamic> _decodeEventTarget(dynamic rawTarget) {
    final raw = (rawTarget?.toString() ?? '').trim().toUpperCase();
    if (raw.isEmpty ||
        raw == 'ALL' ||
        raw == 'NONE' ||
        raw == 'ALL LEVELS' ||
        raw == 'ALL YEAR LEVEL' ||
        raw == 'ALL YEAR LEVELS' ||
        raw == 'ALL COURSES') {
      return {
        'course': 'ALL',
        'years': const <String>['ALL'],
      };
    }

    final multi = RegExp(
      r'^COURSE\s*=\s*(ALL|BSIT-SD|BSIT-BA|BSIT|BSCS)\s*;\s*YEARS\s*=\s*([0-9,\sA-Z]+)$',
    ).firstMatch(raw);
    if (multi != null) {
      final course = _normalizeEventTargetCourse(multi.group(1));
      final yearsRaw = (multi.group(2) ?? '')
          .split(',')
          .map((e) => e.trim().toUpperCase())
          .where((e) => ['ALL', '1', '2', '3', '4'].contains(e))
          .toList();
      final years = yearsRaw.contains('ALL') || yearsRaw.isEmpty
          ? const <String>['ALL']
          : yearsRaw.toSet().toList();
      return {'course': course, 'years': years};
    }

    final pair = RegExp(r'^(BSIT|BSCS)\s*[-_|]\s*([1-4])$').firstMatch(raw);
    if (pair != null) {
      return {
        'course': _normalizeStudentCourse(pair.group(1)),
        'years': <String>[pair.group(2) ?? 'ALL'],
      };
    }

    if (['1', '2', '3', '4'].contains(raw)) {
      return {
        'course': 'ALL',
        'years': <String>[raw],
      };
    }

    return {
      'course': _normalizeEventTargetCourse(raw),
      'years': const <String>['ALL'],
    };
  }

  bool _matchesEventTarget(
    Map<String, dynamic> event, {
    String? yearLevel,
    String? courseCode,
    String? specialization,
  }) {
    final target = _decodeEventTarget(event['event_for']);
    final targetCourse = (target['course'] as String?) ?? 'ALL';
    final targetYears = ((target['years'] as List?) ?? const <String>['ALL'])
        .map((e) => e.toString().trim().toUpperCase())
        .where((e) => e.isNotEmpty)
        .toList();

    final studentCourse = _normalizeStudentCourse(courseCode);
    final studentSpec = (specialization ?? '').trim().toUpperCase();
    final studentYear = _normalizeTargetYear(yearLevel);

    final courseMatches = _studentCourseMatchesTarget(
      studentCourse: studentCourse,
      studentSpec: studentSpec,
      targetCourse: targetCourse,
    );
    final yearMatches = (targetYears.length == 1 && targetYears.first == 'ALL')
        ? true
        : (studentYear != 'ALL' && targetYears.contains(studentYear));

    return courseMatches && yearMatches;
  }

  String _normalizeStudentYearFromRaw(dynamic rawYear) {
    final raw = (rawYear?.toString() ?? '').trim().toUpperCase();
    if (raw.isEmpty) return 'ALL';

    if (['1', '2', '3', '4'].contains(raw)) return raw;

    final digitMatch = RegExp(r'([1-4])').firstMatch(raw);
    if (digitMatch != null) {
      return digitMatch.group(1) ?? 'ALL';
    }

    if (raw.startsWith('FIRST')) return '1';
    if (raw.startsWith('SECOND')) return '2';
    if (raw.startsWith('THIRD')) return '3';
    if (raw.startsWith('FOURTH')) return '4';

    return 'ALL';
  }

  Future<Map<String, String>> getStudentTargetScope(String userId) async {
    final trimmedUserId = userId.trim();
    if (trimmedUserId.isEmpty) {
      return {'courseCode': 'ALL', 'yearLevel': 'ALL', 'specialization': ''};
    }

    final cached = _studentTargetScopeCache[trimmedUserId];
    if (cached != null) return Map<String, String>.from(cached);

    String courseCode = 'ALL';
    String yearLevel = 'ALL';
    String specialization = '';
    String sectionId = '';

    // Never SELECT users via anon — table is locked (048). Use login prefs.
    try {
      final user = await AuthService().getCurrentUser();
      final prefsId = (user?['id']?.toString() ?? '').trim();
      if (prefsId.isEmpty || prefsId == trimmedUserId) {
        courseCode = _normalizeStudentCourse(user?['course']?.toString());
        yearLevel = _normalizeStudentYearFromRaw(user?['year_level']);
        sectionId = user?['section_id']?.toString().trim() ?? '';
        specialization =
            _extractStudentSpecialization(user?['course']?.toString());
      }
    } catch (_) {
      // Fall through with defaults / section lookup.
    }

    if (sectionId.isNotEmpty) {
      try {
        final rows = await _supabase
            .from('sections')
            .select('name')
            .eq('id', sectionId)
            .limit(1);
        if ((rows as List).isNotEmpty) {
          final sectionName = rows.first['name']?.toString() ?? '';
          if (courseCode == 'ALL') {
            courseCode = _normalizeStudentCourse(sectionName);
          }
          if (yearLevel == 'ALL') {
            yearLevel = _normalizeStudentYearFromRaw(sectionName);
          }
          final sectionSpec = _extractStudentSpecialization(sectionName);
          if (sectionSpec.isNotEmpty) {
            specialization = sectionSpec;
          }
        }
      } catch (_) {
        // Keep best-effort values.
      }
    }

    final scope = {
      'courseCode': courseCode,
      'yearLevel': yearLevel,
      'specialization': specialization,
    };
    _studentTargetScopeCache[trimmedUserId] = scope;
    return Map<String, String>.from(scope);
  }

  bool isStudentAllowedForEvent(
    Map<String, dynamic> event, {
    String? yearLevel,
    String? courseCode,
    String? specialization,
  }) {
    return _matchesEventTarget(
      event,
      yearLevel: yearLevel,
      courseCode: courseCode,
      specialization: specialization,
    );
  }

  // Helper to filter events by target participant scope (course + year + spec)
  List<Map<String, dynamic>> _filterByTargetParticipant(
    List<Map<String, dynamic>> events, {
    String? yearLevel,
    String? courseCode,
    String? specialization,
  }) {
    return events
        .where(
          (event) => _matchesEventTarget(
            event,
            yearLevel: yearLevel,
            courseCode: courseCode,
            specialization: specialization,
          ),
        )
        .toList();
  }

  static const Duration _minSecondsBeforeCheckout = Duration(seconds: 20);

  // Get all active/published events (ongoing + upcoming, not yet ended)
  Future<List<Map<String, dynamic>>> getActiveEvents({
    String? yearLevel,
    String? courseCode,
    String? specialization,
    bool forceFresh = false,
  }) async {
    final cacheKey =
        'active:v5:${yearLevel ?? ''}:${courseCode ?? ''}:${specialization ?? ''}';
    if (!forceFresh) {
      final cached = _readListCache(cacheKey, _activeEventsTtl);
      if (cached != null) {
        return cached;
      }

      final stale = _readListCache(
        cacheKey,
        _activeEventsTtl,
        allowStale: true,
      );
      if (stale != null && stale.isNotEmpty) {
        unawaited(
          _fetchActiveEvents(
            cacheKey,
            yearLevel: yearLevel,
            courseCode: courseCode,
            specialization: specialization,
          ),
        );
        return stale;
      }

      final diskCached = await _appCache.loadJsonList(cacheKey);
      if (diskCached.isNotEmpty) {
        _writeListCache(cacheKey, diskCached);
        unawaited(
          _fetchActiveEvents(
            cacheKey,
            yearLevel: yearLevel,
            courseCode: courseCode,
            specialization: specialization,
          ),
        );
        return diskCached;
      }
    }

    return _appCache.fetchOnce(
      'fetch:$cacheKey',
      () => _fetchActiveEvents(
        cacheKey,
        yearLevel: yearLevel,
        courseCode: courseCode,
        specialization: specialization,
        forceFresh: forceFresh,
      ),
      forceFresh: forceFresh,
    );
  }

  Future<List<Map<String, dynamic>>> _fetchActiveEvents(
    String cacheKey, {
    String? yearLevel,
    String? courseCode,
    String? specialization,
    bool forceFresh = false,
  }) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final offline = await isLikelyOffline();
      List<dynamic> response = [];

      // Online: Supabase is source of truth so deletes/archives clear lists.
      // Firestore catalog can lag and was re-writing deleted "test" events
      // back onto disk after a correct pull-to-refresh.
      if (!offline) {
        response = await _selectPublishedActiveEvents(now);
      } else if (!forceFresh) {
        try {
          final catalog =
              await PublicCatalogService.instance.loadIfRevisionChanged(
            limit: 120,
          );
          if (catalog == null) {
            final warm = _readListCache(cacheKey, _activeEventsTtl);
            if (warm != null && warm.isNotEmpty) {
              return warm;
            }
          } else if (catalog.isNotEmpty) {
            final nowDt = DateTime.now().toUtc();
            response = catalog.where((row) {
              final endRaw = (row['end_at'] ?? '').toString().trim();
              if (endRaw.isEmpty) return true;
              try {
                return DateTime.parse(endRaw).toUtc().isAfter(nowDt);
              } catch (_) {
                return true;
              }
            }).toList();
          }
        } catch (_) {
          response = [];
        }
      }

      if (response.isEmpty && !offline) {
        response = await _selectPublishedActiveEvents(now);
      }

      final list = List<Map<String, dynamic>>.from(response);
      final filtered = _filterByTargetParticipant(
        list,
        yearLevel: yearLevel,
        courseCode: courseCode,
        specialization: specialization,
      );

      // Never wipe a warm offline cache with an empty refresh while offline.
      var toStore = filtered;
      if (filtered.isEmpty && offline) {
        toStore = await _preferExistingCacheIfEmpty(cacheKey, filtered);
      }
      _writeListCache(cacheKey, toStore);
      await _appCache.saveJsonList(
        cacheKey,
        toStore,
        preserveNonEmptyOnEmpty: offline,
      );
      return toStore;
    } catch (e) {
      final stale = _readListCache(
        cacheKey,
        _activeEventsTtl,
        allowStale: true,
        staleTtl: const Duration(hours: 24),
      );
      if (stale != null && stale.isNotEmpty) {
        return stale;
      }
      final diskCached = await _appCache.loadJsonList(cacheKey);
      if (diskCached.isNotEmpty) {
        _writeListCache(cacheKey, diskCached);
      }
      return diskCached;
    }
  }

  Future<List<dynamic>> _selectPublishedActiveEvents(String nowUtc) async {
    try {
      return await _supabase
          .from('events')
          .select(_eventListColumns)
          .eq('status', 'published')
          .gte('end_at', nowUtc)
          .order('start_at', ascending: true);
    } catch (e) {
      debugPrint('EventService: active events fallback select: $e');
      try {
        return await _supabase
            .from('events')
            .select(_eventListColumnsFallback)
            .eq('status', 'published')
            .gte('end_at', nowUtc)
            .order('start_at', ascending: true);
      } catch (e2) {
        debugPrint('EventService: active events minimal select: $e2');
        return await _supabase
            .from('events')
            .select(_eventListColumnsMinimal)
            .eq('status', 'published')
            .gte('end_at', nowUtc)
            .order('start_at', ascending: true);
      }
    }
  }

  /// Calendar markers only: published + approved (ready to publish), not ended.
  /// Do not use this for Active/Upcoming lists — those stay published-only.
  Future<List<Map<String, dynamic>>> getCalendarEvents({
    String? yearLevel,
    String? courseCode,
    String? specialization,
    bool forceFresh = false,
  }) async {
    final cacheKey =
        'calendar:v1:${yearLevel ?? ''}:${courseCode ?? ''}:${specialization ?? ''}';
    if (!forceFresh) {
      final cached = _readListCache(cacheKey, _activeEventsTtl);
      if (cached != null) return cached;
    }

    return _appCache.fetchOnce(
      'fetch:$cacheKey',
      () => _fetchCalendarEvents(
        cacheKey,
        yearLevel: yearLevel,
        courseCode: courseCode,
        specialization: specialization,
      ),
      forceFresh: forceFresh,
    );
  }

  Future<List<Map<String, dynamic>>> _fetchCalendarEvents(
    String cacheKey, {
    String? yearLevel,
    String? courseCode,
    String? specialization,
  }) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      List<dynamic> response;
      try {
        response = await _supabase
            .from('events')
            .select(_eventListColumns)
            .inFilter('status', ['published', 'approved'])
            .gte('end_at', now)
            .order('start_at', ascending: true);
      } catch (_) {
        try {
          response = await _supabase
              .from('events')
              .select(_eventListColumnsFallback)
              .inFilter('status', ['published', 'approved'])
              .gte('end_at', now)
              .order('start_at', ascending: true);
        } catch (_) {
          response = await _supabase
              .from('events')
              .select(_eventListColumnsMinimal)
              .inFilter('status', ['published', 'approved'])
              .gte('end_at', now)
              .order('start_at', ascending: true);
        }
      }

      final list = List<Map<String, dynamic>>.from(response);
      final filtered = _filterByTargetParticipant(
        list,
        yearLevel: yearLevel,
        courseCode: courseCode,
        specialization: specialization,
      );
      _writeListCache(cacheKey, filtered);
      await _appCache.saveJsonList(cacheKey, filtered);
      return filtered;
    } catch (_) {
      final stale = _readListCache(
        cacheKey,
        _activeEventsTtl,
        allowStale: true,
        staleTtl: const Duration(hours: 24),
      );
      return stale ?? <Map<String, dynamic>>[];
    }
  }

  // Get expired events (already ended)
  Future<List<Map<String, dynamic>>> getExpiredEvents({
    String? yearLevel,
    String? courseCode,
    String? specialization,
  }) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final response = await _supabase
          .from('events')
          .select()
          .eq('status', 'published')
          .lt('end_at', now)
          .order('end_at', ascending: false);
      final list = List<Map<String, dynamic>>.from(response);
      return _filterByTargetParticipant(
        list,
        yearLevel: yearLevel,
        courseCode: courseCode,
        specialization: specialization,
      );
    } catch (e) {
      return [];
    }
  }

  // Get upcoming events (future events)
  Future<List<Map<String, dynamic>>> getUpcomingEvents({
    String? yearLevel,
    String? courseCode,
    String? specialization,
  }) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      // We don't use .limit(5) on the DB side if we filter in Dart,
      // because we might drop events and return fewer than 5.
      // Since it's upcoming, getting all and slicing after filter is safer.
      final response = await _supabase
          .from('events')
          .select()
          .eq('status', 'published')
          .gte('start_at', now)
          .order('start_at', ascending: true);
      final list = List<Map<String, dynamic>>.from(response);
      final filtered = _filterByTargetParticipant(
        list,
        yearLevel: yearLevel,
        courseCode: courseCode,
        specialization: specialization,
      );
      return filtered.take(5).toList();
    } catch (e) {
      return [];
    }
  }

  // Get event by ID
  Future<Map<String, dynamic>?> getEventById(
    String eventId, {
    bool forceFresh = false,
  }) async {
    final id = eventId.trim();
    if (id.isEmpty) return null;

    final key = 'event_by_id:$id';
    return _appCache.fetchOnce<Map<String, dynamic>?>(
      key,
      () async {
        try {
          final response = await _supabase
              .from('events')
              .select()
              .eq('id', id)
              .single();
          return Map<String, dynamic>.from(response);
        } catch (_) {
          return null;
        }
      },
      ttl: _eventByIdTtl,
      forceFresh: forceFresh,
    );
  }

  Future<Map<String, dynamic>?> getEventRegistrationSettings(
    String eventId, {
    bool forceFresh = false,
  }) async {
    final id = eventId.trim();
    if (id.isEmpty) return null;
    final key = 'event_reg_settings:$id';
    return _appCache.fetchOnce<Map<String, dynamic>?>(
      key,
      () => _fetchRegistrationEvent(id),
      ttl: _eventRegistrationSettingsTtl,
      forceFresh: forceFresh,
    );
  }

  Map<String, dynamic> mergeEventRegistrationSettings(
    Map<String, dynamic>? baseEvent,
    Map<String, dynamic>? registrationSettings,
  ) {
    final merged = <String, dynamic>{
      if (baseEvent != null) ...Map<String, dynamic>.from(baseEvent),
      if (registrationSettings != null)
        ...Map<String, dynamic>.from(registrationSettings),
    };
    return merged;
  }

  int? registrationLimitFromEvent(Map<String, dynamic>? event) {
    if (event == null) return null;
    return _normalizeRegistrationLimit(event['registration_limit']);
  }

  int registeredCountFromEvent(Map<String, dynamic>? event) {
    if (event == null) return 0;
    return int.tryParse(event['registered_count']?.toString() ?? '') ?? 0;
  }

  bool isEventAtCapacity(Map<String, dynamic>? event, {int? participantCount}) {
    final limit = registrationLimitFromEvent(event);
    if (limit == null) return false;

    final count = participantCount ?? registeredCountFromEvent(event);
    return count >= limit;
  }

  String formatParticipantTotal(int count, dynamic registrationLimit) {
    final limit = _normalizeRegistrationLimit(registrationLimit);
    if (limit != null) {
      return '$count/$limit';
    }
    return count.toString();
  }

  bool _asRegistrationBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return const {'1', 'true', 't', 'yes', 'y', 'on'}.contains(normalized);
  }

  int? _normalizeRegistrationLimit(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 1 || parsed > 9999) return null;
    return parsed;
  }

  final _mobileBackend = MobileBackendService();

  Future<Map<String, dynamic>?> getRegistrationSnapshot(String eventId) async {
    return _fetchRegistrationSnapshot(eventId);
  }

  Future<Map<String, dynamic>?> _fetchRegistrationSnapshot(String eventId) async {
    try {
      final response = await _supabase.rpc(
        'get_event_registration_snapshot',
        params: {'p_event_id': eventId},
      );

      if (response is Map) {
        final map = Map<String, dynamic>.from(response);
        if (map['ok'] == true || map.containsKey('registration_count')) {
          return map;
        }
      }
    } catch (_) {
      // RPC not deployed yet.
    }

    return null;
  }

  Map<String, dynamic> applyRegistrationSnapshot(
    Map<String, dynamic> event,
    Map<String, dynamic> snapshot,
  ) {
    final merged = Map<String, dynamic>.from(event);
    if (snapshot.containsKey('registration_count')) {
      merged['registered_count'] = snapshot['registration_count'];
    }
    if (snapshot.containsKey('registration_limit')) {
      merged['registration_limit'] = snapshot['registration_limit'];
    }
    if (snapshot.containsKey('allow_registration')) {
      merged['allow_registration'] = snapshot['allow_registration'];
    }
    if (snapshot.containsKey('is_free_event')) {
      merged['is_free_event'] = snapshot['is_free_event'];
    }
    return merged;
  }

  Future<int?> _fetchHostedRegistrationCount(String eventId) async {
    if (!MobileBackendService.isConfigured) {
      return null;
    }

    final info = await _mobileBackend.getEventRegistrationInfo(eventId: eventId);
    if (info['ok'] != true) {
      return null;
    }

    return int.tryParse(info['registration_count']?.toString() ?? '');
  }

  Future<Map<String, dynamic>?> _fetchStudentDocumentAccessGate(
    String eventId,
    String studentId,
  ) async {
    // BFF first — event_student_* tables are locked from anon (048).
    if (MobileBackendService.isConfigured) {
      try {
        final hosted = await _fetchStudentDocumentAccessGateFromHosted(
          eventId,
          studentId,
        ).timeout(
          const Duration(seconds: 8),
          onTimeout: () => null,
        );
        if (hosted != null) {
          return hosted;
        }
      } catch (_) {
        // Fall through only for catalog RPC (no locked-table SELECT).
      }
    }

    final requirements = await fetchEventStudentRequirementsList(
      eventId,
      studentId: studentId,
    );
    if (requirements.isEmpty) {
      return null;
    }

    // Building the gate locally needs locked document tables — skip when BFF
    // is configured (already tried above). Without BFF, best-effort only.
    if (MobileBackendService.isConfigured) {
      return null;
    }

    return _buildStudentDocumentAccessGate(
      eventId: eventId,
      studentId: studentId,
      requirements: requirements,
    );
  }

  Future<Map<String, dynamic>?> _fetchStudentDocumentAccessGateFromHosted(
    String eventId,
    String studentId,
  ) async {
    if (!MobileBackendService.isConfigured) {
      return null;
    }

    try {
      final hosted = await _mobileBackend.getStudentRequirementsInfo(
        eventId: eventId,
        userId: studentId,
      );
      if (hosted['ok'] != true) {
        return null;
      }

      final requirements = List<Map<String, dynamic>>.from(
        hosted['requirements'] as List? ?? const [],
      );
      if (requirements.isEmpty) {
        return null;
      }

      final access = hosted['access'] is Map
          ? Map<String, dynamic>.from(hosted['access'] as Map)
          : <String, dynamic>{};
      final status = (access['status']?.toString() ?? '').trim().toLowerCase();
      final declineReason =
          (access['decline_reason']?.toString() ?? '').trim();
      final complete = access['complete'] == true;
      final approved = access['approved'] == true;
      final message = (access['message']?.toString() ?? '').trim();

      if (approved) {
        return {
          'requirementsRequired': true,
          'requirementsComplete': true,
          'requirementsApproved': true,
          'requirementsStatus': 'approved',
          'requirementsDeclineReason': '',
          'allowed': true,
          'message': '',
        };
      }

      if (status == 'pending_review') {
        return {
          'requirementsRequired': true,
          'requirementsComplete': complete,
          'requirementsApproved': false,
          'requirementsStatus': 'pending_review',
          'requirementsDeclineReason': '',
          'allowed': false,
          'message': message.isNotEmpty
              ? message
              : 'Your documents are under review. Registration will open after approval.',
        };
      }

      if (status == 'declined') {
        return {
          'requirementsRequired': true,
          'requirementsComplete': complete,
          'requirementsApproved': false,
          'requirementsStatus': 'declined',
          'requirementsDeclineReason': declineReason,
          'allowed': false,
          'message': message.isNotEmpty
              ? message
              : (declineReason.isNotEmpty
                    ? 'Your documents were declined: $declineReason'
                    : 'Your documents were declined. Please update and resubmit.'),
        };
      }

      if (!complete) {
        return {
          'requirementsRequired': true,
          'requirementsComplete': false,
          'requirementsApproved': false,
          'requirementsStatus': 'incomplete',
          'requirementsDeclineReason': '',
          'allowed': false,
          'message': message.isNotEmpty
              ? message
              : 'Submit the required documents before registering.',
        };
      }

      return {
        'requirementsRequired': true,
        'requirementsComplete': true,
        'requirementsApproved': false,
        'requirementsStatus': status.isNotEmpty ? status : 'ready_to_submit',
        'requirementsDeclineReason': declineReason,
        'allowed': false,
        'message': message.isNotEmpty
            ? message
            : 'Submit your documents for review before registering.',
      };
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _buildStudentDocumentAccessGate({
    required String eventId,
    required String studentId,
    required List<Map<String, dynamic>> requirements,
  }) async {
    try {
      final documents = List<Map<String, dynamic>>.from(
        await _supabase
            .from('event_student_documents')
            .select('requirement_id,file_url,file_path')
            .eq('event_id', eventId)
            .eq('student_id', studentId),
      );

      final uploadedIds = <String>{};
      for (final doc in documents) {
        final requirementId = doc['requirement_id']?.toString() ?? '';
        final fileUrl = doc['file_url']?.toString().trim() ?? '';
        final filePath = doc['file_path']?.toString().trim() ?? '';
        if (requirementId.isNotEmpty && (fileUrl.isNotEmpty || filePath.isNotEmpty)) {
          uploadedIds.add(requirementId);
        }
      }

      var submittedCount = 0;
      for (final requirement in requirements) {
        final requirementId = requirement['id']?.toString() ?? '';
        if (requirementId.isNotEmpty && uploadedIds.contains(requirementId)) {
          submittedCount += 1;
        }
      }

      final complete = submittedCount >= requirements.length;
      final submissionRows = List<Map<String, dynamic>>.from(
        await _supabase
            .from('event_student_submissions')
            .select('status,decline_reason,submitted_at')
            .eq('event_id', eventId)
            .eq('student_id', studentId)
            .limit(1),
      );

      final submission = submissionRows.isNotEmpty
          ? Map<String, dynamic>.from(submissionRows.first)
          : <String, dynamic>{};
      final status = (submission['status']?.toString() ?? '').trim().toLowerCase();
      final declineReason = (submission['decline_reason']?.toString() ?? '').trim();

      if (status == 'approved') {
        return {
          'requirementsRequired': true,
          'requirementsComplete': true,
          'requirementsApproved': true,
          'requirementsStatus': 'approved',
          'requirementsDeclineReason': '',
          'allowed': true,
          'message': '',
        };
      }

      if (status == 'pending_review') {
        return {
          'requirementsRequired': true,
          'requirementsComplete': complete,
          'requirementsApproved': false,
          'requirementsStatus': 'pending_review',
          'requirementsDeclineReason': '',
          'allowed': false,
          'message':
              'Your documents are under review. Registration will open after approval.',
        };
      }

      if (status == 'declined') {
        return {
          'requirementsRequired': true,
          'requirementsComplete': complete,
          'requirementsApproved': false,
          'requirementsStatus': 'declined',
          'requirementsDeclineReason': declineReason,
          'allowed': false,
          'message': declineReason.isNotEmpty
              ? 'Your documents were declined: $declineReason'
              : 'Your documents were declined. Please update and resubmit.',
        };
      }

      if (!complete) {
        return {
          'requirementsRequired': true,
          'requirementsComplete': false,
          'requirementsApproved': false,
          'requirementsStatus': 'incomplete',
          'requirementsDeclineReason': '',
          'allowed': false,
          'message': 'Submit the required documents before registering.',
        };
      }

      return {
        'requirementsRequired': true,
        'requirementsComplete': true,
        'requirementsApproved': false,
        'requirementsStatus': 'ready_to_submit',
        'requirementsDeclineReason': '',
        'allowed': false,
        'message': 'Submit your documents for review before registering.',
      };
    } catch (_) {
      return _fetchStudentDocumentAccessGateFromHosted(eventId, studentId);
    }
  }

  Future<List<Map<String, dynamic>>> fetchEventStudentRequirementsList(
    String eventId, {
    String? studentId,
  }) async {
    final trimmedEventId = eventId.trim();
    if (trimmedEventId.isEmpty) {
      return [];
    }

    final cached = _readCachedStudentRequirements(trimmedEventId);
    if (cached != null) {
      return cached;
    }

    final trimmedStudentId = studentId?.trim() ?? '';
    // Prefer PHP — event_student_requirements SELECT is revoked for anon.
    if (MobileBackendService.isConfigured && trimmedStudentId.isNotEmpty) {
      try {
        final hosted = await _mobileBackend
            .getStudentRequirementsInfo(
              eventId: trimmedEventId,
              userId: trimmedStudentId,
            )
            .timeout(
              const Duration(seconds: 8),
              onTimeout: () => {'ok': false},
            );
        if (hosted['ok'] == true) {
          final hostedRequirements = List<Map<String, dynamic>>.from(
            hosted['requirements'] as List? ?? const [],
          );
          _writeCachedStudentRequirements(trimmedEventId, hostedRequirements);
          return hostedRequirements;
        }
      } catch (_) {
        // Fall through to public RPC only.
      }
    }

    try {
      final rpcRows = await _supabase.rpc(
        'get_event_student_requirements',
        params: {'p_event_id': trimmedEventId},
      );
      final rpcRequirements = List<Map<String, dynamic>>.from(rpcRows);
      // Empty is a valid answer — do NOT fall through to locked table SELECT.
      _writeCachedStudentRequirements(trimmedEventId, rpcRequirements);
      return rpcRequirements;
    } catch (_) {
      // No readable requirements source.
    }

    _writeCachedStudentRequirements(trimmedEventId, const []);
    return [];
  }

  Future<Map<String, dynamic>> getStudentRequirementsInfo(
    String eventId,
    String studentId,
  ) async {
    // Prefer PHP BFF after security lockdown — anon cannot reliably read
    // event_student_submissions, which caused "Submit" while already pending.
    if (MobileBackendService.isConfigured) {
      try {
        final hosted = await _mobileBackend
            .getStudentRequirementsInfo(
              eventId: eventId,
              userId: studentId,
            )
            .timeout(
              const Duration(seconds: 12),
              onTimeout: () => {'ok': false},
            );
        if (hosted['ok'] == true) {
          final hostedRequirements = List<Map<String, dynamic>>.from(
            hosted['requirements'] as List? ?? const [],
          );
          if (hostedRequirements.isNotEmpty) {
            _writeCachedStudentRequirements(eventId, hostedRequirements);
            final access = hosted['access'] is Map
                ? Map<String, dynamic>.from(hosted['access'] as Map)
                : <String, dynamic>{};
            return {
              ...hosted,
              'access': {
                'required': true,
                'complete': access['complete'] == true,
                'approved': access['approved'] == true,
                'status': access['status']?.toString() ?? 'incomplete',
                'message': access['message']?.toString() ??
                    'Upload the required documents before registering.',
                'decline_reason': access['decline_reason']?.toString() ?? '',
              },
            };
          }
          // Hosted says no requirements — trust that.
          return {
            'ok': true,
            'requirements': <Map<String, dynamic>>[],
            'documents': <Map<String, dynamic>>[],
            'submission': null,
            'access': {
              'required': false,
              'complete': true,
              'approved': true,
              'status': '',
              'message': '',
              'decline_reason': '',
            },
          };
        }
      } catch (_) {
        // Fail closed — do not SELECT locked event_student_* tables.
      }
    }

    return {
      'ok': true,
      'requirements': <Map<String, dynamic>>[],
      'documents': <Map<String, dynamic>>[],
      'submission': null,
      'access': {
        'required': false,
        'complete': true,
        'approved': true,
        'status': '',
        'message': '',
        'decline_reason': '',
      },
    };
  }

  Future<Map<String, dynamic>> submitStudentRequirementsForReview(
    String eventId,
    String studentId,
  ) async {
    if (MobileBackendService.isConfigured) {
      final hosted = await _mobileBackend.submitStudentRequirements(
        eventId: eventId,
        userId: studentId,
      );
      if (hosted['ok'] == true || hosted['already_approved'] == true) {
        return hosted;
      }
      // Idempotent: already pending is success for the student UI.
      final err = (hosted['error']?.toString() ?? '').toLowerCase();
      if (hosted['already_pending'] == true ||
          err.contains('already under review') ||
          err.contains('under review')) {
        return {
          'ok': true,
          'already_pending': true,
          'submission': hosted['submission'],
        };
      }
      // Do not fall through to anon upsert after lockdown — return PHP error.
      return {
        'ok': false,
        'error': hosted['error']?.toString() ?? 'Submit failed.',
      };
    }

    return {
      'ok': false,
      'error': 'Submit requires the mobile backend.',
    };
  }

  Future<Map<String, dynamic>> uploadStudentRequirementDocument({
    required String eventId,
    required String requirementId,
    required String studentId,
    required String fileName,
    required String mimeType,
    List<int>? bytes,
    String? filePath,
  }) async {
    if (MobileBackendService.isConfigured) {
      final hosted = await _mobileBackend.uploadStudentRequirementFile(
        eventId: eventId,
        requirementId: requirementId,
        userId: studentId,
        bytes: bytes,
        filePath: filePath,
        fileName: fileName,
        mimeType: mimeType,
      );
      if (hosted['ok'] == true) {
        return hosted;
      }
      return {
        'ok': false,
        'error': hosted['error']?.toString() ?? 'Upload failed.',
      };
    }

    return {
      'ok': false,
      'error': 'Upload requires the mobile backend.',
    };
  }

  Future<int?> _fetchEventRegisteredCountColumn(String eventId) async {
    // Skip probing registered_count — column often missing and each miss is a
    // Postgres ERROR. Prefer RPC / hosted snapshot instead.
    return null;
  }

  Future<int> _fetchEventRegistrationCount(
    String eventId, {
    Map<String, dynamic>? eventHint,
  }) async {
    final snapshot = await _fetchRegistrationSnapshot(eventId);
    if (snapshot != null) {
      final count = int.tryParse(snapshot['registration_count']?.toString() ?? '');
      if (count != null) {
        return count;
      }
    }

    final hostedCount = await _fetchHostedRegistrationCount(eventId);
    if (hostedCount != null) {
      return hostedCount;
    }

    final columnCount = await _fetchEventRegisteredCountColumn(eventId);
    if (columnCount != null) {
      return columnCount;
    }

    final hintCount = int.tryParse(
      eventHint?['registered_count']?.toString() ?? '',
    );
    if (hintCount != null &&
        eventHint != null &&
        eventHint.containsKey('registered_count')) {
      return hintCount;
    }

    try {
      final response = await _supabase.rpc(
        'event_registration_count',
        params: {'p_event_id': eventId},
      );
      if (response is int) return response;
      if (response is num) return response.toInt();
      final parsed = int.tryParse(response?.toString() ?? '');
      if (parsed != null) return parsed;
    } catch (_) {
      // Fall back when RPC is not deployed yet.
    }

    // Do not count via anon table SELECT — prefer 0 over ERROR spam.
    return 0;
  }

  bool _isEventRegistrationFullSync(
    Map<String, dynamic> event, {
    int? participantCount,
  }) {
    final limit = _normalizeRegistrationLimit(event['registration_limit']);
    if (limit == null) return false;

    final count = participantCount ?? registeredCountFromEvent(event);
    return count >= limit;
  }

  Future<bool> _isEventRegistrationFull(
    String eventId,
    Map<String, dynamic> event, {
    int? participantCount,
  }) async {
    if (_isEventRegistrationFullSync(
      event,
      participantCount: participantCount,
    )) {
      return true;
    }

    final limit = _normalizeRegistrationLimit(event['registration_limit']);
    if (limit == null) return false;

    final count = participantCount ??
        await _fetchEventRegistrationCount(eventId, eventHint: event);
    return count >= limit;
  }

  Future<void> _maybeCloseRegistrationAtCapacity(
    String eventId,
    Map<String, dynamic> event,
  ) async {
    final limit = _normalizeRegistrationLimit(event['registration_limit']);
    if (limit == null) return;

    try {
      final count = await _fetchEventRegistrationCount(eventId);
      if (count >= limit) {
        await _supabase
            .from('events')
            .update({'allow_registration': false})
            .eq('id', eventId);
        event['allow_registration'] = false;
      }
    } catch (_) {
      // Best-effort only.
    }
  }

  /// When the scheduled registration close date has passed, turn Allow OFF.
  /// Re-opening via web toggle clears the close-limit so it is not enforced again.
  Future<void> _maybeCloseRegistrationByWindow(
    String eventId,
    Map<String, dynamic> event,
  ) async {
    if (!_asRegistrationBool(event['allow_registration'])) return;
    if (!isEventRegistrationWindowClosed(event)) return;

    try {
      await _supabase
          .from('events')
          .update({'allow_registration': false})
          .eq('id', eventId);
      event['allow_registration'] = false;
    } catch (_) {
      // Best-effort only (PHP pages also auto-close).
    }
  }

  String _normalizeRegistrationPaymentStatus(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    switch (normalized) {
      case 'paid':
      case 'approve':
      case 'approved':
      case 'allow':
      case 'allowed':
      case 'yes':
      case 'y':
      case '1':
      case 'true':
      case 't':
        return 'paid';
      case 'waived':
      case 'waive':
      case 'free':
      case 'exempt':
        return 'waived';
      case 'rejected':
      case 'reject':
      case 'declined':
      case 'denied':
      case 'deny':
      case 'blocked':
      case 'no':
      case 'n':
      case '0':
      case 'false':
      case 'f':
        return 'rejected';
      default:
        return 'pending';
    }
  }

  bool _registrationAccessRowAllows(Map<String, dynamic> row) {
    if (_asRegistrationBool(row['approved'])) {
      return true;
    }

    final paymentStatus = _normalizeRegistrationPaymentStatus(
      row['payment_status'],
    );
    return paymentStatus == 'paid' || paymentStatus == 'waived';
  }

  bool _eventIsFreeRegistrationEvent(Map<String, dynamic> event) {
    return _asRegistrationBool(event['is_free_event'] ?? true);
  }

  double? _normalizeEventFee(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      final fee = value.toDouble();
      return fee >= 0 ? fee : null;
    }
    final raw = value.toString().trim().replaceAll(',', '');
    if (raw.isEmpty) return null;
    final fee = double.tryParse(raw);
    if (fee == null || fee < 0) return null;
    return fee;
  }

  bool _eventRegistrationOpenToAll(Map<String, dynamic> event) {
    // Driven only by the Allow Registration toggle (mirrors web).
    return _asRegistrationBool(event['allow_registration']);
  }

  Future<Map<String, dynamic>?> _fetchRegistrationEvent(String eventId) async {
    const selectAttempts = [
      'id,status,event_for,start_at,allow_registration,is_free_event,event_fee,registration_limit,registration_close_weeks,registration_close_extend_days,registered_count',
      'id,status,event_for,start_at,allow_registration,is_free_event,registration_limit,registration_close_weeks,registration_close_extend_days,registered_count',
      'id,status,event_for,start_at,allow_registration,is_free_event,event_fee,registration_limit,registration_close_weeks,registered_count',
      'id,status,event_for,start_at,allow_registration,is_free_event,registration_limit,registration_close_weeks,registered_count',
      'id,status,event_for,start_at,allow_registration,is_free_event,registration_limit,registered_count',
      'id,status,event_for,start_at,allow_registration,is_free_event,registration_limit,registration_close_weeks',
      'id,status,event_for,start_at,allow_registration,is_free_event,registration_limit',
      'id,status,event_for,start_at,allow_registration,is_free_event',
      'id,status,event_for,start_at,allow_registration',
      'id,status,event_for,start_at,is_free_event',
      'id,status,event_for,start_at',
    ];

    for (final fields in selectAttempts) {
      try {
        final response = await _supabase
            .from('events')
            .select(fields)
            .eq('id', eventId)
            .maybeSingle();
        if (response == null) {
          return null;
        }

        final event = Map<String, dynamic>.from(response);
        event.putIfAbsent('is_free_event', () => true);
        event.putIfAbsent('registration_limit', () => null);
        event.putIfAbsent('registration_close_weeks', () => null);
        event.putIfAbsent('registration_close_extend_days', () => 0);
        return event;
      } catch (_) {
        continue;
      }
    }

    return null;
  }

  Future<Map<String, dynamic>> getStudentRegistrationAvailability(
    String eventId,
    String studentId, {
    Map<String, dynamic>? preloadedEvent,
  }) async {
    // Local/Supabase only — hosted mobile_event_registration_info.php regularly
    // times out on device and was blocking Event Details for seconds on every open.
    // Defer document-gate fetch until after paid settle-payment check.

    final event = preloadedEvent != null
        ? Map<String, dynamic>.from(preloadedEvent)
        : await _fetchRegistrationEvent(eventId);

    if (event == null) {
      return {
        'allowed': false,
        'targetAllowed': false,
        'approvalRequired': false,
        'registrationOpenToAll': false,
        'message': 'Event not found.',
      };
    }

    final snapshot = await _fetchRegistrationSnapshot(eventId);
    if (snapshot != null) {
      event.addAll(applyRegistrationSnapshot(event, snapshot));
      if (snapshot['is_full'] == true) {
        return {
          'allowed': false,
          'targetAllowed': true,
          'approvalRequired': false,
          'registrationOpenToAll': _eventRegistrationOpenToAll(event),
          'message': 'Registration is full for this event.',
        };
      }
    }

    if (_normalizeRegistrationLimit(event['registration_limit']) == null) {
      final settings = await _fetchRegistrationEvent(eventId);
      if (settings != null) {
        event.addAll(settings);
      }
    }

    final count = await _fetchEventRegistrationCount(eventId, eventHint: event);
    event['registered_count'] = count;

    final status = (event['status']?.toString() ?? '').trim().toLowerCase();
    if (status != 'published') {
      return {
        'allowed': false,
        'targetAllowed': false,
        'approvalRequired': false,
        'registrationOpenToAll': false,
        'message': status == 'approved'
            ? 'This event is approved and will open for registration once published.'
            : 'Registration is currently closed.',
      };
    }

    final studentScope = await getStudentTargetScope(studentId);
    final targetAllowed = isStudentAllowedForEvent(
      event,
      yearLevel: studentScope['yearLevel'],
      courseCode: studentScope['courseCode'],
      specialization: studentScope['specialization'],
    );
    if (!targetAllowed) {
      return {
        'allowed': false,
        'targetAllowed': false,
        'approvalRequired': false,
        'registrationOpenToAll': false,
        'message': 'This event is not available for your course/year level.',
      };
    }

    if (await _isEventRegistrationFull(eventId, event)) {
      return {
        'allowed': false,
        'targetAllowed': true,
        'approvalRequired': false,
        'registrationOpenToAll': _eventRegistrationOpenToAll(event),
        'message': 'Registration is full for this event.',
      };
    }

    await _maybeCloseRegistrationByWindow(eventId, event);

    if (isEventRegistrationWindowClosed(event)) {
      return {
        'allowed': false,
        'targetAllowed': true,
        'approvalRequired': false,
        'registrationOpenToAll': _eventRegistrationOpenToAll(event),
        'message': 'Registration is closed for this event.',
      };
    }

    final isPaidEvent = !_eventIsFreeRegistrationEvent(event);
    final openToAll = _eventRegistrationOpenToAll(event);

    // Free events only: Allow Registration OFF pauses signup.
    // Paid events always go through settle-payment first (below), even if
    // Allow Registration is ON — never jump straight to Submit Documents.
    if (!isPaidEvent && !openToAll) {
      return {
        'allowed': false,
        'targetAllowed': true,
        'approvalRequired': false,
        'paymentRequired': false,
        'isPaidEvent': false,
        'registrationOpenToAll': false,
        'message': 'Registration is currently closed by the organizer.',
      };
    }

    // Paid: Payments → settle → docs → ticket (always, regardless of Allow Registration).
    // Check payment BEFORE document gate so Event Details CTA isn't blocked by a hung docs fetch.
    if (isPaidEvent) {
      Map<String, dynamic>? accessRow;
      try {
        final accessRows = List<Map<String, dynamic>>.from(
          await _supabase
              .from('event_registration_access')
              .select('approved,payment_status,payment_note,amount_paid,updated_at')
              .eq('event_id', eventId)
              .eq('student_id', studentId)
              .order('updated_at', ascending: false)
              .limit(1),
        );
        if (accessRows.isNotEmpty) {
          accessRow = Map<String, dynamic>.from(accessRows.first);
        }
      } catch (_) {
        try {
          final accessRows = List<Map<String, dynamic>>.from(
            await _supabase
                .from('event_registration_access')
                .select('approved,payment_status,payment_note,updated_at')
                .eq('event_id', eventId)
                .eq('student_id', studentId)
                .order('updated_at', ascending: false)
                .limit(1),
          );
          if (accessRows.isNotEmpty) {
            accessRow = Map<String, dynamic>.from(accessRows.first);
          }
        } catch (_) {
          // Fail closed for paid / payment-gated registration.
        }
      }

      final paymentCleared = (accessRow != null &&
              _registrationAccessRowAllows(accessRow)) ||
          await _hasServerApprovedRegistrationSignal(studentId, eventId) ||
          await hasCachedApprovedRegistrationAccess(studentId, eventId);

      if (!paymentCleared) {
        final fee = _normalizeEventFee(event['event_fee']);
        final feeText = fee == null ? '' : '₱${fee.toStringAsFixed(2)}';
        var message =
            'Settle your payment first with the authorized person assigned for this event.';
        if (feeText.isNotEmpty) {
          message =
              'Settle $feeText with the authorized person assigned for this event before you can continue.';
        }
        return {
          'allowed': false,
          'targetAllowed': true,
          'approvalRequired': true,
          'paymentRequired': true,
          'paymentCleared': false,
          'isPaidEvent': true,
          'eventFee': fee,
          'registrationOpenToAll': openToAll,
          'requirementsRequired': false,
          'message': message,
        };
      }

      await cacheApprovedRegistrationAccess(studentId, eventId);

      // Only fetch document gate after payment is cleared.
      final paidDocumentGate =
          await _fetchStudentDocumentAccessGate(eventId, studentId);

      if (paidDocumentGate != null &&
          paidDocumentGate['requirementsApproved'] != true) {
        return {
          'allowed': false,
          'targetAllowed': true,
          'approvalRequired': false,
          'paymentRequired': false,
          'paymentCleared': true,
          'isPaidEvent': true,
          'registrationOpenToAll': openToAll,
          'requirementsRequired':
              paidDocumentGate['requirementsRequired'] == true,
          'requirementsComplete':
              paidDocumentGate['requirementsComplete'] == true,
          'requirementsApproved': false,
          'requirementsStatus': paidDocumentGate['requirementsStatus'] ?? '',
          'requirementsDeclineReason':
              paidDocumentGate['requirementsDeclineReason'] ?? '',
          'message': (paidDocumentGate['message'] as String? ?? '').trim(),
        };
      }

      return {
        'allowed': true,
        'targetAllowed': true,
        'approvalRequired': false,
        'paymentRequired': false,
        'paymentCleared': true,
        'isPaidEvent': true,
        'registrationOpenToAll': openToAll,
        'message': '',
      };
    }

    // Free / open registration: documents gate as before.
    final documentGate =
        await _fetchStudentDocumentAccessGate(eventId, studentId);
    if (documentGate != null && documentGate['requirementsApproved'] != true) {
      return {
        'allowed': false,
        'targetAllowed': true,
        'approvalRequired': false,
        'registrationOpenToAll': true,
        'requirementsRequired': documentGate['requirementsRequired'] == true,
        'requirementsComplete': documentGate['requirementsComplete'] == true,
        'requirementsApproved': false,
        'requirementsStatus': documentGate['requirementsStatus'] ?? '',
        'requirementsDeclineReason':
            documentGate['requirementsDeclineReason'] ?? '',
        'message': (documentGate['message'] as String? ?? '').trim(),
      };
    }

    return {
      'allowed': true,
      'targetAllowed': true,
      'approvalRequired': false,
      'registrationOpenToAll': true,
      'message': '',
    };
  }

  // Helper to generate a random 32-character hex token similar to PHP's bin2hex(random_bytes(16))
  String _generateToken() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  // Register student for an event
  Future<Map<String, dynamic>> registerForEvent(
    String eventId,
    String userId,
  ) async {
    final documentGate = await _fetchStudentDocumentAccessGate(eventId, userId);
    if (documentGate != null && documentGate['requirementsApproved'] != true) {
      return {
        'ok': false,
        'error': (documentGate['message'] as String? ?? '').trim().isNotEmpty
            ? documentGate['message'] as String
            : 'Submit and get your documents approved before registering.',
        'requirements_required': true,
      };
    }

    if (MobileBackendService.isConfigured) {
      final result = await _mobileBackend.registerForEvent(
        eventId: eventId,
        userId: userId,
      );
      // Never fall back to anon PostgREST writes (revoked after security lockdown).
      if (result['ok'] == true) {
        // Tickets tab keeps a TTL cache; clear it so the new ticket appears.
        unawaited(invalidateMyTicketsCache(userId));
        invalidateEventDetailCache(eventId);
      }
      return result;
    }
    return {
      'ok': false,
      'error':
          'Hosted backend is required for registration. Set mobilePushApiBaseUrl in env.dart.',
    };
  }

  Future<Map<String, dynamic>> _registerForEventViaSupabase(
    String eventId,
    String userId,
  ) async {
    // Direct anon writes revoked after security lockdown — use PHP register path.
    return {
      'ok': false,
      'error': 'Direct Supabase registration is disabled for security.',
    };
  }

  // Get events the user registered for (tickets)
  Future<List<Map<String, dynamic>>> getMyTickets(
    String userId, {
    bool forceFresh = false,
  }) async {
    final cacheKey = 'tickets:$userId';
    if (!forceFresh) {
      final memCached = await _appCache.loadJsonList(cacheKey);
      // Prefer warm memory/disk so offline reopen stays populated.
      if (memCached.isNotEmpty) {
        final age = await _appCache.lastUpdatedAt(cacheKey);
        final isFresh = age != null &&
            DateTime.now().toUtc().difference(age.toUtc()) <= _ticketsTtl;
        if (isFresh) {
          return memCached;
        }
        unawaited(_fetchAndPersistMyTickets(userId, cacheKey));
        return memCached;
      }
    }

    return _appCache.fetchOnce(
      'fetch:$cacheKey',
      () => _fetchAndPersistMyTickets(userId, cacheKey),
      forceFresh: forceFresh,
    );
  }

  Future<List<Map<String, dynamic>>> _fetchAndPersistMyTickets(
    String userId,
    String cacheKey,
  ) async {
    try {
      final rows = await _fetchMyTickets(userId);
      final offline = await isLikelyOffline();
      var toStore = rows;
      if (rows.isEmpty && offline) {
        toStore = await _preferExistingCacheIfEmpty(cacheKey, rows);
      }
      await _appCache.saveJsonList(
        cacheKey,
        toStore,
        preserveNonEmptyOnEmpty: offline,
      );
      return toStore;
    } catch (_) {
      final diskCached = await _appCache.loadJsonList(cacheKey);
      if (diskCached.isNotEmpty) {
        return diskCached;
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> _fetchMyTickets(String userId) async {
    if (MobileBackendService.isConfigured) {
      try {
        final result = await _mobileBackend.getMyTicketsSecure();
        if (result['ok'] == true && result['rows'] is List) {
          return List<Map<String, dynamic>>.from(
            (result['rows'] as List).map(
              (e) => Map<String, dynamic>.from(e as Map),
            ),
          );
        }
      } catch (e) {
        debugPrint('[tickets] BFF failed: $e');
      }
      // Fail closed — anon embed path floods Postgres ERROR after lockdown.
      return [];
    }

    try {
      final response = await _supabase
          .from('event_registrations')
          .select('*, events(*), tickets(*, attendance(*))')
          .eq('student_id', userId)
          .order('registered_at', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getTicketSeminarAttendance({
    required String eventId,
    required String registrationId,
    String ticketId = '',
  }) async {
    if (eventId.trim().isEmpty || registrationId.trim().isEmpty) {
      return [];
    }

    final sessions = await _fetchSessionsForEvent(eventId);
    if (sessions.isEmpty) return [];

    final checkInBySession = <String, String>{};
    final checkOutBySession = <String, String>{};

    if (await _supportsEventSessionAttendanceTable()) {
      try {
        final rows = await _supabase
            .from('event_session_attendance')
            .select('session_id,status,check_in_at,check_out_at')
            .eq('registration_id', registrationId);
        for (final row in List<Map<String, dynamic>>.from(rows)) {
          if (!_hasCheckInRecord(row)) continue;
          final sessionId = row['session_id']?.toString() ?? '';
          final checkInAt = row['check_in_at']?.toString() ?? '';
          final checkOutAt = row['check_out_at']?.toString() ?? '';
          if (sessionId.isEmpty || checkInAt.isEmpty) continue;
          checkInBySession.putIfAbsent(sessionId, () => checkInAt);
          if (checkOutAt.trim().isNotEmpty) {
            checkOutBySession.putIfAbsent(sessionId, () => checkOutAt);
          }
        }
      } catch (_) {
        // Fallback below handles older schemas.
      }
    }

    final supportsSessionId = await _supportsAttendanceColumn('session_id');
    if (supportsSessionId && ticketId.trim().isNotEmpty) {
      try {
        final rows = await _supabase
            .from('attendance')
            .select('session_id,status,check_in_at,check_out_at')
            .eq('ticket_id', ticketId)
            .not('session_id', 'is', null);
        for (final row in List<Map<String, dynamic>>.from(rows)) {
          if (!_hasCheckInRecord(row)) continue;
          final sessionId = row['session_id']?.toString() ?? '';
          final checkInAt = row['check_in_at']?.toString() ?? '';
          final checkOutAt = row['check_out_at']?.toString() ?? '';
          if (sessionId.isEmpty || checkInAt.isEmpty) continue;
          checkInBySession.putIfAbsent(sessionId, () => checkInAt);
          if (checkOutAt.trim().isNotEmpty) {
            checkOutBySession.putIfAbsent(sessionId, () => checkOutAt);
          }
        }
      } catch (_) {}
    }

    return sessions.map((session) {
      final sessionMap = _asStringMap(session);
      final sessionId = sessionMap['id']?.toString() ?? '';
      return {
        'id': sessionId,
        'title': _sessionDisplayName(sessionMap),
        'check_in_at': checkInBySession[sessionId] ?? '',
        'check_out_at': checkOutBySession[sessionId] ?? '',
      };
    }).toList();
  }

  // Get participant count for an event
  Future<int> getParticipantCount(
    String eventId, {
    Map<String, dynamic>? eventHint,
  }) async {
    return _fetchEventRegistrationCount(eventId, eventHint: eventHint);
  }

  // Check if user is registered for an event
  Future<bool> isRegistered(String eventId, String userId) async {
    final eId = eventId.trim();
    final uId = userId.trim();
    if (eId.isEmpty || uId.isEmpty) return false;

    if (MobileBackendService.isConfigured) {
      try {
        final res = await _mobileBackend.secureRead(
          table: 'event_registrations',
          select: 'id',
          filters: {'event_id': eId, 'student_id': uId},
          limit: 1,
        );
        if (res['ok'] == true && res['rows'] is List) {
          return (res['rows'] as List).isNotEmpty;
        }
      } catch (_) {}
      // Fail closed — do not anon-SELECT (avoids ERROR spam / RLS noise).
      return false;
    }

    try {
      final response = await _supabase
          .from('event_registrations')
          .select('id')
          .eq('event_id', eId)
          .eq('student_id', uId)
          .limit(1);
      return response.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // Get user's certificates (cached; list payload omits heavy canvas_state).
  Future<List<Map<String, dynamic>>> getMyCertificates(
    String userId, {
    bool forceFresh = false,
  }) async {
    final uid = userId.trim();
    if (uid.isEmpty) return [];
    final cacheKey = 'certs:v2:$uid';

    if (!forceFresh) {
      final cached = _readListCache(cacheKey, _myCertificatesTtl);
      if (cached != null) {
        return cached;
      }

      final stale = _readListCache(
        cacheKey,
        _myCertificatesTtl,
        allowStale: true,
        staleTtl: const Duration(hours: 24),
      );
      if (stale != null && stale.isNotEmpty) {
        unawaited(_fetchMyCertificates(uid, cacheKey));
        return stale;
      }

      final diskCached = await _appCache.loadJsonList(cacheKey);
      if (diskCached.isNotEmpty) {
        _writeListCache(cacheKey, diskCached);
        unawaited(_fetchMyCertificates(uid, cacheKey));
        return diskCached;
      }
    }

    return _appCache.fetchOnce(
      'fetch:$cacheKey',
      () => _fetchMyCertificates(uid, cacheKey, forceFresh: forceFresh),
      forceFresh: forceFresh,
    );
  }

  List<Map<String, dynamic>> _stripHeavyCertFields(
    List<Map<String, dynamic>> rows,
  ) {
    return rows.map((row) {
      final copy = Map<String, dynamic>.from(row);
      copy.remove('template_canvas_state');
      copy.remove('template_source_row');
      copy.remove('canvas_state');
      return copy;
    }).toList();
  }

  /// Lazy-load Fabric canvas for certificate preview/download only.
  Future<Map<String, dynamic>?> fetchCertificateCanvasState({
    String? templateId,
    String? sessionTemplateId,
  }) async {
    final sessionId = (sessionTemplateId ?? '').trim();
    final eventTplId = (templateId ?? '').trim();
    try {
      if (sessionId.isNotEmpty) {
        final rows = await _supabase
            .from('event_session_certificate_templates')
            .select('canvas_state')
            .eq('id', sessionId)
            .limit(1);
        if (rows.isNotEmpty) {
          final raw = rows.first['canvas_state'];
          if (raw is Map<String, dynamic>) return raw;
          if (raw is Map) {
            return raw.map((k, v) => MapEntry(k.toString(), v));
          }
          if (raw is String && raw.trim().isNotEmpty) {
            final decoded = jsonDecode(raw);
            if (decoded is Map<String, dynamic>) return decoded;
            if (decoded is Map) {
              return decoded.map((k, v) => MapEntry(k.toString(), v));
            }
          }
        }
      }
      if (eventTplId.isNotEmpty) {
        final rows = await _supabase
            .from('certificate_templates')
            .select('canvas_state')
            .eq('id', eventTplId)
            .limit(1);
        if (rows.isNotEmpty) {
          final raw = rows.first['canvas_state'];
          if (raw is Map<String, dynamic>) return raw;
          if (raw is Map) {
            return raw.map((k, v) => MapEntry(k.toString(), v));
          }
          if (raw is String && raw.trim().isNotEmpty) {
            final decoded = jsonDecode(raw);
            if (decoded is Map<String, dynamic>) return decoded;
            if (decoded is Map) {
              return decoded.map((k, v) => MapEntry(k.toString(), v));
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<Map<String, dynamic>>> _fetchMyCertificates(
    String userId,
    String cacheKey, {
    bool forceFresh = false,
  }) async {
    try {
      final participantName = await _resolveParticipantNameForUser(userId);

      Map<String, dynamic> templatePayload(dynamic raw) {
        final row = _asStringMap(raw);
        return {
          'thumbnail_url': row['thumbnail_url']?.toString(),
          // canvas_state is fetched on preview only — keeps list/cache light.
          'template_title': row['title']?.toString(),
          'template_body_text': row['body_text']?.toString(),
          'template_footer_text': row['footer_text']?.toString(),
          'template_id': row['id']?.toString(),
        };
      }

      Future<Map<String, Map<String, dynamic>>> loadTemplateMap({
        required String table,
        required String keyColumn,
        required List<String> values,
      }) async {
        final map = <String, Map<String, dynamic>>{};
        if (values.isEmpty) return map;
        try {
          final rows = await _supabase
              .from(table)
              .select(
                keyColumn == 'id'
                    ? 'id,title,thumbnail_url,body_text,footer_text'
                    : 'id,title,thumbnail_url,body_text,footer_text,$keyColumn',
              )
              .inFilter(keyColumn, values)
              .order('created_at', ascending: false);
          for (final raw in List<Map<String, dynamic>>.from(rows)) {
            final row = _asStringMap(raw);
            final key = row[keyColumn]?.toString() ?? '';
            if (key.isEmpty) continue;
            map.putIfAbsent(key, () => templatePayload(row));
          }
        } catch (_) {
          // Keep fallback empty map.
        }
        return map;
      }

      // Fetch event + session certs in parallel (failures stay independent).
      final simpleFuture = _supabase
          .from('certificates')
          .select(
            'id,event_id,student_id,template_id,certificate_code,issued_at,event_title,'
            'events(title, start_at)',
          )
          .eq('student_id', userId)
          .order('issued_at', ascending: false);

      final sessionFuture = _supabase
          .from('event_session_certificates')
          .select(
            'id, session_id, event_id, student_id, template_id, session_template_id, certificate_code, issued_at, event_title, session_title, '
            'event_sessions(id, event_id, title, topic, start_at, events(id, title, start_at))',
          )
          .eq('student_id', userId)
          .order('issued_at', ascending: false);

      late final List<Map<String, dynamic>> rawSimpleCerts;
      late final List<Map<String, dynamic>> rawSessionCerts;
      final settled = await Future.wait([
        () async {
          try {
            return List<Map<String, dynamic>>.from(await simpleFuture);
          } catch (_) {
            return <Map<String, dynamic>>[];
          }
        }(),
        () async {
          try {
            return List<Map<String, dynamic>>.from(await sessionFuture);
          } catch (_) {
            return <Map<String, dynamic>>[];
          }
        }(),
      ]);
      rawSimpleCerts = settled[0];
      rawSessionCerts = settled[1];

      final simpleTemplateIds = rawSimpleCerts
          .map((row) => row['template_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      final simpleEventIds = rawSimpleCerts
          .map((row) => row['event_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      final simpleTemplateById = await loadTemplateMap(
        table: 'certificate_templates',
        keyColumn: 'id',
        values: simpleTemplateIds,
      );
      final simpleTemplateByEvent = await loadTemplateMap(
        table: 'certificate_templates',
        keyColumn: 'event_id',
        values: simpleEventIds,
      );

      final simpleCerts = rawSimpleCerts.map((row) {
        final eventMap = row['events'] is Map
            ? Map<String, dynamic>.from(row['events'] as Map)
            : <String, dynamic>{};
        final liveTitle = (eventMap['title']?.toString() ?? '').trim();
        final snapTitle = (row['event_title']?.toString() ?? '').trim();
        final resolvedTitle =
            liveTitle.isNotEmpty ? liveTitle : (snapTitle.isNotEmpty ? snapTitle : 'Event');
        if (eventMap['title'] == null || (eventMap['title']?.toString() ?? '').trim().isEmpty) {
          eventMap['title'] = resolvedTitle;
        }
        final selectedTemplate =
            simpleTemplateById[row['template_id']?.toString() ?? ''] ??
            simpleTemplateByEvent[row['event_id']?.toString() ?? ''] ??
            <String, dynamic>{};
        return {
          ...row,
          ...selectedTemplate,
          'certificate_scope': 'event',
          'participant_name': participantName,
          'display_title': resolvedTitle,
          'events': eventMap,
        };
      }).toList();

      List<Map<String, dynamic>> sessionCerts = [];
      if (rawSessionCerts.isNotEmpty) {
        try {
          final sessionTemplateIds = rawSessionCerts
              .map((row) => row['session_template_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList();
          final eventTemplateIds = rawSessionCerts
              .map((row) => row['template_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList();
          final sessionIds = rawSessionCerts
              .map((row) => row['session_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList();
          final eventIds = rawSessionCerts
              .map((row) => _asStringMap(row['event_sessions']))
              .map((session) => session['event_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList();

          final templateMaps = await Future.wait([
            loadTemplateMap(
              table: 'event_session_certificate_templates',
              keyColumn: 'id',
              values: sessionTemplateIds,
            ),
            loadTemplateMap(
              table: 'event_session_certificate_templates',
              keyColumn: 'session_id',
              values: sessionIds,
            ),
            loadTemplateMap(
              table: 'certificate_templates',
              keyColumn: 'id',
              values: eventTemplateIds,
            ),
            loadTemplateMap(
              table: 'certificate_templates',
              keyColumn: 'event_id',
              values: eventIds,
            ),
          ]);
          final sessionTemplateById = templateMaps[0];
          final sessionTemplateBySession = templateMaps[1];
          final eventTemplateById = templateMaps[2];
          final eventTemplateByEvent = templateMaps[3];

          sessionCerts = rawSessionCerts.map((row) {
            final session = _asStringMap(row['event_sessions']);
            final sessionId =
                session['id']?.toString() ?? row['session_id']?.toString() ?? '';
            final sessionEventId = (session['event_id']?.toString() ?? '').trim();
            final rowEventId = (row['event_id']?.toString() ?? '').trim();
            final eventId =
                sessionEventId.isNotEmpty ? sessionEventId : rowEventId;
            final event = _asStringMap(session['events']);
            final liveSessionName = _sessionDisplayName(session);
            final snapSessionName = (row['session_title']?.toString() ?? '').trim();
            final sessionName = liveSessionName.isNotEmpty &&
                    liveSessionName.toLowerCase() != 'seminar'
                ? liveSessionName
                : (snapSessionName.isNotEmpty ? snapSessionName : liveSessionName);
            final liveEventTitle = (event['title']?.toString() ?? '').trim();
            final snapEventTitle = (row['event_title']?.toString() ?? '').trim();
            final eventTitle = liveEventTitle.isNotEmpty
                ? liveEventTitle
                : (snapEventTitle.isNotEmpty ? snapEventTitle : 'Event');
            if ((event['title']?.toString() ?? '').trim().isEmpty) {
              event['title'] = eventTitle;
            }
            if (session.isNotEmpty &&
                (session['title']?.toString() ?? '').trim().isEmpty &&
                sessionName.isNotEmpty) {
              session['title'] = sessionName;
            }

            final selectedTemplate =
                sessionTemplateById[row['session_template_id']?.toString() ??
                    ''] ??
                eventTemplateById[row['template_id']?.toString() ?? ''] ??
                sessionTemplateBySession[sessionId] ??
                eventTemplateByEvent[eventId] ??
                <String, dynamic>{};

            return {
              ...row,
              ...selectedTemplate,
              'session_id': sessionId,
              'event_id': eventId,
              'events': event,
              'session': session,
              'certificate_scope': 'session',
              'participant_name': participantName,
              'display_title': sessionName.isNotEmpty
                  ? '$eventTitle - $sessionName'
                  : eventTitle,
            };
          }).toList();
        } catch (_) {
          try {
            sessionCerts = await _getSessionCertificatesFallback(userId);
            sessionCerts = sessionCerts.map((row) {
              return {
                ...row,
                'participant_name': participantName,
              };
            }).toList();
          } catch (_) {
            sessionCerts = [];
          }
        }
      }

      final all = <Map<String, dynamic>>[...simpleCerts, ...sessionCerts].map((
        row,
      ) {
        final existingName = (row['participant_name']?.toString() ?? '').trim();
        return {
          ...row,
          'participant_name': existingName.isNotEmpty
              ? existingName
              : participantName,
        };
      }).toList();
      all.sort((a, b) {
        final aIssued = DateTime.tryParse(a['issued_at']?.toString() ?? '');
        final bIssued = DateTime.tryParse(b['issued_at']?.toString() ?? '');
        if (aIssued == null && bIssued == null) return 0;
        if (aIssued == null) return 1;
        if (bIssued == null) return -1;
        return bIssued.compareTo(aIssued);
      });

      final slim = _stripHeavyCertFields(all);
      final offline = await isLikelyOffline();
      var toStore = slim;
      if (slim.isEmpty && offline) {
        toStore = await _preferExistingCacheIfEmpty(cacheKey, slim);
      }
      _writeListCache(cacheKey, toStore);
      unawaited(
        _appCache.saveJsonList(
          cacheKey,
          toStore,
          preserveNonEmptyOnEmpty: offline,
        ),
      );
      return toStore;
    } catch (e) {
      if (!forceFresh) {
        final stale = _readListCache(
          cacheKey,
          _myCertificatesTtl,
          allowStale: true,
          staleTtl: const Duration(hours: 24),
        );
        if (stale != null) return stale;
        final disk = await _appCache.loadJsonList(cacheKey);
        if (disk.isNotEmpty) return disk;
      }
      return [];
    }
  }

  Future<Map<String, dynamic>> getTicketForEvent(
    String eventId,
    String userId,
  ) async {
    final eId = eventId.trim();
    final uId = userId.trim();
    if (eId.isEmpty || uId.isEmpty) return {};

    if (MobileBackendService.isConfigured) {
      try {
        final rows = await _fetchMyTickets(uId);
        for (final row in rows) {
          final rowEventId = (row['event_id']?.toString() ?? '').trim();
          final nested = row['events'];
          final nestedId = nested is Map
              ? (nested['id']?.toString() ?? '').trim()
              : '';
          if (rowEventId == eId || nestedId == eId) {
            return Map<String, dynamic>.from(row);
          }
        }
      } catch (_) {}
      return {};
    }

    try {
      final rows = await _supabase
          .from('event_registrations')
          .select('event_id, events(*), tickets(*, attendance(*))')
          .eq('student_id', uId)
          .eq('event_id', eId)
          .limit(1);

      if (rows.isEmpty) {
        return {};
      }

      return Map<String, dynamic>.from(rows.first);
    } catch (_) {
      return {};
    }
  }

  // --- TEACHER METHODS ---

  // Get events created by this teacher
  Future<List<Map<String, dynamic>>> getTeacherEvents(String teacherId) async {
    try {
      final response = await _supabase
          .from('events')
          .select()
          .eq('created_by', teacherId)
          .order('start_at', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getTeacherAccessibleEvents(
    String teacherId, {
    bool forceFresh = false,
  }) async {
    final cacheKey = 'teacher_accessible:$teacherId';
    if (!forceFresh) {
      final cached = _readListCache(cacheKey, _teacherEventsTtl);
      if (cached != null) {
        return cached;
      }
    }

    return _appCache.fetchOnce(
      'fetch:$cacheKey',
      () => _loadTeacherAccessibleEvents(teacherId, cacheKey),
      forceFresh: forceFresh,
    );
  }

  Future<List<Map<String, dynamic>>> _loadTeacherAccessibleEvents(
    String teacherId,
    String cacheKey,
  ) async {
    final merged = <String, Map<String, dynamic>>{};

    // Always try created events first so teacher still sees their own
    // events even if assignments query is blocked by RLS.
    try {
      final created = await _supabase
          .from('events')
          .select(_eventListColumns)
          .eq('created_by', teacherId);
      for (final event in List<Map<String, dynamic>>.from(created)) {
        final eventId = event['id']?.toString() ?? '';
        if (eventId.isNotEmpty) merged[eventId] = event;
      }
    } catch (_) {
      // keep going; assigned events may still be available
    }

    // IMPORTANT: keep teacher visibility strict.
    // Teachers should only see events they created or are explicitly assigned to.

    try {
      final assignedRows = await _supabase
          .from('event_teacher_assignments')
          .select('event_id')
          .eq('teacher_id', teacherId);

      final assignedIds = assignedRows
          .map((row) => row['event_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      if (assignedIds.isNotEmpty) {
        final assignedEvents = List<Map<String, dynamic>>.from(
          await _supabase
              .from('events')
              .select(_eventListColumns)
              .inFilter('id', assignedIds),
        );
        for (final event in assignedEvents) {
          final eventId = event['id']?.toString() ?? '';
          if (eventId.isNotEmpty) merged[eventId] = event;
        }
      }
    } catch (e) {
      if (merged.isEmpty && _isMissingTeacherAssignmentsTableError(e)) {
        return getTeacherEvents(teacherId);
      }
      // If this fails due to policy/schema, keep created events.
    }

    final list = merged.values.toList();
    list.sort((a, b) {
      final dateA = _toUtcDate(a['start_at']) ?? DateTime(2000).toUtc();
      final dateB = _toUtcDate(b['start_at']) ?? DateTime(2000).toUtc();
      return dateB.compareTo(dateA); // Descending (latest first)
    });
    _writeListCache(cacheKey, list);
    return list;
  }

  // Get only UPCOMING accessible events for a specific teacher, max 5 limit
  Future<List<Map<String, dynamic>>> getTeacherUpcomingEvents(
    String teacherId,
  ) async {
    try {
      final allAccessible = await getTeacherAccessibleEvents(teacherId);
      final now = DateTime.now().toUtc().add(kManilaOffset);

      // Same criteria as teacher Events tab "Active": published and not ended.
      final upcoming = allAccessible
          .where((e) => isTeacherActiveEvent(e, now: now))
          .toList();

      // Return ascending for upcoming
      upcoming.sort((a, b) {
        final dateA = _toUtcDate(a['start_at']) ?? DateTime(2000).toUtc();
        final dateB = _toUtcDate(b['start_at']) ?? DateTime(2000).toUtc();
        return dateA.compareTo(dateB);
      });

      return upcoming.take(5).toList();
    } catch (e) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getTeacherScanAccessibleEvents(
    String teacherId,
  ) async {
    try {
      List<Map<String, dynamic>> assignmentRows;
      try {
        assignmentRows = List<Map<String, dynamic>>.from(
          await _supabase
              .from('event_teacher_assignments')
              .select('event_id,can_scan,can_manage_assistants')
              .eq('teacher_id', teacherId)
              .limit(200),
        );
      } catch (_) {
        assignmentRows = List<Map<String, dynamic>>.from(
          await _supabase
              .from('event_teacher_assignments')
              .select('event_id,can_scan')
              .eq('teacher_id', teacherId)
              .eq('can_scan', true)
              .limit(200),
        );
      }

      final filtered = assignmentRows.where((row) {
        final scan = row['can_scan'] == true;
        final manage = row['can_manage_assistants'] == true;
        return scan || manage;
      }).toList();

      if (filtered.isEmpty) {
        return [];
      }

      final eventIds = filtered
          .map((row) => row['event_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      if (eventIds.isEmpty) {
        return [];
      }

      // Do not filter by end_at here — null/incorrect end_at was excluding live
      // assignments; scan windows are enforced in _resolveSingleEventScanContext.
      final eventRows = await _supabase
          .from('events')
          .select()
          .inFilter('id', eventIds)
          .inFilter('status', ['published', 'approved'])
          .order('start_at', ascending: true);

      return List<Map<String, dynamic>>.from(eventRows);
    } catch (e) {
      // Don't treat network/schema failures as "no assignment" — callers must
      // distinguish empty assignment from unreachable server.
      rethrow;
    }
  }

  /// Prefer BFF early_out flag — fresher than anon event embeds after web toggle.
  /// For seminar events, also stamps the active seminar's early_out onto that session.
  Future<List<Map<String, dynamic>>> _enrichEventsWithEarlyOut(
    List<Map<String, dynamic>> events,
  ) async {
    if (events.isEmpty || !MobileBackendService.isConfigured) {
      return events;
    }

    final ids = events
        .map((e) => e['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return events;

    final byId = <String, dynamic>{};
    final sessionByEvent = <String, String>{};
    await Future.wait(ids.map((id) async {
      try {
        final res = await _mobileBackend.getEventEarlyOutStatus(eventId: id);
        if (res['ok'] != true) return;
        final earlyOut = res['early_out'];
        if (earlyOut is! Map) return;
        final enabled = earlyOut['enabled'] == true;
        byId[id] = enabled ? earlyOut['enabled_at'] : null;
        final sid = res['session_id']?.toString().trim() ?? '';
        if (sid.isNotEmpty) {
          sessionByEvent[id] = sid;
        }
      } catch (_) {}
    }));

    if (byId.isEmpty) return events;
    return events.map((event) {
      final id = event['id']?.toString() ?? '';
      if (id.isEmpty || !byId.containsKey(id)) return event;
      return {
        ...event,
        'early_out_enabled_at': byId[id],
        if (sessionByEvent[id] != null) '_early_out_session_id': sessionByEvent[id],
      };
    }).toList();
  }

  List<Map<String, dynamic>> _sessionsWithEarlyOutMerged(
    List<Map<String, dynamic>> sessions,
    Map<String, dynamic> event,
  ) {
    final eoSessionId = event['_early_out_session_id']?.toString().trim() ?? '';
    final eoAt = event['early_out_enabled_at'];
    if (eoSessionId.isEmpty) {
      return sessions;
    }
    return sessions.map((session) {
      final sid = session['id']?.toString() ?? '';
      if (sid != eoSessionId) return session;
      // BFF is source of truth right after toggle (anon session row can lag).
      return {...session, 'early_out_enabled_at': eoAt};
    }).toList();
  }

  Map<String, dynamic>? _findOpenSessionCheckOut({
    required Map<String, dynamic> eventSummary,
    required List<Map<String, dynamic>> sessions,
    required DateTime nowUtc,
  }) {
    Map<String, dynamic>? best;
    DateTime? bestEnabled;
    for (final session in sessions) {
      final sessionSummary = {
        'id': session['id']?.toString() ?? '',
        'title': session['title']?.toString() ?? '',
        'topic': session['topic']?.toString() ?? '',
        'display_name': _sessionDisplayName(session),
        'start_at': session['start_at']?.toString() ?? '',
        'end_at': session['end_at']?.toString() ?? '',
        'scan_window_minutes': _sessionWindowMinutes(session),
        'early_out_enabled_at': session['early_out_enabled_at'],
      };
      final open = _resolveCheckOutScanOpen(
        eventSummary: eventSummary,
        endRaw: session['end_at'],
        earlyOutEnabledAt: session['early_out_enabled_at'],
        nowUtc: nowUtc,
        source: 'session',
        session: sessionSummary,
      );
      if (open == null) continue;
      final enabledAt = _toUtcDate(session['early_out_enabled_at']);
      // Prefer an active Early Out window over a normal end+1h window.
      if (enabledAt != null) {
        if (bestEnabled == null || enabledAt.isAfter(bestEnabled)) {
          bestEnabled = enabledAt;
          best = open;
        }
        continue;
      }
      best ??= open;
    }
    return best;
  }

  Map<String, dynamic> _finalizeTeacherScanContext({
    required List<Map<String, dynamic>> events,
    required List<Map<String, dynamic>> contexts,
    required DateTime nowUtc,
  }) {
    if (events.isEmpty) {
      return {
        'ok': true,
        'status': 'no_assignment',
        'scanner_enabled': false,
        'message': 'No published QR scanner assignment found.',
        'context': null,
        'assignments': 0,
        'server_time': nowUtc.toIso8601String(),
      };
    }

    final open = contexts
        .where((ctx) => (ctx['status']?.toString() ?? '') == 'open')
        .toList();
    if (open.length > 1) {
      return {
        'ok': true,
        'status': 'conflict',
        'scanner_enabled': false,
        'message':
            'Multiple assigned events are open at the same time. Contact admin.',
        'context': null,
        'assignments': events.length,
        'server_time': nowUtc.toIso8601String(),
      };
    }

    if (open.length == 1) {
      return {
        'ok': true,
        'status': 'open',
        'scanner_enabled': true,
        'message': open.first['message']?.toString() ?? 'Scanning is open.',
        'context': open.first,
        'assignments': events.length,
        'server_time': nowUtc.toIso8601String(),
      };
    }

    final waiting = contexts
        .where((ctx) => (ctx['status']?.toString() ?? '') == 'waiting')
        .toList();
    if (waiting.isNotEmpty) {
      waiting.sort(
        (a, b) => (a['opens_at']?.toString() ?? '').compareTo(
          b['opens_at']?.toString() ?? '',
        ),
      );
      return {
        'ok': true,
        'status': 'waiting',
        'scanner_enabled': false,
        'message':
            waiting.first['message']?.toString() ?? 'Waiting for scan window.',
        'context': waiting.first,
        'assignments': events.length,
        'server_time': nowUtc.toIso8601String(),
      };
    }

    final closed = contexts
        .where((ctx) => (ctx['status']?.toString() ?? '') == 'closed')
        .toList();
    if (closed.isNotEmpty) {
      closed.sort(
        (a, b) => (b['closes_at']?.toString() ?? '').compareTo(
          a['closes_at']?.toString() ?? '',
        ),
      );
      return {
        'ok': true,
        'status': 'closed',
        'scanner_enabled': false,
        'message': 'Assigned scanner event has already ended.',
        'context': closed.first,
        'assignments': events.length,
        'server_time': nowUtc.toIso8601String(),
      };
    }

    final missing = contexts
        .where((ctx) => (ctx['status']?.toString() ?? '') == 'missing_schedule')
        .toList();
    if (missing.isNotEmpty) {
      return {
        'ok': true,
        'status': 'missing_schedule',
        'scanner_enabled': false,
        'message':
            missing.first['message']?.toString() ??
            'Assigned event has missing schedule.',
        'context': missing.first,
        'assignments': events.length,
        'server_time': nowUtc.toIso8601String(),
      };
    }

    return {
      'ok': true,
      'status': 'closed',
      'scanner_enabled': false,
      'message': 'Scanner is currently unavailable.',
      'context': contexts.isNotEmpty ? contexts.first : null,
      'assignments': events.length,
      'server_time': nowUtc.toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> getTeacherScanContext(String teacherId) async {
    if (teacherId.trim().isEmpty) {
      return {
        'ok': true,
        'status': 'no_assignment',
        'scanner_enabled': false,
        'message': 'Unable to identify your teacher account.',
        'context': null,
        'assignments': 0,
        'server_time': DateTime.now().toUtc().toIso8601String(),
      };
    }

    try {
      final events = <Map<String, dynamic>>[];

      final directEvents = await getTeacherScanAccessibleEvents(teacherId);
      for (final event in List<Map<String, dynamic>>.from(directEvents)) {
        final eventId = event['id']?.toString() ?? '';
        if (eventId.isEmpty) continue;
        events.add(event);
      }

      if (events.isEmpty) {
        final assignmentRows = await _fetchTeacherScanAssignmentRows(teacherId);
        for (final row in List<Map<String, dynamic>>.from(assignmentRows)) {
          final rawEvent = row['events'];
          Map<String, dynamic>? event;
          if (rawEvent is Map<String, dynamic>) {
            event = rawEvent;
          } else if (rawEvent is Map) {
            event = Map<String, dynamic>.from(rawEvent);
          } else if (rawEvent is List &&
              rawEvent.isNotEmpty &&
              rawEvent.first is Map) {
            event = Map<String, dynamic>.from(rawEvent.first as Map);
          }
          if (event == null) continue;
          final status = (event['status']?.toString() ?? '').toLowerCase();
          if (status != 'published' && status != 'approved') continue;
          final eventId = event['id']?.toString() ?? '';
          if (eventId.isEmpty) continue;
          events.add(event);
        }
      }

      if (events.isEmpty) {
        return _finalizeTeacherScanContext(
          events: const [],
          contexts: const [],
          nowUtc: DateTime.now().toUtc(),
        );
      }

      final enrichedEvents = await _enrichEventsWithEarlyOut(events);
      final nowUtc = DateTime.now().toUtc();
      final contexts = <Map<String, dynamic>>[];
      for (final event in enrichedEvents) {
        contexts.add(await _resolveSingleEventScanContext(event, nowUtc));
      }
      return _finalizeTeacherScanContext(
        events: enrichedEvents,
        contexts: contexts,
        nowUtc: nowUtc,
      );
    } catch (_) {
      return {
        'ok': false,
        'status': 'error',
        'scanner_enabled': false,
        'message': 'Unable to load scanner context right now.',
        'context': null,
        'assignments': 0,
        'server_time': DateTime.now().toUtc().toIso8601String(),
      };
    }
  }

  Future<List<Map<String, dynamic>>> _fetchStudentAssistantScanRows(
    String studentId,
  ) async {
    try {
      final rows = await _supabase
          .from('event_assistants')
          .select('event_id,allow_scan,assigned_by_teacher_id')
          .eq('student_id', studentId)
          .eq('allow_scan', true)
          .limit(200);
      return List<Map<String, dynamic>>.from(rows);
    } catch (_) {
      try {
        final rows = await _supabase
            .from('event_assistants')
            .select('event_id,allow_scan,assigned_by_teacher_id')
            .eq('student_id', studentId)
            .eq('allow_scan', true)
            .limit(200);
        return List<Map<String, dynamic>>.from(rows);
      } catch (_) {
        final rows = await _supabase
            .from('event_assistants')
            .select('event_id,allow_scan')
            .eq('student_id', studentId)
            .eq('allow_scan', true)
            .limit(200);
        return List<Map<String, dynamic>>.from(rows);
      }
    }
  }

  Future<Map<String, dynamic>> getStudentScanContext(String studentId) async {
    if (studentId.trim().isEmpty) {
      return {
        'ok': true,
        'status': 'no_assignment',
        'scanner_enabled': false,
        'message': 'Unable to identify your student account.',
        'context': null,
        'assignments': 0,
        'server_time': DateTime.now().toUtc().toIso8601String(),
      };
    }

    try {
      final rows = await _fetchStudentAssistantScanRows(studentId);
      final candidateRows = <Map<String, dynamic>>[];
      final eventIds = <String>{};

      for (final row in List<Map<String, dynamic>>.from(rows)) {
        final assignedBy =
            row['assigned_by_teacher_id']?.toString().trim() ?? '';
        final eventId = row['event_id']?.toString() ?? '';
        if (eventId.isEmpty) continue;
        candidateRows.add({
          'assigned_by_teacher_id': assignedBy,
          'event_id': eventId,
        });
        eventIds.add(eventId);
      }

      if (candidateRows.isEmpty || eventIds.isEmpty) {
        return _finalizeTeacherScanContext(
          events: const [],
          contexts: const [],
          nowUtc: DateTime.now().toUtc(),
        );
      }

      final eventsById = <String, Map<String, dynamic>>{};
      try {
        dynamic eventRows;
        try {
          eventRows = await _supabase
              .from('events')
              .select(
                'id,title,status,start_at,end_at,location,event_mode,event_structure,grace_time',
              )
              .inFilter('id', eventIds.toList())
              .inFilter('status', ['published', 'approved'])
              .limit(500);
        } catch (_) {
          try {
            eventRows = await _supabase
                .from('events')
                .select(
                  'id,title,status,start_at,end_at,location,grace_time',
                )
                .inFilter('id', eventIds.toList())
                .inFilter('status', ['published', 'approved'])
                .limit(500);
          } catch (_) {
            // Last-resort backward compatible schema (no uses_sessions).
            eventRows = await _supabase
                .from('events')
                .select('id,title,status,start_at,end_at,location,grace_time')
                .inFilter('id', eventIds.toList())
                .inFilter('status', ['published', 'approved'])
                .limit(500);
          }
        }

        for (final row in List<Map<String, dynamic>>.from(eventRows)) {
          final id = row['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          eventsById[id] = Map<String, dynamic>.from(row);
        }
      } catch (_) {
        return {
          'ok': false,
          'status': 'error',
          'scanner_enabled': false,
          'message': 'Unable to load scanner context right now.',
          'context': null,
          'assignments': 0,
          'server_time': DateTime.now().toUtc().toIso8601String(),
        };
      }

      // Do not require a follow-up SELECT on event_teacher_assignments here.
      // Assist rows are inserted only via assignEventAssistant()/teacher session,
      // where canTeacherManageAssistants already applied. Reading that table **as the
      // student often returns zero rows under RLS**, which made canTeacherManageAssistants()
      // false for every candidate and yielded "no assignment" permanently.
      final events = <Map<String, dynamic>>[];
      final seenEventIds = <String>{};
      for (final row in candidateRows) {
        final eventId = row['event_id']?.toString().trim() ?? '';
        final assignedBy =
            row['assigned_by_teacher_id']?.toString().trim() ?? '';
        if (eventId.isEmpty) continue;
        if (assignedBy.isEmpty) continue;
        final event = eventsById[eventId];
        if (event == null) continue;
        if (!seenEventIds.add(eventId)) continue;
        events.add(event);
      }

      if (events.isEmpty) {
        return _finalizeTeacherScanContext(
          events: const [],
          contexts: const [],
          nowUtc: DateTime.now().toUtc(),
        );
      }

      final enrichedEvents = await _enrichEventsWithEarlyOut(events);
      final nowUtc = DateTime.now().toUtc();
      final contexts = <Map<String, dynamic>>[];
      for (final event in enrichedEvents) {
        contexts.add(await _resolveSingleEventScanContext(event, nowUtc));
      }
      return _finalizeTeacherScanContext(
        events: enrichedEvents,
        contexts: contexts,
        nowUtc: nowUtc,
      );
    } catch (e) {
      return {
        'ok': false,
        'status': 'error',
        'scanner_enabled': false,
        'message': 'Unable to load scanner context right now. ${e.toString()}',
        'context': null,
        'assignments': 0,
        'server_time': DateTime.now().toUtc().toIso8601String(),
      };
    }
  }

  // Get ALL events (to match admin dashboard for testing)
  Future<List<Map<String, dynamic>>> getAllEvents() async {
    try {
      final response = await _supabase
          .from('events')
          .select()
          .order('start_at', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }

  // Create a new event (pending approval)
  Future<Map<String, dynamic>> createEvent(Map<String, dynamic> payload) async {
    if (MobileBackendService.isConfigured) {
      try {
        final result = await _mobileBackend.createEventSecure(payload);
        return Map<String, dynamic>.from(result);
      } catch (e) {
        return {'ok': false, 'error': 'Failed to create event: ${e.toString()}'};
      }
    }

    try {
      final work = Map<String, dynamic>.from(payload);
      final rawSessions = work['sessions'];
      final sessions = rawSessions is List
          ? rawSessions
                .map((row) => Map<String, dynamic>.from(row as Map))
                .toList()
          : <Map<String, dynamic>>[];
      work.remove('sessions');

      // Event status should forcefully start as 'pending' for Admin approval
      work['status'] = 'pending';
      work['event_for'] =
          (work['event_for']?.toString().trim().isNotEmpty ?? false)
          ? work['event_for']
          : 'All';

      final isSeminarBased =
          (work['event_mode']?.toString().trim() == 'seminar_based') ||
          sessions.isNotEmpty;
      work['event_mode'] = isSeminarBased ? 'seminar_based' : 'simple';
      work['event_structure'] = isSeminarBased
          ? (sessions.length > 1 ? 'two_seminars' : 'one_seminar')
          : 'simple';
      // Never INSERT uses_sessions — column absent on prod (42703 storm).
      work.remove('uses_sessions');

      final optionalColumns = [
        'event_mode',
        'event_structure',
        'event_span',
      ];

      Map<String, dynamic>? createdEvent;
      final workingPayload = Map<String, dynamic>.from(work);
      for (var attempt = 0; attempt < 8; attempt++) {
        try {
          createdEvent = await _supabase
              .from('events')
              .insert(workingPayload)
              .select()
              .single();
          break;
        } catch (e) {
          if (!_isMissingColumnError(e, relation: 'events')) rethrow;
          final err = e.toString().toLowerCase();
          bool removed = false;
          for (final col in optionalColumns) {
            if (workingPayload.containsKey(col) && err.contains(col)) {
              workingPayload.remove(col);
              removed = true;
            }
          }
          if (!removed) {
            for (final col in optionalColumns) {
              if (workingPayload.containsKey(col)) {
                workingPayload.remove(col);
                removed = true;
                break;
              }
            }
          }
          if (!removed) rethrow;
        }
      }

      if (createdEvent == null) {
        return {
          'ok': false,
          'error':
              'Failed to create event: Unable to save event schema fields.',
        };
      }

      if (isSeminarBased && sessions.isNotEmpty) {
        final eventId = createdEvent['id']?.toString() ?? '';
        if (eventId.isNotEmpty) {
          try {
            await _insertEventSessionsForCreate(
              eventId: eventId,
              sessions: sessions,
            );
          } catch (e) {
            // Best-effort rollback so no broken seminar event remains.
            try {
              await _supabase.from('events').delete().eq('id', eventId);
            } catch (_) {}
            return {
              'ok': false,
              'error':
                  'Failed to create event sessions: ${e.toString().replaceFirst('Exception: ', '')}',
            };
          }
        }
      }

      return {'ok': true, 'event': createdEvent};
    } catch (e) {
      return {'ok': false, 'error': 'Failed to create event: ${e.toString()}'};
    }
  }

  Future<void> _insertEventSessionsForCreate({
    required String eventId,
    required List<Map<String, dynamic>> sessions,
  }) async {
    if (sessions.isEmpty) return;
    final supportedColumns = await _eventSessionsSupportedColumns();

    for (var i = 0; i < sessions.length; i++) {
      final source = sessions[i];
      final title = source['title']?.toString().trim() ?? '';
      final startAt = source['start_at']?.toString().trim() ?? '';
      final endAt = source['end_at']?.toString().trim();
      if (title.isEmpty || startAt.isEmpty) {
        throw Exception('Seminar ${i + 1} requires title and start time.');
      }

      final payload = <String, dynamic>{
        'event_id': eventId,
        'title': title,
        'start_at': startAt,
      };

      if (endAt != null && endAt.isNotEmpty) {
        payload['end_at'] = endAt;
      }
      payload['sort_order'] = i;
      payload['scan_window_minutes'] =
          int.tryParse(source['scan_window_minutes']?.toString() ?? '') ??
          int.tryParse(source['attendance_window_minutes']?.toString() ?? '') ??
          30;

      final topic = source['topic']?.toString().trim();
      final description = source['description']?.toString().trim();
      final location = source['location']?.toString().trim();
      if (topic != null && topic.isNotEmpty) payload['topic'] = topic;
      if (description != null && description.isNotEmpty) {
        payload['description'] = description;
      }
      if (location != null && location.isNotEmpty)
        payload['location'] = location;

      final essentialColumns = {'event_id', 'title', 'start_at'};
      final working = <String, dynamic>{};
      for (final entry in payload.entries) {
        if (essentialColumns.contains(entry.key) ||
            supportedColumns.contains(entry.key)) {
          working[entry.key] = entry.value;
        }
      }

      final optionalOrder = [
        'topic',
        'description',
        'location',
        'scan_window_minutes',
        'sort_order',
        'end_at',
      ];

      var inserted = false;
      for (var attempt = 0; attempt < 12; attempt++) {
        try {
          await _supabase.from('event_sessions').insert(working);
          inserted = true;
          break;
        } catch (e) {
          if (_isMissingRelationError(e, relation: 'event_sessions')) {
            throw Exception(
              'event_sessions table is missing. Run session migration first.',
            );
          }

          final lower = e.toString().toLowerCase();
          bool adjusted = false;

          if (_isMissingColumnError(e, relation: 'event_sessions')) {
            for (final key in optionalOrder) {
              if (working.containsKey(key) && lower.contains(key)) {
                working.remove(key);
                adjusted = true;
              }
            }
            if (!adjusted) {
              for (final key in optionalOrder) {
                if (working.containsKey(key)) {
                  working.remove(key);
                  adjusted = true;
                  break;
                }
              }
            }
          }

          if (!adjusted &&
              lower.contains('null value in column') &&
              lower.contains('session_no') &&
              !working.containsKey('session_no')) {
            working['session_no'] = i + 1;
            adjusted = true;
          }
          if (!adjusted &&
              lower.contains('null value in column') &&
              lower.contains('end_at') &&
              !working.containsKey('end_at') &&
              endAt != null &&
              endAt.isNotEmpty) {
            working['end_at'] = endAt;
            adjusted = true;
          }

          if (!adjusted) rethrow;
          if (attempt == 11) rethrow;
        }
      }
      if (!inserted) {
        throw Exception(
          'Unable to insert seminar ${i + 1} due to schema mismatch.',
        );
      }
    }
  }

  // Get participants (registered students) for a specific event
  Future<List<Map<String, dynamic>>> getEventParticipants(
    String eventId,
  ) async {
    Future<List<Map<String, dynamic>>> loadParticipants() async {
      if (MobileBackendService.isConfigured) {
        try {
          final res = await _mobileBackend.getEventRosterSecure(
            eventId: eventId,
            type: 'participants',
          );
          if (res['ok'] == true && res['rows'] is List) {
            final rows = List<Map<String, dynamic>>.from(res['rows'] as List);
            if (rows.isNotEmpty) {
              return _enrichParticipantsWithSeminarAttendance(eventId, rows);
            }
            return rows;
          }
        } catch (_) {}
        // Fail closed — no anon event_registrations fallback after lockdown.
        return <Map<String, dynamic>>[];
      }

      try {
        // No users(...) embed — users table is locked from anon (048).
        final response = await _supabase
            .from('event_registrations')
            .select(
              'id, registered_at, student_id, tickets(*, attendance(*))',
            )
            .eq('event_id', eventId)
            .order('registered_at', ascending: false);

        final list = List<Map<String, dynamic>>.from(response);
        return _enrichParticipantsWithSeminarAttendance(eventId, list);
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    }

    final initial = await loadParticipants();
    if (initial.isEmpty) return initial;

    final materialized = await _materializeMissedAttendanceForEvent(
      eventId,
      participants: initial,
    );
    if (!materialized) {
      return initial;
    }

    return loadParticipants();
  }

  Future<List<Map<String, dynamic>>> getOfflineScannerRoster(
    String eventId,
  ) async {
    if (eventId.trim().isEmpty) return <Map<String, dynamic>>[];

    Future<List<Map<String, dynamic>>> buildFromParticipants(
      List<Map<String, dynamic>> participants,
    ) async {
      if (participants.isEmpty) return <Map<String, dynamic>>[];

      final roster = <Map<String, dynamic>>[];
      for (final participant in participants) {
        final participantRow = Map<String, dynamic>.from(participant);
        final userRaw = participantRow['users'];
        Map<String, dynamic>? user;
        if (userRaw is Map<String, dynamic>) {
          user = userRaw;
        } else if (userRaw is Map) {
          user = Map<String, dynamic>.from(userRaw);
        } else if (userRaw is List &&
            userRaw.isNotEmpty &&
            userRaw.first is Map) {
          user = Map<String, dynamic>.from(userRaw.first as Map);
        }

        final registrationId = (participantRow['id']?.toString() ?? '').trim();
        final participantName = _composeDisplayName(user);
        final participantStudentId =
            (user?['student_id']?.toString() ??
                    participantRow['student_id']?.toString() ??
                    '')
                .trim();
        final participantPhotoUrl = await _resolveAvatarDisplayUrl(
          user?['photo_url']?.toString() ?? '',
        );

        final sessionPresence = <String, bool>{};
        final sessionAttendance = participantRow['session_attendance'];
        if (sessionAttendance is List) {
          for (final item in sessionAttendance) {
            if (item is! Map) continue;
            final row = Map<String, dynamic>.from(item);
            final sessionId = (row['session_id']?.toString() ?? '').trim();
            if (sessionId.isEmpty) continue;
            if (_attendanceRecordCountsAsPresent(row)) {
              sessionPresence[sessionId] = true;
            }
          }
        }

        final ticketsRaw = participantRow['tickets'];
        final tickets = ticketsRaw is List
            ? ticketsRaw
                  .whereType<Map>()
                  .map(Map<String, dynamic>.from)
                  .toList()
            : (ticketsRaw is Map
                  ? <Map<String, dynamic>>[
                      Map<String, dynamic>.from(ticketsRaw),
                    ]
                  : <Map<String, dynamic>>[]);
        if (tickets.isEmpty) continue;
        for (final rawTicket in tickets) {
          final ticket = Map<String, dynamic>.from(rawTicket);
          final ticketId = (ticket['id']?.toString() ?? '').trim();
          if (ticketId.isEmpty) continue;

          var attendanceStatus = 'unscanned';
          final attendanceRaw = ticket['attendance'];
          final attendance = attendanceRaw is List
              ? attendanceRaw
                    .whereType<Map>()
                    .map(Map<String, dynamic>.from)
                    .toList()
              : (attendanceRaw is Map
                    ? <Map<String, dynamic>>[
                        Map<String, dynamic>.from(attendanceRaw),
                      ]
                    : <Map<String, dynamic>>[]);
          if (attendance.isNotEmpty) {
            final row = Map<String, dynamic>.from(attendance.first);
            if (_attendanceRecordCountsAsPresent(row)) {
              attendanceStatus = 'present';
            } else {
              final rawStatus = (row['status']?.toString() ?? '')
                  .trim()
                  .toLowerCase();
              attendanceStatus = rawStatus.isEmpty ? 'unscanned' : rawStatus;
            }
          }

          roster.add({
            'ticket_id': ticketId,
            'registration_id': registrationId,
            'event_id': eventId,
            'participant_name': participantName,
            'participant_student_id': participantStudentId,
            'participant_photo_url': participantPhotoUrl,
            'session_presence': sessionPresence,
            'attendance_status': attendanceStatus,
          });
        }
      }

      return roster;
    }

    try {
      List<Map<String, dynamic>> registrations;
      try {
        final response = await _supabase
            .from('event_registrations')
            .select('id, registered_at, student_id')
            .eq('event_id', eventId)
            .order('registered_at', ascending: false);
        registrations = List<Map<String, dynamic>>.from(response);
      } catch (_) {
        return <Map<String, dynamic>>[];
      }

      if (registrations.isEmpty) {
        return <Map<String, dynamic>>[];
      }

      final registrationIds = registrations
          .map((row) => row['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      if (registrationIds.isEmpty) {
        return <Map<String, dynamic>>[];
      }

      final ticketRows = await _supabase
          .from('tickets')
          .select('id, registration_id')
          .inFilter('registration_id', registrationIds);

      final ticketsByRegistration = <String, List<Map<String, dynamic>>>{};
      final ticketIds = <String>[];
      for (final raw in List<Map<String, dynamic>>.from(ticketRows)) {
        final ticketId = (raw['id']?.toString() ?? '').trim();
        final registrationId = (raw['registration_id']?.toString() ?? '')
            .trim();
        if (ticketId.isEmpty || registrationId.isEmpty) continue;
        ticketIds.add(ticketId);
        ticketsByRegistration
            .putIfAbsent(registrationId, () => <Map<String, dynamic>>[])
            .add({
              'id': ticketId,
              'registration_id': registrationId,
              'attendance': <Map<String, dynamic>>[],
            });
      }

      if (ticketIds.isNotEmpty) {
        try {
          final attendanceRows = await _supabase
              .from('attendance')
              .select('ticket_id,status,check_in_at,last_scanned_at')
              .inFilter('ticket_id', ticketIds);
          for (final raw in List<Map<String, dynamic>>.from(attendanceRows)) {
            final ticketId = (raw['ticket_id']?.toString() ?? '').trim();
            if (ticketId.isEmpty) continue;
            for (final entry in ticketsByRegistration.entries) {
              final ticketIndex = entry.value.indexWhere(
                (ticket) => (ticket['id']?.toString() ?? '').trim() == ticketId,
              );
              if (ticketIndex < 0) continue;
              final ticket = Map<String, dynamic>.from(
                entry.value[ticketIndex],
              );
              final attendance = ticket['attendance'] is List
                  ? List<Map<String, dynamic>>.from(
                      ticket['attendance'] as List,
                    )
                  : <Map<String, dynamic>>[];
              attendance.add(Map<String, dynamic>.from(raw));
              ticket['attendance'] = attendance;
              entry.value[ticketIndex] = ticket;
              break;
            }
          }
        } catch (_) {}
      }

      final participants = registrations.map((registration) {
        final registrationId = (registration['id']?.toString() ?? '').trim();
        return {
          ...registration,
          'tickets': List<Map<String, dynamic>>.from(
            ticketsByRegistration[registrationId] ??
                const <Map<String, dynamic>>[],
          ),
        };
      }).toList();

      final enriched = await _enrichParticipantsWithSeminarAttendance(
        eventId,
        participants,
      );
      final roster = await buildFromParticipants(enriched);
      if (roster.isNotEmpty) {
        return roster;
      }
    } catch (_) {
      // Fallback below.
    }

    final participants = await getEventParticipants(eventId);
    return buildFromParticipants(participants);
  }

  Future<bool> canTeacherManageAssistants(
    String eventId,
    String teacherId,
  ) async {
    try {
      final manageRows = await _supabase
          .from('event_teacher_assignments')
          .select('id')
          .eq('event_id', eventId)
          .eq('teacher_id', teacherId)
          .eq('can_manage_assistants', true)
          .limit(1);
      if (manageRows.isNotEmpty) {
        return true;
      }

      // Backward compatibility:
      // Older assignment rows may have can_scan=true while can_manage_assistants
      // remained false. Treat scanner-assigned teachers as assistant managers.
      final scanRows = await _supabase
          .from('event_teacher_assignments')
          .select('id')
          .eq('event_id', eventId)
          .eq('teacher_id', teacherId)
          .eq('can_scan', true)
          .limit(1);
      return scanRows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool?> verifyTeacherScanEventAccess(
    String eventId,
    String teacherId,
  ) async {
    try {
      return await canTeacherManageAssistants(eventId, teacherId);
    } catch (_) {
      return null;
    }
  }

  Future<bool> canTeacherScanEvent(String eventId, String teacherId) async {
    final verified = await verifyTeacherScanEventAccess(eventId, teacherId);
    return verified == true;
  }

  Future<bool> hasTeacherAnyScanAccess(String teacherId) async {
    try {
      List<Map<String, dynamic>> rows;
      try {
        rows = List<Map<String, dynamic>>.from(
          await _supabase
              .from('event_teacher_assignments')
              .select('event_id,can_scan,can_manage_assistants')
              .eq('teacher_id', teacherId)
              .limit(50),
        );
      } catch (_) {
        rows = List<Map<String, dynamic>>.from(
          await _supabase
              .from('event_teacher_assignments')
              .select('event_id,can_scan')
              .eq('teacher_id', teacherId)
              .eq('can_scan', true)
              .limit(50),
        );
      }

      final assignmentRows = rows.where((row) {
        return row['can_scan'] == true || row['can_manage_assistants'] == true;
      }).toList();

      if (assignmentRows.isEmpty) {
        return false;
      }

      final eventIds = assignmentRows
          .map((row) => row['event_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      if (eventIds.isEmpty) {
        return false;
      }

      final eventRows = await _supabase
          .from('events')
          .select('id')
          .inFilter('id', eventIds)
          .inFilter('status', ['published', 'approved'])
          .limit(1);
      return eventRows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  DateTime? _parseReplayScanAtUtc(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  Future<Map<String, String>> _loadTicketEventBinding(String ticketId) async {
    var registrationId = '';
    var eventId = '';

    try {
      final ticketRes = await _supabase
          .from('tickets')
          .select('id, registration_id, event_registrations!inner(event_id)')
          .eq('id', ticketId)
          .limit(1);

      if (ticketRes.isNotEmpty) {
        registrationId = ticketRes.first['registration_id']?.toString() ?? '';
        final reg = ticketRes.first['event_registrations'];
        if (reg is Map) {
          eventId = reg['event_id']?.toString() ?? '';
        } else if (reg is List && reg.isNotEmpty && reg.first is Map) {
          eventId = (reg.first as Map)['event_id']?.toString() ?? '';
        }
      }
    } catch (_) {
      // Keep fallback query below.
    }

    if (eventId.isEmpty || registrationId.isEmpty) {
      final ticketBaseRes = await _supabase
          .from('tickets')
          .select('id, registration_id')
          .eq('id', ticketId)
          .limit(1);

      if (ticketBaseRes.isNotEmpty) {
        registrationId =
            ticketBaseRes.first['registration_id']?.toString() ??
            registrationId;
      }

      if (registrationId.isNotEmpty) {
        final regRes = await _supabase
            .from('event_registrations')
            .select('event_id')
            .eq('id', registrationId)
            .limit(1);
        if (regRes.isNotEmpty) {
          eventId = regRes.first['event_id']?.toString() ?? eventId;
        }
      }
    }

    return {'registration_id': registrationId, 'event_id': eventId};
  }

  Future<Map<String, dynamic>?> _loadScannerReplayEvent(String eventId) async {
    final id = eventId.trim();
    if (id.isEmpty) return null;

    try {
      final rows = await _supabase
          .from('events')
          .select(
            'id,title,status,start_at,end_at,location,event_mode,event_structure,grace_time',
          )
          .eq('id', id)
          .eq('status', 'published')
          .limit(1);
      if (rows.isNotEmpty) {
        return Map<String, dynamic>.from(rows.first);
      }
    } catch (_) {
      try {
        final rows = await _supabase
            .from('events')
            .select(
              'id,title,status,start_at,end_at,location,grace_time',
            )
            .eq('id', id)
            .eq('status', 'published')
            .limit(1);
        if (rows.isNotEmpty) {
          return Map<String, dynamic>.from(rows.first);
        }
      } catch (_) {
        final rows = await _supabase
            .from('events')
            .select('id,title,status,start_at,end_at,location,grace_time')
            .eq('id', id)
            .eq('status', 'published')
            .limit(1);
        if (rows.isNotEmpty) {
          return Map<String, dynamic>.from(rows.first);
        }
      }
    }

    return null;
  }

  Future<Map<String, dynamic>> _resolveTeacherReplayScanContext({
    required String teacherId,
    required String ticketId,
    required String scannedAtIso,
  }) async {
    final replayAt = _parseReplayScanAtUtc(scannedAtIso);
    if (replayAt == null) {
      return {
        'ok': false,
        'status': 'invalid',
        'message': 'Recorded offline scan time is invalid.',
      };
    }

    final binding = await _loadTicketEventBinding(ticketId);
    final eventId = (binding['event_id'] ?? '').trim();
    if (eventId.isEmpty) {
      return {
        'ok': false,
        'status': 'invalid',
        'message': 'Unable to resolve event for this ticket.',
      };
    }

    final hasAccess = await canTeacherScanEvent(eventId, teacherId);
    if (!hasAccess) {
      return {
        'ok': false,
        'status': 'no_assignment',
        'message': 'QR scanner access for this event was removed by admin.',
      };
    }

    final event = await _loadScannerReplayEvent(eventId);
    if (event == null) {
      return {
        'ok': false,
        'status': 'invalid',
        'message': 'Replay event data is unavailable.',
      };
    }

    final context = await _resolveSingleEventScanContext(event, replayAt);
    final status = (context['status']?.toString() ?? 'closed')
        .trim()
        .toLowerCase();
    if (status != 'open') {
      return {
        'ok': false,
        'status': status.isEmpty ? 'closed' : status,
        'message':
            context['message']?.toString() ??
            'Recorded offline scan is outside the allowed scan window.',
      };
    }

    return {
      'ok': true,
      'status': 'open',
      'scanner_enabled': true,
      'message': 'Replaying offline scan using the recorded scan time.',
      'context': context,
      'assignments': 1,
    };
  }

  Future<Map<String, dynamic>> _resolveAssistantReplayScanContext({
    required String studentId,
    required String ticketId,
    required String scannedAtIso,
  }) async {
    final replayAt = _parseReplayScanAtUtc(scannedAtIso);
    if (replayAt == null) {
      return {
        'ok': false,
        'status': 'invalid',
        'message': 'Recorded offline scan time is invalid.',
      };
    }

    final binding = await _loadTicketEventBinding(ticketId);
    final eventId = (binding['event_id'] ?? '').trim();
    if (eventId.isEmpty) {
      return {
        'ok': false,
        'status': 'invalid',
        'message': 'Unable to resolve event for this ticket.',
      };
    }

    String assignedByTeacherId = '';
    try {
      final rows = await _supabase
          .from('event_assistants')
          .select('assigned_by_teacher_id')
          .eq('event_id', eventId)
          .eq('student_id', studentId)
          .eq('allow_scan', true)
          .limit(1);
      if (rows.isNotEmpty) {
        assignedByTeacherId =
            rows.first['assigned_by_teacher_id']?.toString().trim() ?? '';
      }
    } catch (_) {
      return {
        'ok': false,
        'status': 'error',
        'message': 'Unable to verify assistant scanner access right now.',
      };
    }

    if (assignedByTeacherId.isEmpty) {
      return {
        'ok': false,
        'status': 'no_assignment',
        'message':
            'Scanner assistant access for this event is no longer available.',
      };
    }

    final event = await _loadScannerReplayEvent(eventId);
    if (event == null) {
      return {
        'ok': false,
        'status': 'invalid',
        'message': 'Replay event data is unavailable.',
      };
    }

    final context = await _resolveSingleEventScanContext(event, replayAt);
    final status = (context['status']?.toString() ?? 'closed')
        .trim()
        .toLowerCase();
    if (status != 'open') {
      return {
        'ok': false,
        'status': status.isEmpty ? 'closed' : status,
        'message':
            context['message']?.toString() ??
            'Recorded offline scan is outside the allowed scan window.',
      };
    }

    return {
      'ok': true,
      'status': 'open',
      'scanner_enabled': true,
      'message': 'Replaying offline scan using the recorded scan time.',
      'context': context,
      'assignments': 1,
    };
  }

  Future<List<Map<String, dynamic>>> _enrichParticipantsWithUsers(
    List<Map<String, dynamic>> regs,
  ) async {
    // users table is locked from anon — never SELECT it here.
    // Prefer BFF roster (already includes user fields) or leave rows as-is.
    return regs;
  }

  // Get assistants (authorized student scanners) for a specific event
  Future<List<Map<String, dynamic>>> getEventAssistants(String eventId) async {
    if (MobileBackendService.isConfigured) {
      try {
        final res = await _mobileBackend.getEventRosterSecure(
          eventId: eventId,
          type: 'assistants',
        );
        if (res['ok'] == true && res['rows'] is List) {
          return List<Map<String, dynamic>>.from(res['rows'] as List);
        }
      } catch (_) {
        // Fall back to direct Supabase when BFF is unavailable.
      }
    }

    try {
      // By fetching base table and enriching, we avoid ambiguous relation embed
      // errors from Supabase due to multiple foreign keys linking to users table.
      final base = await _supabase
          .from('event_assistants')
          .select(
            'id, event_id, student_id, allow_scan, assigned_by_teacher_id',
          )
          .eq('event_id', eventId);
      final list = List<Map<String, dynamic>>.from(base);
      return _enrichAssistantsWithUsers(list);
    } catch (e) {
      if (_isMissingAssistantsTableError(e)) {
        return [];
      }
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _enrichAssistantsWithUsers(
    List<Map<String, dynamic>> assistants,
  ) async {
    // users table is locked from anon — BFF roster should already include names.
    return assistants;
  }

  Future<void> _dispatchAssistantAssignmentPush({
    required String eventId,
    required String studentId,
    required String teacherId,
    required bool allowScan,
  }) async {
    final baseUrl = Env.mobilePushApiBaseUrl.trim();
    final eId = eventId.trim();
    final sId = studentId.trim();
    final tId = teacherId.trim();
    if (eId.isEmpty || sId.isEmpty || tId.isEmpty) return;
    final payload = {
      'action': 'assistant_assignment',
      'event_id': eId,
      'student_id': sId,
      'teacher_id': tId,
      'allow_scan': allowScan,
    };
    final pushKey = Env.mobilePushApiKey.trim();

    // Preferred path when PHP backend is hosted.
    if (_isHostedMobilePushConfiguredBaseUrl(baseUrl)) {
      final normalizedBase = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      final uri = Uri.tryParse('$normalizedBase/api/mobile_push_dispatch.php');
      if (uri != null) {
        final headers = <String, String>{'Content-Type': 'application/json'};
        if (pushKey.isNotEmpty) {
          headers['X-Mobile-Push-Key'] = pushKey;
        }

        try {
          final res = await http
              .post(uri, headers: headers, body: jsonEncode(payload))
              .timeout(const Duration(seconds: 10));
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return;
          }
          debugPrint(
            '[push] php dispatch failed (${res.statusCode}): ${res.body}',
          );
        } catch (e) {
          debugPrint('[push] php dispatch error: $e');
        }
      }
    }
  }

  Future<void> _touchAssistantAssignmentTimestamp({
    required String eventId,
    required String studentId,
  }) async {
    // event_assistants writes revoked for anon (052). Timestamps are set by
    // PHP assistant_assign / assistant_update_access — do not anon UPDATE.
  }

  // Assign or re-assign assistant access for an event.
  Future<Map<String, dynamic>> assignEventAssistant({
    required String eventId,
    required String studentId,
    required String teacherId,
    bool allowScan = true,
  }) async {
    final resolvedStudentId = await _resolveUserUuidFromStudentRef(studentId);
    if (resolvedStudentId.isEmpty) {
      return {'ok': false, 'error': 'Missing assistant student account.'};
    }

    final canManage = await canTeacherManageAssistants(eventId, teacherId);
    if (!canManage) {
      return {
        'ok': false,
        'error':
            'Only teachers assigned by admin can manage assistants for this event.',
      };
    }

    try {
      // Enforce participants-only assistant assignment per event/batch.
      final regCheck = await _supabase
          .from('event_registrations')
          .select('id')
          .eq('event_id', eventId)
          .eq('student_id', resolvedStudentId)
          .limit(1);
      if (regCheck.isEmpty) {
        return {
          'ok': false,
          'error':
              'Only registered participants of this event can be assigned as assistants.',
        };
      }
    } catch (_) {
      // If validation query fails, proceed to write path to avoid false blocking.
    }

    if (MobileBackendService.isConfigured) {
      try {
        final result = await _mobileBackend.assignAssistantSecure(
          eventId: eventId,
          studentId: resolvedStudentId,
          allowScan: allowScan,
        );
        if (result['ok'] == true) {
          await _dispatchAssistantAssignmentPush(
            eventId: eventId,
            studentId: resolvedStudentId,
            teacherId: teacherId,
            allowScan: allowScan,
          );
          return {
            'ok': true,
            'assistant': result['assistant'] ?? {
              'event_id': eventId,
              'student_id': resolvedStudentId,
              'allow_scan': allowScan,
              'assigned_by_teacher_id': teacherId,
            },
          };
        }
        return {
          'ok': false,
          'error': result['error']?.toString() ??
              'Failed to assign assistant. Please try again.',
        };
      } catch (e) {
        return {
          'ok': false,
          'error': 'Failed to assign assistant. Please try again.',
          'debug': e.toString(),
        };
      }
    }

    final payload = {
      'event_id': eventId,
      'student_id': resolvedStudentId,
      'allow_scan': allowScan,
      'assigned_by_teacher_id': teacherId,
    };
    final legacyPayload = {
      'event_id': eventId,
      'student_id': resolvedStudentId,
      'allow_scan': allowScan,
    };

    // Fast path: write without requiring SELECT privileges on event_assistants.
    // Some deployments allow insert/update but deny select via RLS.
    try {
      try {
        await _supabase
            .from('event_assistants')
            .upsert(payload, onConflict: 'event_id,student_id');
      } catch (e) {
        if (!_isMissingAssistantAssignedByTeacherColumnError(e)) {
          rethrow;
        }
        await _supabase
            .from('event_assistants')
            .upsert(legacyPayload, onConflict: 'event_id,student_id');
      }
      await _touchAssistantAssignmentTimestamp(
        eventId: eventId,
        studentId: resolvedStudentId,
      );
      await _dispatchAssistantAssignmentPush(
        eventId: eventId,
        studentId: resolvedStudentId,
        teacherId: teacherId,
        allowScan: allowScan,
      );
      return {'ok': true, 'assistant': payload};
    } catch (_) {
      // Keep robust fallback paths below for schemas where upsert/onConflict
      // is unavailable.
    }

    try {
      List<Map<String, dynamic>> existing;
      try {
        existing = List<Map<String, dynamic>>.from(
          await _supabase
              .from('event_assistants')
              .select('id, event_id, student_id, allow_scan, assigned_by_teacher_id')
              .eq('event_id', eventId)
              .eq('student_id', resolvedStudentId)
              .limit(1),
        );
      } catch (existingErr) {
        if (!_isMissingAssistantAssignedByTeacherColumnError(existingErr)) {
          rethrow;
        }
        existing = List<Map<String, dynamic>>.from(
          await _supabase
              .from('event_assistants')
              .select('id, event_id, student_id, allow_scan')
              .eq('event_id', eventId)
              .eq('student_id', resolvedStudentId)
              .limit(1),
        );
      }

      if (existing.isNotEmpty) {
        try {
          await _supabase
              .from('event_assistants')
              .update({
                'allow_scan': allowScan,
                'assigned_by_teacher_id': teacherId,
              })
              .eq('event_id', eventId)
              .eq('student_id', resolvedStudentId);
        } catch (updateErr) {
          if (!_isMissingAssistantAssignedByTeacherColumnError(updateErr)) {
            rethrow;
          }
          await _supabase
              .from('event_assistants')
              .update({'allow_scan': allowScan})
              .eq('event_id', eventId)
              .eq('student_id', resolvedStudentId);
        }

        await _touchAssistantAssignmentTimestamp(
          eventId: eventId,
          studentId: resolvedStudentId,
        );
        await _dispatchAssistantAssignmentPush(
          eventId: eventId,
          studentId: resolvedStudentId,
          teacherId: teacherId,
          allowScan: allowScan,
        );
        final item = Map<String, dynamic>.from(existing.first);
        item['allow_scan'] = allowScan;
        item['assigned_by_teacher_id'] = teacherId;
        return {'ok': true, 'assistant': item};
      }

      List<Map<String, dynamic>> inserted;
      try {
        inserted = List<Map<String, dynamic>>.from(
          await _supabase
              .from('event_assistants')
              .insert(payload)
              .select('id, event_id, student_id, allow_scan, assigned_by_teacher_id'),
        );
      } catch (insertErr) {
        if (!_isMissingAssistantAssignedByTeacherColumnError(insertErr)) {
          rethrow;
        }
        inserted = List<Map<String, dynamic>>.from(
          await _supabase
              .from('event_assistants')
              .insert(legacyPayload)
              .select('id, event_id, student_id, allow_scan'),
        );
      }

      await _touchAssistantAssignmentTimestamp(
        eventId: eventId,
        studentId: resolvedStudentId,
      );
      await _dispatchAssistantAssignmentPush(
        eventId: eventId,
        studentId: resolvedStudentId,
        teacherId: teacherId,
        allowScan: allowScan,
      );
      return {
        'ok': true,
        'assistant': inserted.isNotEmpty ? inserted.first : legacyPayload,
      };
    } catch (e) {
      if (_isMissingAssistantsTableError(e)) {
        return {
          'ok': false,
          'error':
              'Assistant feature is not set up yet in your database. Please apply the latest Supabase migration first.',
        };
      }
      if (_isMissingAssistantAssignedByTeacherColumnError(e)) {
        return {
          'ok': false,
          'error':
              'Assistant assignment needs latest DB migration. Please apply migration 003_event_teacher_assignments.sql.',
        };
      }
      if (_isAccessPolicyError(e)) {
        return {
          'ok': false,
          'error':
              'Assistant assignment is blocked by database access policy. Please contact admin.',
        };
      }
      return {
        'ok': false,
        'error': 'Failed to assign assistant. Please try again.',
        'debug': e.toString(),
      };
    }
  }

  // Update assistant scan access.
  Future<Map<String, dynamic>> updateAssistantAccess({
    String? assistantId,
    String? eventId,
    String? studentId,
    required String teacherId,
    required bool allowScan,
  }) async {
    final eId = eventId?.toString() ?? '';
    if (eId.isEmpty) {
      return {'ok': false, 'error': 'Missing event identity.'};
    }

    final canManage = await canTeacherManageAssistants(eId, teacherId);
    if (!canManage) {
      return {
        'ok': false,
        'error':
            'Only teachers assigned by admin can update assistant access for this event.',
      };
    }

    if (MobileBackendService.isConfigured) {
      try {
        final normalizedId = assistantId?.toString() ?? '';
        final resolvedStudentId = studentId?.toString().trim() ?? '';
        final result = await _mobileBackend.updateAssistantAccessSecure(
          eventId: eId,
          assistantId: normalizedId.isNotEmpty ? normalizedId : null,
          studentId: resolvedStudentId.isNotEmpty ? resolvedStudentId : null,
          allowScan: allowScan,
        );
        if (result['ok'] == true) {
          if (resolvedStudentId.isNotEmpty) {
            await _dispatchAssistantAssignmentPush(
              eventId: eId,
              studentId: resolvedStudentId,
              teacherId: teacherId,
              allowScan: allowScan,
            );
          }
          return {'ok': true};
        }
        return {
          'ok': false,
          'error': result['error']?.toString() ??
              'Failed to update assistant access.',
        };
      } catch (e) {
        return {
          'ok': false,
          'error': 'Failed to update assistant access.',
          'debug': e.toString(),
        };
      }
    }

    try {
      final normalizedId = assistantId?.toString() ?? '';
      if (normalizedId.isNotEmpty) {
        var resolvedStudentId = studentId?.toString().trim() ?? '';
        if (resolvedStudentId.isEmpty) {
          try {
            final row = await _supabase
                .from('event_assistants')
                .select('student_id')
                .eq('id', normalizedId)
                .maybeSingle();
            resolvedStudentId = row?['student_id']?.toString().trim() ?? '';
          } catch (_) {
            // Best-effort lookup only.
          }
        }

        await _supabase
            .from('event_assistants')
            .update({
              'allow_scan': allowScan,
              'assigned_by_teacher_id': teacherId,
            })
            .eq('id', normalizedId);
        if (resolvedStudentId.isNotEmpty) {
          await _touchAssistantAssignmentTimestamp(
            eventId: eId,
            studentId: resolvedStudentId,
          );
          await _dispatchAssistantAssignmentPush(
            eventId: eId,
            studentId: resolvedStudentId,
            teacherId: teacherId,
            allowScan: allowScan,
          );
        }
        return {'ok': true};
      }

      final sId = studentId?.toString() ?? '';
      if (eId.isEmpty || sId.isEmpty) {
        return {'ok': false, 'error': 'Missing assistant identity.'};
      }

      await _supabase
          .from('event_assistants')
          .update({
            'allow_scan': allowScan,
            'assigned_by_teacher_id': teacherId,
          })
          .eq('event_id', eId)
          .eq('student_id', sId);
      await _touchAssistantAssignmentTimestamp(eventId: eId, studentId: sId);
      await _dispatchAssistantAssignmentPush(
        eventId: eId,
        studentId: sId,
        teacherId: teacherId,
        allowScan: allowScan,
      );

      return {'ok': true};
    } catch (e) {
      if (_isMissingAssistantsTableError(e)) {
        return {
          'ok': false,
          'error':
              'Assistant feature is not set up yet in your database. Please apply the latest Supabase migration first.',
        };
      }
      return {
        'ok': false,
        'error': 'Failed to update assistant access. Please try again.',
      };
    }
  }

  Future<Map<String, dynamic>> checkInParticipantAsTeacher(
    String ticketPayload,
    String teacherId, {
    bool dryRun = false,
    String? scannedAtIso,
    String? expectedEventId,
  }) async {
    if (!ticketPayload.startsWith('PULSE-') ||
        ticketPayload.toUpperCase().startsWith('PULSE-EVENT-')) {
      return {
        'ok': false,
        'error': 'Invalid QR Code Format',
        'status': 'invalid',
      };
    }

    if (MobileBackendService.isConfigured) {
      try {
        return Map<String, dynamic>.from(
          await _mobileBackend.scanTicket(
            ticketPayload: ticketPayload,
            dryRun: dryRun,
            scannedAtIso: scannedAtIso,
            expectedEventId: expectedEventId,
          ),
        );
      } catch (e) {
        final msg = e.toString().toLowerCase();
        final likelyOffline = msg.contains('socketexception') ||
            msg.contains('timed out') ||
            msg.contains('failed host lookup') ||
            msg.contains('network');
        return {
          'ok': false,
          'error': likelyOffline
              ? 'Check-in failed. Check internet connection.'
              : 'Check-in failed. Please try again.',
          'status': 'error',
          'debug': e.toString(),
        };
      }
    }

    final ticketId = ticketPayload.replaceFirst('PULSE-', '').trim();
    final replayRequested =
        !dryRun && ((scannedAtIso?.trim().isNotEmpty) ?? false);

    try {
      var scanContext = await getTeacherScanContext(teacherId);
      var contextStatus = (scanContext['status']?.toString() ?? '')
          .toLowerCase();
      if (scanContext['ok'] != true || contextStatus != 'open') {
        if (!replayRequested) {
          return {
            'ok': false,
            'error':
                scanContext['message']?.toString() ??
                'Scanner is not open for this schedule.',
            'status': contextStatus.isEmpty
                ? (scanContext['status']?.toString() ?? 'error')
                : contextStatus,
          };
        }

        final replayContext = await _resolveTeacherReplayScanContext(
          teacherId: teacherId,
          ticketId: ticketId,
          scannedAtIso: scannedAtIso ?? '',
        );
        if (replayContext['ok'] != true) {
          return {
            'ok': false,
            'error':
                replayContext['message']?.toString() ??
                'Recorded offline scan is outside the allowed scan window.',
            'status': replayContext['status']?.toString() ?? 'error',
          };
        }
        scanContext = replayContext;
        contextStatus = 'open';
      }

      final context = scanContext['context'];
      final contextMap = context is Map<String, dynamic>
          ? context
          : (context is Map ? Map<String, dynamic>.from(context) : null);
      final eventMapRaw = contextMap?['event'];
      final eventMap = eventMapRaw is Map<String, dynamic>
          ? eventMapRaw
          : (eventMapRaw is Map
                ? Map<String, dynamic>.from(eventMapRaw)
                : <String, dynamic>{});
      final activeEventId = eventMap['id']?.toString() ?? '';
      if (activeEventId.isEmpty) {
        return {
          'ok': false,
          'error': 'Active scanner event is missing.',
          'status': 'error',
        };
      }

      final binding = await _loadTicketEventBinding(ticketId);
      final ticketEventId = (binding['event_id'] ?? '').trim();
      final registrationId = (binding['registration_id'] ?? '').trim();

      if (registrationId.isEmpty) {
        return {
          'ok': false,
          'error':
              'Ticket is not recognized for this scanner. It may belong to a different event.',
          'status': 'invalid',
        };
      }

      if (ticketEventId.isEmpty) {
        return {
          'ok': false,
          'error': 'Unable to resolve event for this ticket.',
          'status': 'invalid',
        };
      }

      if (ticketEventId != activeEventId) {
        return {
          'ok': false,
          'error':
              'This ticket belongs to a different event. Please scan it in the correct event scanner.',
          'status': 'wrong_event',
        };
      }

      final nowIso = DateTime.now().toUtc().toIso8601String();
      final effectiveScanAtIso = _normalizedScanTimestampIso(
        scannedAtIso,
        fallbackIso: nowIso,
      );
      final participantIdentity =
          await _resolveParticipantIdentityForRegistration(registrationId);
      final participantName = (participantIdentity['name'] ?? '').trim();
      final participantPhotoUrl = (participantIdentity['photo_url'] ?? '')
          .trim();
      final participantStudentId = (participantIdentity['student_id'] ?? '')
          .trim();
      final source = contextMap?['source']?.toString().toLowerCase() ?? 'event';

      if (source == 'session') {
        final sessionRaw = contextMap?['session'];
        final session = sessionRaw is Map<String, dynamic>
            ? sessionRaw
            : (sessionRaw is Map
                  ? Map<String, dynamic>.from(sessionRaw)
                  : <String, dynamic>{});
        final sessionId = session['id']?.toString() ?? '';
        if (sessionId.isEmpty) {
          return {
            'ok': false,
            'error': 'Active seminar context is missing.',
            'status': 'error',
          };
        }

        return _recordSessionAttendance(
          ticketId: ticketId,
          registrationId: registrationId,
          sessionId: sessionId,
          teacherId: teacherId,
          nowIso: nowIso,
          scannedAtIso: effectiveScanAtIso,
          session: session,
          participantName: participantName,
          participantPhotoUrl: participantPhotoUrl,
          participantStudentId: participantStudentId,
          dryRun: dryRun,
        );
      }

      final attendanceRows = await _supabase
          .from('attendance')
          .select('id,status,check_in_at')
          .eq('ticket_id', ticketId)
          .limit(1);
      if (attendanceRows.isEmpty) {
        return {
          'ok': false,
          'error': 'Attendance record is missing for this ticket.',
          'status': 'invalid',
        };
      }

      final attendance = Map<String, dynamic>.from(attendanceRows.first);
      final alreadyCheckedIn =
          _isCheckedInStatus(attendance['status']) ||
          (attendance['check_in_at']?.toString().trim().isNotEmpty ?? false);
      if (alreadyCheckedIn) {
        if (!dryRun &&
            _shouldApplyIncomingCheckIn(
              incomingScanAtIso: effectiveScanAtIso,
              recordedCheckInAt: attendance['check_in_at'],
            )) {
          await _supabase
              .from('attendance')
              .update({'status': 'present', 'check_in_at': effectiveScanAtIso})
              .eq('ticket_id', ticketId);

          return {
            'ok': true,
            'ticket_id': ticketId,
            'status': 'present',
            'participant_name': participantName,
            'participant_photo_url': participantPhotoUrl,
            'participant_student_id': participantStudentId,
            'message':
                'Check-in synchronized using the earliest recorded scan time.',
          };
        }
        return {
          'ok': false,
          'error': 'Ticket already checked in.',
          'status': 'already_checked_in',
          'participant_name': participantName,
          'participant_photo_url': participantPhotoUrl,
          'participant_student_id': participantStudentId,
        };
      }

      if (dryRun) {
        return {
          'ok': true,
          'ticket_id': ticketId,
          'status': 'ready_for_confirmation',
          'participant_name': participantName,
          'participant_photo_url': participantPhotoUrl,
          'participant_student_id': participantStudentId,
          'message': 'Review participant, then confirm check-in.',
        };
      }

      await _supabase
          .from('attendance')
          .update({
            'status': 'present',
            'check_in_at': effectiveScanAtIso,
            'last_scanned_at': effectiveScanAtIso,
          })
          .eq('ticket_id', ticketId);

      return {
        'ok': true,
        'ticket_id': ticketId,
        'status': 'present',
        'participant_name': participantName,
        'participant_photo_url': participantPhotoUrl,
        'participant_student_id': participantStudentId,
        'message': 'Check-in successful!',
      };
    } catch (e) {
      final msg = e.toString().toLowerCase();
      final likelyOffline =
          msg.contains('socketexception') ||
          msg.contains('timed out') ||
          msg.contains('failed host lookup') ||
          msg.contains('network');
      String errorMessage = likelyOffline
          ? 'Check-in failed. Check internet connection.'
          : 'Check-in failed. Please try again.';

      if (!likelyOffline) {
        if (_isUniqueViolationError(e)) {
          errorMessage =
              'This ticket is already recorded for the active schedule.';
        } else if (msg.contains('attendance_status_check')) {
          errorMessage = 'Check-in failed due to attendance status mismatch.';
        } else if (_isAccessPolicyError(e)) {
          errorMessage =
              'Check-in failed due to access policy. Please contact admin.';
        } else if (_isEventSessionAttendanceUnavailableError(e) ||
            _isMissingColumnError(
              e,
              relation: 'attendance',
              column: 'session_id',
            )) {
          errorMessage =
              'Seminar attendance storage is not available yet. Please apply the latest seminar attendance migration first.';
        }
      }

      return {
        'ok': false,
        'error': errorMessage,
        'status': 'error',
        'debug': e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> checkInParticipantAsAssistant(
    String ticketPayload,
    String studentId, {
    bool dryRun = false,
    String? scannedAtIso,
    String? expectedEventId,
  }) async {
    if (!ticketPayload.startsWith('PULSE-') ||
        ticketPayload.toUpperCase().startsWith('PULSE-EVENT-')) {
      return {
        'ok': false,
        'error': 'Invalid QR Code Format',
        'status': 'invalid',
      };
    }

    if (MobileBackendService.isConfigured) {
      try {
        return Map<String, dynamic>.from(
          await _mobileBackend.scanTicket(
            ticketPayload: ticketPayload,
            dryRun: dryRun,
            scannedAtIso: scannedAtIso,
            expectedEventId: expectedEventId,
          ),
        );
      } catch (e) {
        final msg = e.toString().toLowerCase();
        final likelyOffline = msg.contains('socketexception') ||
            msg.contains('timed out') ||
            msg.contains('failed host lookup') ||
            msg.contains('network');
        return {
          'ok': false,
          'error': likelyOffline
              ? 'Check-in failed. Check internet connection.'
              : 'Check-in failed. Please try again.',
          'status': 'error',
          'debug': e.toString(),
        };
      }
    }

    final ticketId = ticketPayload.replaceFirst('PULSE-', '').trim();
    final replayRequested =
        !dryRun && ((scannedAtIso?.trim().isNotEmpty) ?? false);

    try {
      var scanContext = await getStudentScanContext(studentId);
      var contextStatus = (scanContext['status']?.toString() ?? '')
          .toLowerCase();
      if (scanContext['ok'] != true || contextStatus != 'open') {
        if (!replayRequested) {
          return {
            'ok': false,
            'error':
                scanContext['message']?.toString() ??
                'Scanner is not open for this schedule.',
            'status': contextStatus.isEmpty
                ? (scanContext['status']?.toString() ?? 'error')
                : contextStatus,
          };
        }

        final replayContext = await _resolveAssistantReplayScanContext(
          studentId: studentId,
          ticketId: ticketId,
          scannedAtIso: scannedAtIso ?? '',
        );
        if (replayContext['ok'] != true) {
          return {
            'ok': false,
            'error':
                replayContext['message']?.toString() ??
                'Recorded offline scan is outside the allowed scan window.',
            'status': replayContext['status']?.toString() ?? 'error',
          };
        }
        scanContext = replayContext;
        contextStatus = 'open';
      }

      final context = scanContext['context'];
      final contextMap = context is Map<String, dynamic>
          ? context
          : (context is Map ? Map<String, dynamic>.from(context) : null);
      final eventMapRaw = contextMap?['event'];
      final eventMap = eventMapRaw is Map<String, dynamic>
          ? eventMapRaw
          : (eventMapRaw is Map
                ? Map<String, dynamic>.from(eventMapRaw)
                : <String, dynamic>{});
      final activeEventId = eventMap['id']?.toString() ?? '';
      if (activeEventId.isEmpty) {
        return {
          'ok': false,
          'error': 'Active scanner event is missing.',
          'status': 'error',
        };
      }

      final binding = await _loadTicketEventBinding(ticketId);
      final ticketEventId = (binding['event_id'] ?? '').trim();
      final registrationId = (binding['registration_id'] ?? '').trim();

      if (registrationId.isEmpty) {
        return {
          'ok': false,
          'error':
              'Ticket is not recognized for this scanner. It may belong to a different event.',
          'status': 'invalid',
        };
      }

      if (ticketEventId.isEmpty) {
        return {
          'ok': false,
          'error': 'Unable to resolve event for this ticket.',
          'status': 'invalid',
        };
      }

      if (ticketEventId != activeEventId) {
        return {
          'ok': false,
          'error':
              'This ticket belongs to a different event. Please scan it in the correct event scanner.',
          'status': 'wrong_event',
        };
      }

      final nowIso = DateTime.now().toUtc().toIso8601String();
      final effectiveScanAtIso = _normalizedScanTimestampIso(
        scannedAtIso,
        fallbackIso: nowIso,
      );
      final participantIdentity =
          await _resolveParticipantIdentityForRegistration(registrationId);
      final participantName = (participantIdentity['name'] ?? '').trim();
      final participantPhotoUrl = (participantIdentity['photo_url'] ?? '')
          .trim();
      final participantStudentId = (participantIdentity['student_id'] ?? '')
          .trim();
      final source = contextMap?['source']?.toString().toLowerCase() ?? 'event';

      if (source == 'session') {
        final sessionRaw = contextMap?['session'];
        final session = sessionRaw is Map<String, dynamic>
            ? sessionRaw
            : (sessionRaw is Map
                  ? Map<String, dynamic>.from(sessionRaw)
                  : <String, dynamic>{});
        final sessionId = session['id']?.toString() ?? '';
        if (sessionId.isEmpty) {
          return {
            'ok': false,
            'error': 'Active seminar context is missing.',
            'status': 'error',
          };
        }

        return _recordSessionAttendance(
          ticketId: ticketId,
          registrationId: registrationId,
          sessionId: sessionId,
          teacherId: studentId,
          nowIso: nowIso,
          scannedAtIso: effectiveScanAtIso,
          session: session,
          participantName: participantName,
          participantPhotoUrl: participantPhotoUrl,
          participantStudentId: participantStudentId,
          dryRun: dryRun,
        );
      }

      final attendanceRows = await _supabase
          .from('attendance')
          .select('id,status,check_in_at')
          .eq('ticket_id', ticketId)
          .limit(1);
      if (attendanceRows.isEmpty) {
        return {
          'ok': false,
          'error': 'Attendance record is missing for this ticket.',
          'status': 'invalid',
        };
      }

      final attendance = Map<String, dynamic>.from(attendanceRows.first);
      final alreadyCheckedIn =
          _isCheckedInStatus(attendance['status']) ||
          (attendance['check_in_at']?.toString().trim().isNotEmpty ?? false);
      if (alreadyCheckedIn) {
        if (!dryRun &&
            _shouldApplyIncomingCheckIn(
              incomingScanAtIso: effectiveScanAtIso,
              recordedCheckInAt: attendance['check_in_at'],
            )) {
          await _supabase
              .from('attendance')
              .update({'status': 'present', 'check_in_at': effectiveScanAtIso})
              .eq('ticket_id', ticketId);

          return {
            'ok': true,
            'ticket_id': ticketId,
            'status': 'present',
            'participant_name': participantName,
            'participant_photo_url': participantPhotoUrl,
            'participant_student_id': participantStudentId,
            'message':
                'Check-in synchronized using the earliest recorded scan time.',
          };
        }
        return {
          'ok': false,
          'error': 'Ticket already checked in.',
          'status': 'already_checked_in',
          'participant_name': participantName,
          'participant_photo_url': participantPhotoUrl,
          'participant_student_id': participantStudentId,
        };
      }

      if (dryRun) {
        return {
          'ok': true,
          'ticket_id': ticketId,
          'status': 'ready_for_confirmation',
          'participant_name': participantName,
          'participant_photo_url': participantPhotoUrl,
          'participant_student_id': participantStudentId,
          'message': 'Review participant, then confirm check-in.',
        };
      }

      await _supabase
          .from('attendance')
          .update({
            'status': 'present',
            'check_in_at': effectiveScanAtIso,
            'last_scanned_at': effectiveScanAtIso,
          })
          .eq('ticket_id', ticketId);

      return {
        'ok': true,
        'ticket_id': ticketId,
        'status': 'present',
        'participant_name': participantName,
        'participant_photo_url': participantPhotoUrl,
        'participant_student_id': participantStudentId,
        'message': 'Check-in successful!',
      };
    } catch (e) {
      final msg = e.toString().toLowerCase();
      final likelyOffline =
          msg.contains('socketexception') ||
          msg.contains('timed out') ||
          msg.contains('failed host lookup') ||
          msg.contains('network');
      String errorMessage = likelyOffline
          ? 'Check-in failed. Check internet connection.'
          : 'Check-in failed. Please try again.';

      if (!likelyOffline) {
        if (_isUniqueViolationError(e)) {
          errorMessage =
              'This ticket is already recorded for the active schedule.';
        } else if (msg.contains('attendance_status_check')) {
          errorMessage = 'Check-in failed due to attendance status mismatch.';
        } else if (_isAccessPolicyError(e)) {
          errorMessage =
              'Check-in failed due to access policy. Please contact admin.';
        } else if (_isEventSessionAttendanceUnavailableError(e) ||
            _isMissingColumnError(
              e,
              relation: 'attendance',
              column: 'session_id',
            )) {
          errorMessage =
              'Seminar attendance storage is not available yet. Please apply the latest seminar attendance migration first.';
        }
      }

      return {
        'ok': false,
        'error': errorMessage,
        'status': 'error',
        'debug': e.toString(),
      };
    }
  }

  static String buildEventQrPayload(String eventId) {
    final id = eventId.trim();
    if (id.isEmpty) return '';
    return 'PULSE-EVENT-$id';
  }

  Future<Map<String, dynamic>> checkInSelfViaEventQr(
    String eventQrPayload,
  ) async {
    final payload = eventQrPayload.trim();
    if (!payload.toUpperCase().startsWith('PULSE-EVENT-')) {
      return {
        'ok': false,
        'error': 'Invalid event QR code.',
        'status': 'invalid',
      };
    }

    if (MobileBackendService.isConfigured) {
      try {
        return Map<String, dynamic>.from(
          await _mobileBackend.selfCheckInViaEventQr(
            eventQrPayload: payload,
          ),
        );
      } catch (e) {
        final msg = e.toString().toLowerCase();
        final likelyOffline = msg.contains('socketexception') ||
            msg.contains('timed out') ||
            msg.contains('failed host lookup') ||
            msg.contains('network');
        return {
          'ok': false,
          'error': likelyOffline
              ? 'Check-in failed. Check internet connection.'
              : 'Check-in failed. Please try again.',
          'status': 'error',
          'debug': e.toString(),
        };
      }
    }

    return {
      'ok': false,
      'error': 'Mobile backend is not configured.',
      'status': 'error',
    };
  }

  // Check in a participant via their ticket token/ID
  // Enhanced with time validation matching JADX QRCheckInActivity logic
  Future<Map<String, dynamic>> checkInParticipant(String ticketPayload) async {
    try {
      // Expecting payload like "PULSE-{UUID}"
      if (!ticketPayload.startsWith('PULSE-')) {
        return {
          'ok': false,
          'error': 'Invalid QR Code Format',
          'status': 'invalid',
        };
      }

      final ticketId = ticketPayload.replaceFirst('PULSE-', '').trim();

      // 1. Find attendance record + ticket + registration + event
      final existingParams = await _supabase
          .from('attendance')
          .select('*')
          .eq('ticket_id', ticketId)
          .limit(1);

      if (existingParams.isEmpty) {
        return {
          'ok': false,
          'error':
              'Ticket is not recognized for this scanner. It may belong to a different event.',
          'status': 'invalid',
        };
      }

      final attendance = existingParams[0];
      final isCheckedIn = _isCheckedInStatus(attendance['status']);

      // 2. Get event info via ticket -> registration -> event
      Map<String, dynamic>? eventData;
      try {
        final ticketRes = await _supabase
            .from('tickets')
            .select(
              'id, registration_id, event_registrations!inner(event_id, events!inner(*))',
            )
            .eq('id', ticketId)
            .limit(1);

        if (ticketRes.isNotEmpty) {
          final reg = ticketRes[0]['event_registrations'];
          if (reg != null) {
            eventData = reg['events'] as Map<String, dynamic>?;
          }
        }
      } catch (_) {
        // Ignore and continue to fallback.
      }

      if (eventData == null) {
        try {
          final ticketBaseRes = await _supabase
              .from('tickets')
              .select('id, registration_id')
              .eq('id', ticketId)
              .limit(1);

          if (ticketBaseRes.isNotEmpty) {
            final registrationId =
                ticketBaseRes.first['registration_id']?.toString() ?? '';
            if (registrationId.isNotEmpty) {
              final regRes = await _supabase
                  .from('event_registrations')
                  .select('event_id')
                  .eq('id', registrationId)
                  .limit(1);

              if (regRes.isNotEmpty) {
                final eventId = regRes.first['event_id']?.toString() ?? '';
                if (eventId.isNotEmpty) {
                  final eventRes = await _supabase
                      .from('events')
                      .select('*')
                      .eq('id', eventId)
                      .limit(1);
                  if (eventRes.isNotEmpty) {
                    eventData = Map<String, dynamic>.from(eventRes.first);
                  }
                }
              }
            }
          }
        } catch (_) {
          // Keep eventData null; fallback check-in below still works.
        }
      }

      // 3. Time validation (if we have event data)
      if (eventData != null) {
        final now = DateTime.now();
        final startAt = eventData['start_at'] != null
            ? DateTime.tryParse(eventData['start_at'])
            : null;
        final endAt = eventData['end_at'] != null
            ? DateTime.tryParse(eventData['end_at'])
            : null;
        final graceMinutes =
            int.tryParse(eventData['grace_time']?.toString() ?? '0') ?? 0;

        if (startAt != null) {
          // Too early check - more than 30 minutes before start
          if (now.isBefore(startAt.subtract(const Duration(minutes: 30)))) {
            return {
              'ok': false,
              'error':
                  'Event hasn\'t started yet. Check-in opens 30 minutes before the event.',
              'status': 'too_early',
            };
          }

          // Already ended check
          if (endAt != null && now.isAfter(endAt)) {
            // If already checked in, let them check out
            if (isCheckedIn && attendance['check_out_at'] == null) {
              await _supabase
                  .from('attendance')
                  .update({'check_out_at': now.toIso8601String()})
                  .eq('ticket_id', ticketId);
              return {
                'ok': true,
                'status': 'checked_out',
                'message': 'Check-out recorded! Event has ended.',
              };
            }
            return {
              'ok': false,
              'error': 'This event has already ended.',
              'status': 'ended',
            };
          }

          // Already checked in - allow check-out
          if (isCheckedIn) {
            if (attendance['check_out_at'] != null) {
              return {
                'ok': false,
                'error': 'Ticket already fully used (checked in & out).',
                'status': 'used',
              };
            }

            final checkInAt = attendance['check_in_at'] != null
                ? DateTime.tryParse(attendance['check_in_at'].toString())
                : null;
            if (checkInAt != null &&
                now.difference(checkInAt).abs() < _minSecondsBeforeCheckout) {
              return {
                'ok': false,
                'error':
                    'Already checked in. Please wait a few seconds before scanning again.',
                'status': 'already_checked_in',
              };
            }

            await _supabase
                .from('attendance')
                .update({'check_out_at': now.toIso8601String()})
                .eq('ticket_id', ticketId);
            return {
              'ok': true,
              'status': 'checked_out',
              'message': 'Check-out successful!',
            };
          }

          // Determine status for first check-in
          bool isLate = false;
          if (graceMinutes > 0) {
            final graceDeadline = startAt.add(Duration(minutes: graceMinutes));
            isLate = now.isAfter(graceDeadline);
          } else {
            isLate = now.isAfter(startAt);
          }
          final isEarly = now.isBefore(startAt);
          final checkInStatus = isEarly
              ? 'early'
              : (isLate ? 'late' : 'present');
          final checkInMessage = isEarly
              ? 'Check-in successful (EARLY)'
              : (isLate
                    ? 'Check-in successful (LATE)'
                    : 'Check-in successful - On Time!');

          await _supabase
              .from('attendance')
              .update({
                'status': checkInStatus,
                'check_in_at': now.toIso8601String(),
              })
              .eq('ticket_id', ticketId);

          return {
            'ok': true,
            'ticket_id': ticketId,
            'status': checkInStatus,
            'message': checkInMessage,
          };
        }
      }

      // Fallback: no event timing data, just check in
      if (isCheckedIn) {
        return {
          'ok': false,
          'error': 'Ticket has already been scanned.',
          'status': 'used',
        };
      }

      await _supabase
          .from('attendance')
          .update({
            'status': 'present',
            'check_in_at': DateTime.now().toIso8601String(),
          })
          .eq('ticket_id', ticketId);

      return {
        'ok': true,
        'ticket_id': ticketId,
        'status': 'present',
        'message': 'Check-in successful!',
      };
    } catch (e) {
      final msg = e.toString().toLowerCase();
      final likelyOffline =
          msg.contains('socketexception') ||
          msg.contains('timed out') ||
          msg.contains('failed host lookup') ||
          msg.contains('network');

      String errorMessage = likelyOffline
          ? 'Check-in failed. Check internet connection.'
          : 'Check-in failed. Please try again.';

      if (!likelyOffline) {
        if (msg.contains('attendance_status_check')) {
          errorMessage = 'Check-in failed due to attendance status mismatch.';
        } else if (msg.contains('permission denied') ||
            msg.contains('row level security')) {
          errorMessage =
              'Check-in failed due to access policy. Please contact admin.';
        }
      }

      return {'ok': false, 'error': errorMessage, 'status': 'error'};
    }
  }

  // Get evaluation questions for an event
  Future<List<Map<String, dynamic>>> getEvaluationQuestions(
    String eventId,
  ) async {
    try {
      final response = await _supabase
          .from('evaluation_questions')
          .select('id, question_text, field_type, required, sort_order')
          .eq('event_id', eventId)
          .order('sort_order', ascending: true);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }

  // Submit evaluation answers
  Future<Map<String, dynamic>> submitEvaluation({
    required String eventId,
    required String studentId,
    required List<Map<String, dynamic>> answers,
  }) async {
    try {
      final nowIso = DateTime.now().toIso8601String();
      final eventPayloads = <Map<String, dynamic>>[];
      final sessionPayloads = <Map<String, dynamic>>[];

      for (final ans in answers) {
        final questionId = ans['question_id']?.toString() ?? '';
        final answerText = ans['answer_text']?.toString() ?? '';
        if (questionId.isEmpty || !_isNonEmptyAnswer(answerText)) {
          continue;
        }

        final sessionId = ans['session_id']?.toString() ?? '';
        final payload = {
          'question_id': questionId,
          'student_id': studentId,
          'answer_text': answerText,
          'submitted_at': nowIso,
        };

        if (sessionId.isNotEmpty) {
          sessionPayloads.add({...payload, 'session_id': sessionId});
        } else {
          eventPayloads.add({...payload, 'event_id': eventId});
        }
      }

      if (eventPayloads.isEmpty && sessionPayloads.isEmpty) {
        return {'ok': false, 'error': 'No answers provided.'};
      }

      if (MobileBackendService.isConfigured) {
        if (eventPayloads.isNotEmpty) {
          final res = await _mobileBackend.secureWrite('evaluation_upsert', {
            'table': 'evaluation_answers',
            'rows': eventPayloads,
          });
          if (res['ok'] != true) {
            return {
              'ok': false,
              'error': res['error']?.toString() ?? 'Evaluation submission failed.',
            };
          }
        }
        if (sessionPayloads.isNotEmpty) {
          final res = await _mobileBackend.secureWrite('evaluation_upsert', {
            'table': 'event_session_evaluation_answers',
            'rows': sessionPayloads,
          });
          if (res['ok'] != true) {
            return {
              'ok': false,
              'error': res['error']?.toString() ?? 'Evaluation submission failed.',
            };
          }
        }

        // Separate BFF step: issue cert only after answers are persisted + eval complete.
        // Eval save already succeeded — never fail the whole submit on cert claim.
        // One attempt only (no soft-heal retries — those recreated deleted DB rows).
        Map<String, dynamic>? cert;
        try {
          final certRes = await _mobileBackend.secureWrite('certificate_auto_issue', {
            'event_id': eventId,
          });
          final raw = certRes['certificate'];
          final map = raw is Map
              ? Map<String, dynamic>.from(raw)
              : (certRes['ok'] == true
                  ? <String, dynamic>{'ok': true, 'issued': 0, 'skipped': ''}
                  : null);
          cert = map;
          // ignore: avoid_print
          debugPrint('[cert] claim issued=${map?['issued']} skipped=${map?['skipped']}');
        } catch (e) {
          // ignore: avoid_print
          debugPrint('[cert] claim error: $e');
          cert = {'ok': true, 'issued': 0, 'skipped': ''};
        }
        return {
          'ok': true,
          if (cert != null) 'certificate': cert,
        };
      }

      // Fail closed: evaluation writes are locked to service-role / PHP BFF.
      return {
        'ok': false,
        'error': 'Secure backend is required to submit evaluation.',
      };
    } catch (e) {
      return {'ok': false, 'error': 'Evaluation submission failed.'};
    }
  }

  // Check if evaluation is already submitted
  Future<bool> isEvaluationSubmitted(String eventId, String studentId) async {
    try {
      final bundle = await getEvaluationBundle(
        eventId: eventId,
        studentId: studentId,
      );
      return bundle['ok'] == true &&
          bundle['is_eligible'] == true &&
          bundle['is_complete'] == true;
    } catch (e) {
      return false;
    }
  }

  // Get student's submitted answers for an event
  Future<List<Map<String, dynamic>>> getStudentAnswers(
    String eventId,
    String studentId,
  ) async {
    try {
      final response = await _supabase
          .from('evaluation_answers')
          .select('question_id, answer_text, submitted_at')
          .eq('event_id', eventId)
          .eq('student_id', studentId);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, String>> _loadRegistrationContext(
    String eventId,
    String studentId,
  ) async {
    try {
      final rows = await _supabase
          .from('event_registrations')
          .select('id, tickets(id)')
          .eq('event_id', eventId)
          .eq('student_id', studentId)
          .limit(1);

      if (rows.isEmpty) {
        return const {};
      }

      final row = Map<String, dynamic>.from(rows.first);
      final registrationId = row['id']?.toString() ?? '';
      String ticketId = '';
      final rawTickets = row['tickets'];
      if (rawTickets is List &&
          rawTickets.isNotEmpty &&
          rawTickets.first is Map) {
        ticketId = (rawTickets.first as Map)['id']?.toString() ?? '';
      } else if (rawTickets is Map) {
        ticketId = rawTickets['id']?.toString() ?? '';
      }

      return {'registration_id': registrationId, 'ticket_id': ticketId};
    } catch (_) {
      return const {};
    }
  }

  bool _hasCheckInRecord(Map<String, dynamic> row) {
    return (row['check_in_at']?.toString().trim().isNotEmpty ?? false) ||
        _isCheckedInStatus(row['status']);
  }

  bool _hasCheckOutRecord(Map<String, dynamic> row) {
    return row['check_out_at']?.toString().trim().isNotEmpty ?? false;
  }

  bool _hasCompletedAttendanceForEval(Map<String, dynamic> row) {
    return _hasCheckInRecord(row) && _hasCheckOutRecord(row);
  }

  /// Latest-ending seminar id for multi-seminar events (null = simple / 1 seminar).
  String? _finalSeminarIdForEvaluation(List<Map<String, dynamic>> sessions) {
    if (sessions.length <= 1) return null;
    String? finalId;
    DateTime? finalEnd;
    for (final session in sessions) {
      final sid = session['id']?.toString().trim() ?? '';
      if (sid.isEmpty) continue;
      final end =
          DateTime.tryParse(session['end_at']?.toString() ?? '')?.toLocal() ??
          DateTime.tryParse(session['start_at']?.toString() ?? '')?.toLocal();
      if (end == null) continue;
      if (finalEnd == null || end.isAfter(finalEnd)) {
        finalEnd = end;
        finalId = sid;
      }
    }
    return finalId;
  }

  bool _isNonEmptyAnswer(dynamic value) {
    return (value?.toString().trim().isNotEmpty ?? false);
  }

  Map<String, String> _answerMapFromRows(List<Map<String, dynamic>> rows) {
    final map = <String, String>{};
    for (final row in rows) {
      final questionId = row['question_id']?.toString() ?? '';
      if (questionId.isEmpty) continue;
      final answerText = row['answer_text']?.toString() ?? '';
      if (_isNonEmptyAnswer(answerText)) {
        map[questionId] = answerText;
      }
    }
    return map;
  }

  bool _isEvaluationSectionComplete(
    List<Map<String, dynamic>> questions,
    Map<String, String> answers,
  ) {
    if (questions.isEmpty) return true;

    final requiredIds = questions
        .where((question) => question['required'] == true)
        .map((question) => question['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();

    if (requiredIds.isNotEmpty) {
      return requiredIds.every((id) => _isNonEmptyAnswer(answers[id]));
    }

    return answers.values.any(_isNonEmptyAnswer);
  }

  Future<bool> _hasSimpleAttendanceForEvaluation(
    String eventId,
    String studentId,
  ) async {
    final registration = await _loadRegistrationContext(eventId, studentId);
    final ticketId = registration['ticket_id'] ?? '';
    if (ticketId.isEmpty) return false;

    try {
      final rows = await _supabase
          .from('attendance')
          .select('status, check_in_at, check_out_at')
          .eq('ticket_id', ticketId)
          .limit(1);
      if (rows.isEmpty) return false;
      return _hasCompletedAttendanceForEval(
        Map<String, dynamic>.from(rows.first),
      );
    } catch (_) {
      return false;
    }
  }

  Future<Set<String>> _attendedSessionIdsForEvaluation(
    String eventId,
    String studentId,
  ) async {
    final registration = await _loadRegistrationContext(eventId, studentId);
    final registrationId = registration['registration_id'] ?? '';
    final ticketId = registration['ticket_id'] ?? '';
    final attended = <String>{};
    if (registrationId.isEmpty && ticketId.isEmpty) return attended;

    if (await _supportsEventSessionAttendanceTable()) {
      try {
        final rows = await _supabase
            .from('event_session_attendance')
            .select('session_id, status, check_in_at, check_out_at')
            .eq('registration_id', registrationId);
        for (final row in List<Map<String, dynamic>>.from(rows)) {
          if (!_hasCompletedAttendanceForEval(row)) continue;
          final sessionId = row['session_id']?.toString() ?? '';
          if (sessionId.isNotEmpty) {
            attended.add(sessionId);
          }
        }
      } catch (_) {}
    }

    final supportsSessionId = await _supportsAttendanceColumn('session_id');
    if (supportsSessionId && ticketId.isNotEmpty) {
      try {
        final rows = await _supabase
            .from('attendance')
            .select('session_id, status, check_in_at, check_out_at')
            .eq('ticket_id', ticketId)
            .not('session_id', 'is', null);
        for (final row in List<Map<String, dynamic>>.from(rows)) {
          // Eval requires time-out, not time-in alone.
          if (!_hasCompletedAttendanceForEval(row)) continue;
          final sessionId = row['session_id']?.toString() ?? '';
          if (sessionId.isNotEmpty) {
            attended.add(sessionId);
          }
        }
      } catch (_) {}
    }

    return attended;
  }

  Future<List<Map<String, dynamic>>> _loadEventEvaluationQuestions(
    String eventId,
  ) async {
    try {
      final rows = await _supabase
          .from('evaluation_questions')
          .select('id, question_text, field_type, required, sort_order')
          .eq('event_id', eventId)
          .order('sort_order', ascending: true);
      return List<Map<String, dynamic>>.from(rows);
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _loadSessionEvaluationQuestions(
    String sessionId,
  ) async {
    try {
      final rows = await _supabase
          .from('event_session_evaluation_questions')
          .select('id, question_text, field_type, required, sort_order')
          .eq('session_id', sessionId)
          .order('sort_order', ascending: true);
      return List<Map<String, dynamic>>.from(rows);
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _loadEventAnswersForStudent(
    String eventId,
    String studentId,
  ) async {
    try {
      final rows = await _supabase
          .from('evaluation_answers')
          .select('question_id, answer_text, submitted_at')
          .eq('event_id', eventId)
          .eq('student_id', studentId);
      return List<Map<String, dynamic>>.from(rows);
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _loadSessionAnswersForStudent(
    String sessionId,
    String studentId,
  ) async {
    try {
      final rows = await _supabase
          .from('event_session_evaluation_answers')
          .select('question_id, answer_text, submitted_at')
          .eq('session_id', sessionId)
          .eq('student_id', studentId);
      return List<Map<String, dynamic>>.from(rows);
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>> getEvaluationBundle({
    required String eventId,
    required String studentId,
  }) async {
    final event = await getEventById(eventId);
    if (event == null) {
      return {
        'ok': false,
        'error': 'Event not found.',
        'is_eligible': false,
        'has_questions': false,
        'is_complete': false,
        'sections': const <Map<String, dynamic>>[],
      };
    }

    final usesSessions = _eventUsesSessions(event);
    final sections = <Map<String, dynamic>>[];

    if (usesSessions) {
      final parallel = await Future.wait<dynamic>([
        _fetchSessionsForEvent(eventId),
        _attendedSessionIdsForEvaluation(eventId, studentId),
        _loadEventEvaluationQuestions(eventId),
      ]);
      final sessions = List<Map<String, dynamic>>.from(parallel[0] as List);
      final attendedSessionIds = Set<String>.from(parallel[1] as Set<String>);
      final eventQuestions = List<Map<String, dynamic>>.from(
        parallel[2] as List,
      );

      if (attendedSessionIds.isEmpty) {
        return {
          'ok': true,
          'event': event,
          'uses_sessions': true,
          'is_eligible': false,
          'has_questions': false,
          'is_complete': false,
          'sections': const <Map<String, dynamic>>[],
          'message':
              'Time-out required before evaluation. Scan the event QR to check out first.',
        };
      }

      // 2+ seminars: wait for final seminar (latest end_at) time-out — not Seminar 1.
      final finalSeminarId = _finalSeminarIdForEvaluation(sessions);
      if (finalSeminarId != null &&
          !attendedSessionIds.contains(finalSeminarId)) {
        Map<String, dynamic>? finalSession;
        for (final s in sessions) {
          if ((s['id']?.toString() ?? '') == finalSeminarId) {
            finalSession = s;
            break;
          }
        }
        final finalLabel = finalSession != null
            ? _sessionDisplayName(finalSession)
            : 'the final seminar';
        return {
          'ok': true,
          'event': {...event, 'sessions': sessions},
          'uses_sessions': true,
          'is_eligible': false,
          'has_questions': false,
          'is_complete': false,
          'sections': const <Map<String, dynamic>>[],
          'message':
              'Evaluation opens after you time out of $finalLabel.',
        };
      }

      if (eventQuestions.isNotEmpty) {
        final answerRows = await _loadEventAnswersForStudent(
          eventId,
          studentId,
        );
        final answers = _answerMapFromRows(answerRows);
        sections.add({
          'scope': 'event',
          'scope_id': eventId,
          'title': 'Event Feedback',
          'subtitle': event['title']?.toString() ?? 'Event',
          'start_at': event['start_at'],
          'end_at': event['end_at'],
          'questions': eventQuestions,
          'answers': answers,
          'is_complete': _isEvaluationSectionComplete(eventQuestions, answers),
        });
      }

      final attendedSessions = sessions.where((session) {
        final sessionId = session['id']?.toString() ?? '';
        return attendedSessionIds.contains(sessionId);
      }).toList();

      final sessionSections = await Future.wait<Map<String, dynamic>?>(
        attendedSessions.map((session) async {
          final sessionId = session['id']?.toString() ?? '';
          if (sessionId.isEmpty) {
            return null;
          }

          final sessionParallel = await Future.wait<dynamic>([
            _loadSessionEvaluationQuestions(sessionId),
            _loadSessionAnswersForStudent(sessionId, studentId),
          ]);
          final questions = List<Map<String, dynamic>>.from(
            sessionParallel[0] as List,
          );
          if (questions.isEmpty) {
            return null;
          }

          final answerRows = List<Map<String, dynamic>>.from(
            sessionParallel[1] as List,
          );
          final answers = _answerMapFromRows(answerRows);
          return {
            'scope': 'session',
            'scope_id': sessionId,
            'session': session,
            'title': _sessionDisplayName(session),
            'subtitle': session['title']?.toString() ?? 'Seminar',
            'start_at': session['start_at'],
            'end_at': session['end_at'],
            'questions': questions,
            'answers': answers,
            'is_complete': _isEvaluationSectionComplete(questions, answers),
          };
        }),
      );
      sections.addAll(sessionSections.whereType<Map<String, dynamic>>());

      final hasQuestions = sections.isNotEmpty;
      final isComplete = sections.isEmpty
          ? true
          : sections.every((section) => section['is_complete'] == true);

      return {
        'ok': true,
        'event': {...event, 'sessions': sessions},
        'uses_sessions': true,
        'is_eligible': true,
        'has_questions': hasQuestions,
        'is_complete': isComplete,
        'sections': sections,
      };
    }

    final simpleParallel = await Future.wait<dynamic>([
      _hasSimpleAttendanceForEvaluation(eventId, studentId),
      _loadEventEvaluationQuestions(eventId),
    ]);
    final hasAttendance = simpleParallel[0] == true;
    final questions = List<Map<String, dynamic>>.from(
      simpleParallel[1] as List,
    );

    if (!hasAttendance) {
      return {
        'ok': true,
        'event': event,
        'uses_sessions': false,
        'is_eligible': false,
        'has_questions': false,
        'is_complete': false,
        'sections': const <Map<String, dynamic>>[],
        'message':
            'Time-out required before evaluation. Scan the event QR to check out first.',
      };
    }

    if (questions.isNotEmpty) {
      final answerRows = await _loadEventAnswersForStudent(eventId, studentId);
      final answers = _answerMapFromRows(answerRows);
      sections.add({
        'scope': 'event',
        'scope_id': eventId,
        'title': 'Event Feedback',
        'subtitle': event['title']?.toString() ?? 'Event',
        'start_at': event['start_at'],
        'end_at': event['end_at'],
        'questions': questions,
        'answers': answers,
        'is_complete': _isEvaluationSectionComplete(questions, answers),
      });
    }

    final hasQuestions = sections.isNotEmpty;
    final isComplete = sections.isEmpty
        ? true
        : sections.every((section) => section['is_complete'] == true);

    return {
      'ok': true,
      'event': event,
      'uses_sessions': false,
      'is_eligible': true,
      'has_questions': hasQuestions,
      'is_complete': isComplete,
      'sections': sections,
    };
  }

  Future<List<Map<String, dynamic>>> getExpiredEventsOpenForEvaluation({
    required String studentId,
    String? yearLevel,
    bool forceFresh = false,
  }) async {
    final cacheKey = 'expired_eval:$studentId:${yearLevel ?? ''}';
    if (!forceFresh) {
      final cached = _readListCache(cacheKey, _expiredEvalTtl);
      if (cached != null) {
        return cached;
      }
    }

    List<Map<String, dynamic>> publishedEvents = [];

    try {
      final response = await _supabase
          .from('events')
          .select(_eventListColumns)
          .inFilter('status', ['published', 'expired', 'finished', 'archived'])
          .order('end_at', ascending: false)
          .limit(15);
      // Evaluation visibility should follow registration + attendance eligibility,
      // not the list-level year filter, because students may already be registered
      // for older events whose targeting format changed over time.
      publishedEvents = List<Map<String, dynamic>>.from(response);
    } catch (_) {
      final stale = _readListCache(
        cacheKey,
        _expiredEvalTtl,
        allowStale: true,
        staleTtl: const Duration(hours: 24),
      );
      if (stale != null && stale.isNotEmpty) {
        return stale;
      }
      return [];
    }

    final visibleResults = await Future.wait(
      publishedEvents.map((event) async {
        final eventId = event['id']?.toString() ?? '';
        if (eventId.isEmpty) return null;

        List<Map<String, dynamic>> sessions = const [];
        if (_eventUsesSessions(event)) {
          sessions = await _fetchSessionsForEvent(eventId);
        }

        final bundle = await getEvaluationBundle(
          eventId: eventId,
          studentId: studentId,
        );

        if (bundle['ok'] != true ||
            bundle['is_eligible'] != true ||
            bundle['has_questions'] != true) {
          return null;
        }

        final effectiveEnd = _effectiveEventEndAt(event, sessions);

        return <String, dynamic>{
          ...event,
          if (sessions.isNotEmpty) 'sessions': sessions,
          if (effectiveEnd != null)
            'effective_end_at': effectiveEnd.toIso8601String(),
          'evaluation_bundle': bundle,
          'evaluation_complete': bundle['is_complete'] == true,
        };
      }),
    );

    final visible = visibleResults.whereType<Map<String, dynamic>>().toList();

    visible.sort((a, b) {
      final aEnd = DateTime.tryParse(
        a['effective_end_at']?.toString() ?? a['end_at']?.toString() ?? '',
      );
      final bEnd = DateTime.tryParse(
        b['effective_end_at']?.toString() ?? b['end_at']?.toString() ?? '',
      );
      if (aEnd == null && bEnd == null) return 0;
      if (aEnd == null) return 1;
      if (bEnd == null) return -1;
      return bEnd.compareTo(aEnd);
    });

    _writeListCache(cacheKey, visible);
    return visible;
  }

  String _absenceScopeKey(String eventId, {String? sessionId}) {
    final sid = sessionId?.trim() ?? '';
    return sid.isEmpty ? '$eventId::event' : '$eventId::session::$sid';
  }

  Future<List<Map<String, dynamic>>> _fetchStudentRegistrationRowsWithEvents(
    String studentId,
  ) async {
    final sid = studentId.trim();
    if (sid.isEmpty) return [];

    List<Map<String, dynamic>> regs = [];
    if (MobileBackendService.isConfigured) {
      try {
        final res = await _mobileBackend.secureRead(
          table: 'event_registrations',
          select: 'id,event_id,registered_at',
          filters: {'student_id': sid},
          limit: 200,
        );
        if (res['ok'] == true && res['rows'] is List) {
          regs = List<Map<String, dynamic>>.from(
            (res['rows'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
          );
        }
      } catch (_) {
        return [];
      }
    } else {
      try {
        final rows = await _supabase
            .from('event_registrations')
            .select('id,event_id,registered_at')
            .eq('student_id', sid)
            .order('registered_at', ascending: false);
        regs = List<Map<String, dynamic>>.from(rows);
      } catch (_) {
        return [];
      }
    }

    if (regs.isEmpty) return [];

    final eventIds = regs
        .map((r) => r['event_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (eventIds.isEmpty) return regs;

    final eventsById = <String, Map<String, dynamic>>{};
    try {
      final events = await _supabase
          .from('events')
          .select(
            'id,title,start_at,end_at,status,location,event_mode,event_structure',
          )
          .inFilter('id', eventIds);
      for (final raw in List<Map<String, dynamic>>.from(events)) {
        final id = raw['id']?.toString() ?? '';
        if (id.isNotEmpty) eventsById[id] = raw;
      }
    } catch (_) {
      try {
        final events = await _supabase
            .from('events')
            .select('id,title,start_at,end_at,status,location')
            .inFilter('id', eventIds);
        for (final raw in List<Map<String, dynamic>>.from(events)) {
          final id = raw['id']?.toString() ?? '';
          if (id.isNotEmpty) eventsById[id] = raw;
        }
      } catch (_) {}
    }

    return regs.map((reg) {
      final eventId = reg['event_id']?.toString() ?? '';
      return {
        ...reg,
        'events': eventsById[eventId],
      };
    }).toList();
  }

  Future<({Map<String, Map<String, dynamic>> map, bool resolved})>
  _loadStudentAbsenceReasonMap(String studentId) async {
    final mapped = <String, Map<String, dynamic>>{};

    try {
      final rows = await _supabase
          .from('attendance_absence_reasons')
          .select(
            'id,event_id,session_id,reason_text,review_status,admin_note,submitted_at,reviewed_at',
          )
          .eq('student_id', studentId)
          .order('submitted_at', ascending: false);

      for (final item in List<Map<String, dynamic>>.from(rows)) {
        final eventId = item['event_id']?.toString() ?? '';
        if (eventId.isEmpty) continue;
        final sessionId = item['session_id']?.toString() ?? '';
        mapped[_absenceScopeKey(eventId, sessionId: sessionId)] = item;
      }
    } catch (e) {
      if (_isAbsenceReasonsTableUnavailableError(e)) {
        return (map: mapped, resolved: true);
      }
      // On transient failures we mark unresolved so caller can avoid
      // temporary false-locks while data is inconsistent.
      return (map: mapped, resolved: false);
    }

    return (map: mapped, resolved: true);
  }

  Future<List<Map<String, dynamic>>> getStudentPendingAbsenceScopes({
    required String studentId,
  }) async {
    if (studentId.trim().isEmpty) return [];

    final pending = <Map<String, dynamic>>[];
    final seenKeys = <String>{};
    final nowUtc = DateTime.now().toUtc();
    final reasonResult = await _loadStudentAbsenceReasonMap(studentId);
    final reasonMap = reasonResult.map;
    if (!reasonResult.resolved) {
      // Fail-open for lock gate when we cannot verify submitted reasons.
      return [];
    }

    final registrationRows = await _fetchStudentRegistrationRowsWithEvents(
      studentId,
    );
    if (registrationRows.isEmpty) {
      return [];
    }

    // Cap scanned regs for home gate — typical students have few active regs.
    final scopedRegs = registrationRows.length > 40
        ? registrationRows.take(40).toList()
        : registrationRows;

    // One batched ticket lookup instead of per-registration selects.
    final registrationIds = scopedRegs
        .map((r) => r['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    final ticketByRegistrationId = <String, String>{};
    if (registrationIds.isNotEmpty) {
      try {
        final ticketRows = await _supabase
            .from('tickets')
            .select('id,registration_id')
            .inFilter('registration_id', registrationIds);
        for (final raw in List<Map<String, dynamic>>.from(ticketRows)) {
          final rid = raw['registration_id']?.toString() ?? '';
          final tid = raw['id']?.toString() ?? '';
          if (rid.isNotEmpty && tid.isNotEmpty) {
            ticketByRegistrationId.putIfAbsent(rid, () => tid);
          }
        }
      } catch (_) {
        // Leave map empty — scopes still work without ticket_id fallbacks.
      }
    }

    for (final reg in scopedRegs) {
      final registrationId = reg['id']?.toString() ?? '';
      final eventId = reg['event_id']?.toString() ?? '';
      if (registrationId.isEmpty || eventId.isEmpty) continue;

      final rawEvent = reg['events'];
      final event = _extractEmbeddedMap(rawEvent) ?? <String, dynamic>{};
      if (event.isEmpty) continue;

      final eventTitle = event['title']?.toString().trim().isNotEmpty == true
          ? event['title'].toString().trim()
          : 'Event';
      final eventLocation = event['location']?.toString() ?? '';
      final ticketId = ticketByRegistrationId[registrationId] ?? '';

      var sessions = <Map<String, dynamic>>[];
      if (_eventUsesSessions(event)) {
        sessions = await _fetchSessionsForEvent(eventId);
      } else {
        final discovered = await _fetchSessionsForEvent(eventId);
        if (discovered.isNotEmpty) {
          sessions = discovered;
        }
      }

      if (sessions.isNotEmpty) {
        final presentBySession = <String, bool>{};
        final absentBySession = <String, bool>{};
        var loadedFromSnapshot = false;
        var attendanceStateResolved = false;

        // Primary read path: server-side snapshot RPC (same source used by web-aligned fetch).
        try {
          final snapshotRows = await _supabase.rpc(
            'get_event_session_attendance_snapshot',
            params: {'p_event_id': eventId},
          );
          final filtered = <Map<String, dynamic>>[];
          for (final raw in List<Map<String, dynamic>>.from(snapshotRows)) {
            final rowRegistrationId = raw['registration_id']?.toString() ?? '';
            final rowTicketId = raw['ticket_id']?.toString() ?? '';
            if (rowRegistrationId == registrationId ||
                (ticketId.isNotEmpty && rowTicketId == ticketId)) {
              filtered.add(raw);
            }
          }

          for (final row in filtered) {
            final sid = row['session_id']?.toString() ?? '';
            if (sid.isEmpty) continue;
            if (_attendanceRecordCountsAsPresent(row)) {
              presentBySession[sid] = true;
            } else if ((row['status']?.toString().toLowerCase() ?? '') ==
                'absent') {
              absentBySession[sid] = true;
            }
          }
          loadedFromSnapshot = true;
          attendanceStateResolved = true;
        } catch (_) {
          // Fallback to direct table reads for deployments without RPC.
        }

        if (!loadedFromSnapshot &&
            await _supportsEventSessionAttendanceTable()) {
          try {
            final attendanceRows = await _supabase
                .from('event_session_attendance')
                .select('session_id,status,check_in_at')
                .eq('registration_id', registrationId);
            final mergedRows = <Map<String, dynamic>>[
              ...List<Map<String, dynamic>>.from(attendanceRows),
            ];

            // Fallback for legacy rows where registration_id may be missing
            // but ticket_id exists. This prevents false absence locks for
            // students already marked present in session attendance.
            if (ticketId.isNotEmpty) {
              final byTicketRows = await _supabase
                  .from('event_session_attendance')
                  .select('session_id,status,check_in_at')
                  .eq('ticket_id', ticketId);
              mergedRows.addAll(List<Map<String, dynamic>>.from(byTicketRows));
            }

            for (final row in mergedRows) {
              final sid = row['session_id']?.toString() ?? '';
              if (sid.isEmpty) continue;
              if (_attendanceRecordCountsAsPresent(row)) {
                presentBySession[sid] = true;
              } else if ((row['status']?.toString().toLowerCase() ?? '') ==
                  'absent') {
                absentBySession[sid] = true;
              }
            }
            attendanceStateResolved = true;
          } catch (_) {
            // Continue to fallback storage if available.
          }
        }

        final supportsSessionId = await _supportsAttendanceColumn('session_id');
        if (supportsSessionId && ticketId.isNotEmpty) {
          try {
            final attendanceRows = await _supabase
                .from('attendance')
                .select('session_id,status,check_in_at')
                .eq('ticket_id', ticketId)
                .not('session_id', 'is', null);
            for (final row in List<Map<String, dynamic>>.from(attendanceRows)) {
              final sid = row['session_id']?.toString() ?? '';
              if (sid.isEmpty) continue;
              if (_attendanceRecordCountsAsPresent(row)) {
                presentBySession[sid] = true;
              } else if ((row['status']?.toString().toLowerCase() ?? '') ==
                  'absent') {
                absentBySession[sid] = true;
              }
            }
            attendanceStateResolved = true;
          } catch (_) {
            // Ignore fallback read failure and continue.
          }
        }

        if (!attendanceStateResolved) {
          // If all attendance sources failed, avoid generating a transient lock.
          continue;
        }

        final sessionMeta = <Map<String, dynamic>>[];
        DateTime? earliestSessionStart;
        DateTime? latestWindowClose;
        DateTime? latestSessionEnd;
        for (final session in sessions) {
          final sessionId = session['id']?.toString() ?? '';
          if (sessionId.isEmpty) continue;

          final startAt = _toUtcDate(session['start_at']);
          if (startAt == null) continue;
          if (earliestSessionStart == null ||
              startAt.isBefore(earliestSessionStart)) {
            earliestSessionStart = startAt;
          }

          final windowMinutes = _sessionWindowMinutes(session);
          final closesAt = startAt.add(Duration(minutes: windowMinutes));
          if (latestWindowClose == null ||
              closesAt.isAfter(latestWindowClose)) {
            latestWindowClose = closesAt;
          }

          final sessionEndAt = _toUtcDate(session['end_at']) ?? closesAt;
          if (latestSessionEnd == null ||
              sessionEndAt.isAfter(latestSessionEnd)) {
            latestSessionEnd = sessionEndAt;
          }

          sessionMeta.add({
            'session': session,
            'session_id': sessionId,
            'start_at': startAt,
            'closes_at': closesAt,
            'window_minutes': windowMinutes,
            'end_at': sessionEndAt,
          });
        }

        if (sessionMeta.isEmpty) {
          continue;
        }

        // Seminar-based lock should trigger once seminar scan windows are done.
        // Using event.end_at here can delay lock incorrectly when admins set a
        // much later end time than actual seminar attendance windows.
        final lockAt =
            latestWindowClose ??
            latestSessionEnd ??
            _toUtcDate(event['end_at']);
        if (lockAt != null && !nowUtc.isAfter(lockAt)) {
          continue;
        }

        final hasAnyPresent = sessionMeta.any((meta) {
          final sid = meta['session_id']?.toString() ?? '';
          if (sid.isEmpty) return false;
          return presentBySession[sid] == true;
        });

        final missedSessions = <Map<String, dynamic>>[];
        for (final meta in sessionMeta) {
          final sid = meta['session_id']?.toString() ?? '';
          if (sid.isEmpty) continue;
          final closesAt = meta['closes_at'] as DateTime;
          if (!nowUtc.isAfter(closesAt)) continue;
          if (presentBySession[sid] == true) continue;
          // Align with web participant behavior:
          // once a session window is closed and student has no present record,
          // treat it as missed/absent for lock purposes (even if explicit absent
          // row has not been materialized yet).
          missedSessions.add(meta);
        }

        if (missedSessions.isEmpty) {
          continue;
        }

        if (!hasAnyPresent) {
          // If student attended none of the seminars, show one event-level lock item.
          final scopeKey = _absenceScopeKey(eventId);
          if (reasonMap.containsKey(scopeKey) || seenKeys.contains(scopeKey)) {
            continue;
          }
          seenKeys.add(scopeKey);

          final windowOpensAt =
              earliestSessionStart ?? _toUtcDate(event['start_at']) ?? nowUtc;
          final windowClosesAt =
              latestWindowClose ??
              lockAt ??
              windowOpensAt.add(const Duration(minutes: 30));

          pending.add({
            'scope_key': scopeKey,
            'scope_type': 'event',
            'event_id': eventId,
            'event_title': eventTitle,
            'event_location': eventLocation,
            'event_start_at': event['start_at'],
            'event_end_at': event['end_at'],
            'session_id': null,
            'session_title': null,
            'session_start_at': null,
            'session_end_at': null,
            'window_minutes': 30,
            'window_opens_at': windowOpensAt.toIso8601String(),
            'window_closes_at': windowClosesAt.toIso8601String(),
          });
          continue;
        }

        for (final meta in missedSessions) {
          final sessionId = meta['session_id']?.toString() ?? '';
          if (sessionId.isEmpty) continue;

          final scopeKey = _absenceScopeKey(eventId, sessionId: sessionId);
          if (reasonMap.containsKey(scopeKey) || seenKeys.contains(scopeKey)) {
            continue;
          }
          seenKeys.add(scopeKey);

          final session = Map<String, dynamic>.from(
            meta['session'] as Map<String, dynamic>,
          );
          final startAt = meta['start_at'] as DateTime;
          final closesAt = meta['closes_at'] as DateTime;
          final windowMinutes = meta['window_minutes'] as int;

          pending.add({
            'scope_key': scopeKey,
            'scope_type': 'session',
            'event_id': eventId,
            'event_title': eventTitle,
            'event_location': eventLocation,
            'event_start_at': event['start_at'],
            'event_end_at': event['end_at'],
            'session_id': sessionId,
            'session_title': _sessionDisplayName(session),
            'session_start_at': session['start_at'],
            'session_end_at': session['end_at'],
            'window_minutes': windowMinutes,
            'window_opens_at': startAt.toIso8601String(),
            'window_closes_at': closesAt.toIso8601String(),
          });
        }

        continue;
      }

      final eventStartAt = _toUtcDate(event['start_at']);
      if (eventStartAt == null) {
        continue;
      }
      final closesAt = eventStartAt.add(
        Duration(minutes: _eventGraceMinutes(event)),
      );
      if (!nowUtc.isAfter(closesAt)) {
        continue;
      }

      var present = false;
      var attendanceStateResolved = false;
      if (ticketId.isNotEmpty) {
        try {
          final attendanceRows = await _supabase
              .from('attendance')
              .select('status,check_in_at')
              .eq('ticket_id', ticketId)
              .limit(50);
          for (final row in List<Map<String, dynamic>>.from(attendanceRows)) {
            if (_attendanceRecordCountsAsPresent(row)) {
              present = true;
              break;
            }
          }
          attendanceStateResolved = true;
        } catch (_) {
          attendanceStateResolved = false;
        }
      }

      if (!attendanceStateResolved) {
        // Fail-open when attendance lookup itself cannot be verified.
        continue;
      }

      if (present) continue;

      // Simple-event lock should align with the rest of the attendance flow:
      // once the grace window is closed and there is no present record,
      // treat the registration as missed/absent even if the explicit absent
      // row has not been materialized yet.

      final scopeKey = _absenceScopeKey(eventId);
      if (reasonMap.containsKey(scopeKey) || seenKeys.contains(scopeKey)) {
        continue;
      }
      seenKeys.add(scopeKey);

      pending.add({
        'scope_key': scopeKey,
        'scope_type': 'event',
        'event_id': eventId,
        'event_title': eventTitle,
        'event_location': eventLocation,
        'event_start_at': event['start_at'],
        'event_end_at': event['end_at'],
        'session_id': null,
        'session_title': null,
        'session_start_at': null,
        'session_end_at': null,
        'window_minutes': 30,
        'window_opens_at': eventStartAt.toIso8601String(),
        'window_closes_at': closesAt.toIso8601String(),
      });
    }

    pending.sort((a, b) {
      final aClose = DateTime.tryParse(a['window_closes_at']?.toString() ?? '');
      final bClose = DateTime.tryParse(b['window_closes_at']?.toString() ?? '');
      if (aClose == null && bClose == null) return 0;
      if (aClose == null) return 1;
      if (bClose == null) return -1;
      return bClose.compareTo(aClose);
    });

    return pending;
  }

  Future<Map<String, dynamic>> submitAbsenceReason({
    required String studentId,
    required String eventId,
    String? sessionId,
    required String reasonText,
  }) async {
    final sid = sessionId?.trim() ?? '';
    final reason = reasonText.trim();
    if (studentId.trim().isEmpty || eventId.trim().isEmpty) {
      return {'ok': false, 'error': 'Missing student or event context.'};
    }
    if (reason.isEmpty) {
      return {'ok': false, 'error': 'Please provide your reason first.'};
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();

    try {
      final existingRows = await _supabase
          .from('attendance_absence_reasons')
          .select('id,session_id')
          .eq('student_id', studentId)
          .eq('event_id', eventId)
          .limit(100);

      String existingId = '';
      for (final row in List<Map<String, dynamic>>.from(existingRows)) {
        final rowSessionId = row['session_id']?.toString() ?? '';
        final isMatch = sid.isEmpty
            ? rowSessionId.isEmpty
            : rowSessionId == sid;
        if (isMatch) {
          existingId = row['id']?.toString() ?? '';
          if (existingId.isNotEmpty) break;
        }
      }

      final payload = <String, dynamic>{
        'student_id': studentId,
        'event_id': eventId,
        'session_id': sid.isEmpty ? null : sid,
        'reason_text': reason,
        'review_status': 'pending',
        'admin_note': null,
        'reviewed_at': null,
        'reviewed_by': null,
        'submitted_at': nowIso,
      };

      if (MobileBackendService.isConfigured) {
        final res = await _mobileBackend.secureWrite('absence_reason_upsert', {
          'method': existingId.isNotEmpty ? 'PATCH' : 'POST',
          if (existingId.isNotEmpty) 'filter': 'id=eq.$existingId',
          'payload': payload,
        });
        if (res['ok'] != true) {
          return {
            'ok': false,
            'error':
                res['error']?.toString() ??
                'Failed to submit your reason. Please try again.',
          };
        }
        return {'ok': true};
      }

      // Anon writes revoked (051) — require BFF.
      return {
        'ok': false,
        'error': 'Unable to submit reason. Please try again when online.',
      };
    } catch (e) {
      if (_isAbsenceReasonsTableUnavailableError(e)) {
        return {
          'ok': false,
          'error':
              'Absence reason storage is not available yet. Please apply migration 008_attendance_absence_reasons.sql first.',
        };
      }
      return {
        'ok': false,
        'error': 'Failed to submit your reason. Please try again.',
      };
    }
  }

  // Manual check-out for a participant
  Future<Map<String, dynamic>> manualCheckOut(String ticketId) async {
    try {
      if (!MobileBackendService.isConfigured) {
        return {
          'ok': false,
          'error': 'Check-out requires a secure backend connection.',
        };
      }
      final trimmed = ticketId.trim();
      if (trimmed.isEmpty) {
        return {'ok': false, 'error': 'ticket_id required.'};
      }
      // Resolve event via ticket so attendance_upsert auth can run.
      final ticketRows = await _supabase
          .from('tickets')
          .select('id, registration_id, event_registrations(event_id)')
          .eq('id', trimmed)
          .limit(1);
      if (ticketRows.isEmpty) {
        return {'ok': false, 'error': 'Ticket not found.'};
      }
      final reg = ticketRows.first['event_registrations'];
      String eventId = '';
      if (reg is Map) {
        eventId = (reg['event_id']?.toString() ?? '').trim();
      } else if (reg is List && reg.isNotEmpty && reg.first is Map) {
        eventId = (reg.first['event_id']?.toString() ?? '').trim();
      }
      if (eventId.isEmpty) {
        return {'ok': false, 'error': 'Could not resolve event for ticket.'};
      }
      final res = await _mobileBackend.secureWrite('attendance_upsert', {
        'event_id': eventId,
        'table': 'attendance',
        'method': 'PATCH',
        'filter': 'ticket_id=eq.$trimmed',
        'payload': {
          'check_out_at': DateTime.now().toIso8601String(),
        },
      });
      if (res['ok'] == true) {
        return {'ok': true, 'message': 'Check-out recorded!'};
      }
      return {
        'ok': false,
        'error': res['error']?.toString() ?? 'Check-out failed.',
      };
    } catch (e) {
      return {'ok': false, 'error': 'Manual check-out failed.'};
    }
  }

  // Get attendance info for a ticket (check-in/out times, status)
  Future<Map<String, dynamic>?> getTicketAttendance(String ticketId) async {
    try {
      final response = await _supabase
          .from('attendance')
          .select('*')
          .eq('ticket_id', ticketId)
          .limit(1);
      if (response.isNotEmpty) {
        return response[0];
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}

class _CachedStudentRequirements {
  final List<Map<String, dynamic>> items;
  final DateTime cachedAt;

  const _CachedStudentRequirements({
    required this.items,
    required this.cachedAt,
  });
}

class _ListCacheEntry {
  final List<Map<String, dynamic>> data;
  final DateTime cachedAt;

  const _ListCacheEntry(this.data, this.cachedAt);
}
