import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/event_time_utils.dart';
import 'event_service.dart';
import 'offline_backup_service.dart';
import 'offline_scan_store.dart';

class OfflineSyncService {
  /// Min interval for background snapshot warmups (Home / main ticker).
  /// On-demand Scan / post-sync callers should pass force: true.
  static const Duration _backgroundSnapshotMinInterval = Duration(minutes: 5);
  DateTime? _lastBackgroundSnapshotAt;
  Future<Map<String, dynamic>>? _inFlightSnapshot;

  OfflineSyncService({
    EventService? eventService,
    OfflineScanStore? store,
    OfflineBackupService? backupService,
  }) : _eventService = eventService ?? EventService(),
       _store = store ?? OfflineScanStore.instance,
       _backupService = backupService ?? OfflineBackupService();

  static const Duration _maxCacheAge = Duration(hours: 24);

  final EventService _eventService;
  final OfflineScanStore _store;
  final OfflineBackupService _backupService;
  bool _autoRestoreChecked = false;
  final Set<String> _avatarWarmupsInFlight = <String>{};

  Future<void> _ensureAutoRestore() async {
    if (_autoRestoreChecked) return;
    _autoRestoreChecked = true;
    await _backupService.autoRestoreIfNeeded();
  }

  String _actorRole({required bool isTeacher}) =>
      isTeacher ? 'teacher' : 'assistant';

  String _actorKey({required String actorId, required bool isTeacher}) {
    return '${_actorRole(isTeacher: isTeacher)}:${actorId.trim()}';
  }

  String _selfActorKey(String studentId) => 'self:${studentId.trim()}';

  bool _hasValidTimeIn(Map<String, dynamic>? row) {
    if (row == null || row.isEmpty) return false;
    final status = (row['status']?.toString() ?? '').trim().toLowerCase();
    if (status == 'absent') return false;
    if ((row['check_in_at']?.toString() ?? '').trim().isNotEmpty) return true;
    return _isCheckedInStatus(status);
  }

  Map<String, dynamic> _checkInWindowForStart({
    required DateTime? startAt,
    required int graceMinutes,
    required DateTime nowUtc,
  }) {
    final grace = graceMinutes < 1 ? 30 : graceMinutes;
    if (startAt == null) {
      return {
        'open': false,
        'opens_at': null,
        'closes_at': null,
        'status': 'missing_schedule',
        'message': 'Start time is missing.',
      };
    }
    final closes = startAt.add(Duration(minutes: grace));
    if (nowUtc.isBefore(startAt)) {
      return {
        'open': false,
        'opens_at': startAt.toIso8601String(),
        'closes_at': closes.toIso8601String(),
        'status': 'waiting',
        'message': 'Too early to time in. Wait for the scheduled start.',
      };
    }
    if (!nowUtc.isAfter(closes)) {
      return {
        'open': true,
        'opens_at': startAt.toIso8601String(),
        'closes_at': closes.toIso8601String(),
        'status': 'open',
        'message': 'Time-in is open.',
      };
    }
    return {
      'open': false,
      'opens_at': startAt.toIso8601String(),
      'closes_at': closes.toIso8601String(),
      'status': 'closed',
      'message': 'Time-in grace has ended.',
    };
  }

  Map<String, dynamic> _checkOutWindowForEnd({
    required DateTime? endAt,
    String? earlyOutEnabledAtRaw,
    required DateTime nowUtc,
    DateTime? startAt,
    int graceMinutes = 30,
  }) {
    final grace = graceMinutes < 1 ? 30 : graceMinutes;
    final graceCloses = startAt?.add(Duration(minutes: grace));
    final earlyRaw = (earlyOutEnabledAtRaw ?? '').trim();
    if (earlyRaw.isNotEmpty) {
      if (graceCloses != null && nowUtc.isBefore(graceCloses)) {
        return {
          'open': false,
          'opens_at': graceCloses.toIso8601String(),
          'closes_at': null,
          'status': 'too_early_checkout',
          'message': 'Too early to time out. Time-in grace is still open.',
          'mode': 'early_out',
        };
      }
      final enabledAt = _parseScheduleManila(earlyRaw);
      if (enabledAt != null) {
        final closes = enabledAt.add(const Duration(hours: 1));
        if (!nowUtc.isBefore(enabledAt) && !nowUtc.isAfter(closes)) {
          return {
            'open': true,
            'opens_at': enabledAt.toIso8601String(),
            'closes_at': closes.toIso8601String(),
            'status': 'open',
            'message': 'Early time-out is open.',
            'mode': 'early_out',
          };
        }
        if (nowUtc.isBefore(enabledAt)) {
          return {
            'open': false,
            'opens_at': enabledAt.toIso8601String(),
            'closes_at': closes.toIso8601String(),
            'status': 'too_early_checkout',
            'message': 'Early time-out is not open yet.',
            'mode': 'early_out',
          };
        }
        return {
          'open': false,
          'opens_at': enabledAt.toIso8601String(),
          'closes_at': closes.toIso8601String(),
          'status': 'closed',
          'message': 'Early time-out window has closed.',
          'mode': 'early_out',
        };
      }
    }
    if (endAt == null) {
      return {
        'open': false,
        'opens_at': null,
        'closes_at': null,
        'status': 'missing_schedule',
        'message': 'End time is missing.',
        'mode': 'normal',
      };
    }
    var opensAt = endAt;
    if (graceCloses != null && opensAt.isBefore(graceCloses)) {
      opensAt = graceCloses;
    }
    final closes = opensAt.add(const Duration(hours: 1));
    if (nowUtc.isBefore(opensAt)) {
      return {
        'open': false,
        'opens_at': opensAt.toIso8601String(),
        'closes_at': closes.toIso8601String(),
        'status': 'too_early_checkout',
        'message': graceCloses != null && opensAt == graceCloses
            ? 'Too early to time out. Time-in grace is still open.'
            : 'Time-out is not open yet.',
        'mode': 'normal',
      };
    }
    if (!nowUtc.isAfter(closes)) {
      return {
        'open': true,
        'opens_at': opensAt.toIso8601String(),
        'closes_at': closes.toIso8601String(),
        'status': 'open',
        'message': 'Time-out is open.',
        'mode': 'normal',
      };
    }
    return {
      'open': false,
      'opens_at': opensAt.toIso8601String(),
      'closes_at': closes.toIso8601String(),
      'status': 'closed',
      'message': 'Time-out window has closed.',
      'mode': 'normal',
    };
  }

  DateTime? _parseDate(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  /// Event/session wall times — same Manila civil clock as PHP Event QR.
  DateTime? _parseScheduleManila(String? raw) {
    final wall = parseStoredEventDateTime(raw);
    if (wall == null) return null;
    return DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
      wall.millisecond,
      wall.microsecond,
    );
  }

