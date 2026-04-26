import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'event_service.dart';
import 'offline_backup_service.dart';
import 'offline_scan_store.dart';

class OfflineSyncService {
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

  DateTime? _parseDate(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  String _ticketHash(String payload) {
    return sha256.convert(utf8.encode(payload.trim())).toString();
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
    return normalized == 'scanned' ||
        normalized == 'present' ||
        normalized == 'late' ||
        normalized == 'early';
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
    Duration delay;
    if (attemptCount <= 1) {
      delay = const Duration(seconds: 5);
    } else if (attemptCount == 2) {
      delay = const Duration(seconds: 15);
    } else if (attemptCount == 3) {
      delay = const Duration(seconds: 60);
    } else {
      delay = const Duration(minutes: 5);
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
        await _store.deleteContextCache(actorKey);
        await _store.clearTicketCacheForActor(actorKey);
        await _backupService.autoBackupIfConfigured(force: true);
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
        return {
          'ok': false,
          'status': contextStatus,
          'ticket_count': 0,
          'event_id': eventId,
          'roster_ready': false,
          'error':
              'Scanner context was saved, but no ticket roster rows were cached for this event.',
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

    if (status.toLowerCase() == 'no_assignment') {
      await _store.deleteContextCache(actorKey);
      await _store.clearTicketCacheForActor(actorKey);
      await _backupService.autoBackupIfConfigured(force: true);
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
    final opensAt =
        _parseDate(contextMap['opens_at']?.toString()) ??
        sessionStartAt ??
        eventStartAt;
    final explicitClosesAt = _parseDate(contextMap['closes_at']?.toString());
    final sessionWindowMinutes =
        int.tryParse(sessionMap['scan_window_minutes']?.toString() ?? '') ??
        int.tryParse(contextMap['window_minutes']?.toString() ?? '') ??
        30;
    final eventWindowMinutes =
        int.tryParse(eventMap['grace_time']?.toString() ?? '') ??
        int.tryParse(contextMap['window_minutes']?.toString() ?? '') ??
        30;
    DateTime? effectiveCloseAt = explicitClosesAt;
    if (effectiveCloseAt == null) {
      if (sessionStartAt != null) {
        effectiveCloseAt = sessionStartAt.add(
          Duration(minutes: sessionWindowMinutes),
        );
      } else if (eventStartAt != null) {
        effectiveCloseAt = eventStartAt.add(
          Duration(minutes: eventWindowMinutes),
        );
      }
    }

    if (opensAt != null && now.isBefore(opensAt)) {
      return {
        ...contextPayload,
        'status': 'waiting',
        'scanner_enabled': false,
      };
    }
    if (effectiveCloseAt != null && now.isAfter(effectiveCloseAt)) {
      return {
        ...contextPayload,
        'status': 'closed',
        'scanner_enabled': false,
      };
    }
    if (opensAt != null &&
        (effectiveCloseAt == null ||
            now.isBefore(effectiveCloseAt) ||
            now == effectiveCloseAt)) {
      return {
        ...contextPayload,
        'status': 'open',
        'scanner_enabled': true,
      };
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

    Map<String, dynamic> effectiveContext = context;
    if (activeContextOverride != null && activeContextOverride.isNotEmpty) {
      effectiveContext = _resolveContextStatusLocally(
        Map<String, dynamic>.from(activeContextOverride),
      );
      effectiveContext['offline_cache_stale'] = context['offline_cache_stale'];
      effectiveContext['offline_cache_synced_at'] =
          context['offline_cache_synced_at'];
      effectiveContext['offline_cache_expires_at'] =
          context['offline_cache_expires_at'];
    }

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

    var alreadyCheckedIn = false;
    if (activeSessionId.isNotEmpty) {
      alreadyCheckedIn = sessionPresence[activeSessionId] == true || pendingSync;
    } else {
      alreadyCheckedIn = _isCheckedInStatus(attendanceStatus) || pendingSync;
    }
    if (alreadyCheckedIn) {
      return {
        'ok': false,
        'status': 'already_checked_in',
        'error': 'Ticket already checked in.',
        'participant_name': payload['participant_name'],
        'participant_photo_url': payload['participant_photo_url'],
        'participant_photo_local_path': payload['participant_photo_local_path'],
        'participant_student_id': payload['participant_student_id'],
      };
    }

    return {
      'ok': true,
      'status': 'ready_for_confirmation',
      'message': 'Review participant, then confirm check-in.',
      'ticket_hash': _ticketHash(normalizedPayload),
      'event_id': payloadEventId,
      'session_id': activeSessionId,
      'participant_name': payload['participant_name'],
      'participant_photo_url': payload['participant_photo_url'],
      'participant_photo_local_path': payload['participant_photo_local_path'],
      'participant_student_id': payload['participant_student_id'],
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
    if (sessionId.trim().isNotEmpty) {
      final current = payload['session_presence'] is Map
          ? Map<String, dynamic>.from(payload['session_presence'] as Map)
          : <String, dynamic>{};
      current[sessionId.trim()] = status == 'present' || pending;
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
      };
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final opId =
        'op_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    final payload = {
      'ticket_payload': ticketPayload.trim(),
      'ticket_hash': ticketHash,
      'event_id': validation['event_id']?.toString() ?? '',
      'session_id': sessionId,
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
      status: 'pending',
    );
    await _backupService.autoBackupIfConfigured(force: true);

    return {
      'ok': true,
      'status': 'queued_offline',
      'message': 'Offline check-in saved. It will auto-sync when internet comes back.',
      'participant_name': validation['participant_name'],
      'participant_photo_url': validation['participant_photo_url'],
      'participant_photo_local_path': validation['participant_photo_local_path'],
      'participant_student_id': validation['participant_student_id'],
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

    final actorKey = _actorKey(actorId: actor, isTeacher: isTeacher);
    final operations = await _store.listDuePendingOperations(actorKey);
    var synced = 0;
    var rejected = 0;
    var conflictResolved = 0;

    for (final operation in operations) {
      final id = (operation['id']?.toString() ?? '').trim();
      if (id.isEmpty) continue;

      Map<String, dynamic> payload;
      try {
        final decoded = jsonDecode(operation['payload_json']?.toString() ?? '{}');
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

      final ticketPayload = (payload['ticket_payload']?.toString() ?? '').trim();
      final ticketHash = (payload['ticket_hash']?.toString() ?? '').trim();
      final sessionId = (payload['session_id']?.toString() ?? '').trim();
      final scannedAtIso =
          (payload['scanned_at']?.toString() ?? '').trim().isNotEmpty
          ? (payload['scanned_at']?.toString() ?? '').trim()
          : (payload['queued_at']?.toString() ?? '').trim();
      final response = isTeacher
          ? await _eventService.checkInParticipantAsTeacher(
              ticketPayload,
              actor,
              scannedAtIso: scannedAtIso,
            )
          : await _eventService.checkInParticipantAsAssistant(
              ticketPayload,
              actor,
              scannedAtIso: scannedAtIso,
            );

      final status = (response['status']?.toString() ?? '').toLowerCase().trim();
      final nowIso = DateTime.now().toUtc().toIso8601String();

      if (response['ok'] == true || status == 'present') {
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
            status: 'present',
          );
        }
        synced++;
        continue;
      }

      if (status == 'already_checked_in' || status == 'used') {
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
          status == 'conflict') {
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
        final attempts =
            (operation['attempt_count'] is num
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
        continue;
      }

      final attempts =
          (operation['attempt_count'] is num
              ? (operation['attempt_count'] as num).toInt()
              : int.tryParse(operation['attempt_count']?.toString() ?? '') ?? 0) +
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
    return _store.pendingCount(actorKey);
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
    final rosterReady = activeEventId.isNotEmpty && cachedTicketCount > 0;
    final refreshError = refreshResult == null
        ? ''
        : _monitorRefreshErrorText(refreshResult);
    final offlineReady = hasSnapshot && !snapshotStale && rosterReady;

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
    } else if (!rosterReady) {
      if (refreshError.isNotEmpty) {
        message =
            'Scanner context is saved, but the ticket roster cache is still empty. Latest refresh issue: $refreshError';
      } else {
        message =
            'Scanner context is saved, but the ticket roster cache is still empty for the active event.';
      }
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
      'snapshot_stale': snapshotStale,
      'offline_ready': offlineReady,
      'roster_ready': rosterReady,
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