  DateTime _nowManila() {
    final wall = DateTime.now().toUtc().add(kManilaOffset);
    return DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
      wall.millisecond,
      wall.microsecond,
    );
  }

  String _ticketHash(String payload) {
    return sha256.convert(utf8.encode(payload.trim())).toString();
  }

  String _normalizeEventQrPayload(String raw) {
    final trimmed = raw.trim();
    final match = RegExp(
      r'^PULSE-EVENT-(.+)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (match == null) return trimmed;
    final eventId = (match.group(1) ?? '').trim().toLowerCase();
    if (eventId.isEmpty) return trimmed;
    return EventService.buildEventQrPayload(eventId);
  }

  String _eventIdFromEventQr(String raw) {
    final match = RegExp(
      r'^PULSE-EVENT-(.+)$',
      caseSensitive: false,
    ).firstMatch(raw.trim());
    return (match?.group(1) ?? '').trim();
  }

  Future<Set<String>> _selfIdentityKeys(String userId) async {
    final keys = <String>{};
    void add(String? value) {
      final v = (value ?? '').trim().toLowerCase();
      if (v.isNotEmpty) keys.add(v);
    }

    add(userId);
    try {
      final prefs = await SharedPreferences.getInstance();
      add(prefs.getString('user_id'));
      add(prefs.getString('student_id'));
      final userData = prefs.getString('user_data');
      if (userData != null && userData.trim().isNotEmpty) {
        final parsed = jsonDecode(userData);
        if (parsed is Map) {
          add(parsed['id']?.toString());
          add(parsed['student_id']?.toString());
          add(parsed['student_no']?.toString());
          add(parsed['student_number']?.toString());
        }
      }
    } catch (_) {}
    return keys;
  }

  bool _payloadMatchesSelfIdentity(
    Map<String, dynamic> payload,
    Set<String> identities,
  ) {
    if (identities.isEmpty) return false;
    const fields = [
      'participant_student_id',
      'participant_student_no',
      'participant_user_id',
      'student_id',
      'user_id',
    ];
    for (final field in fields) {
      final value = (payload[field]?.toString() ?? '').trim().toLowerCase();
      if (value.isNotEmpty && identities.contains(value)) return true;
    }
    return false;
  }

  Future<Map<String, dynamic>?> _lookupSelfTicketCacheRow({
    required String actorKey,
    required String eventQrPayload,
  }) async {
    final raw = eventQrPayload.trim();
    final normalized = _normalizeEventQrPayload(raw);
    final hashes = <String>{
      if (raw.isNotEmpty) _ticketHash(raw),
      if (normalized.isNotEmpty) _ticketHash(normalized),
    };
    for (final hash in hashes) {
      final row = await _store.getTicketCacheByHash(
        actorKey: actorKey,
        ticketHash: hash,
      );
      if (row != null) return row;
    }

    final eventId = _eventIdFromEventQr(normalized);
    if (eventId.isEmpty) return null;

    var rows = await _store.listTicketCacheForEvent(
      actorKey: actorKey,
      eventId: eventId,
    );
    if (rows.isEmpty) {
      final recent = await _store.listRecentTicketCache(
        actorKey: actorKey,
        limit: 500,
      );
      final wanted = eventId.toLowerCase();
      rows = recent
          .where(
            (row) =>
                (row['event_id']?.toString() ?? '').trim().toLowerCase() ==
                wanted,
          )
          .toList();
    }
    if (rows.isEmpty) return null;
    return rows.first;
  }

  String _offlineParticipantKey(
    Map<String, dynamic> payload,
    String fallbackHash,
  ) {
    final registrationId =
        (payload['registration_id']?.toString() ?? '').trim();
    if (registrationId.isNotEmpty) return 'registration:$registrationId';

    final studentId =
        (payload['participant_student_id']?.toString() ?? '').trim();
    if (studentId.isNotEmpty) return 'student:$studentId';

    return 'ticket:$fallbackHash';
  }

  String _normalizeOfflineAttendanceStatus(
    String status, {
    required bool pendingSync,
  }) {
    final normalized = status.trim().toLowerCase();
    if (pendingSync) return 'present';
    if (_isCheckedInStatus(normalized)) return 'present';
    if (normalized == 'absent') return 'absent';
    if (normalized.isEmpty) return 'unscanned';
    return normalized;
  }

  void _upsertOfflineSessionAttendance(
    List<Map<String, dynamic>> sessionAttendance,
    Map<String, dynamic> candidate,
  ) {
    final sessionId = (candidate['session_id']?.toString() ?? '').trim();
    if (sessionId.isEmpty) return;

    final index = sessionAttendance.indexWhere(
      (row) => (row['session_id']?.toString() ?? '').trim() == sessionId,
    );
    if (index < 0) {
      sessionAttendance.add(candidate);
      return;
    }

    final existing = Map<String, dynamic>.from(sessionAttendance[index]);
    final existingPending = existing['offline_pending'] == true;
    final candidatePending = candidate['offline_pending'] == true;
    final existingLast =
        (existing['last_scanned_at']?.toString() ?? '').trim();
    final candidateLast =
        (candidate['last_scanned_at']?.toString() ?? '').trim();

    if (candidatePending && !existingPending) {
      sessionAttendance[index] = candidate;
      return;
    }
    if (candidateLast.isNotEmpty &&
        (existingLast.isEmpty || candidateLast.compareTo(existingLast) > 0)) {
      sessionAttendance[index] = candidate;
    }
  }

  bool _isCheckedInStatus(String status) {
    final normalized = status.trim().toLowerCase();
    if (normalized == 'absent') return false;
    return normalized == 'scanned' ||
        normalized == 'present' ||
        normalized == 'late' ||
        normalized == 'early';
  }

  bool _isOfflineCheckOutMode(Map<String, dynamic> effectiveContext) {
    final topMode =
        (effectiveContext['scan_mode']?.toString() ?? '').trim().toLowerCase();
    if (topMode == 'check_out') return true;
    final contextMap = effectiveContext['context'] is Map
        ? Map<String, dynamic>.from(effectiveContext['context'] as Map)
        : <String, dynamic>{};
    final nestedMode =
        (contextMap['scan_mode']?.toString() ?? '').trim().toLowerCase();
    if (nestedMode == 'check_out') return true;
    final message =
        '${effectiveContext['message'] ?? ''} ${contextMap['message'] ?? ''}'
            .toLowerCase();
    return message.contains('time-out') || message.contains('early time-out');
  }

  bool _looksLikeTransientError(Map<String, dynamic> response) {
    final status = (response['status']?.toString() ?? '').toLowerCase().trim();
    if (status.isNotEmpty && status != 'error') return false;
    final errorText =
        '${response['error'] ?? ''} ${response['debug'] ?? ''}'.toLowerCase();
    return errorText.contains('socketexception') ||
        errorText.contains('timed out') ||
        errorText.contains('network') ||
        errorText.contains('failed host lookup') ||
        errorText.contains('check internet');
  }

  bool _looksLikeReachabilityIssueText(String text) {
    final normalized = text.toLowerCase();
    return normalized.contains('socketexception') ||
        normalized.contains('failed host lookup') ||
        normalized.contains('timed out') ||
        normalized.contains('network') ||
        normalized.contains('dns');
  }

  String _monitorRefreshErrorText(Map<String, dynamic> refreshResult) {
    if (refreshResult['ok'] == true) return '';

    final status = (refreshResult['status']?.toString() ?? '')
        .trim()
        .toLowerCase();
    final rawError = (refreshResult['error']?.toString() ?? '').trim();
    final debug = (refreshResult['debug']?.toString() ?? '').trim();
    final combined = '$rawError $debug'.trim();

    if (_looksLikeReachabilityIssueText(combined)) {
      return 'This device has signal, but the app could not reach the server yet. Check internet or DNS, then refresh again.';
    }

    switch (status) {
      case 'no_assignment':
        return 'No QR scanner assignment was found for this account yet.';
      case 'conflict':
        return 'Multiple assigned events are open at the same time. Resolve the conflict first.';
      case 'waiting':
        return 'Scanner access exists, but the scan window has not opened yet.';
      case 'closed':
        return 'Scanner access exists, but the current scan window is closed.';
      case 'missing_schedule':
        return 'The assigned event is missing its scan schedule.';
      default:
        break;
    }

    if (rawError.isNotEmpty) return rawError;
    return 'Unable to refresh offline scanner data right now.';
  }

  String _monitorConnectionLabel({
    required bool isOffline,
    Map<String, dynamic>? refreshResult,
  }) {
    if (isOffline) return 'Offline';
    if (refreshResult == null) return 'Online';
    final error = _monitorRefreshErrorText(refreshResult);
    if (error.isNotEmpty && _looksLikeReachabilityIssueText(error)) {
      return 'Online, server unreachable';
    }
    return 'Online';
  }

  String _nextRetryAtIso(int attemptCount) {
    final now = DateTime.now().toUtc();
    // Faster retries under load so queued offline scans clear sooner.
    Duration delay;
    if (attemptCount <= 1) {
      delay = const Duration(seconds: 2);
    } else if (attemptCount == 2) {
      delay = const Duration(seconds: 5);
    } else if (attemptCount == 3) {
      delay = const Duration(seconds: 15);
    } else if (attemptCount == 4) {
      delay = const Duration(seconds: 45);
    } else {
      delay = const Duration(minutes: 3);
    }
    return now.add(delay).toIso8601String();
  }

  Future<String> _cacheAvatarLocally(String ticketId, String remoteUrl) async {
    final url = remoteUrl.trim();
    if (url.isEmpty || !url.toLowerCase().startsWith('http')) return '';

    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return '';
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) return '';

      final appDir = await getApplicationSupportDirectory();
      final avatarsDir = Directory(p.join(appDir.path, 'offline_avatars'));
      if (!avatarsDir.existsSync()) {
        avatarsDir.createSync(recursive: true);
      }

      final extension = () {
        final path = uri.path.toLowerCase();
        if (path.endsWith('.png')) return '.png';
        if (path.endsWith('.webp')) return '.webp';
        if (path.endsWith('.jpeg')) return '.jpeg';
        if (path.endsWith('.jpg')) return '.jpg';
        return '.jpg';
      }();
      final hashed = sha256.convert(utf8.encode(url)).toString().substring(0, 16);
      final file = File(
        p.join(avatarsDir.path, 'avatar_${ticketId}_$hashed$extension'),
      );
      await file.writeAsBytes(response.bodyBytes, flush: true);
      return file.path;
    } catch (_) {
      return '';
    }
  }

  Future<void> _warmAvatarCacheForRows({
    required String actorKey,
    required List<Map<String, dynamic>> rows,
  }) async {
    if (rows.isEmpty) return;
    if (_avatarWarmupsInFlight.contains(actorKey)) return;
    _avatarWarmupsInFlight.add(actorKey);

    try {
      var updatedAny = false;
      for (final row in rows) {
        final ticketHash = (row['ticket_hash']?.toString() ?? '').trim();
        final remoteUrl = (row['avatar_remote_url']?.toString() ?? '').trim();
        final currentLocalPath =
            (row['avatar_local_path']?.toString() ?? '').trim();
        if (ticketHash.isEmpty || remoteUrl.isEmpty) continue;
        if (currentLocalPath.isNotEmpty && File(currentLocalPath).existsSync()) {
          continue;
        }

        Map<String, dynamic> payload;
        try {
          final decoded = jsonDecode(row['payload_json']?.toString() ?? '{}');
          if (decoded is! Map) continue;
          payload = Map<String, dynamic>.from(decoded);
        } catch (_) {
          continue;
        }

        final ticketId = (payload['ticket_id']?.toString() ?? '').trim();
        if (ticketId.isEmpty) continue;

        final avatarLocalPath = await _cacheAvatarLocally(ticketId, remoteUrl);
        if (avatarLocalPath.isEmpty) continue;

        payload['participant_photo_local_path'] = avatarLocalPath;
        payload['updated_at'] = DateTime.now().toUtc().toIso8601String();
        await _store.updateTicketCacheByHash(
          actorKey: actorKey,
          ticketHash: ticketHash,
          updates: {
            'payload_json': jsonEncode(payload),
            'avatar_local_path': avatarLocalPath,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
        );
        updatedAny = true;
      }

      if (updatedAny) {
        await _backupService.autoBackupIfConfigured(force: true);
      }
    } finally {
      _avatarWarmupsInFlight.remove(actorKey);
    }
  }

  Map<String, dynamic>? _mapFromDynamic(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  bool _payloadHasEventContext(Map<String, dynamic>? payload) {
    if (payload == null || payload.isEmpty) return false;
    final contextMap = _mapFromDynamic(payload['context']);
    final eventMap = _mapFromDynamic(contextMap?['event']);
    final eventId = (eventMap?['id']?.toString() ?? '').trim();
    return eventId.isNotEmpty;
  }

  bool _resolvedPayloadIsOpen(Map<String, dynamic> payload) {
    final resolved = _resolveContextStatusLocally(Map<String, dynamic>.from(payload));
    final status = (resolved['status']?.toString() ?? '').trim().toLowerCase();
    return resolved['scanner_enabled'] == true && status == 'open';
  }

  bool _resolvedPayloadIsReusable(Map<String, dynamic> payload) {
    final resolved = _resolveContextStatusLocally(Map<String, dynamic>.from(payload));
    final status = (resolved['status']?.toString() ?? '').trim().toLowerCase();
    return _payloadHasEventContext(resolved) &&
        (status == 'open' || status == 'waiting');
  }

  Future<Map<String, dynamic>?> _loadRawContextPayload(String actorKey) async {
    final row = await _store.getContextCache(actorKey);
    if (row == null || row.isEmpty) return null;
    final payloadJson = (row['payload_json']?.toString() ?? '').trim();
    if (payloadJson.isEmpty) return null;

    try {
      final payload = jsonDecode(payloadJson);
      if (payload is! Map) return null;
      return Map<String, dynamic>.from(payload);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _selectPreferredContextPayload({
    Map<String, dynamic>? existingPayload,
    required Map<String, dynamic> newPayload,
  }) {
    if (existingPayload == null || existingPayload.isEmpty) {
      return Map<String, dynamic>.from(newPayload);
    }

    final newHasContext = _payloadHasEventContext(newPayload);
    final existingHasContext = _payloadHasEventContext(existingPayload);
    final existingOpen = _resolvedPayloadIsOpen(existingPayload);
    final newStatus =
        (newPayload['status']?.toString() ?? '').trim().toLowerCase();
    final newTransient = newStatus == 'error';

    if (existingOpen && newTransient) {
      return Map<String, dynamic>.from(existingPayload);
    }

    if (!newHasContext &&
        existingHasContext &&
        _resolvedPayloadIsReusable(existingPayload) &&
        newTransient) {
      return Map<String, dynamic>.from(existingPayload);
    }

    return Map<String, dynamic>.from(newPayload);
  }

  Map<String, dynamic> _selectResolvedOfflineContext({
    required Map<String, dynamic> resolvedPayload,
    Map<String, dynamic>? derivedPayload,
  }) {
    if (derivedPayload == null || derivedPayload.isEmpty) {
      return resolvedPayload;
    }

    final resolvedStatus =
        (resolvedPayload['status']?.toString() ?? '').trim().toLowerCase();
    final resolvedHasContext = _payloadHasEventContext(resolvedPayload);
    final derivedHasContext = _payloadHasEventContext(derivedPayload);

    if (resolvedStatus == 'no_assignment') {
      return resolvedPayload;
    }

    if (!resolvedHasContext && derivedHasContext) {
      return derivedPayload;
    }

    if (resolvedStatus == 'error') {
      return derivedPayload;
    }

    return resolvedPayload;
  }

  Map<String, dynamic>? _deriveContextCandidateFromTicketPayload(
    Map<String, dynamic> payload, {
    Map<String, dynamic>? fallbackPayload,
  }) {
    final fallbackContext = _mapFromDynamic(fallbackPayload?['context']);
    final fallbackEvent = _mapFromDynamic(fallbackContext?['event']);
    final fallbackSession = _mapFromDynamic(fallbackContext?['session']);

    final eventId = (payload['event_id']?.toString() ??
            fallbackEvent?['id']?.toString() ??
            '')
        .trim();
    if (eventId.isEmpty) return null;

    final eventTitle = (payload['event_title']?.toString() ??
            fallbackEvent?['title']?.toString() ??
            'Assigned Event')
        .trim();
    final eventLocation = (payload['event_location']?.toString() ??
            fallbackEvent?['location']?.toString() ??
            '')
        .trim();
    final eventStartAtRaw = (payload['event_start_at']?.toString() ??
            fallbackEvent?['start_at']?.toString() ??
            '')
        .trim();
    final eventEndAtRaw = (payload['event_end_at']?.toString() ??
            fallbackEvent?['end_at']?.toString() ??
            '')
        .trim();
    final eventGraceTime =
        int.tryParse(payload['event_grace_time']?.toString() ?? '') ??
        int.tryParse(fallbackEvent?['grace_time']?.toString() ?? '') ??
        30;

    final sessionId = (payload['session_id']?.toString() ??
            fallbackSession?['id']?.toString() ??
            '')
        .trim();
    final sessionTitle = (payload['session_title']?.toString() ??
            fallbackSession?['title']?.toString() ??
            '')
        .trim();
    final sessionDisplayName = (payload['session_display_name']?.toString() ??
            fallbackSession?['display_name']?.toString() ??
            sessionTitle)
        .trim();
    final sessionStartAtRaw = (payload['session_start_at']?.toString() ??
            (sessionId.isNotEmpty
                ? (fallbackSession?['start_at']?.toString() ?? '')
                : ''))
        .trim();
    final sessionEndAtRaw = (payload['session_end_at']?.toString() ??
            (sessionId.isNotEmpty
                ? (fallbackSession?['end_at']?.toString() ?? '')
                : ''))
        .trim();
    final source = ((payload['scanner_source']?.toString() ?? '').trim()
            .toLowerCase())
        .isNotEmpty
        ? (payload['scanner_source']?.toString() ?? '').trim().toLowerCase()
        : (sessionId.isNotEmpty ? 'session' : 'event');
    final windowMinutes =
        int.tryParse(payload['session_scan_window_minutes']?.toString() ?? '') ??
            int.tryParse(
              fallbackSession?['scan_window_minutes']?.toString() ?? '',
            ) ??
            30;
    final opensAt =
        _parseDate(payload['context_opens_at']?.toString()) ??
        _parseDate(
          sessionId.isNotEmpty ? sessionStartAtRaw : eventStartAtRaw,
        );
    DateTime? closesAt = _parseDate(payload['context_closes_at']?.toString());
    if (closesAt == null && opensAt != null) {
      final computedClose = opensAt.add(
        Duration(minutes: sessionId.isNotEmpty ? windowMinutes : eventGraceTime),
      );
      final hardEndAt = _parseDate(
        sessionId.isNotEmpty
            ? (sessionEndAtRaw.isNotEmpty ? sessionEndAtRaw : eventEndAtRaw)
            : eventEndAtRaw,
      );
      if (hardEndAt != null && hardEndAt.isBefore(computedClose)) {
        closesAt = hardEndAt;
      } else {
        closesAt = computedClose;
      }
    }

    if (opensAt == null) return null;

    final now = DateTime.now().toUtc();
    String status;
    String message;
    if (now.isBefore(opensAt)) {
      status = 'waiting';
      message = source == 'session'
          ? 'Waiting for seminar scan window.'
          : 'Waiting for event scan window.';
    } else if (closesAt != null && now.isAfter(closesAt)) {
      status = 'closed';
      message = source == 'session'
          ? 'Seminar scan window has closed.'
          : 'Event scan window has closed.';
    } else {
      status = 'open';
      message = source == 'session'
          ? 'Seminar scanning is open.'
          : 'Event scanning is open.';
    }

    final updatedAtIso = (payload['updated_at']?.toString() ?? '').trim();

    return {
      'ok': true,
      'status': status,
      'scanner_enabled': status == 'open',
      'message': message,
      'context': {
        'status': status,
        'source': source,
        'event': {
          'id': eventId,
          'title': eventTitle,
          'location': eventLocation,
          'start_at': eventStartAtRaw,
          'end_at': eventEndAtRaw,
        },
        'session': sessionId.isEmpty
            ? null
            : {
                'id': sessionId,
                'title': sessionTitle,
                'display_name': sessionDisplayName,
                'start_at': sessionStartAtRaw,
                'end_at': sessionEndAtRaw,
                'scan_window_minutes': windowMinutes,
              },
        'opens_at': opensAt.toIso8601String(),
        'closes_at': closesAt?.toIso8601String(),
        'window_minutes': sessionId.isNotEmpty ? windowMinutes : eventGraceTime,
        'message': message,
      },
      'assignments': 1,
      'server_time': now.toIso8601String(),
      'offline_context_source': 'ticket_cache',
      'offline_context_updated_at': updatedAtIso,
    };
  }

  Future<Map<String, dynamic>?> _deriveContextFromTicketCache({
    required String actorKey,
    Map<String, dynamic>? fallbackPayload,
  }) async {
    final rows = await _store.listRecentTicketCache(
      actorKey: actorKey,
      limit: 250,
    );
    if (rows.isEmpty) return null;

    final fallbackContext = _mapFromDynamic(fallbackPayload?['context']);
    final fallbackEvent = _mapFromDynamic(fallbackContext?['event']);
    final fallbackEventId = (fallbackEvent?['id']?.toString() ?? '').trim();
    final candidates = <Map<String, dynamic>>[];
    final seenKeys = <String>{};

    for (final row in rows) {
      final payloadJson = (row['payload_json']?.toString() ?? '').trim();
      if (payloadJson.isEmpty) continue;

      dynamic decoded;
      try {
        decoded = jsonDecode(payloadJson);
      } catch (_) {
        continue;
      }
      if (decoded is! Map) continue;

      final payload = Map<String, dynamic>.from(decoded);
      final candidate = _deriveContextCandidateFromTicketPayload(
        payload,
        fallbackPayload: fallbackPayload,
      );
      if (candidate == null) continue;

      final context = _mapFromDynamic(candidate['context']);
      final event = _mapFromDynamic(context?['event']);
      final session = _mapFromDynamic(context?['session']);
      final dedupeKey =
          '${event?['id']?.toString() ?? ''}|${session?['id']?.toString() ?? ''}';
      if (!seenKeys.add(dedupeKey)) continue;

      candidate['offline_context_updated_at'] =
          (row['updated_at']?.toString() ??
                  candidate['offline_context_updated_at']?.toString() ??
                  '')
              .trim();
      candidates.add(candidate);
    }

    if (candidates.isEmpty) return null;

    int rank(Map<String, dynamic> candidate) {
      final status =
          (candidate['status']?.toString() ?? '').trim().toLowerCase();
      final context = _mapFromDynamic(candidate['context']);
      final event = _mapFromDynamic(context?['event']);
      final eventId = (event?['id']?.toString() ?? '').trim();
      final sameEvent = fallbackEventId.isNotEmpty && eventId == fallbackEventId;
      final statusRank = switch (status) {
        'open' => 0,
        'waiting' => 1,
        'closed' => 2,
        _ => 3,
      };
      return sameEvent ? statusRank : statusRank + 10;
    }

    candidates.sort((a, b) {
      final rankCompare = rank(a).compareTo(rank(b));
      if (rankCompare != 0) return rankCompare;

      final aUpdated = (a['offline_context_updated_at']?.toString() ?? '').trim();
      final bUpdated = (b['offline_context_updated_at']?.toString() ?? '').trim();
      return bUpdated.compareTo(aUpdated);
    });

    return candidates.first;
  }

  Future<Map<String, dynamic>?> _findCachedTicketRow({
    required String actorKey,
    required String ticketPayload,
    Map<String, dynamic>? effectiveContext,
  }) async {
    final normalizedPayload = ticketPayload.trim();
    final exactRow = await _store.getTicketCacheByHash(
      actorKey: actorKey,
      ticketHash: _ticketHash(normalizedPayload),
    );
    if (exactRow != null && exactRow.isNotEmpty) {
      return exactRow;
    }

    if (!normalizedPayload.startsWith('PULSE-')) {
      return null;
    }

    final ticketId = normalizedPayload.replaceFirst('PULSE-', '').trim();
    if (ticketId.isEmpty) {
      return null;
    }

    final contextMap = effectiveContext?['context'] is Map
        ? Map<String, dynamic>.from(effectiveContext!['context'] as Map)
        : <String, dynamic>{};
    final eventMap = contextMap['event'] is Map
        ? Map<String, dynamic>.from(contextMap['event'] as Map)
        : <String, dynamic>{};
    final activeEventId = (eventMap['id']?.toString() ?? '').trim();

    final candidateRows = activeEventId.isNotEmpty
        ? await _store.listTicketCacheForEvent(
            actorKey: actorKey,
            eventId: activeEventId,
          )
        : await _store.listRecentTicketCache(
            actorKey: actorKey,
            limit: 5000,
          );

    for (final row in candidateRows) {
      final payloadText = (row['payload_json']?.toString() ?? '').trim();
      if (payloadText.isEmpty) continue;

      try {
        final decoded = jsonDecode(payloadText);
        if (decoded is! Map) continue;
        final payload = Map<String, dynamic>.from(decoded);
        final cachedTicketId = (payload['ticket_id']?.toString() ?? '').trim();
        final cachedTicketPayload =
            (payload['ticket_payload']?.toString() ?? '').trim();
        if (cachedTicketId == ticketId || cachedTicketPayload == normalizedPayload) {
          return row;
        }
      } catch (_) {
        continue;
      }
    }

    if (activeEventId.isEmpty) {
      return null;
    }

    final globalRows = await _store.listRecentTicketCache(
      actorKey: actorKey,
      limit: 5000,
    );
    for (final row in globalRows) {
      final payloadText = (row['payload_json']?.toString() ?? '').trim();
      if (payloadText.isEmpty) continue;

      try {
        final decoded = jsonDecode(payloadText);
        if (decoded is! Map) continue;
        final payload = Map<String, dynamic>.from(decoded);
        final cachedTicketId = (payload['ticket_id']?.toString() ?? '').trim();
        final cachedTicketPayload =
            (payload['ticket_payload']?.toString() ?? '').trim();
        if (cachedTicketId == ticketId || cachedTicketPayload == normalizedPayload) {
          return row;
        }
      } catch (_) {
        continue;
      }
    }

    return null;
  }

  Future<Map<String, dynamic>> refreshSnapshotForCurrentScanner({
    required String actorId,
    required bool isTeacher,
    bool force = false,
  }) async {
    if (!force) {
      final last = _lastBackgroundSnapshotAt;
      if (last != null &&
          DateTime.now().toUtc().difference(last) < _backgroundSnapshotMinInterval) {
        final cached = await getCachedScannerContext(
          actorId: actorId.trim(),
          isTeacher: isTeacher,
        );
        if (cached != null) {
          return {
            'ok': true,
            'status': cached['status']?.toString() ?? 'closed',
            'ticket_count': 0,
            'roster_ready': true,
            'coalesced': true,
          };
        }
      }
      if (_inFlightSnapshot != null) {
        return _inFlightSnapshot!;
      }
    }

    final run = _refreshSnapshotForCurrentScannerBody(
      actorId: actorId,
      isTeacher: isTeacher,
    );
    if (!force) {
      _inFlightSnapshot = run;
    }
    try {
      final result = await run;
      if (!force) {
        _lastBackgroundSnapshotAt = DateTime.now().toUtc();
      }
      return result;
    } finally {
      if (!force && identical(_inFlightSnapshot, run)) {
        _inFlightSnapshot = null;
      }
    }
  }

  Future<Map<String, dynamic>> _refreshSnapshotForCurrentScannerBody({
    required String actorId,
    required bool isTeacher,
  }) async {
    await _ensureAutoRestore();
    final actor = actorId.trim();
    if (actor.isEmpty) {
      return {'ok': false, 'error': 'Missing scanner account id.'};
    }

    final role = _actorRole(isTeacher: isTeacher);
    final actorKey = _actorKey(actorId: actor, isTeacher: isTeacher);
    final now = DateTime.now().toUtc();

    try {
      final liveContext = isTeacher
          ? await _eventService.getTeacherScanContext(actor)
          : await _eventService.getStudentScanContext(actor);
      final liveStatus =
          (liveContext['status']?.toString() ?? '').trim().toLowerCase();
      final liveOk = liveContext['ok'] == true;

      // Network/error responses must never wipe a warm offline roster.
      if (!liveOk || liveStatus == 'error') {
        final existing = await getCachedScannerContext(
          actorId: actor,
          isTeacher: isTeacher,
        );
        if (existing != null) {
          return {
            'ok': true,
            'status': existing['status']?.toString() ?? 'closed',
            'ticket_count': 0,
            'roster_ready': true,
            'kept_cache': true,
            'error': liveContext['message']?.toString() ??
                'Kept offline scanner cache after a failed refresh.',
          };
        }
        return {
          'ok': false,
          'status': 'error',
          'ticket_count': 0,
          'roster_ready': false,
          'error': liveContext['message']?.toString() ??
              'Unable to refresh scanner snapshot right now.',
        };
      }

      final existingPayload = await _loadRawContextPayload(actorKey);
      final effectivePayload = _selectPreferredContextPayload(
        existingPayload: existingPayload,
        newPayload: Map<String, dynamic>.from(liveContext),
      );
      final resolvedPayload = _resolveContextStatusLocally(effectivePayload);
      final contextStatus =
          (resolvedPayload['status']?.toString() ?? 'closed').trim();
      final scannerEnabled = resolvedPayload['scanner_enabled'] == true;

      if (contextStatus.toLowerCase() == 'no_assignment') {
        // Only clear when there is no reusable cached assignment pack.
        // A false BFF no_assignment must not wipe a warm offline snapshot.
        if (liveOk && liveStatus == 'no_assignment') {
          final existing = await _loadRawContextPayload(actorKey);
          if (existing == null || !_payloadHasEventContext(existing)) {
            await _store.deleteContextCache(actorKey);
            await _store.clearTicketCacheForActor(actorKey);
            await _backupService.autoBackupIfConfigured(force: true);
          }
        }
        final kept = await getCachedScannerContext(
          actorId: actor,
          isTeacher: isTeacher,
        );
        if (kept != null && _payloadHasEventContext(kept)) {
          return {
            'ok': true,
            'status': kept['status']?.toString() ?? 'closed',
            'ticket_count': 0,
            'roster_ready': true,
            'kept_cache': true,
            'error': 'Kept offline scanner cache after no_assignment response.',
          };
        }
        return {
          'ok': false,
          'status': contextStatus,
          'ticket_count': 0,
          'roster_ready': false,
          'error': 'No QR scanner assignment found for this account.',
        };
      }

      await _store.upsertContextCache(
        actorKey: actorKey,
        role: role,
        actorId: actor,
        status: contextStatus,
        scannerEnabled: scannerEnabled,
        syncedAtIso: now.toIso8601String(),
        expiresAtIso: now.add(_maxCacheAge).toIso8601String(),
        payloadJson: jsonEncode(effectivePayload),
      );

      final contextMap = resolvedPayload['context'] is Map
          ? Map<String, dynamic>.from(resolvedPayload['context'] as Map)
          : <String, dynamic>{};
      final eventMap = contextMap['event'] is Map
          ? Map<String, dynamic>.from(contextMap['event'] as Map)
          : <String, dynamic>{};
      final eventId = (eventMap['id']?.toString() ?? '').trim();
      if (eventId.isEmpty) {
        await _backupService.autoBackupIfConfigured(force: true);
        return {
          'ok': false,
          'status': contextStatus,
          'ticket_count': 0,
          'roster_ready': false,
          'error': 'Scanner context has no active event to cache offline.',
        };
      }

      final existingRows = await _store.listTicketCacheForEvent(
        actorKey: actorKey,
        eventId: eventId,
      );
      final existingRowsByHash = <String, Map<String, dynamic>>{
        for (final row in existingRows)
          (row['ticket_hash']?.toString() ?? '').trim(): Map<String, dynamic>.from(row),
      };
      final roster = await _eventService.getOfflineScannerRoster(eventId);
      final activeSession = contextMap['session'] is Map
          ? Map<String, dynamic>.from(contextMap['session'] as Map)
          : <String, dynamic>{};
    final activeSessionId = (activeSession['id']?.toString() ?? '').trim();
    final eventTitle = (eventMap['title']?.toString() ?? '').trim();
    final eventLocation = (eventMap['location']?.toString() ?? '').trim();
    final eventStartAt = (eventMap['start_at']?.toString() ?? '').trim();
    final eventEndAt = (eventMap['end_at']?.toString() ?? '').trim();
    final eventGraceTime =
        int.tryParse(eventMap['grace_time']?.toString() ?? '') ??
        int.tryParse(contextMap['window_minutes']?.toString() ?? '') ??
        30;
    final scannerSource = activeSessionId.isNotEmpty ? 'session' : 'event';
    final sessionTitle = (activeSession['title']?.toString() ?? '').trim();
    final sessionDisplayName =
        (activeSession['display_name']?.toString() ?? sessionTitle).trim();
    final sessionStartAt = (activeSession['start_at']?.toString() ?? '').trim();
    final sessionEndAt = (activeSession['end_at']?.toString() ?? '').trim();
    final contextOpensAt = (contextMap['opens_at']?.toString() ?? '').trim();
    final contextClosesAt = (contextMap['closes_at']?.toString() ?? '').trim();
    final contextWindowMinutes =
        int.tryParse(contextMap['window_minutes']?.toString() ?? '') ?? 30;
    final sessionWindowMinutes = int.tryParse(
          activeSession['scan_window_minutes']?.toString() ?? '',
        ) ??
        int.tryParse(contextMap['window_minutes']?.toString() ?? '') ??
        30;

      final rows = <Map<String, dynamic>>[];
      for (final rosterItem in roster) {
        final item = Map<String, dynamic>.from(rosterItem);
        final ticketId = (item['ticket_id']?.toString() ?? '').trim();
        if (ticketId.isEmpty) continue;

        final payloadTicket = 'PULSE-$ticketId';
        final ticketHash = _ticketHash(payloadTicket);
        final participantName = (item['participant_name']?.toString() ?? '').trim();
        final participantStudentId =
            (item['participant_student_id']?.toString() ?? '').trim();
        final participantStudentNo =
            (item['participant_student_no']?.toString() ?? participantStudentId)
                .trim();
        final participantUserId =
            (item['participant_user_id']?.toString() ?? '').trim();
        final remotePhotoUrl =
            (item['participant_photo_url']?.toString() ?? '').trim();
        var avatarLocalPath = '';
        final existingRow = existingRowsByHash[ticketHash];
        final existingLocalPath =
            (existingRow?['avatar_local_path']?.toString() ?? '').trim();
        if (existingLocalPath.isNotEmpty && File(existingLocalPath).existsSync()) {
          avatarLocalPath = existingLocalPath;
        } else if (remotePhotoUrl.isNotEmpty) {
          avatarLocalPath = await _cacheAvatarLocally(ticketId, remotePhotoUrl);
        }
        final registrationId = (item['registration_id']?.toString() ?? '').trim();
        final sessionPresenceRaw = item['session_presence'];
        final sessionPresence = sessionPresenceRaw is Map
            ? Map<String, dynamic>.from(sessionPresenceRaw)
            : <String, dynamic>{};

        var attendanceStatus =
            (item['attendance_status']?.toString() ?? 'unscanned')
                .trim()
                .toLowerCase();
        if (attendanceStatus.isEmpty) {
          attendanceStatus = 'unscanned';
        }
        if (activeSessionId.isNotEmpty &&
            sessionPresence[activeSessionId] == true) {
          attendanceStatus = 'present';
        }

        final payload = {
          'ticket_id': ticketId,
          'ticket_payload': payloadTicket,
          'registration_id': registrationId,
          'event_id': eventId,
          'participant_name': participantName,
          'participant_student_id': participantStudentId,
          'participant_student_no': participantStudentNo,
          'participant_user_id': participantUserId,
          'participant_photo_url': remotePhotoUrl,
          'participant_photo_local_path': avatarLocalPath,
          'session_presence': sessionPresence,
          'attendance_status': attendanceStatus,
          'pending_sync': false,
          'scanner_source': scannerSource,
          'context_opens_at': contextOpensAt,
          'context_closes_at': contextClosesAt,
          'context_window_minutes': contextWindowMinutes,
          'event_title': eventTitle,
          'event_location': eventLocation,
          'event_start_at': eventStartAt,
          'event_end_at': eventEndAt,
          'event_grace_time': eventGraceTime,
          'session_id': activeSessionId,
          'session_title': sessionTitle,
          'session_display_name': sessionDisplayName,
          'session_start_at': sessionStartAt,
          'session_end_at': sessionEndAt,
          'session_scan_window_minutes': sessionWindowMinutes,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        };

        rows.add({
          'actor_key': actorKey,
          'event_id': eventId,
          'session_id': activeSessionId,
          'ticket_hash': ticketHash,
          'payload_json': jsonEncode(payload),
          'avatar_local_path': avatarLocalPath,
          'avatar_remote_url': remotePhotoUrl,
          'attendance_status': attendanceStatus,
          'pending_sync': 0,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      }

      if (rows.isEmpty) {
        final existingTicketCount = existingRows.length;
        await _backupService.autoBackupIfConfigured(force: true);
        if (existingTicketCount > 0) {
          return {
            'ok': true,
            'status': contextStatus,
            'ticket_count': existingTicketCount,
            'event_id': eventId,
            'roster_ready': true,
            'used_cached_roster': true,
            'warning':
                'Latest roster refresh returned no ticket rows, so the previously saved offline roster is being kept.',
          };
        }
        // Empty roster is still a successful warm: assignment + schedule are
        // cached. Tickets can be empty before anyone registers.
        return {
          'ok': true,
          'status': contextStatus,
          'ticket_count': 0,
          'event_id': eventId,
          'roster_ready': true,
          'empty_roster': true,
        };
      }

      await _store.replaceTicketCacheForEvent(
        actorKey: actorKey,
        eventId: eventId,
        rows: rows,
      );
      unawaited(_warmAvatarCacheForRows(actorKey: actorKey, rows: rows));
      await _backupService.autoBackupIfConfigured(force: true);

      return {
        'ok': true,
        'status': contextStatus,
        'ticket_count': rows.length,
        'event_id': eventId,
        'roster_ready': true,
      };
    } catch (e) {
      return {
        'ok': false,
        'error': 'Unable to refresh offline snapshot right now.',
        'debug': kDebugMode ? e.toString() : '',
      };
    }
  }

  Future<void> clearCachedScannerAccess({
    required String actorId,
    required bool isTeacher,
  }) async {
    await _ensureAutoRestore();
    final actor = actorId.trim();
    if (actor.isEmpty) return;

    final actorKey = _actorKey(actorId: actor, isTeacher: isTeacher);
    await _store.deleteContextCache(actorKey);
    await _store.clearTicketCacheForActor(actorKey);
    await _backupService.autoBackupIfConfigured(force: true);
  }

  Future<void> cacheLiveScannerContext({
    required String actorId,
    required bool isTeacher,
    required Map<String, dynamic> contextPayload,
  }) async {
    await _ensureAutoRestore();
    final actor = actorId.trim();
    if (actor.isEmpty || contextPayload.isEmpty) return;

    final role = _actorRole(isTeacher: isTeacher);
    final actorKey = _actorKey(actorId: actor, isTeacher: isTeacher);
    final now = DateTime.now().toUtc();
    final existingPayload = await _loadRawContextPayload(actorKey);
    final effectivePayload = _selectPreferredContextPayload(
      existingPayload: existingPayload,
      newPayload: Map<String, dynamic>.from(contextPayload),
    );
    final resolvedPayload = _resolveContextStatusLocally(effectivePayload);
    final status = (resolvedPayload['status']?.toString() ?? 'closed').trim();
    final scannerEnabled = resolvedPayload['scanner_enabled'] == true;
    final liveOk = contextPayload['ok'] == true;
    final liveStatus =
        (contextPayload['status']?.toString() ?? '').trim().toLowerCase();

    if (status.toLowerCase() == 'no_assignment') {
      // Never wipe warm offline data from a transient/error payload.
      if (liveOk && liveStatus == 'no_assignment') {
        await _store.deleteContextCache(actorKey);
        await _store.clearTicketCacheForActor(actorKey);
        await _backupService.autoBackupIfConfigured(force: true);
      }
      return;
    }

    await _store.upsertContextCache(
      actorKey: actorKey,
      role: role,
      actorId: actor,
      status: status,
      scannerEnabled: scannerEnabled,
      syncedAtIso: now.toIso8601String(),
      expiresAtIso: now.add(_maxCacheAge).toIso8601String(),
      payloadJson: jsonEncode(effectivePayload),
    );
    await _backupService.autoBackupIfConfigured(force: true);
  }

  /// Recompute scanner open/closed from cached schedule.
  /// Handles time-in grace → time-out at end (+1h) or Early Out for simple
  /// and seminar events so offline/online local clocks stay aligned with BFF.
  Map<String, dynamic> resolveScannerContextLocally(
    Map<String, dynamic> contextPayload,
  ) {
    return _resolveContextStatusLocally(contextPayload);
  }

  Map<String, dynamic> _resolveContextStatusLocally(
    Map<String, dynamic> contextPayload,
  ) {
    final now = DateTime.now().toUtc();
    final cachedStatus =
        (contextPayload['status']?.toString() ?? 'closed').toLowerCase().trim();
    final cachedEnabled = contextPayload['scanner_enabled'] == true;
    final contextMap = contextPayload['context'] is Map
        ? Map<String, dynamic>.from(contextPayload['context'] as Map)
        : <String, dynamic>{};
    final sessionMap = contextMap['session'] is Map
        ? Map<String, dynamic>.from(contextMap['session'] as Map)
        : <String, dynamic>{};
    final eventMap = contextMap['event'] is Map
        ? Map<String, dynamic>.from(contextMap['event'] as Map)
        : <String, dynamic>{};

    final sessionStartAt = _parseDate(sessionMap['start_at']?.toString());
    final eventStartAt = _parseDate(eventMap['start_at']?.toString());
    final sessionEndAt = _parseDate(sessionMap['end_at']?.toString());
    final eventEndAt = _parseDate(eventMap['end_at']?.toString());

    final sessionWindowMinutes =
        int.tryParse(sessionMap['scan_window_minutes']?.toString() ?? '') ??
        int.tryParse(contextMap['window_minutes']?.toString() ?? '') ??
        30;
    final eventWindowMinutes =
        int.tryParse(eventMap['grace_time']?.toString() ?? '') ??
        int.tryParse(contextMap['window_minutes']?.toString() ?? '') ??
        30;

    final checkInOpens = sessionStartAt ?? eventStartAt;
    final checkInGrace = sessionStartAt != null
        ? sessionWindowMinutes
        : eventWindowMinutes;
    final checkInCloses = checkInOpens?.add(Duration(minutes: checkInGrace));

    final earlyOutRaw = (sessionMap['early_out_enabled_at']?.toString() ??
            eventMap['early_out_enabled_at']?.toString() ??
            contextMap['early_out_enabled_at']?.toString() ??
            '')
        .trim();
    final earlyOutAt = _parseDate(earlyOutRaw);

    DateTime? checkOutOpens;
    DateTime? checkOutCloses;
    var checkOutIsEarly = false;
    if (earlyOutAt != null) {
      final earlyCloses = earlyOutAt.add(const Duration(hours: 1));
      // Early Out only while still within its hour (same as PHP).
      if (!now.isAfter(earlyCloses)) {
        checkOutOpens = earlyOutAt;
        checkOutCloses = earlyCloses;
        checkOutIsEarly = true;
      }
    }
    if (checkOutOpens == null) {
      checkOutOpens = sessionEndAt ?? eventEndAt;
      if (checkOutOpens != null) {
        checkOutCloses = checkOutOpens.add(const Duration(hours: 1));
      }
    }

    Map<String, dynamic> withWindow({
      required String status,
      required bool enabled,
      required String scanMode,
      DateTime? opensAt,
      DateTime? closesAt,
      String? message,
    }) {
      final nextContext = Map<String, dynamic>.from(contextMap);
      nextContext['status'] = status;
      nextContext['scan_mode'] = scanMode;
      if (opensAt != null) {
        nextContext['opens_at'] = opensAt.toIso8601String();
      }
      if (closesAt != null) {
        nextContext['closes_at'] = closesAt.toIso8601String();
      }
      if (checkOutIsEarly && scanMode == 'check_out') {
        nextContext['early_out'] = true;
      }
      return {
        ...contextPayload,
        'status': status,
        'scanner_enabled': enabled,
        'context': nextContext,
        if (message != null && message.trim().isNotEmpty) 'message': message,
      };
    }

    // 1) Time-in window open
    if (checkInOpens != null &&
        checkInCloses != null &&
        !now.isBefore(checkInOpens) &&
        !now.isAfter(checkInCloses)) {
      return withWindow(
        status: 'open',
        enabled: true,
        scanMode: 'check_in',
        opensAt: checkInOpens,
        closesAt: checkInCloses,
        message: 'Scanning is open for time-in.',
      );
    }

    // 2) Time-out window open (end → end+1h or Early Out)
    if (checkOutOpens != null &&
        checkOutCloses != null &&
        !now.isBefore(checkOutOpens) &&
        !now.isAfter(checkOutCloses)) {
      return withWindow(
        status: 'open',
        enabled: true,
        scanMode: 'check_out',
        opensAt: checkOutOpens,
        closesAt: checkOutCloses,
        message: checkOutIsEarly
            ? 'Early time-out is open.'
            : 'Time-out is open.',
      );
    }

    // 3) Before time-in
    if (checkInOpens != null && now.isBefore(checkInOpens)) {
      return withWindow(
        status: 'waiting',
        enabled: false,
        scanMode: 'check_in',
        opensAt: checkInOpens,
        closesAt: checkInCloses,
        message: 'Too early to time in. Wait for the scheduled start.',
      );
    }

    // 4) Between time-in grace end and time-out open
    if (checkOutOpens != null && now.isBefore(checkOutOpens)) {
      return withWindow(
        status: 'closed',
        enabled: false,
        scanMode: 'check_out',
        opensAt: checkOutOpens,
        closesAt: checkOutCloses,
        message:
            'Too early to time out. Time-out opens at the scheduled end.',
      );
    }

    // 5) After time-out window
    if (checkOutCloses != null && now.isAfter(checkOutCloses)) {
      return withWindow(
        status: 'closed',
        enabled: false,
        scanMode: 'check_out',
        opensAt: checkOutOpens,
        closesAt: checkOutCloses,
        message: 'Time-out window has closed.',
      );
    }

    // Fallback: honor explicit BFF opens/closes when schedule fields missing.
    final opensAt = _parseDate(contextMap['opens_at']?.toString());
    final closesAt = _parseDate(contextMap['closes_at']?.toString());
    final scanMode =
        (contextMap['scan_mode']?.toString() ?? 'check_in').toLowerCase().trim();
    if (opensAt != null && now.isBefore(opensAt)) {
      return withWindow(
        status: 'waiting',
        enabled: false,
        scanMode: scanMode.isEmpty ? 'check_in' : scanMode,
        opensAt: opensAt,
        closesAt: closesAt,
      );
    }
    if (closesAt != null && now.isAfter(closesAt)) {
      return withWindow(
        status: 'closed',
        enabled: false,
        scanMode: scanMode.isEmpty ? 'check_in' : scanMode,
        opensAt: opensAt,
        closesAt: closesAt,
      );
    }
    if (opensAt != null &&
        (closesAt == null ||
            now.isBefore(closesAt) ||
            now.isAtSameMomentAs(closesAt))) {
      return withWindow(
        status: 'open',
        enabled: true,
        scanMode: scanMode.isEmpty ? 'check_in' : scanMode,
        opensAt: opensAt,
        closesAt: closesAt,
      );
    }

    return {
      ...contextPayload,
      'status': cachedStatus,
      'scanner_enabled': cachedEnabled,
    };
  }

  Future<Map<String, dynamic>?> getCachedScannerContext({
    required String actorId,
    required bool isTeacher,
  }) async {
    await _ensureAutoRestore();
    final actor = actorId.trim();
    if (actor.isEmpty) return null;

    final actorKey = _actorKey(actorId: actor, isTeacher: isTeacher);
    final row = await _store.getContextCache(actorKey);
    Map<String, dynamic>? storedPayload;
    DateTime syncedAt = DateTime.fromMillisecondsSinceEpoch(0).toUtc();
    DateTime expiresAt = syncedAt.add(_maxCacheAge);

    if (row != null && row.isNotEmpty) {
      final payloadJson = (row['payload_json']?.toString() ?? '').trim();
      if (payloadJson.isNotEmpty) {
        try {
          final payload = jsonDecode(payloadJson);
          if (payload is Map) {
            storedPayload = Map<String, dynamic>.from(payload);
          }
        } catch (_) {}
      }
      syncedAt = _parseDate(row['synced_at']?.toString()) ?? syncedAt;
      expiresAt = _parseDate(row['expires_at']?.toString()) ??
          syncedAt.add(_maxCacheAge);
    }

    if (storedPayload == null) {
      return null;
    }

    final derivedPayload = await _deriveContextFromTicketCache(
      actorKey: actorKey,
      fallbackPayload: storedPayload,
    );
    final stale = DateTime.now().toUtc().isAfter(expiresAt);
    final resolved = _resolveContextStatusLocally(
      Map<String, dynamic>.from(storedPayload),
    );
    final resolvedStatus =
        (resolved['status']?.toString() ?? '').trim().toLowerCase();
    final effective = resolvedStatus == 'error'
        ? _selectResolvedOfflineContext(
            resolvedPayload: resolved,
            derivedPayload: derivedPayload,
          )
        : resolved;
    return {
      ...effective,
      'offline_cache_stale': stale,
      'offline_cache_synced_at': syncedAt.toIso8601String(),
      'offline_cache_expires_at': expiresAt.toIso8601String(),
    };
  }

  Future<List<Map<String, dynamic>>> getOfflineParticipantRoster({
    required String actorId,
    required bool isTeacher,
    required String eventId,
  }) async {
    await _ensureAutoRestore();
    final actor = actorId.trim();
    final currentEventId = eventId.trim();
    if (actor.isEmpty || currentEventId.isEmpty) return <Map<String, dynamic>>[];

    final actorKey = _actorKey(actorId: actor, isTeacher: isTeacher);
    final rows = await _store.listTicketCacheForEvent(
      actorKey: actorKey,
      eventId: currentEventId,
    );
    if (rows.isEmpty) return <Map<String, dynamic>>[];

    final grouped = <String, Map<String, dynamic>>{};

    for (final row in rows) {
      final payloadText = (row['payload_json']?.toString() ?? '').trim();
      if (payloadText.isEmpty) continue;

      dynamic payloadRaw;
      try {
        payloadRaw = jsonDecode(payloadText);
      } catch (_) {
        continue;
      }
      if (payloadRaw is! Map) continue;
      final payload = Map<String, dynamic>.from(payloadRaw);

      final ticketHash = (row['ticket_hash']?.toString() ?? '').trim();
      final key = _offlineParticipantKey(payload, ticketHash);
      final registrationId =
          (payload['registration_id']?.toString() ?? '').trim();
      final participantName =
          (payload['participant_name']?.toString() ?? '').trim();
      final studentId =
          (payload['participant_student_id']?.toString() ?? '').trim();
      final remotePhotoUrl =
          (payload['participant_photo_url']?.toString() ?? '').trim();
      final localPhotoPath =
          (payload['participant_photo_local_path']?.toString() ?? '').trim();
      final updatedAtIso =
          (payload['updated_at']?.toString() ?? row['updated_at']?.toString() ?? '')
              .trim();
      final pendingSync =
          payload['pending_sync'] == true || row['pending_sync'] == 1;
      final attendanceStatus = _normalizeOfflineAttendanceStatus(
        payload['attendance_status']?.toString() ?? '',
        pendingSync: pendingSync,
      );

      final participant = grouped.putIfAbsent(key, () {
        return {
          'id': registrationId.isNotEmpty ? registrationId : key,
          'student_id': studentId,
          'display_name': participantName,
          'offline_cached': true,
          'offline_pending': pendingSync,
          'offline_updated_at': updatedAtIso,
          'users': <String, dynamic>{
            'display_name': participantName,
            'full_name': participantName,
            'student_id': studentId,
            'photo_url': remotePhotoUrl,
            'photo_local_path': localPhotoPath,
          },
          'tickets': <Map<String, dynamic>>[],
          'session_attendance': <Map<String, dynamic>>[],
        };
      });

      if (registrationId.isNotEmpty) {
        participant['id'] = registrationId;
      }
      if (studentId.isNotEmpty) {
        participant['student_id'] = studentId;
      }
      if (participantName.isNotEmpty) {
        participant['display_name'] = participantName;
      }
      if (pendingSync) {
        participant['offline_pending'] = true;
      }
      final currentUpdatedAt =
          (participant['offline_updated_at']?.toString() ?? '').trim();
      if (updatedAtIso.isNotEmpty &&
          (currentUpdatedAt.isEmpty ||
              updatedAtIso.compareTo(currentUpdatedAt) > 0)) {
        participant['offline_updated_at'] = updatedAtIso;
      }

      final users = participant['users'] is Map
          ? Map<String, dynamic>.from(participant['users'] as Map)
          : <String, dynamic>{};
      if (participantName.isNotEmpty) {
        users['display_name'] = participantName;
        users['full_name'] = participantName;
      }
      if (studentId.isNotEmpty) {
        users['student_id'] = studentId;
      }
      if (remotePhotoUrl.isNotEmpty) {
        users['photo_url'] = remotePhotoUrl;
      }
      if (localPhotoPath.isNotEmpty) {
        users['photo_local_path'] = localPhotoPath;
      }
      participant['users'] = users;

      final sessionAttendance = participant['session_attendance'] is List
          ? (participant['session_attendance'] as List)
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
          : <Map<String, dynamic>>[];

      final sessionPresenceRaw = payload['session_presence'];
      final sessionPresence = sessionPresenceRaw is Map
          ? Map<String, dynamic>.from(sessionPresenceRaw)
          : <String, dynamic>{};

      for (final entry in sessionPresence.entries) {
        final sessionId = entry.key.toString().trim();
        if (sessionId.isEmpty || entry.value != true) continue;
        _upsertOfflineSessionAttendance(sessionAttendance, {
          'session_id': sessionId,
          'status': 'present',
          'check_in_at': updatedAtIso,
          'last_scanned_at': updatedAtIso,
          'offline_pending': pendingSync,
        });
      }
      participant['session_attendance'] = sessionAttendance;

      final hasRecordedCheckIn =
          pendingSync ||
          attendanceStatus == 'present' ||
          attendanceStatus == 'late';
      final tickets = <Map<String, dynamic>>[
        {
          'id': payload['ticket_id'],
          'attendance': [
            {
              'status': attendanceStatus,
              'check_in_at': hasRecordedCheckIn ? updatedAtIso : null,
              'last_scanned_at': hasRecordedCheckIn ? updatedAtIso : null,
              'offline_pending': pendingSync,
            },
          ],
        },
      ];
      participant['tickets'] = tickets;
    }

    final participants = grouped.values.toList()
      ..sort((a, b) {
        final aName =
            (a['display_name']?.toString() ?? '').trim().toLowerCase();
        final bName =
            (b['display_name']?.toString() ?? '').trim().toLowerCase();
        return aName.compareTo(bName);
      });
    return participants;
  }

  Future<Map<String, dynamic>> validateOfflineDryRun({
    required String actorId,
    required bool isTeacher,
    required String ticketPayload,
    Map<String, dynamic>? activeContextOverride,
  }) async {
    await _ensureAutoRestore();
    final actor = actorId.trim();
    if (actor.isEmpty) {
      return {
        'ok': false,
        'status': 'no_assignment',
        'error': 'Unable to identify scanner account.',
      };
    }

    final normalizedPayload = ticketPayload.trim();
    if (!normalizedPayload.startsWith('PULSE-')) {
      return {
        'ok': false,
        'status': 'invalid',
        'error': 'Invalid QR code format.',
      };
    }

    final context = await getCachedScannerContext(
      actorId: actor,
      isTeacher: isTeacher,
    );
    if (context == null) {
      return {
        'ok': false,
        'status': 'no_cache',
        'error':
            'Offline scanner data is not ready yet. Keep the app online for a moment first.',
      };
    }
    if (context['offline_cache_stale'] == true) {
      return {
        'ok': false,
        'status': 'cache_stale',
        'error':
            'Offline scanner data is already stale. Reconnect to refresh the latest event data.',
      };
    }

    Map<String, dynamic> effectiveContext = _resolveContextStatusLocally(
      Map<String, dynamic>.from(
        (activeContextOverride != null && activeContextOverride.isNotEmpty)
            ? activeContextOverride
            : context,
      ),
    );
    effectiveContext['offline_cache_stale'] = context['offline_cache_stale'];
    effectiveContext['offline_cache_synced_at'] =
        context['offline_cache_synced_at'];
    effectiveContext['offline_cache_expires_at'] =
        context['offline_cache_expires_at'];

    final status =
        (effectiveContext['status']?.toString() ?? '').toLowerCase().trim();
    final scannerEnabled = effectiveContext['scanner_enabled'] == true;
    if (!scannerEnabled || status != 'open') {
      return {
        'ok': false,
        'status': status.isEmpty ? 'closed' : status,
        'error': 'Scanner is not open in the current offline schedule.',
      };
    }

    final actorKey = _actorKey(actorId: actor, isTeacher: isTeacher);
    final row = await _findCachedTicketRow(
      actorKey: actorKey,
      ticketPayload: normalizedPayload,
      effectiveContext: effectiveContext,
    );
    if (row == null || row.isEmpty) {
      return {
        'ok': false,
        'status': 'invalid',
        'error':
            'Ticket is not in the offline roster cache yet. Reconnect to update the latest assignment data.',
      };
    }

    final payloadRaw = jsonDecode(row['payload_json']?.toString() ?? '{}');
    if (payloadRaw is! Map) {
      return {
        'ok': false,
        'status': 'invalid',
        'error': 'Offline ticket cache is corrupted.',
      };
    }
    final payload = Map<String, dynamic>.from(payloadRaw);

    final activeEvent = effectiveContext['context'] is Map
        ? Map<String, dynamic>.from(effectiveContext['context'] as Map)
        : <String, dynamic>{};
    final activeEventMap = activeEvent['event'] is Map
        ? Map<String, dynamic>.from(activeEvent['event'] as Map)
        : <String, dynamic>{};
    final activeEventId = (activeEventMap['id']?.toString() ?? '').trim();
    final payloadEventId = (payload['event_id']?.toString() ?? '').trim();

    if (activeEventId.isNotEmpty &&
        payloadEventId.isNotEmpty &&
        activeEventId != payloadEventId) {
      return {
        'ok': false,
        'status': 'wrong_event',
        'error': 'Ticket is not for the current active cached event.',
      };
    }

    final activeSession = activeEvent['session'] is Map
        ? Map<String, dynamic>.from(activeEvent['session'] as Map)
        : <String, dynamic>{};
    final activeSessionId = (activeSession['id']?.toString() ?? '').trim();
    final sessionPresenceRaw = payload['session_presence'];
    final sessionPresence = sessionPresenceRaw is Map
        ? Map<String, dynamic>.from(sessionPresenceRaw)
        : <String, dynamic>{};

    final attendanceStatus =
        (payload['attendance_status']?.toString() ?? '').trim().toLowerCase();
    final pendingSync =
        payload['pending_sync'] == true || row['pending_sync'] == 1;
    final checkOutAt =
        (payload['check_out_at']?.toString() ?? '').trim();
    final alreadyCheckedOut = checkOutAt.isNotEmpty ||
        attendanceStatus == 'checked_out' ||
        attendanceStatus == 'already_checked_out' ||
        attendanceStatus == 'out';

    var alreadyCheckedIn = false;
    if (activeSessionId.isNotEmpty) {
      alreadyCheckedIn = sessionPresence[activeSessionId] == true ||
          _isCheckedInStatus(attendanceStatus) ||
          pendingSync;
    } else {
      alreadyCheckedIn = _isCheckedInStatus(attendanceStatus) || pendingSync;
    }

    final isCheckOut = _isOfflineCheckOutMode(effectiveContext);

    if (isCheckOut) {
      if (alreadyCheckedOut) {
        return {
          'ok': false,
          'status': 'already_checked_out',
          'error': 'Ticket already timed out.',
          'action': 'check_out',
          'participant_name': payload['participant_name'],
          'participant_photo_url': payload['participant_photo_url'],
          'participant_photo_local_path':
              payload['participant_photo_local_path'],
          'participant_student_id': payload['participant_student_id'],
          'participant_student_no': payload['participant_student_no'] ??
              payload['participant_student_id'],
        };
      }
      if (!alreadyCheckedIn && attendanceStatus != 'pending') {
        return {
          'ok': false,
          'status': 'absent_no_time_in',
          'error':
              'Cannot time out — this student has no time-in (marked absent).',
          'action': 'check_out',
          'participant_name': payload['participant_name'],
          'participant_photo_url': payload['participant_photo_url'],
          'participant_photo_local_path':
              payload['participant_photo_local_path'],
          'participant_student_id': payload['participant_student_id'],
          'participant_student_no': payload['participant_student_no'] ??
              payload['participant_student_id'],
        };
      }

      return {
        'ok': true,
        'status': 'ready_for_confirmation',
        'message': 'Offline time-out ready to queue.',
        'action': 'check_out',
        'ticket_hash': _ticketHash(normalizedPayload),
        'event_id': payloadEventId,
        'session_id': activeSessionId,
        'participant_name': payload['participant_name'],
        'participant_photo_url': payload['participant_photo_url'],
        'participant_photo_local_path': payload['participant_photo_local_path'],
        'participant_student_id': payload['participant_student_id'],
        'participant_student_no':
            payload['participant_student_no'] ?? payload['participant_student_id'],
        'from_offline_cache': true,
      };
    }

    if (alreadyCheckedIn || alreadyCheckedOut) {
      return {
        'ok': false,
        'status': alreadyCheckedOut ? 'already_checked_out' : 'already_checked_in',
        'error': alreadyCheckedOut
            ? 'Ticket already timed out.'
            : 'Ticket already checked in.',
        'participant_name': payload['participant_name'],
        'participant_photo_url': payload['participant_photo_url'],
        'participant_photo_local_path': payload['participant_photo_local_path'],
        'participant_student_id': payload['participant_student_id'],
        'participant_student_no':
            payload['participant_student_no'] ?? payload['participant_student_id'],
      };
    }

    return {
      'ok': true,
      'status': 'ready_for_confirmation',
      'message': 'Review participant, then confirm check-in.',
      'action': 'check_in',
      'ticket_hash': _ticketHash(normalizedPayload),
      'event_id': payloadEventId,
      'session_id': activeSessionId,
      'participant_name': payload['participant_name'],
      'participant_photo_url': payload['participant_photo_url'],
      'participant_photo_local_path': payload['participant_photo_local_path'],
      'participant_student_id': payload['participant_student_id'],
      'participant_student_no':
          payload['participant_student_no'] ?? payload['participant_student_id'],
      'from_offline_cache': true,
    };
  }

  Future<void> _updateCachedTicketAfterQueue({
    required String actorKey,
    required String ticketHash,
    required String sessionId,
    required bool pending,
    required String status,
  }) async {
    final row = await _store.getTicketCacheByHash(
      actorKey: actorKey,
      ticketHash: ticketHash,
    );
    if (row == null || row.isEmpty) return;

    final payloadRaw = jsonDecode(row['payload_json']?.toString() ?? '{}');
    if (payloadRaw is! Map) return;
    final payload = Map<String, dynamic>.from(payloadRaw);

    payload['pending_sync'] = pending;
    payload['attendance_status'] = status;
    payload['updated_at'] = DateTime.now().toUtc().toIso8601String();
    if (status == 'checked_out' || status == 'already_checked_out') {
      payload['check_out_at'] =
          (payload['check_out_at']?.toString() ?? '').trim().isNotEmpty
              ? payload['check_out_at']
              : DateTime.now().toUtc().toIso8601String();
    }
    if (sessionId.trim().isNotEmpty) {
      final current = payload['session_presence'] is Map
          ? Map<String, dynamic>.from(payload['session_presence'] as Map)
          : <String, dynamic>{};
      // Keep session presence true after time-in or while checkout is pending.
      current[sessionId.trim()] = status == 'present' ||
          status == 'checked_out' ||
          status == 'pending' ||
          pending;
      payload['session_presence'] = current;
    }

    await _store.updateTicketCacheByHash(
      actorKey: actorKey,
      ticketHash: ticketHash,
      updates: {
        'payload_json': jsonEncode(payload),
        'pending_sync': pending ? 1 : 0,
        'attendance_status': status,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  Future<Map<String, dynamic>?> getCachedSelfAttendancePack({
    required String studentId,
  }) async {
    await _ensureAutoRestore();
    final actor = studentId.trim();
    if (actor.isEmpty) return null;
    final actorKey = _selfActorKey(actor);
    final cached = await _store.getContextCache(actorKey);
    if (cached == null) return null;

    Map<String, dynamic> payload = {};
    try {
      final decoded = jsonDecode(cached['payload_json']?.toString() ?? '{}');
      if (decoded is Map) {
        payload = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      payload = {};
    }

    final syncedAt = _parseDate(cached['synced_at']?.toString());
    final expiresAt = _parseDate(cached['expires_at']?.toString());
    final now = DateTime.now().toUtc();
    final stale = expiresAt == null || now.isAfter(expiresAt);

    return {
      ...payload,
      'offline_cache_synced_at': syncedAt?.toIso8601String(),
      'offline_cache_expires_at': expiresAt?.toIso8601String(),
      'offline_cache_stale': stale,
      'status': (cached['status']?.toString() ?? 'ready').trim(),
      'scanner_enabled': cached['scanner_enabled'] == 1 ||
          cached['scanner_enabled'] == true,
    };
  }

  Future<Map<String, dynamic>> refreshSelfAttendanceSnapshot({
    required String studentId,
  }) async {
    await _ensureAutoRestore();
    final actor = studentId.trim();
    if (actor.isEmpty) {
      return {
        'ok': false,
        'status': 'error',
        'error': 'Missing student account id.',
        'event_count': 0,
      };
    }

    final actorKey = _selfActorKey(actor);
    var pack = await _eventService.getSelfAttendancePack();
    var usedTicketsFallback = false;

    if (pack['ok'] != true) {
      debugPrint(
        '[self-offline] pack API failed: ${pack['error']}; falling back to my_tickets',
      );
      final fallback = await _buildSelfPackFromMyTickets(actor);
      if (fallback['ok'] == true) {
        pack = fallback;
        usedTicketsFallback = true;
      } else {
        final existing = await getCachedSelfAttendancePack(studentId: actor);
        if (existing != null && existing['offline_cache_stale'] != true) {
          return {
            'ok': true,
            'status': 'ready',
            'event_count':
                int.tryParse(existing['event_count']?.toString() ?? '') ?? 0,
            'used_cached_pack': true,
            'warning': pack['error']?.toString() ??
                'Kept previously saved self-attendance pack.',
          };
        }
        return {
          'ok': false,
          'status': 'error',
          'error': pack['error']?.toString() ??
              fallback['error']?.toString() ??
              'Failed to refresh self-attendance pack.',
          'event_count': 0,
        };
      }
    }

    final persist = await _persistSelfAttendancePack(
      actorId: actor,
      actorKey: actorKey,
      pack: pack,
    );
    if (usedTicketsFallback) {
      persist['used_tickets_fallback'] = true;
    }
    return persist;
  }

  Future<Map<String, dynamic>> _buildSelfPackFromMyTickets(
    String studentId,
  ) async {
    try {
      var rows = await _eventService.getMyTicketsCached(studentId);
      if (rows.isEmpty) {
        rows = await _eventService.getMyTickets(
          studentId,
          forceFresh: false,
        );
      }
      final events = <Map<String, dynamic>>[];
      for (final row in rows) {
        final event = row['events'] is Map
            ? Map<String, dynamic>.from(row['events'] as Map)
            : <String, dynamic>{};
        final eventId = (event['id']?.toString() ??
                row['event_id']?.toString() ??
                '')
            .trim();
        if (eventId.isEmpty) continue;
        final eventStatus =
            (event['status']?.toString() ?? '').trim().toLowerCase();
        if (!const {
          'published',
          'approved',
          'finished',
          'expired',
        }.contains(eventStatus)) {
          continue;
        }

        Map<String, dynamic>? ticket;
        final ticketsRaw = row['tickets'];
        if (ticketsRaw is List && ticketsRaw.isNotEmpty) {
          final first = ticketsRaw.first;
          if (first is Map) ticket = Map<String, dynamic>.from(first);
        } else if (ticketsRaw is Map) {
          ticket = Map<String, dynamic>.from(ticketsRaw);
        }
        if (ticket == null || (ticket['id']?.toString() ?? '').trim().isEmpty) {
          continue;
        }

        Map<String, dynamic>? attendance;
        final attendanceRaw = ticket['attendance'];
        if (attendanceRaw is List && attendanceRaw.isNotEmpty) {
          final first = attendanceRaw.first;
          if (first is Map) attendance = Map<String, dynamic>.from(first);
        } else if (attendanceRaw is Map) {
          attendance = Map<String, dynamic>.from(attendanceRaw);
        }

        final sessionsRaw = event['sessions'];
        final sessions = <Map<String, dynamic>>[];
        if (sessionsRaw is List) {
          for (final session in sessionsRaw) {
            if (session is! Map) continue;
            final sessionMap = Map<String, dynamic>.from(session);
            final sid = (sessionMap['id']?.toString() ?? '').trim();
            if (sid.isEmpty) continue;
            sessions.add({
              'id': sid,
              'title': (sessionMap['title']?.toString() ?? '').trim(),
              'topic': (sessionMap['topic']?.toString() ?? '').trim(),
              'location': (sessionMap['location']?.toString() ?? '').trim(),
              'start_at': (sessionMap['start_at']?.toString() ?? '').trim(),
              'end_at': (sessionMap['end_at']?.toString() ?? '').trim(),
              'scan_window_minutes':
                  int.tryParse(
                    sessionMap['scan_window_minutes']?.toString() ?? '',
                  ) ??
                  30,
              'early_out_enabled_at': null,
              'attendance': null,
            });
          }
        }

        final usesSessions = event['uses_sessions'] == true ||
            sessions.isNotEmpty ||
            (event['event_mode']?.toString() ?? '')
                .toLowerCase()
                .contains('seminar');

        events.add({
          'event_id': eventId,
          'title': (event['title']?.toString() ?? 'Event').trim(),
          'status': eventStatus,
          'start_at': (event['start_at']?.toString() ?? '').trim(),
          'end_at': (event['end_at']?.toString() ?? '').trim(),
          'location': (event['location']?.toString() ?? '').trim(),
          'event_mode': (event['event_mode']?.toString() ?? '').trim(),
          'event_structure':
              (event['event_structure']?.toString() ?? '').trim(),
          'grace_time':
              int.tryParse(event['grace_time']?.toString() ?? '') ?? 30,
          'early_out_enabled_at': null,
          'uses_sessions': usesSessions,
          'qr_payload': EventService.buildEventQrPayload(eventId),
          'registration_id': (row['id']?.toString() ?? '').trim(),
          'ticket_id': (ticket['id']?.toString() ?? '').trim(),
          'attendance': attendance == null
              ? null
              : {
                  'id': (attendance['id']?.toString() ?? '').trim(),
                  'status': (attendance['status']?.toString() ?? '').trim(),
                  'check_in_at':
                      (attendance['check_in_at']?.toString() ?? '').trim(),
                  'check_out_at':
                      (attendance['check_out_at']?.toString() ?? '').trim(),
                  'last_scanned_at':
                      (attendance['last_scanned_at']?.toString() ?? '').trim(),
                },
          'sessions': sessions,
          'participant_name': '',
          'participant_photo_url': '',
          'participant_student_id': studentId,
          'participant_student_no': '',
        });
      }

      debugPrint(
        '[self-offline] my_tickets fallback built ${events.length} events',
      );
      return {
        'ok': true,
        'events': events,
        'event_count': events.length,
        'synced_at': DateTime.now().toUtc().toIso8601String(),
      };
    } catch (e) {
      debugPrint('[self-offline] my_tickets fallback failed: $e');
      return {
        'ok': false,
        'error': 'Failed to build self-attendance pack from tickets.',
        'events': <Map<String, dynamic>>[],
      };
    }
  }

  /// Build/merge Event-QR self pack from locally cached tickets (no network).
  /// Used when switching Assist → Take Attendance while already offline.
  Future<Map<String, dynamic>> ensureSelfAttendancePackFromLocalTickets({
    required String studentId,
  }) async {
    await _ensureAutoRestore();
    final actor = studentId.trim();
    if (actor.isEmpty) {
      return {
        'ok': false,
        'event_count': 0,
        'error': 'Missing student account id.',
      };
    }

    final actorKey = _selfActorKey(actor);
    final fromTickets = await _buildSelfPackFromMyTickets(actor);
    final fromAssist = await _buildSelfPackFromAssistRoster(actor);
    final events = _unionSelfPackEvents(fromTickets, fromAssist);
    final built = {
      'ok': events.isNotEmpty,
      'events': events,
      'event_count': events.length,
      'synced_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (events.isEmpty) {
      final existing = await getCachedSelfAttendancePack(studentId: actor);
      final count =
          int.tryParse(existing?['event_count']?.toString() ?? '') ?? 0;
      return {
        'ok': existing != null && count > 0,
        'event_count': count,
        'kept_existing': true,
      };
    }

    return _mergeSelfAttendancePack(
      actorId: actor,
      actorKey: actorKey,
      pack: built,
    );
  }

  List<Map<String, dynamic>> _unionSelfPackEvents(
    Map<String, dynamic> ticketsPack,
    Map<String, dynamic> assistPack,
  ) {
    final byId = <String, Map<String, dynamic>>{};
    void add(Map<String, dynamic> pack) {
      final raw = pack['events'];
      if (raw is! List) return;
      for (final item in raw) {
        if (item is! Map) continue;
        final event = Map<String, dynamic>.from(item);
        final eventId =
            (event['event_id']?.toString() ?? '').trim().toLowerCase();
        if (eventId.isEmpty || byId.containsKey(eventId)) continue;
        byId[eventId] = event;
      }
    }

    add(ticketsPack);
    add(assistPack);
    return byId.values.toList();
  }

  List<Map<String, dynamic>> _sessionsFromEventMap(Map<String, dynamic> eventMap) {
    final sessions = <Map<String, dynamic>>[];
    final sessionsRaw = eventMap['sessions'];
    if (sessionsRaw is! List) return sessions;
    for (final session in sessionsRaw) {
      if (session is! Map) continue;
      final sessionMap = Map<String, dynamic>.from(session);
      final sid = (sessionMap['id']?.toString() ?? '').trim();
      if (sid.isEmpty) continue;
      sessions.add({
        'id': sid,
        'title': (sessionMap['title']?.toString() ?? '').trim(),
        'topic': (sessionMap['topic']?.toString() ?? '').trim(),
        'location': (sessionMap['location']?.toString() ?? '').trim(),
        'start_at': (sessionMap['start_at']?.toString() ?? '').trim(),
        'end_at': (sessionMap['end_at']?.toString() ?? '').trim(),
        'scan_window_minutes':
            int.tryParse(sessionMap['scan_window_minutes']?.toString() ?? '') ??
                30,
        'early_out_enabled_at': sessionMap['early_out_enabled_at'],
        'attendance': sessionMap['attendance'],
      });
    }
    return sessions;
  }

  /// When Assist → Take Attendance happens offline, reuse this student's
  /// row from the assistant roster (same event) as an Event-QR self pack.
  Future<Map<String, dynamic>> _buildSelfPackFromAssistRoster(
    String studentId,
  ) async {
    final assistContext = await getCachedScannerContext(
      actorId: studentId,
      isTeacher: false,
    );
    if (assistContext == null) {
      return {'ok': false, 'events': <Map<String, dynamic>>[]};
    }
    final contextMap = assistContext['context'] is Map
        ? Map<String, dynamic>.from(assistContext['context'] as Map)
        : <String, dynamic>{};
    final eventMap = contextMap['event'] is Map
        ? Map<String, dynamic>.from(contextMap['event'] as Map)
        : <String, dynamic>{};
    final eventId = (eventMap['id']?.toString() ?? '').trim();
    if (eventId.isEmpty) {
      return {'ok': false, 'events': <Map<String, dynamic>>[]};
    }

    final assistKey = _actorKey(actorId: studentId, isTeacher: false);
    var rosterRows = await _store.listTicketCacheForEvent(
      actorKey: assistKey,
      eventId: eventId,
    );
    if (rosterRows.isEmpty) {
      final recent = await _store.listRecentTicketCache(
        actorKey: assistKey,
        limit: 5000,
      );
      final wanted = eventId.toLowerCase();
      rosterRows = recent
          .where(
            (row) =>
                (row['event_id']?.toString() ?? '').trim().toLowerCase() ==
                wanted,
          )
          .toList();
    }

    final identities = await _selfIdentityKeys(studentId);
    Map<String, dynamic>? mine;
    for (final row in rosterRows) {
      Map<String, dynamic> payload = {};
      try {
        final decoded = jsonDecode(row['payload_json']?.toString() ?? '{}');
        if (decoded is Map) {
          payload = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        continue;
      }
      if (_payloadMatchesSelfIdentity(payload, identities)) {
        mine = payload;
        break;
      }
    }
    if (mine == null) {
      debugPrint(
        '[self-offline] assist roster has ${rosterRows.length} tickets but none match this student',
      );
      return {'ok': false, 'events': <Map<String, dynamic>>[]};
    }

    final sessions = _sessionsFromEventMap(eventMap);
    final usesSessions = usesEventSessions(eventMap) || sessions.isNotEmpty;
    debugPrint(
      '[self-offline] hydrated Event QR pack from assist roster event=$eventId',
    );
    return {
      'ok': true,
      'events': [
        {
          'event_id': eventId,
          'title': (eventMap['title']?.toString() ??
                  mine['event_title']?.toString() ??
                  'Event')
              .trim(),
          'status': (eventMap['status']?.toString() ?? 'published').trim(),
          'start_at': (eventMap['start_at']?.toString() ??
                  mine['event_start_at']?.toString() ??
                  '')
              .trim(),
          'end_at': (eventMap['end_at']?.toString() ??
                  mine['event_end_at']?.toString() ??
                  '')
              .trim(),
          'location': (eventMap['location']?.toString() ??
                  mine['event_location']?.toString() ??
                  '')
              .trim(),
          'grace_time':
              int.tryParse(eventMap['grace_time']?.toString() ?? '') ??
                  int.tryParse(mine['event_grace_time']?.toString() ?? '') ??
                  30,
          'early_out_enabled_at':
              (eventMap['early_out_enabled_at']?.toString() ?? '').trim(),
          'uses_sessions': usesSessions,
          'qr_payload': EventService.buildEventQrPayload(eventId),
          'registration_id': (mine['registration_id']?.toString() ?? '').trim(),
          'ticket_id': (mine['ticket_id']?.toString() ?? '').trim(),
          'attendance': null,
          'sessions': sessions,
          'participant_name': mine['participant_name'],
          'participant_photo_url': mine['participant_photo_url'],
          'participant_student_id': studentId,
          'participant_student_no': mine['participant_student_no'] ??
              mine['participant_student_id'],
          'participant_user_id': mine['participant_user_id'],
        },
      ],
      'event_count': 1,
    };
  }

  /// Insert missing Event-QR rows without wiping queued offline self-scans.
  Future<Map<String, dynamic>> _mergeSelfAttendancePack({
    required String actorId,
    required String actorKey,
    required Map<String, dynamic> pack,
  }) async {
    final eventsRaw = pack['events'];
    final events = eventsRaw is List
        ? eventsRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];

    final now = DateTime.now().toUtc();
    final nowIso = now.toIso8601String();
    var inserted = 0;
    var kept = 0;

    for (final event in events) {
      final eventId = (event['event_id']?.toString() ?? '').trim();
      final rawQr = (event['qr_payload']?.toString() ?? '').trim();
      final qrPayload = _normalizeEventQrPayload(
        rawQr.isNotEmpty ? rawQr : EventService.buildEventQrPayload(eventId),
      );
      if (eventId.isEmpty || qrPayload.isEmpty) continue;

      final existing = await _lookupSelfTicketCacheRow(
        actorKey: actorKey,
        eventQrPayload: qrPayload,
      );
      if (existing != null) {
        kept++;
        continue;
      }

      final ticketHash = _ticketHash(qrPayload);

      final attendance = event['attendance'] is Map
          ? Map<String, dynamic>.from(event['attendance'] as Map)
          : <String, dynamic>{};
      final attendanceStatus =
          (attendance['status']?.toString() ?? '').trim().toLowerCase();
      final payload = {
        'op_kind': 'self_checkin',
        'event_id': eventId,
        'qr_payload': qrPayload,
        'ticket_payload': qrPayload,
        'ticket_id': (event['ticket_id']?.toString() ?? '').trim(),
        'registration_id': (event['registration_id']?.toString() ?? '').trim(),
        'title': (event['title']?.toString() ?? '').trim(),
        'status': (event['status']?.toString() ?? '').trim(),
        'start_at': (event['start_at']?.toString() ?? '').trim(),
        'end_at': (event['end_at']?.toString() ?? '').trim(),
        'location': (event['location']?.toString() ?? '').trim(),
        'grace_time':
            int.tryParse(event['grace_time']?.toString() ?? '') ?? 30,
        'early_out_enabled_at':
            (event['early_out_enabled_at']?.toString() ?? '').trim(),
        'uses_sessions': event['uses_sessions'] == true,
        'sessions': event['sessions'] is List ? event['sessions'] : <dynamic>[],
        'attendance': attendance,
        'attendance_status': attendanceStatus,
        'participant_name': event['participant_name'],
        'participant_photo_url': event['participant_photo_url'],
        'participant_student_id': event['participant_student_id'],
        'participant_student_no': event['participant_student_no'],
        'updated_at': nowIso,
      };

      await _store.replaceTicketCacheForEvent(
        actorKey: actorKey,
        eventId: eventId,
        rows: [
          {
            'actor_key': actorKey,
            'event_id': eventId,
            'session_id': '',
            'ticket_hash': ticketHash,
            'payload_json': jsonEncode(payload),
            'avatar_local_path': null,
            'avatar_remote_url':
                (event['participant_photo_url']?.toString() ?? '').trim(),
            'attendance_status':
                attendanceStatus.isEmpty ? 'unscanned' : attendanceStatus,
            'pending_sync': 0,
            'updated_at': nowIso,
          },
        ],
      );
      inserted++;
    }

    final total = inserted + kept;
    final existingCtx = await getCachedSelfAttendancePack(studentId: actorId);
    final contextPayload = {
      'status': 'ready',
      'scanner_enabled': true,
      'self_pack': true,
      'event_count': total,
      'message': total <= 0
          ? 'No registered events cached yet for Event QR check-in.'
          : 'Self-attendance pack ready for offline Event QR scans.',
    };

    if (total > 0 || existingCtx == null) {
      await _store.upsertContextCache(
        actorKey: actorKey,
        role: 'self',
        actorId: actorId,
        status: 'ready',
        scannerEnabled: true,
        syncedAtIso: nowIso,
        expiresAtIso: now.add(_maxCacheAge).toIso8601String(),
        payloadJson: jsonEncode(contextPayload),
      );
    }

    debugPrint(
      '[self-offline] local hydrate inserted=$inserted kept=$kept actor=$actorKey',
    );

    return {
      'ok': total > 0,
      'event_count': total,
      'inserted': inserted,
      'kept': kept,
      'from_local_tickets': true,
    };
  }

  Future<Map<String, dynamic>> _persistSelfAttendancePack({
    required String actorId,
    required String actorKey,
    required Map<String, dynamic> pack,
  }) async {
    final eventsRaw = pack['events'];
    final events = eventsRaw is List
        ? eventsRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];

    final now = DateTime.now().toUtc();
    final nowIso = now.toIso8601String();
    final rows = <Map<String, dynamic>>[];

    for (final event in events) {
      final eventId = (event['event_id']?.toString() ?? '').trim();
      final rawQr = (event['qr_payload']?.toString() ?? '').trim();
      final qrPayload = _normalizeEventQrPayload(
        rawQr.isNotEmpty ? rawQr : EventService.buildEventQrPayload(eventId),
      );
      if (eventId.isEmpty || qrPayload.isEmpty) continue;

      final ticketHash = _ticketHash(qrPayload);
      final attendance = event['attendance'] is Map
          ? Map<String, dynamic>.from(event['attendance'] as Map)
          : <String, dynamic>{};
      final attendanceStatus =
          (attendance['status']?.toString() ?? '').trim().toLowerCase();

      final payload = {
        'op_kind': 'self_checkin',
        'event_id': eventId,
        'qr_payload': qrPayload,
        'ticket_payload': qrPayload,
        'ticket_id': (event['ticket_id']?.toString() ?? '').trim(),
        'registration_id': (event['registration_id']?.toString() ?? '').trim(),
        'title': (event['title']?.toString() ?? '').trim(),
        'status': (event['status']?.toString() ?? '').trim(),
        'start_at': (event['start_at']?.toString() ?? '').trim(),
        'end_at': (event['end_at']?.toString() ?? '').trim(),
        'location': (event['location']?.toString() ?? '').trim(),
        'grace_time':
            int.tryParse(event['grace_time']?.toString() ?? '') ?? 30,
        'early_out_enabled_at':
            (event['early_out_enabled_at']?.toString() ?? '').trim(),
        'uses_sessions': event['uses_sessions'] == true,
        'sessions': event['sessions'] is List ? event['sessions'] : <dynamic>[],
        'attendance': attendance,
        'attendance_status': attendanceStatus,
        'participant_name': event['participant_name'],
        'participant_photo_url': event['participant_photo_url'],
        'participant_student_id': event['participant_student_id'],
        'participant_student_no': event['participant_student_no'],
        'updated_at': nowIso,
      };

      rows.add({
        'actor_key': actorKey,
        'event_id': eventId,
        'session_id': '',
        'ticket_hash': ticketHash,
        'payload_json': jsonEncode(payload),
        'avatar_local_path': null,
        'avatar_remote_url':
            (event['participant_photo_url']?.toString() ?? '').trim(),
        'attendance_status':
            attendanceStatus.isEmpty ? 'unscanned' : attendanceStatus,
        'pending_sync': 0,
        'updated_at': nowIso,
      });
    }

    await _store.clearTicketCacheForActor(actorKey);
    if (rows.isNotEmpty) {
      final byEvent = <String, List<Map<String, dynamic>>>{};
      for (final row in rows) {
        final eid = (row['event_id']?.toString() ?? '').trim();
        byEvent.putIfAbsent(eid, () => <Map<String, dynamic>>[]).add(row);
      }
      for (final entry in byEvent.entries) {
        await _store.replaceTicketCacheForEvent(
          actorKey: actorKey,
          eventId: entry.key,
          rows: entry.value,
        );
      }
    }

    final contextPayload = {
      'status': 'ready',
      'scanner_enabled': true,
      'self_pack': true,
      'event_count': rows.length,
      'message': rows.isEmpty
          ? 'No registered events cached yet for Event QR check-in.'
          : 'Self-attendance pack ready for offline Event QR scans.',
    };

    await _store.upsertContextCache(
      actorKey: actorKey,
      role: 'self',
      actorId: actorId,
      status: 'ready',
      scannerEnabled: true,
      syncedAtIso: nowIso,
      expiresAtIso: now.add(_maxCacheAge).toIso8601String(),
      payloadJson: jsonEncode(contextPayload),
    );
    await _backupService.autoBackupIfConfigured(force: true);

    debugPrint(
      '[self-offline] pack cached event_count=${rows.length} actor=$actorKey',
    );

    return {
      'ok': true,
      'status': 'ready',
      'event_count': rows.length,
      'roster_ready': true,
    };
  }

  Future<Map<String, dynamic>> getSelfOfflineMonitorStatus({
    required String studentId,
    bool refreshSnapshot = false,
    bool isOffline = false,
  }) async {
    await _ensureAutoRestore();
    final actor = studentId.trim();
    if (actor.isEmpty) {
      return {
        'ok': false,
        'has_snapshot': false,
        'snapshot_stale': false,
        'offline_ready': false,
        'pending_queue_count': 0,
        'message': 'No student account is active on this device.',
      };
    }

    Map<String, dynamic>? refreshResult;
    if (refreshSnapshot && !isOffline) {
      refreshResult = await refreshSelfAttendanceSnapshot(studentId: actor);
    }

    final cached = await getCachedSelfAttendancePack(studentId: actor);
    final actorKey = _selfActorKey(actor);
    final pending = await _store.pendingCount(actorKey);
    final hasSnapshot = cached != null;
    final snapshotStale = cached?['offline_cache_stale'] == true;
    final eventCount =
        int.tryParse(cached?['event_count']?.toString() ?? '') ?? 0;
    final offlineReady = hasSnapshot && !snapshotStale && eventCount > 0;
    final refreshAttempted = refreshSnapshot && !isOffline;
    final warmFailed = refreshAttempted &&
        refreshResult != null &&
        refreshResult['ok'] != true &&
        !offlineReady;

    String message;
    if (warmFailed) {
      message = (refreshResult!['error']?.toString() ?? '').trim().isNotEmpty
          ? refreshResult['error'].toString()
          : 'Could not save offline pack. Tap Refresh or reopen Take Attendance.';
    } else if (!hasSnapshot) {
      message = refreshResult?['ok'] == true
          ? 'Pack refresh completed but no cache was saved. Reopen Take Attendance online once more.'
          : 'No offline pack yet. Open Take Attendance while online to prepare.';
    } else if (snapshotStale) {
      message =
          'Self-attendance pack is stale. Reconnect to refresh registered events.';
    } else if (eventCount <= 0) {
      message =
          'No registered events cached yet. Open Take Attendance while online after you join an event.';
    } else {
      message =
          'Offline pack ready ($eventCount event${eventCount == 1 ? '' : 's'}).';
    }

    return {
      'ok': true,
      'has_snapshot': hasSnapshot,
      'snapshot_stale': snapshotStale || warmFailed,
      'offline_ready': offlineReady,
      'warm_failed': warmFailed,
      'event_count': eventCount,
      'pending_queue_count': pending,
      'last_synced_at': cached?['offline_cache_synced_at'],
      'message': message,
      'refresh_ok': refreshResult?['ok'] == true,
    };
  }

  Future<Map<String, dynamic>> validateOfflineSelfCheckIn({
    required String studentId,
    required String eventQrPayload,
  }) async {
    await _ensureAutoRestore();
    final actor = studentId.trim();
    final rawPayload = eventQrPayload.trim();
    if (actor.isEmpty) {
      return {
        'ok': false,
        'status': 'error',
        'error': 'Unable to identify your student account.',
      };
    }
    if (!rawPayload.toUpperCase().startsWith('PULSE-EVENT-')) {
      return {
        'ok': false,
        'status': 'invalid',
        'error': 'Scan the event QR code displayed at the venue.',
      };
    }

    final actorKey = _selfActorKey(actor);
    final normalized = _normalizeEventQrPayload(rawPayload);
    var row = await _lookupSelfTicketCacheRow(
      actorKey: actorKey,
      eventQrPayload: normalized,
    );
    if (row == null) {
      await ensureSelfAttendancePackFromLocalTickets(studentId: actor);
      row = await _lookupSelfTicketCacheRow(
        actorKey: actorKey,
        eventQrPayload: normalized,
      );
    }
    if (row == null) {
      final refreshedPack = await getCachedSelfAttendancePack(studentId: actor);
      if (refreshedPack == null) {
        return {
          'ok': false,
          'status': 'no_cache',
          'error':
              'Offline self-attendance is not ready yet. Open Take Attendance while online first.',
        };
      }
      return {
        'ok': false,
        'status': 'forbidden',
        'error':
            'You are not registered for this event in the offline pack. Reconnect while registered, then try again.',
      };
    }

    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(row['payload_json']?.toString() ?? '{}');
      if (decoded is! Map) {
        return {
          'ok': false,
          'status': 'invalid',
          'error': 'Offline event cache is corrupted.',
        };
      }
      payload = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return {
        'ok': false,
        'status': 'invalid',
        'error': 'Offline event cache is corrupted.',
      };
    }

    final ticketHash = ((row['ticket_hash']?.toString() ?? '').trim().isNotEmpty)
        ? (row['ticket_hash']?.toString() ?? '').trim()
        : _ticketHash(normalized);

    final pendingSync =
        payload['pending_sync'] == true || row['pending_sync'] == 1;
    if (pendingSync) {
      return {
        'ok': false,
        'status': 'already_checked_in',
        'error': 'This Event QR scan is already queued for sync.',
        'participant_name': payload['participant_name'],
        'participant_photo_url': payload['participant_photo_url'],
        'participant_student_id': payload['participant_student_id'],
        'participant_student_no':
            payload['participant_student_no'] ?? payload['participant_student_id'],
      };
    }

    final now = _nowManila();
    final usesSessions = payload['uses_sessions'] == true;
    final sessionsRaw = payload['sessions'];
    final sessions = sessionsRaw is List
        ? sessionsRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];

    String sessionId = '';
    String action = 'check_in';

    if (usesSessions && sessions.isNotEmpty) {
      // Prefer open check-out for a session that already has time-in.
      final outCandidates = <Map<String, dynamic>>[];
      for (final session in sessions) {
        final sid = (session['id']?.toString() ?? '').trim();
        if (sid.isEmpty) continue;
        final att = session['attendance'] is Map
            ? Map<String, dynamic>.from(session['attendance'] as Map)
            : null;
        if (!_hasValidTimeIn(att)) continue;
        if ((att?['check_out_at']?.toString() ?? '').trim().isNotEmpty) {
          continue;
        }
        final outWin = _checkOutWindowForEnd(
          endAt: _parseScheduleManila(session['end_at']?.toString()),
          earlyOutEnabledAtRaw: session['early_out_enabled_at']?.toString(),
          nowUtc: now,
          startAt: _parseScheduleManila(session['start_at']?.toString()),
          graceMinutes:
              int.tryParse(session['scan_window_minutes']?.toString() ?? '') ??
                  30,
        );
        if (outWin['open'] == true) {
          outCandidates.add({'session': session, 'window': outWin});
        }
      }
      if (outCandidates.length > 1) {
        return {
          'ok': false,
          'status': 'conflict',
          'error': 'Multiple seminars are open for time-out. Contact admin.',
        };
      }
      if (outCandidates.length == 1) {
        sessionId =
            (outCandidates.first['session']?['id']?.toString() ?? '').trim();
        action = 'check_out';
      } else {
        final openIn = <Map<String, dynamic>>[];
        final waitingIn = <Map<String, dynamic>>[];
        Map<String, dynamic>? alreadyInBlocked;
        for (final session in sessions) {
          final att = session['attendance'] is Map
              ? Map<String, dynamic>.from(session['attendance'] as Map)
              : null;
          if (_hasValidTimeIn(att)) {
            if ((att?['check_out_at']?.toString() ?? '').trim().isNotEmpty) {
              continue;
            }
            final outWin = _checkOutWindowForEnd(
              endAt: _parseScheduleManila(session['end_at']?.toString()),
              earlyOutEnabledAtRaw: session['early_out_enabled_at']?.toString(),
              nowUtc: now,
              startAt: _parseScheduleManila(session['start_at']?.toString()),
              graceMinutes:
                  int.tryParse(session['scan_window_minutes']?.toString() ?? '') ??
                      30,
            );
            if (outWin['open'] == true) {
              // Should have been caught above; keep scanning.
              continue;
            }
            alreadyInBlocked ??= {
              'session': session,
              'window': outWin,
            };
            continue;
          }
          final start = _parseScheduleManila(session['start_at']?.toString());
          final grace =
              int.tryParse(session['scan_window_minutes']?.toString() ?? '') ??
                  30;
          final win = _checkInWindowForStart(
            startAt: start,
            graceMinutes: grace,
            nowUtc: now,
          );
          if (win['status'] == 'open') {
            openIn.add({'session': session, 'window': win});
          } else if (win['status'] == 'waiting') {
            waitingIn.add({'session': session, 'window': win});
          }
        }
        if (alreadyInBlocked != null) {
          final blocked = alreadyInBlocked['session'] as Map<String, dynamic>;
          final outWin = alreadyInBlocked['window'] as Map<String, dynamic>;
          final blockedName = (blocked['title']?.toString() ??
                  blocked['topic']?.toString() ??
                  'Seminar')
              .trim();
          return {
            'ok': false,
            'status': (outWin['status']?.toString() ?? 'too_early_checkout'),
            'error':
                'Already timed in for $blockedName. ${(outWin['message']?.toString() ?? 'Too early to time out.')}',
            'already_timed_in': true,
            'event_title': payload['title'],
            'session_name': blockedName,
            'session_end_at': blocked['end_at'],
            'participant_name': payload['participant_name'],
            'participant_photo_url': payload['participant_photo_url'],
            'participant_student_id': payload['participant_student_id'],
            'participant_student_no': payload['participant_student_no'] ??
                payload['participant_student_id'],
          };
        }
        if (openIn.length > 1) {
          return {
            'ok': false,
            'status': 'conflict',
            'error':
                'Multiple seminars are open for time-in. Fix overlapping schedule.',
          };
        }
        if (openIn.length == 1) {
          sessionId = (openIn.first['session']?['id']?.toString() ?? '').trim();
          action = 'check_in';
        } else if (waitingIn.isNotEmpty) {
          return {
            'ok': false,
            'status': 'waiting',
            'error': waitingIn.first['window']?['message']?.toString() ??
                'Too early to time in.',
          };
        } else {
          // Check absent during open check-out.
          for (final session in sessions) {
            final outWin = _checkOutWindowForEnd(
              endAt: _parseScheduleManila(session['end_at']?.toString()),
              earlyOutEnabledAtRaw: session['early_out_enabled_at']?.toString(),
              nowUtc: now,
              startAt: _parseScheduleManila(session['start_at']?.toString()),
              graceMinutes:
                  int.tryParse(session['scan_window_minutes']?.toString() ?? '') ??
                      30,
            );
            if (outWin['open'] == true) {
              return {
                'ok': false,
                'status': 'absent_no_time_in',
                'error':
                    'Cannot time out — you have no time-in (marked absent).',
              };
            }
          }
          return {
            'ok': false,
            'status': 'closed',
            'error': 'Attendance is not open for this event right now.',
          };
        }
      }
    } else {
      final attendance = payload['attendance'] is Map
          ? Map<String, dynamic>.from(payload['attendance'] as Map)
          : <String, dynamic>{};
      final hasIn = _hasValidTimeIn(attendance);
      final hasOut =
          (attendance['check_out_at']?.toString() ?? '').trim().isNotEmpty;

      if (hasIn && hasOut) {
        return {
          'ok': false,
          'status': 'already_checked_out',
          'error': 'You already timed out for this event.',
          'participant_name': payload['participant_name'],
          'participant_photo_url': payload['participant_photo_url'],
          'participant_student_id': payload['participant_student_id'],
          'participant_student_no':
              payload['participant_student_no'] ?? payload['participant_student_id'],
        };
      }

      if (hasIn) {
        final outWin = _checkOutWindowForEnd(
          endAt: _parseScheduleManila(payload['end_at']?.toString()),
          earlyOutEnabledAtRaw: payload['early_out_enabled_at']?.toString(),
          nowUtc: now,
          startAt: _parseScheduleManila(payload['start_at']?.toString()),
          graceMinutes:
              int.tryParse(payload['grace_time']?.toString() ?? '') ?? 30,
        );
        if (outWin['open'] != true) {
          return {
            'ok': false,
            'status': (outWin['status']?.toString() ?? 'too_early_checkout'),
            'error': outWin['message']?.toString() ?? 'Time-out is not open yet.',
            'already_timed_in': true,
            'participant_name': payload['participant_name'],
            'participant_photo_url': payload['participant_photo_url'],
            'participant_student_id': payload['participant_student_id'],
            'participant_student_no': payload['participant_student_no'] ??
                payload['participant_student_id'],
          };
        }
        action = 'check_out';
      } else {
        final outWin = _checkOutWindowForEnd(
          endAt: _parseScheduleManila(payload['end_at']?.toString()),
          earlyOutEnabledAtRaw: payload['early_out_enabled_at']?.toString(),
          nowUtc: now,
          startAt: _parseScheduleManila(payload['start_at']?.toString()),
          graceMinutes:
              int.tryParse(payload['grace_time']?.toString() ?? '') ?? 30,
        );
        if (outWin['open'] == true) {
          return {
            'ok': false,
            'status': 'absent_no_time_in',
            'error':
                'Cannot time out — you have no time-in (marked absent).',
          };
        }
        final grace =
            int.tryParse(payload['grace_time']?.toString() ?? '') ?? 30;
        final inWin = _checkInWindowForStart(
          startAt: _parseScheduleManila(payload['start_at']?.toString()),
          graceMinutes: grace,
          nowUtc: now,
        );
        if (inWin['open'] != true) {
          return {
            'ok': false,
            'status': (inWin['status']?.toString() ?? 'closed'),
            'error': inWin['message']?.toString() ?? 'Time-in is not open.',
          };
        }
        action = 'check_in';
      }
    }

    return {
      'ok': true,
      'status': 'ready_for_confirmation',
      'message': action == 'check_out'
          ? 'Offline time-out ready to queue.'
          : 'Offline time-in ready to queue.',
      'ticket_hash': ticketHash,
      'event_id': (payload['event_id']?.toString() ?? '').trim(),
      'session_id': sessionId,
      'action': action,
      'participant_name': payload['participant_name'],
      'participant_photo_url': payload['participant_photo_url'],
      'participant_student_id': payload['participant_student_id'],
      'participant_student_no':
          payload['participant_student_no'] ?? payload['participant_student_id'],
      'event_title': payload['title'],
    };
  }

  Future<Map<String, dynamic>> enqueueOfflineSelfCheckIn({
    required String studentId,
    required String eventQrPayload,
  }) async {
    await _ensureAutoRestore();
    final validation = await validateOfflineSelfCheckIn(
      studentId: studentId,
      eventQrPayload: eventQrPayload,
    );
    if (validation['ok'] != true) return validation;

    final actor = studentId.trim();
    final actorKey = _selfActorKey(actor);
    final ticketHash = (validation['ticket_hash']?.toString() ?? '').trim();
    final sessionId = (validation['session_id']?.toString() ?? '').trim();
    final eventId = (validation['event_id']?.toString() ?? '').trim();
    if (ticketHash.isEmpty) {
      return {
        'ok': false,
        'status': 'invalid',
        'error': 'Unable to queue Event QR due to missing local hash.',
      };
    }

    final existing = await _store.findPendingOperationId(
      actorKey: actorKey,
      ticketHash: ticketHash,
      sessionId: sessionId,
    );
    if (existing != null && existing.trim().isNotEmpty) {
      return {
        'ok': true,
        'status': 'queued_offline',
        'message': 'Event QR scan is already queued for sync.',
        'participant_name': validation['participant_name'],
        'participant_photo_url': validation['participant_photo_url'],
        'participant_student_id': validation['participant_student_id'],
        'participant_student_no': validation['participant_student_no'],
        'event_title': validation['event_title'],
      };
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final opId =
        'op_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    final payload = {
      'op_kind': 'self_checkin',
      'ticket_payload': eventQrPayload.trim(),
      'event_qr_payload': eventQrPayload.trim(),
      'ticket_hash': ticketHash,
      'event_id': eventId,
      'session_id': sessionId,
      'action': validation['action']?.toString() ?? 'check_in',
      'scanned_at': nowIso,
      'queued_at': nowIso,
    };

    await _store.enqueueOperation({
      'id': opId,
      'actor_key': actorKey,
      'role': 'self',
      'actor_id': actor,
      'ticket_hash': ticketHash,
      'event_id': eventId,
      'session_id': sessionId,
      'payload_json': jsonEncode(payload),
      'status': 'pending',
      'attempt_count': 0,
      'next_retry_at': null,
      'created_at': nowIso,
      'updated_at': nowIso,
      'last_error': null,
    });

    await _updateCachedTicketAfterQueue(
      actorKey: actorKey,
      ticketHash: ticketHash,
      sessionId: sessionId,
      pending: true,
      status: 'pending',
    );
    await _backupService.autoBackupIfConfigured(force: true);

    return {
      'ok': true,
      'status': 'queued_offline',
      'message':
          'Offline Event QR saved. It will auto-sync when internet comes back.',
      'participant_name': validation['participant_name'],
      'participant_photo_url': validation['participant_photo_url'],
      'participant_student_id': validation['participant_student_id'],
      'participant_student_no': validation['participant_student_no'],
      'event_title': validation['event_title'],
      'action': validation['action'],
    };
  }

  Future<Map<String, dynamic>> enqueueOfflineCheckIn({
    required String actorId,
    required bool isTeacher,
    required String ticketPayload,
    Map<String, dynamic>? prevalidated,
    Map<String, dynamic>? activeContextOverride,
  }) async {
    await _ensureAutoRestore();
    final validation =
        prevalidated ??
        await validateOfflineDryRun(
          actorId: actorId,
          isTeacher: isTeacher,
          ticketPayload: ticketPayload,
          activeContextOverride: activeContextOverride,
        );
    if (validation['ok'] != true) return validation;

    final actor = actorId.trim();
    final actorKey = _actorKey(actorId: actor, isTeacher: isTeacher);
    final ticketHash = (validation['ticket_hash']?.toString() ?? '').trim();
    final sessionId = (validation['session_id']?.toString() ?? '').trim();
    if (ticketHash.isEmpty) {
      return {
        'ok': false,
        'status': 'invalid',
        'error': 'Unable to queue ticket due to missing local hash.',
      };
    }

    final existing = await _store.findPendingOperationId(
      actorKey: actorKey,
      ticketHash: ticketHash,
      sessionId: sessionId,
    );
    if (existing != null && existing.trim().isNotEmpty) {
      return {
        'ok': true,
        'status': 'queued_offline',
        'message': 'Ticket is already queued for sync.',
        'participant_name': validation['participant_name'],
        'participant_photo_url': validation['participant_photo_url'],
        'participant_photo_local_path':
            validation['participant_photo_local_path'],
        'participant_student_id': validation['participant_student_id'],
        'participant_student_no': validation['participant_student_no'] ??
            validation['participant_student_id'],
      };
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final action =
        (validation['action']?.toString() ?? 'check_in').trim().toLowerCase();
    final isCheckOut = action == 'check_out';
    final opId =
        'op_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    final payload = {
      'ticket_payload': ticketPayload.trim(),
      'ticket_hash': ticketHash,
      'event_id': validation['event_id']?.toString() ?? '',
      'session_id': sessionId,
      'action': isCheckOut ? 'check_out' : 'check_in',
      'scanned_at': nowIso,
      'queued_at': nowIso,
    };

    await _store.enqueueOperation({
      'id': opId,
      'actor_key': actorKey,
      'role': _actorRole(isTeacher: isTeacher),
      'actor_id': actor,
      'ticket_hash': ticketHash,
      'event_id': validation['event_id']?.toString() ?? '',
      'session_id': sessionId,
      'payload_json': jsonEncode(payload),
      'status': 'pending',
      'attempt_count': 0,
      'next_retry_at': null,
      'created_at': nowIso,
      'updated_at': nowIso,
      'last_error': null,
    });

    await _updateCachedTicketAfterQueue(
      actorKey: actorKey,
      ticketHash: ticketHash,
      sessionId: sessionId,
      pending: true,
      status: isCheckOut ? 'checked_out' : 'present',
    );
    await _backupService.autoBackupIfConfigured(force: true);

    return {
      'ok': true,
      'status': 'queued_offline',
      'message': isCheckOut
          ? 'Offline time-out saved. It will auto-sync when internet comes back.'
          : 'Offline check-in saved. It will auto-sync when internet comes back.',
      'action': isCheckOut ? 'check_out' : 'check_in',
      'participant_name': validation['participant_name'],
      'participant_photo_url': validation['participant_photo_url'],
      'participant_photo_local_path': validation['participant_photo_local_path'],
      'participant_student_id': validation['participant_student_id'],
      'participant_student_no': validation['participant_student_no'] ??
          validation['participant_student_id'],
    };
  }

  Future<Map<String, dynamic>> syncPendingQueue({
    required String actorId,
    required bool isTeacher,
  }) async {
    await _ensureAutoRestore();
    final actor = actorId.trim();
    if (actor.isEmpty) {
      return {'ok': false, 'error': 'Missing scanner account id.'};
    }

    final actorKeys = isTeacher
        ? <String>[_actorKey(actorId: actor, isTeacher: true)]
        : <String>[
            _actorKey(actorId: actor, isTeacher: false),
            _selfActorKey(actor),
          ];

    var synced = 0;
    var rejected = 0;
    var conflictResolved = 0;

    for (final actorKey in actorKeys) {
      final operations = await _store.listDuePendingOperations(actorKey);
      final isSelfActor = actorKey.startsWith('self:');

      for (final operation in operations) {
        final id = (operation['id']?.toString() ?? '').trim();
        if (id.isEmpty) continue;

        Map<String, dynamic> payload;
        try {
          final decoded =
              jsonDecode(operation['payload_json']?.toString() ?? '{}');
          if (decoded is! Map) {
            await _store.updateOperation(
              id: id,
              updates: {
                'status': 'rejected',
                'updated_at': DateTime.now().toUtc().toIso8601String(),
                'last_error': 'Invalid queued payload.',
              },
            );
            rejected++;
            continue;
          }
          payload = Map<String, dynamic>.from(decoded);
        } catch (_) {
          await _store.updateOperation(
            id: id,
            updates: {
              'status': 'rejected',
              'updated_at': DateTime.now().toUtc().toIso8601String(),
              'last_error': 'Invalid queued payload.',
            },
          );
          rejected++;
          continue;
        }

        final ticketPayload =
            (payload['ticket_payload']?.toString() ?? '').trim().isNotEmpty
                ? (payload['ticket_payload']?.toString() ?? '').trim()
                : (payload['event_qr_payload']?.toString() ?? '').trim();
        final ticketHash = (payload['ticket_hash']?.toString() ?? '').trim();
        final sessionId = (payload['session_id']?.toString() ?? '').trim();
        final eventId = (payload['event_id']?.toString() ?? '').trim();
        final scannedAtIso =
            (payload['scanned_at']?.toString() ?? '').trim().isNotEmpty
                ? (payload['scanned_at']?.toString() ?? '').trim()
                : (payload['queued_at']?.toString() ?? '').trim();
        final opKind = (payload['op_kind']?.toString() ?? '').trim().toLowerCase();
        final isSelfOp = isSelfActor ||
            opKind == 'self_checkin' ||
            ticketPayload.toUpperCase().startsWith('PULSE-EVENT-');

        final Map<String, dynamic> response;
        if (isSelfOp) {
          response = await _eventService.checkInSelfViaEventQr(
            ticketPayload,
            scannedAtIso: scannedAtIso,
          );
        } else if (isTeacher) {
          response = await _eventService.checkInParticipantAsTeacher(
            ticketPayload,
            actor,
            scannedAtIso: scannedAtIso,
            expectedEventId: eventId.isNotEmpty ? eventId : null,
          );
        } else {
          response = await _eventService.checkInParticipantAsAssistant(
            ticketPayload,
            actor,
            scannedAtIso: scannedAtIso,
            expectedEventId: eventId.isNotEmpty ? eventId : null,
          );
        }

        final status =
            (response['status']?.toString() ?? '').toLowerCase().trim();
        final nowIso = DateTime.now().toUtc().toIso8601String();

        if (response['ok'] == true ||
            status == 'present' ||
            status == 'checked_out' ||
            status == 'already_checked_out') {
          await _store.updateOperation(
            id: id,
            updates: {
              'status': 'synced',
              'updated_at': nowIso,
              'last_error': null,
            },
          );
          if (ticketHash.isNotEmpty) {
            await _updateCachedTicketAfterQueue(
              actorKey: actorKey,
              ticketHash: ticketHash,
              sessionId: sessionId,
              pending: false,
              status: status == 'checked_out' || status == 'already_checked_out'
                  ? 'checked_out'
                  : 'present',
            );
          }
          synced++;
          continue;
        }

        if (status == 'already_checked_in' ||
            status == 'used' ||
            status == 'already_present') {
          await _store.updateOperation(
            id: id,
            updates: {
              'status': 'conflict_resolved',
              'updated_at': nowIso,
              'last_error': null,
            },
          );
          if (ticketHash.isNotEmpty) {
            await _updateCachedTicketAfterQueue(
              actorKey: actorKey,
              ticketHash: ticketHash,
              sessionId: sessionId,
              pending: false,
              status: 'present',
            );
          }
          conflictResolved++;
          continue;
        }

        if (status == 'forbidden' ||
            status == 'invalid' ||
            status == 'wrong_event' ||
            status == 'no_assignment' ||
            status == 'closed' ||
            status == 'conflict' ||
            status == 'waiting' ||
            status == 'too_early_checkout' ||
            status == 'absent_no_time_in' ||
            status == 'already_out') {
          await _store.updateOperation(
            id: id,
            updates: {
              'status': 'rejected',
              'updated_at': nowIso,
              'last_error': response['error']?.toString(),
            },
          );
          if (ticketHash.isNotEmpty) {
            await _updateCachedTicketAfterQueue(
              actorKey: actorKey,
              ticketHash: ticketHash,
              sessionId: sessionId,
              pending: false,
              status: 'rejected',
            );
          }
          rejected++;
          continue;
        }

        if (_looksLikeTransientError(response)) {
          final attempts = (operation['attempt_count'] is num
                  ? (operation['attempt_count'] as num).toInt()
                  : int.tryParse(
                          operation['attempt_count']?.toString() ?? '') ??
                      0) +
              1;
          await _store.updateOperation(
            id: id,
            updates: {
              'attempt_count': attempts,
              'next_retry_at': _nextRetryAtIso(attempts),
              'updated_at': nowIso,
              'last_error': response['error']?.toString(),
            },
          );
          continue;
        }

        final attempts = (operation['attempt_count'] is num
                ? (operation['attempt_count'] as num).toInt()
                : int.tryParse(operation['attempt_count']?.toString() ?? '') ??
                    0) +
            1;
        await _store.updateOperation(
          id: id,
          updates: {
            'attempt_count': attempts,
            'next_retry_at': _nextRetryAtIso(attempts),
            'updated_at': nowIso,
            'last_error': response['error']?.toString(),
          },
        );
      }
    }

    await _backupService.autoBackupIfConfigured(force: true);
    return {
      'ok': true,
      'synced': synced,
      'rejected': rejected,
      'conflict_resolved': conflictResolved,
    };
  }

  Future<int> pendingQueueCount({
    required String actorId,
    required bool isTeacher,
  }) async {
    await _ensureAutoRestore();
    final actor = actorId.trim();
    if (actor.isEmpty) return 0;
    final actorKey = _actorKey(actorId: actor, isTeacher: isTeacher);
    var count = await _store.pendingCount(actorKey);
    if (!isTeacher) {
      count += await _store.pendingCount(_selfActorKey(actor));
    }
    return count;
  }

  String _monitorEventTitle(Map<String, dynamic>? contextPayload) {
    if (contextPayload == null) return '';
    final context = contextPayload['context'];
    if (context is! Map) return '';
    final event = context['event'];
    if (event is! Map) return '';
    return (event['title']?.toString() ?? '').trim();
  }

  String _monitorSessionTitle(Map<String, dynamic>? contextPayload) {
    if (contextPayload == null) return '';
    final context = contextPayload['context'];
    if (context is! Map) return '';
    final session = context['session'];
    if (session is! Map) return '';
    final display = (session['display_name']?.toString() ?? '').trim();
    if (display.isNotEmpty) return display;
    return (session['title']?.toString() ?? '').trim();
  }

  bool _flagIsTrue(dynamic value) {
    if (value is bool) return value;
    final normalized = (value?.toString() ?? '').trim().toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }

  Map<String, dynamic> _buildCachedPackageSummary({
    required Map<String, dynamic> contextMap,
    required List<Map<String, dynamic>> cachedTicketRows,
  }) {
    final eventMap = contextMap['event'] is Map
        ? Map<String, dynamic>.from(contextMap['event'] as Map)
        : <String, dynamic>{};
    final source = (contextMap['source']?.toString() ?? '').trim().toLowerCase();
    final eventMode =
        (eventMap['event_mode']?.toString() ?? '').trim().toLowerCase();
    final eventStructure =
        (eventMap['event_structure']?.toString() ?? '').trim().toLowerCase();
    final usesSessions = _flagIsTrue(eventMap['uses_sessions']) ||
        source == 'session' ||
        eventMode == 'seminar_based' ||
        eventStructure == 'one_seminar' ||
        eventStructure == 'two_seminars';

    final participantKeys = <String>{};
    final localAvatarKeys = <String>{};
    final remoteAvatarKeys = <String>{};
    final sessionEntries = <String, Map<String, dynamic>>{};
    var attendanceStateCount = 0;
    var scheduleReady = false;

    final opensAt = (contextMap['opens_at']?.toString() ?? '').trim();
    final closesAt = (contextMap['closes_at']?.toString() ?? '').trim();
    if (opensAt.isNotEmpty || closesAt.isNotEmpty) {
      scheduleReady = true;
    }

    for (final row in cachedTicketRows) {
      final payloadText = (row['payload_json']?.toString() ?? '').trim();
      if (payloadText.isEmpty) continue;

      dynamic decoded;
      try {
        decoded = jsonDecode(payloadText);
      } catch (_) {
        continue;
      }
      if (decoded is! Map) continue;

      final payload = Map<String, dynamic>.from(decoded);
      final registrationId = (payload['registration_id']?.toString() ?? '').trim();
      final studentId =
          (payload['participant_student_id']?.toString() ?? '').trim();
      final participantName =
          (payload['participant_name']?.toString() ?? '').trim().toLowerCase();
      final participantKey = registrationId.isNotEmpty
          ? 'registration:$registrationId'
          : (studentId.isNotEmpty
                ? 'student:$studentId'
                : (participantName.isNotEmpty
                      ? 'name:$participantName'
                      : 'ticket:${row['ticket_hash']?.toString() ?? ''}'));
      participantKeys.add(participantKey);

      final localAvatarPath =
          (payload['participant_photo_local_path']?.toString() ??
                  row['avatar_local_path']?.toString() ??
                  '')
              .trim();
      if (localAvatarPath.isNotEmpty && File(localAvatarPath).existsSync()) {
        localAvatarKeys.add(participantKey);
      }

      final remoteAvatarUrl =
          (payload['participant_photo_url']?.toString() ??
                  row['avatar_remote_url']?.toString() ??
                  '')
              .trim();
      if (remoteAvatarUrl.isNotEmpty) {
        remoteAvatarKeys.add(participantKey);
      }

      final attendanceStatus =
          (payload['attendance_status']?.toString() ?? '').trim().toLowerCase();
      final pendingSync =
          payload['pending_sync'] == true || row['pending_sync'] == 1;
      if (attendanceStatus.isNotEmpty || pendingSync) {
        attendanceStateCount++;
      }

      final sessionId = (payload['session_id']?.toString() ?? '').trim();
      if (sessionId.isNotEmpty) {
        sessionEntries.putIfAbsent(sessionId, () {
          final sessionDisplay = (payload['session_display_name']?.toString() ??
                  payload['session_title']?.toString() ??
                  'Seminar')
              .trim();
          return {
            'id': sessionId,
            'title': sessionDisplay.isNotEmpty ? sessionDisplay : 'Seminar',
            'start_at': (payload['session_start_at']?.toString() ?? '').trim(),
            'end_at': (payload['session_end_at']?.toString() ?? '').trim(),
          };
        });
      }
    }

    final participantCount = participantKeys.length;
    final localAvatarCount = localAvatarKeys.length;
    final sessionCount = sessionEntries.length;

    String avatarState;
    if (participantCount == 0) {
      avatarState = 'missing';
    } else if (localAvatarCount >= participantCount) {
      avatarState = 'ready';
    } else if (localAvatarCount > 0) {
      avatarState = 'partial';
    } else {
      avatarState = 'missing';
    }

    final checklist = <Map<String, dynamic>>[
      {
        'label': 'Event details',
        'state': eventMap.isNotEmpty ? 'ready' : 'missing',
        'detail': (eventMap['title']?.toString() ?? '').trim().isNotEmpty
            ? (eventMap['title']?.toString() ?? '').trim()
            : 'No cached event details',
      },
      {
        'label': 'Scan schedule',
        'state': scheduleReady ? 'ready' : 'missing',
        'detail': scheduleReady
            ? 'Scanner window and validation rules are saved offline.'
            : 'No offline scan schedule saved yet.',
      },
      {
        'label': 'Participant roster',
        'state': participantCount > 0 ? 'ready' : 'missing',
        'detail': '$participantCount participant${participantCount == 1 ? '' : 's'} cached',
      },
      {
        'label': 'Ticket QR data',
        'state': cachedTicketRows.isNotEmpty ? 'ready' : 'missing',
        'detail':
            '${cachedTicketRows.length} ticket record${cachedTicketRows.length == 1 ? '' : 's'} cached',
      },
      {
        'label': 'Attendance state',
        'state': cachedTicketRows.isNotEmpty ? 'ready' : 'missing',
        'detail':
            '$attendanceStateCount cached attendance state${attendanceStateCount == 1 ? '' : 's'} tracked',
      },
      {
        'label': 'Avatar photos',
        'state': avatarState,
        'detail':
            '$localAvatarCount of $participantCount participant avatar${participantCount == 1 ? '' : 's'} ready offline',
      },
    ];

    if (usesSessions) {
      checklist.add({
        'label': 'Seminar sessions',
        'state': sessionCount > 0 ? 'ready' : 'missing',
        'detail': sessionCount > 0
            ? '$sessionCount seminar window${sessionCount == 1 ? '' : 's'} cached'
            : 'No seminar session details cached yet.',
      });
    }

    final sortedSessions = sessionEntries.values.toList()
      ..sort(
        (a, b) => (a['title']?.toString() ?? '').compareTo(
          b['title']?.toString() ?? '',
        ),
      );

    return {
      'scope_label': usesSessions ? 'Seminar-based event' : 'Simple event',
      'participant_count': participantCount,
      'ticket_count': cachedTicketRows.length,
      'local_avatar_count': localAvatarCount,
      'remote_avatar_count': remoteAvatarKeys.length,
      'session_count': sessionCount,
      'sessions': sortedSessions,
      'checklist': checklist,
    };
  }

  Future<Map<String, dynamic>> getOfflineMonitorStatus({
    required String actorId,
    required bool isTeacher,
    bool refreshSnapshot = false,
    bool isOffline = false,
  }) async {
    await _ensureAutoRestore();
    final actor = actorId.trim();
    if (actor.isEmpty) {
      return {
        'ok': false,
        'has_snapshot': false,
        'snapshot_stale': false,
        'pending_queue_count': 0,
        'message': 'No scanner account is active on this device.',
      };
    }

    Map<String, dynamic>? refreshResult;
    if (refreshSnapshot && !isOffline) {
      refreshResult = await refreshSnapshotForCurrentScanner(
        actorId: actor,
        isTeacher: isTeacher,
      );
    }

    final cached = await getCachedScannerContext(
      actorId: actor,
      isTeacher: isTeacher,
    );
    final actorKey = _actorKey(actorId: actor, isTeacher: isTeacher);
    final pending = await pendingQueueCount(actorId: actor, isTeacher: isTeacher);
    final hasSnapshot = cached != null;
    final snapshotStale = cached?['offline_cache_stale'] == true;
    final liveStatus = (refreshResult?['status']?.toString() ?? '')
        .trim()
        .toLowerCase();
    final scannerStatus = (cached?['status']?.toString() ??
            (liveStatus.isNotEmpty ? liveStatus : 'unavailable'))
        .trim()
        .toLowerCase();
    final scannerEnabled = cached?['scanner_enabled'] == true;
    final eventTitle = _monitorEventTitle(cached);
    final sessionTitle = _monitorSessionTitle(cached);
    final contextMap = cached?['context'] is Map
        ? Map<String, dynamic>.from(cached!['context'] as Map)
        : <String, dynamic>{};
    final eventMap = contextMap['event'] is Map
        ? Map<String, dynamic>.from(contextMap['event'] as Map)
        : <String, dynamic>{};
    final activeEventId = (eventMap['id']?.toString() ?? '').trim();
    final cachedTicketRows = activeEventId.isNotEmpty
        ? await _store.listTicketCacheForEvent(
            actorKey: actorKey,
            eventId: activeEventId,
          )
        : <Map<String, dynamic>>[];
    final cachedTicketCount = cachedTicketRows.length;
    final cachedPackage = _buildCachedPackageSummary(
      contextMap: contextMap,
      cachedTicketRows: cachedTicketRows,
    );
    // Prepared = this device can actually scan this method offline: saved
    // assignment + ticket roster. A live online assignment is not enough.
    final contextReady = activeEventId.isNotEmpty;
    final ticketsReady = cachedTicketCount > 0;
    final rosterReady = contextReady && ticketsReady;
    final refreshError = refreshResult == null
        ? ''
        : _monitorRefreshErrorText(refreshResult);
    final refreshAttempted = refreshSnapshot && !isOffline;
    final warmFailed = refreshAttempted &&
        refreshResult != null &&
        refreshResult['ok'] != true &&
        !(hasSnapshot && !snapshotStale && contextReady && ticketsReady);
    final offlineReady =
        hasSnapshot && !snapshotStale && contextReady && ticketsReady;

    String message;
    if (!hasSnapshot) {
      if (refreshResult != null && refreshResult['ok'] == true) {
        message =
            'Snapshot refresh completed, but this device still has no saved scanner cache. Reopen the app and refresh once more.';
      } else if (refreshError.isNotEmpty) {
        message = refreshError;
      } else {
        message = 'This device has no saved scanner snapshot yet.';
      }
    } else if (!contextReady) {
      if (refreshError.isNotEmpty) {
        message = refreshError;
      } else {
        message =
            'Scanner assignment is not available to cache for offline use yet.';
      }
    } else if (cachedTicketCount == 0) {
      message =
          'Assignment is saved, but no tickets are on this device yet. Keep Scan open with internet until the roster finishes caching.';
    } else if (snapshotStale) {
      message = 'Saved scanner data needs an online refresh.';
    } else if (refreshError.isNotEmpty) {
      message = 'Using the saved scanner snapshot. Latest refresh issue: $refreshError';
    } else {
      message = 'Offline scanner data is available on this device.';
    }

    return {
      'ok': true,
      'is_offline': isOffline,
      'connection_label': _monitorConnectionLabel(
        isOffline: isOffline,
        refreshResult: refreshResult,
      ),
      'has_snapshot': hasSnapshot,
      'snapshot_stale': snapshotStale || warmFailed,
      'offline_ready': offlineReady,
      'roster_ready': rosterReady,
      'warm_failed': warmFailed,
      'last_synced_at': cached?['offline_cache_synced_at'],
      'expires_at': cached?['offline_cache_expires_at'],
      'active_event_id': activeEventId,
      'cached_ticket_count': cachedTicketCount,
      'cached_participant_count': cachedPackage['participant_count'],
      'cached_local_avatar_count': cachedPackage['local_avatar_count'],
      'cached_remote_avatar_count': cachedPackage['remote_avatar_count'],
      'cached_session_count': cachedPackage['session_count'],
      'cache_scope_label': cachedPackage['scope_label'],
      'cached_sessions': cachedPackage['sessions'],
      'cache_checklist': cachedPackage['checklist'],
      'pending_queue_count': pending,
      'scanner_status': scannerStatus,
      'scanner_enabled': scannerEnabled,
      'event_title': eventTitle,
      'session_title': sessionTitle,
      'live_status': liveStatus,
      'refresh_attempted': refreshResult != null,
      'refresh_ok': refreshResult == null ? null : refreshResult['ok'] == true,
      'refresh_error': refreshError,
      'message': message,
    };
  }
}
