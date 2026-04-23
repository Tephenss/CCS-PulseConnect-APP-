import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math';
import 'package:flutter/foundation.dart';

class EventService {
  final _supabase = Supabase.instance.client;
  static const Duration _manilaOffset = Duration(hours: 8);
  final Map<String, bool> _eventSessionColumnSupport = {};
  final Map<String, bool> _attendanceColumnSupport = {};
  bool? _eventSessionAttendanceTableSupported;
  DateTime? _eventSessionAttendanceSupportCheckedAtUtc;

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

  bool _attendanceRecordCountsAsPresent(Map<String, dynamic>? row) {
    if (row == null || row.isEmpty) return false;
    if ((row['check_in_at']?.toString().trim().isNotEmpty ?? false)) {
      return true;
    }
    return _isCheckedInStatus(row['status']);
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

  Future<String> _resolveParticipantNameForRegistration(
    String registrationId,
  ) async {
    if (registrationId.trim().isEmpty) return '';

    String studentId = '';

    try {
      final regRows = await _supabase
          .from('event_registrations')
          .select('student_id, users(first_name,middle_name,last_name,suffix)')
          .eq('id', registrationId)
          .limit(1);

      if (regRows.isNotEmpty) {
        final row = Map<String, dynamic>.from(regRows.first);
        studentId = row['student_id']?.toString() ?? '';
        final rawUser = row['users'];
        Map<String, dynamic>? user;
        if (rawUser is Map<String, dynamic>) {
          user = rawUser;
        } else if (rawUser is Map) {
          user = Map<String, dynamic>.from(rawUser);
        } else if (rawUser is List &&
            rawUser.isNotEmpty &&
            rawUser.first is Map) {
          user = Map<String, dynamic>.from(rawUser.first as Map);
        }
        final name = _composeDisplayName(user);
        if (name.isNotEmpty) return name;
      }
    } catch (_) {
      // Fallback query below.
    }

    if (studentId.isEmpty) {
      try {
        final regRows = await _supabase
            .from('event_registrations')
            .select('student_id')
            .eq('id', registrationId)
            .limit(1);
        if (regRows.isNotEmpty) {
          studentId = regRows.first['student_id']?.toString() ?? '';
        }
      } catch (_) {}
    }

    if (studentId.isEmpty) return '';

    try {
      final userRows = await _supabase
          .from('users')
          .select('first_name,middle_name,last_name,suffix')
          .eq('id', studentId)
          .limit(1);
      if (userRows.isNotEmpty) {
        return _composeDisplayName(Map<String, dynamic>.from(userRows.first));
      }
    } catch (_) {}

    return '';
  }

  Future<String> _resolveParticipantNameForUser(String userId) async {
    final trimmedUserId = userId.trim();
    if (trimmedUserId.isEmpty) return '';
    try {
      final userRows = await _supabase
          .from('users')
          .select('first_name,middle_name,last_name,suffix')
          .eq('id', trimmedUserId)
          .limit(1);
      if (userRows.isNotEmpty) {
        return _composeDisplayName(Map<String, dynamic>.from(userRows.first));
      }
    } catch (_) {}
    return '';
  }

  Future<List<Map<String, dynamic>>> _fetchTeacherScanAssignmentRows(
    String teacherId,
  ) async {
    try {
      final rows = await _supabase
          .from('event_teacher_assignments')
          .select(
            'event_id, can_scan, events(id,title,status,start_at,end_at,location,uses_sessions,event_mode,event_structure)',
          )
          .eq('teacher_id', teacherId)
          .eq('can_scan', true)
          .limit(200);
      return List<Map<String, dynamic>>.from(rows);
    } catch (_) {
      try {
        final rows = await _supabase
            .from('event_teacher_assignments')
            .select(
              'event_id, can_scan, events(id,title,status,start_at,end_at,location,uses_sessions,event_structure)',
            )
            .eq('teacher_id', teacherId)
            .eq('can_scan', true)
            .limit(200);
        return List<Map<String, dynamic>>.from(rows);
      } catch (_) {
        final rows = await _supabase
            .from('event_teacher_assignments')
            .select(
              'event_id, can_scan, events(id,title,status,start_at,end_at,location,uses_sessions)',
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
          'id, session_id, student_id, template_id, session_template_id, certificate_code, issued_at',
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
      final session = sessionMap[sessionId] ?? <String, dynamic>{};
      final eventId = session['event_id']?.toString() ?? '';
      final event = eventMap[eventId] ?? <String, dynamic>{};
      final sessionName = _sessionDisplayName(session);
      final eventTitle = event['title']?.toString() ?? 'Event';
      return {
        ...row,
        'event_id': eventId,
        'events': event,
        'session': session,
        'certificate_scope': 'session',
        'display_title': '$eventTitle - $sessionName',
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

  Future<bool> _supportsEventSessionsColumn(String column) async {
    final cached = _eventSessionColumnSupport[column];
    if (cached != null) return cached;

    try {
      await _supabase.from('event_sessions').select('id,$column').limit(1);
      _eventSessionColumnSupport[column] = true;
      return true;
    } catch (_) {
      _eventSessionColumnSupport[column] = false;
      return false;
    }
  }

  Future<List<String>> _eventSessionsSupportedColumns() async {
    final supported = <String>['id', 'event_id', 'title', 'start_at'];
    final optionalColumns = [
      'topic',
      'description',
      'location',
      'end_at',
      'scan_window_minutes',
      'attendance_window_minutes',
      'sort_order',
      'session_no',
    ];

    for (final column in optionalColumns) {
      if (await _supportsEventSessionsColumn(column)) {
        supported.add(column);
      }
    }

    return supported;
  }

  Future<bool> _supportsAttendanceColumn(String column) async {
    final cached = _attendanceColumnSupport[column];
    if (cached != null) return cached;

    try {
      await _supabase.from('attendance').select('id,$column').limit(1);
      _attendanceColumnSupport[column] = true;
      return true;
    } catch (_) {
      _attendanceColumnSupport[column] = false;
      return false;
    }
  }

  Future<bool> _supportsEventSessionAttendanceTable() async {
    final cached = _eventSessionAttendanceTableSupported;
    if (cached == true) return true;

    // If we previously cached `false`, allow retries after a short cooldown.
    // This prevents the app from getting "stuck" when policies/migrations were
    // applied after the first check, or when network/auth temporarily failed.
    if (cached == false) {
      final checkedAt = _eventSessionAttendanceSupportCheckedAtUtc;
      if (checkedAt != null) {
        final age = DateTime.now().toUtc().difference(checkedAt);
        if (age.inSeconds < 10) return false;
      }
      _eventSessionAttendanceTableSupported = null;
    }

    try {
      await _supabase.from('event_session_attendance').select('id').limit(1);
      _eventSessionAttendanceTableSupported = true;
      _eventSessionAttendanceSupportCheckedAtUtc = DateTime.now().toUtc();
      return true;
    } catch (e) {
      if (_isEventSessionAttendanceUnavailableError(e) ||
          _isAccessPolicyError(e)) {
        _eventSessionAttendanceTableSupported = false;
        _eventSessionAttendanceSupportCheckedAtUtc = DateTime.now().toUtc();
        return false;
      }
      _eventSessionAttendanceTableSupported = false;
      _eventSessionAttendanceSupportCheckedAtUtc = DateTime.now().toUtc();
      return false;
    }
  }

  Future<Map<String, dynamic>> _recordSessionAttendance({
    required String ticketId,
    required String registrationId,
    required String sessionId,
    required String teacherId,
    required String nowIso,
    required Map<String, dynamic> session,
    required String participantName,
  }) async {
    final displayName = session['display_name']?.toString().trim();
    final sessionName = (displayName?.isNotEmpty ?? false)
        ? displayName!
        : _sessionDisplayName(session);

    Map<String, dynamic> successResponse() {
      return {
        'ok': true,
        'ticket_id': ticketId,
        'status': 'present',
        'participant_name': participantName,
        'message': 'Checked in for $sessionName.',
      };
    }

    Map<String, dynamic> alreadyRecordedResponse() {
      return {
        'ok': false,
        'error': 'This ticket is already recorded for the active seminar.',
        'status': 'already_checked_in',
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
          return alreadyRecordedResponse();
        }

        await _supabase.from('event_session_attendance').insert({
          'session_id': sessionId,
          'registration_id': registrationId,
          'ticket_id': ticketId,
          'status': 'present',
          'check_in_at': nowIso,
          'last_scanned_by': teacherId,
          'last_scanned_at': nowIso,
          'updated_at': nowIso,
        });

        return successResponse();
      } catch (e) {
        if (_isUniqueViolationError(e)) {
          return alreadyRecordedResponse();
        }
        if (!_isEventSessionAttendanceUnavailableError(e) &&
            !_isAccessPolicyError(e)) {
          rethrow;
        }
      }
    }

    final supportsSessionId = await _supportsAttendanceColumn('session_id');
    if (supportsSessionId) {
      final supportsLastScannedAt = await _supportsAttendanceColumn(
        'last_scanned_at',
      );

      try {
        final existingRows = await _supabase
            .from('attendance')
            .select('id,status,check_in_at')
            .eq('ticket_id', ticketId)
            .eq('session_id', sessionId)
            .limit(1);

        if (existingRows.isNotEmpty) {
          final attendance = Map<String, dynamic>.from(existingRows.first);
          final alreadyCheckedIn =
              _isCheckedInStatus(attendance['status']) ||
              (attendance['check_in_at']?.toString().trim().isNotEmpty ??
                  false);
          if (alreadyCheckedIn) {
            return alreadyRecordedResponse();
          }

          final payload = <String, dynamic>{
            'status': 'present',
            'check_in_at': nowIso,
          };
          if (supportsLastScannedAt) {
            payload['last_scanned_at'] = nowIso;
          }

          await _supabase
              .from('attendance')
              .update(payload)
              .eq('id', attendance['id']);

          return successResponse();
        }

        final insertPayload = <String, dynamic>{
          'ticket_id': ticketId,
          'session_id': sessionId,
          'status': 'present',
          'check_in_at': nowIso,
        };
        if (supportsLastScannedAt) {
          insertPayload['last_scanned_at'] = nowIso;
        }

        await _supabase.from('attendance').insert(insertPayload);

        return successResponse();
      } catch (e) {
        if (_isUniqueViolationError(e)) {
          return alreadyRecordedResponse();
        }
        if (_isAccessPolicyError(e)) {
          return {
            'ok': false,
            'error':
                'Check-in failed due to access policy. Please contact admin.',
            'status': 'error',
          };
        }
        rethrow;
      }
    }

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

  Future<List<Map<String, dynamic>>> getEventSessions(String eventId) async {
    if (eventId.trim().isEmpty) return [];
    return _fetchSessionsForEvent(eventId);
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
              if ((attendanceItem['ticket_id']?.toString().trim().isEmpty ?? true)) {
                attendanceItem['ticket_id'] = ticketId;
              }
              if ((attendanceItem['registration_id']?.toString().trim().isEmpty ?? true) &&
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
            rowsByRegistration[registrationId] ?? const <Map<String, dynamic>>[],
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
      dynamic query = _supabase
          .from('event_sessions')
          .select(supportedColumns.join(','))
          .eq('event_id', eventId);

      if (supportedColumns.contains('sort_order')) {
        query = query.order('sort_order', ascending: true);
      } else if (supportedColumns.contains('session_no')) {
        query = query.order('session_no', ascending: true);
      }

      query = query.order('start_at', ascending: true);

      final rows = await query;
      return _normalizeEventSessions(
        List<Map<String, dynamic>>.from(rows),
        eventId,
      );
    } catch (_) {
      return [];
    }
  }

  Map<String, dynamic> _resolveEventWindowContext(
    Map<String, dynamic> eventSummary,
    dynamic startRaw,
    DateTime nowUtc, {
    String source = 'event',
    String missingMessage = 'Event start time is missing.',
    String waitingMessage = 'Waiting for event scan window.',
    String openMessage = 'Event scanning is open.',
    String closedMessage = 'Event scan window has closed.',
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

    final closesAt = startAt.add(const Duration(minutes: 30));
    if (nowUtc.isBefore(startAt)) {
      return {
        'status': 'waiting',
        'source': 'event',
        'event': eventSummary,
        'session': null,
        'opens_at': startAt.toIso8601String(),
        'closes_at': closesAt.toIso8601String(),
        'window_minutes': 30,
        'message': waitingMessage,
      };
    }

    if (nowUtc.isAfter(closesAt)) {
      return {
        'status': 'closed',
        'source': 'event',
        'event': eventSummary,
        'session': null,
        'opens_at': startAt.toIso8601String(),
        'closes_at': closesAt.toIso8601String(),
        'window_minutes': 30,
        'message': closedMessage,
      };
    }

    return {
      'status': 'open',
      'source': 'event',
      'event': eventSummary,
      'session': null,
      'opens_at': startAt.toIso8601String(),
      'closes_at': closesAt.toIso8601String(),
      'window_minutes': 30,
      'message': openMessage,
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

    final sessions = await _fetchSessionsForEvent(eventId);
    final shouldUseSessions = _eventUsesSessions(event) || sessions.isNotEmpty;

    if (shouldUseSessions) {
      if (sessions.isEmpty) {
        return _resolveEventWindowContext(
          eventSummary,
          event['start_at'],
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
        final closesAt = startAt.add(Duration(minutes: windowMinutes));
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
          },
          'opens_at': item['opens_at'],
          'closes_at': item['closes_at'],
          'window_minutes': item['window_minutes'],
          'message': 'Seminar scanning is open.',
        };
      }

      // If a previous seminar already closed but a later seminar is still upcoming,
      // show Waiting for the next seminar (gap between sessions).
      if (waiting.isNotEmpty) {
        try {
          await _supabase.rpc(
            'sync_closed_session_absences',
            params: {'p_event_id': eventId},
          );
        } catch (e) {
          debugPrint('[scanContext] sync_closed_session_absences failed: $e');
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
          nowUtc,
          missingMessage: 'Seminar schedule is unavailable for this event.',
          waitingMessage: 'Waiting for event scan window.',
          openMessage: 'Scanning is open for this event.',
          closedMessage: 'Event scan window has closed.',
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
      return {
        'status': 'closed',
        'source': 'session',
        'event': eventSummary,
        'session': last == null
            ? null
            : {
                'id': session['id']?.toString() ?? '',
                'title': session['title']?.toString() ?? '',
                'topic': session['topic']?.toString() ?? '',
                'display_name': _sessionDisplayName(session),
                'start_at': session['start_at']?.toString() ?? '',
                'end_at': session['end_at']?.toString() ?? '',
                'scan_window_minutes': last['window_minutes'],
              },
        'opens_at': last?['opens_at'],
        'closes_at': last?['closes_at'],
        'window_minutes': last?['window_minutes'] ?? 30,
        'message': 'Seminar scan window has closed.',
      };
    }

    return _resolveEventWindowContext(eventSummary, event['start_at'], nowUtc);
  }

  String _normalizeTargetCourse(String? rawCourse) {
    final normalized = (rawCourse ?? '').trim().toUpperCase();
    if (normalized.isEmpty) return 'ALL';
    if (normalized == 'BSIT' ||
        normalized == 'IT' ||
        normalized.contains('BSIT') ||
        normalized.contains(' IT')) {
      return 'BSIT';
    }
    if (normalized == 'BSCS' ||
        normalized == 'CS' ||
        normalized.contains('BSCS') ||
        normalized.contains(' CS')) {
      return 'BSCS';
    }
    return 'ALL';
  }

  String _normalizeTargetYear(String? rawYear) {
    final normalized = (rawYear ?? '').trim();
    if (['1', '2', '3', '4'].contains(normalized)) return normalized;
    return 'ALL';
  }

  Map<String, String> _decodeEventTarget(dynamic rawTarget) {
    final raw = (rawTarget?.toString() ?? '').trim().toUpperCase();
    if (raw.isEmpty ||
        raw == 'ALL' ||
        raw == 'NONE' ||
        raw == 'ALL LEVELS' ||
        raw == 'ALL COURSES') {
      return {'course': 'ALL', 'year': 'ALL'};
    }

    final pair = RegExp(r'^(BSIT|BSCS)\s*[-_|]\s*([1-4])$').firstMatch(raw);
    if (pair != null) {
      return {
        'course': pair.group(1) ?? 'ALL',
        'year': pair.group(2) ?? 'ALL',
      };
    }

    if (raw == 'BSIT' ||
        raw == 'BSCS' ||
        raw == 'IT' ||
        raw == 'CS' ||
        raw == 'BSIT STUDENTS' ||
        raw == 'BSCS STUDENTS') {
      return {'course': _normalizeTargetCourse(raw), 'year': 'ALL'};
    }

    if (['1', '2', '3', '4'].contains(raw)) {
      return {'course': 'ALL', 'year': raw};
    }

    return {'course': 'ALL', 'year': 'ALL'};
  }

  bool _matchesEventTarget(
    Map<String, dynamic> event, {
    String? yearLevel,
    String? courseCode,
  }) {
    final target = _decodeEventTarget(event['event_for']);
    final targetCourse = target['course'] ?? 'ALL';
    final targetYear = target['year'] ?? 'ALL';

    final studentCourse = _normalizeTargetCourse(courseCode);
    final studentYear = _normalizeTargetYear(yearLevel);

    final courseMatches = targetCourse == 'ALL'
        ? true
        : (studentCourse != 'ALL' && targetCourse == studentCourse);
    final yearMatches = targetYear == 'ALL'
        ? true
        : (studentYear != 'ALL' && targetYear == studentYear);

    return courseMatches && yearMatches;
  }

  // Helper to filter events by target participant scope (course + year)
  List<Map<String, dynamic>> _filterByTargetParticipant(
    List<Map<String, dynamic>> events, {
    String? yearLevel,
    String? courseCode,
  }) {
    return events
        .where(
          (event) => _matchesEventTarget(
            event,
            yearLevel: yearLevel,
            courseCode: courseCode,
          ),
        )
        .toList();
  }

  static const Duration _minSecondsBeforeCheckout = Duration(seconds: 20);

  // Get all active/published events (ongoing + upcoming, not yet ended)
  Future<List<Map<String, dynamic>>> getActiveEvents({
    String? yearLevel,
    String? courseCode,
  }) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final response = await _supabase
          .from('events')
          .select()
          .eq('status', 'published')
          .gte('end_at', now)
          .order('start_at', ascending: true);
      final list = List<Map<String, dynamic>>.from(response);
      return _filterByTargetParticipant(
        list,
        yearLevel: yearLevel,
        courseCode: courseCode,
      );
    } catch (e) {
      return [];
    }
  }

  // Get expired events (already ended)
  Future<List<Map<String, dynamic>>> getExpiredEvents({
    String? yearLevel,
    String? courseCode,
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
      );
    } catch (e) {
      return [];
    }
  }

  // Get upcoming events (future events)
  Future<List<Map<String, dynamic>>> getUpcomingEvents({
    String? yearLevel,
    String? courseCode,
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
      );
      return filtered.take(5).toList();
    } catch (e) {
      return [];
    }
  }

  // Get event by ID
  Future<Map<String, dynamic>?> getEventById(String eventId) async {
    try {
      final response = await _supabase
          .from('events')
          .select()
          .eq('id', eventId)
          .single();
      return response;
    } catch (e) {
      return null;
    }
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
    String registrationId = '';
    try {
      // 1. Check if already registered
      final existing = await _supabase
          .from('event_registrations')
          .select('id')
          .eq('event_id', eventId)
          .eq('student_id', userId)
          .limit(1);

      if (existing.isNotEmpty) {
        return {'ok': true, 'already_registered': true};
      }

      // 2. Create registration
      final regRes = await _supabase
          .from('event_registrations')
          .insert({'event_id': eventId, 'student_id': userId})
          .select()
          .single();

      final regId = regRes['id']?.toString() ?? '';
      registrationId = regId;

      // 3. Create ticket
      final token = _generateToken();
      final ticketRes = await _supabase
          .from('tickets')
          .insert({'registration_id': regId, 'token': token})
          .select()
          .single();

      final ticketId = ticketRes['id']?.toString() ?? '';

      // 4. Create attendance
      // Attendance row creation can be restricted by RLS in some deployments.
      // Registration should still be considered successful even if attendance
      // bootstrap insert is blocked; the scanner flow will create/update it later.
      if (ticketId.isNotEmpty) {
        try {
          await _supabase.from('attendance').insert({
            'ticket_id': ticketId,
            'status': 'unscanned',
          });
        } catch (_) {
          // Best-effort only.
        }
      }

      return {'ok': true};
    } catch (e) {
      // If registration/ticket was created but a later step failed (commonly
      // attendance bootstrap insert blocked by RLS), treat as success.
      if (registrationId.isNotEmpty) {
        return {'ok': true};
      }

      // Final safety net: re-check whether the user is now registered.
      // This prevents confusing UX where the first tap registers successfully
      // but UI shows an error due to a non-critical post-step failure.
      try {
        final existing = await _supabase
            .from('event_registrations')
            .select('id')
            .eq('event_id', eventId)
            .eq('student_id', userId)
            .limit(1);
        if (existing.isNotEmpty) {
          return {'ok': true};
        }
      } catch (_) {}

      return {'ok': false, 'error': 'Registration failed: ${e.toString()}'};
    }
  }

  // Get events the user registered for (tickets)
  Future<List<Map<String, dynamic>>> getMyTickets(String userId) async {
    try {
      final response = await _supabase
          .from('event_registrations')
          .select('*, events(*), tickets(*, attendance(*))')
          .eq('student_id', userId)
          .order('registered_at', ascending: false);
      final rows = List<Map<String, dynamic>>.from(response);

      // Best-effort: if a registration exists but its ticket row was deleted
      // (common during manual DB cleanup), recreate the missing ticket so the
      // student can still "See Ticket" from My Tickets.
      for (final reg in rows) {
        final regId = reg['id']?.toString() ?? '';
        if (regId.isEmpty) continue;

        final ticketData = reg['tickets'];
        final existingTicketId = ticketData is List && ticketData.isNotEmpty
            ? (ticketData.first['id'] ?? '').toString()
            : ticketData is Map
                ? (ticketData['id'] ?? '').toString()
                : '';
        if (existingTicketId.trim().isNotEmpty) continue;

        try {
          final token = _generateToken();
          final ticketRes = await _supabase
              .from('tickets')
              .insert({'registration_id': regId, 'token': token})
              .select()
              .single();
          final ticketId = ticketRes['id']?.toString() ?? '';
          if (ticketId.isNotEmpty) {
            reg['tickets'] = [ticketRes];
            // Bootstrap attendance is best-effort only.
            try {
              await _supabase.from('attendance').insert({
                'ticket_id': ticketId,
                'status': 'unscanned',
              });
            } catch (_) {}
          }
        } catch (_) {
          // If ticket recreate fails due to policy/schema, skip silently.
        }
      }

      return rows;
    } catch (e) {
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

    if (await _supportsEventSessionAttendanceTable()) {
      try {
        final rows = await _supabase
            .from('event_session_attendance')
            .select('session_id,status,check_in_at')
            .eq('registration_id', registrationId);
        for (final row in List<Map<String, dynamic>>.from(rows)) {
          if (!_hasCheckInRecord(row)) continue;
          final sessionId = row['session_id']?.toString() ?? '';
          final checkInAt = row['check_in_at']?.toString() ?? '';
          if (sessionId.isEmpty || checkInAt.isEmpty) continue;
          checkInBySession.putIfAbsent(sessionId, () => checkInAt);
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
            .select('session_id,status,check_in_at')
            .eq('ticket_id', ticketId)
            .not('session_id', 'is', null);
        for (final row in List<Map<String, dynamic>>.from(rows)) {
          if (!_hasCheckInRecord(row)) continue;
          final sessionId = row['session_id']?.toString() ?? '';
          final checkInAt = row['check_in_at']?.toString() ?? '';
          if (sessionId.isEmpty || checkInAt.isEmpty) continue;
          checkInBySession.putIfAbsent(sessionId, () => checkInAt);
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
      };
    }).toList();
  }

  // Get participant count for an event
  Future<int> getParticipantCount(String eventId) async {
    try {
      final response = await _supabase
          .from('event_registrations')
          .select('id')
          .eq('event_id', eventId);
      return (response as List).length;
    } catch (e) {
      return 0;
    }
  }

  // Check if user is registered for an event
  Future<bool> isRegistered(String eventId, String userId) async {
    try {
      final response = await _supabase
          .from('event_registrations')
          .select('id')
          .eq('event_id', eventId)
          .eq('student_id', userId)
          .limit(1);
      return response.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  // Get user's certificates
  Future<List<Map<String, dynamic>>> getMyCertificates(String userId) async {
    try {
      final participantName = await _resolveParticipantNameForUser(userId);

      Map<String, dynamic> templatePayload(dynamic raw) {
        final row = _asStringMap(raw);
        return {
          'thumbnail_url': row['thumbnail_url']?.toString(),
          'template_canvas_state': row['canvas_state'],
          'template_title': row['title']?.toString(),
          'template_body_text': row['body_text']?.toString(),
          'template_footer_text': row['footer_text']?.toString(),
          'template_id': row['id']?.toString(),
          'template_source_row': row,
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
              .select('*')
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

      final simpleResponse = await _supabase
          .from('certificates')
          .select('*, events(title, start_at)')
          .eq('student_id', userId)
          .order('issued_at', ascending: false);

      final rawSimpleCerts = List<Map<String, dynamic>>.from(simpleResponse);
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
        final selectedTemplate =
            simpleTemplateById[row['template_id']?.toString() ?? ''] ??
            simpleTemplateByEvent[row['event_id']?.toString() ?? ''] ??
            <String, dynamic>{};
        return {
          ...row,
          ...selectedTemplate,
          'certificate_scope': 'event',
          'participant_name': participantName,
          'display_title': eventMap['title']?.toString() ?? 'Event',
          'events': eventMap,
        };
      }).toList();

      List<Map<String, dynamic>> sessionCerts = [];
      try {
        final sessionResponse = await _supabase
            .from('event_session_certificates')
            .select(
              'id, session_id, student_id, template_id, session_template_id, certificate_code, issued_at, '
              'event_sessions(id, event_id, title, topic, start_at, events(id, title, start_at))',
            )
            .eq('student_id', userId)
            .order('issued_at', ascending: false);

        final rawSessionCerts = List<Map<String, dynamic>>.from(
          sessionResponse,
        );
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

        final sessionTemplateById = await loadTemplateMap(
          table: 'event_session_certificate_templates',
          keyColumn: 'id',
          values: sessionTemplateIds,
        );
        final sessionTemplateBySession = await loadTemplateMap(
          table: 'event_session_certificate_templates',
          keyColumn: 'session_id',
          values: sessionIds,
        );
        final eventTemplateById = await loadTemplateMap(
          table: 'certificate_templates',
          keyColumn: 'id',
          values: eventTemplateIds,
        );
        final eventTemplateByEvent = await loadTemplateMap(
          table: 'certificate_templates',
          keyColumn: 'event_id',
          values: eventIds,
        );

        sessionCerts = rawSessionCerts.map((row) {
          final session = _asStringMap(row['event_sessions']);
          final sessionId =
              session['id']?.toString() ?? row['session_id']?.toString() ?? '';
          final eventId = session['event_id']?.toString() ?? '';
          final event = _asStringMap(session['events']);
          final sessionName = _sessionDisplayName(session);
          final eventTitle = event['title']?.toString() ?? 'Event';

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
            'display_title': '$eventTitle - $sessionName',
          };
        }).toList();
      } catch (_) {
        try {
          sessionCerts = await _getSessionCertificatesFallback(userId);
          final sessionTemplateIds = sessionCerts
              .map((row) => row['session_template_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList();
          final eventTemplateIds = sessionCerts
              .map((row) => row['template_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList();
          final sessionIds = sessionCerts
              .map((row) => row['session_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList();
          final eventIds = sessionCerts
              .map((row) => row['event_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList();

          final sessionTemplateById = await loadTemplateMap(
            table: 'event_session_certificate_templates',
            keyColumn: 'id',
            values: sessionTemplateIds,
          );
          final sessionTemplateBySession = await loadTemplateMap(
            table: 'event_session_certificate_templates',
            keyColumn: 'session_id',
            values: sessionIds,
          );
          final eventTemplateById = await loadTemplateMap(
            table: 'certificate_templates',
            keyColumn: 'id',
            values: eventTemplateIds,
          );
          final eventTemplateByEvent = await loadTemplateMap(
            table: 'certificate_templates',
            keyColumn: 'event_id',
            values: eventIds,
          );

          sessionCerts = sessionCerts.map((row) {
            final selectedTemplate =
                sessionTemplateById[row['session_template_id']?.toString() ??
                    ''] ??
                eventTemplateById[row['template_id']?.toString() ?? ''] ??
                sessionTemplateBySession[row['session_id']?.toString() ?? ''] ??
                eventTemplateByEvent[row['event_id']?.toString() ?? ''] ??
                <String, dynamic>{};
            return {
              ...row,
              ...selectedTemplate,
              'participant_name': participantName,
            };
          }).toList();
        } catch (_) {
          sessionCerts = [];
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
      return all;
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, dynamic>> getTicketForEvent(
    String eventId,
    String userId,
  ) async {
    try {
      final rows = await _supabase
          .from('event_registrations')
          .select('event_id, events(*), tickets(*, attendance(*))')
          .eq('student_id', userId)
          .eq('event_id', eventId)
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
    String teacherId,
  ) async {
    final merged = <String, Map<String, dynamic>>{};

    // Always try created events first so teacher still sees their own
    // events even if assignments query is blocked by RLS.
    try {
      final created = await _supabase
          .from('events')
          .select()
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
          await _supabase.from('events').select().inFilter('id', assignedIds),
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
    return list;
  }

  // Get only UPCOMING accessible events for a specific teacher, max 5 limit
  Future<List<Map<String, dynamic>>> getTeacherUpcomingEvents(
    String teacherId,
  ) async {
    try {
      final allAccessible = await getTeacherAccessibleEvents(teacherId);
      final now = DateTime.now().toUtc();

      final upcoming = allAccessible.where((e) {
        final status = (e['status']?.toString() ?? '').toLowerCase();
        if (status != 'published' && status != 'approved') {
          return false;
        }
        final start = _toUtcDate(e['start_at']);
        final end = _toUtcDate(e['end_at']);

        // Show event on home while it is upcoming OR still ongoing.
        if (end != null) {
          return end.isAfter(now) || end.isAtSameMomentAs(now);
        }
        if (start == null) return false;
        return start.isAfter(now) || start.isAtSameMomentAs(now);
      }).toList();

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
    final now = DateTime.now().toUtc().toIso8601String();

    try {
      final assignmentRows = await _supabase
          .from('event_teacher_assignments')
          .select('event_id')
          .eq('teacher_id', teacherId)
          .eq('can_scan', true)
          .limit(200);

      if (assignmentRows.isEmpty) {
        return [];
      }

      final eventIds = assignmentRows
          .map((row) => row['event_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      if (eventIds.isEmpty) {
        return [];
      }

      final eventRows = await _supabase
          .from('events')
          .select()
          .inFilter('id', eventIds)
          .eq('status', 'published')
          .gte('end_at', now)
          .order('start_at', ascending: true);

      return List<Map<String, dynamic>>.from(eventRows);
    } catch (_) {
      return [];
    }
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
        'message':
            closed.first['message']?.toString() ?? 'Scan window is closed.',
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
          if (status != 'published') continue;
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

      final nowUtc = DateTime.now().toUtc();
      final contexts = <Map<String, dynamic>>[];
      for (final event in events) {
        contexts.add(await _resolveSingleEventScanContext(event, nowUtc));
      }
      return _finalizeTeacherScanContext(
        events: events,
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
      final teacherIds = <String>{};
      final eventIds = <String>{};

      for (final row in List<Map<String, dynamic>>.from(rows)) {
        final assignedBy =
            row['assigned_by_teacher_id']?.toString().trim() ?? '';
        final eventId = row['event_id']?.toString() ?? '';
        // Only accept rows explicitly assigned by a teacher.
        // This prevents legacy rows (without assigning teacher) from
        // accidentally granting scanner context.
        if (eventId.isEmpty || assignedBy.isEmpty) continue;
        candidateRows.add({
          'assigned_by_teacher_id': assignedBy,
          'event_id': eventId,
        });
        teacherIds.add(assignedBy);
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
                'id,title,status,start_at,end_at,location,uses_sessions,event_mode,event_structure',
              )
              .inFilter('id', eventIds.toList())
              .eq('status', 'published')
              .limit(500);
        } catch (_) {
          try {
            eventRows = await _supabase
                .from('events')
                .select(
                  'id,title,status,start_at,end_at,location,uses_sessions',
                )
                .inFilter('id', eventIds.toList())
                .eq('status', 'published')
                .limit(500);
          } catch (_) {
            // Last-resort backward compatible schema (no uses_sessions).
            eventRows = await _supabase
                .from('events')
                .select('id,title,status,start_at,end_at,location')
                .inFilter('id', eventIds.toList())
                .eq('status', 'published')
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

      // Strict verification:
      // Assistant access is valid only when the assigning teacher still has
      // active scanner permission for the same event.
      final allowedTeacherEventPairs = <String>{};
      if (teacherIds.isNotEmpty) {
        try {
          final teacherAssignmentRows = await _supabase
              .from('event_teacher_assignments')
              .select('event_id,teacher_id')
              .inFilter('event_id', eventIds.toList())
              .inFilter('teacher_id', teacherIds.toList())
              .eq('can_scan', true)
              .limit(500);
          for (final raw in List<Map<String, dynamic>>.from(teacherAssignmentRows)) {
            final eventId = raw['event_id']?.toString().trim() ?? '';
            final teacherId = raw['teacher_id']?.toString().trim() ?? '';
            if (eventId.isEmpty || teacherId.isEmpty) continue;
            allowedTeacherEventPairs.add('$eventId|$teacherId');
          }
        } catch (e) {
          // Fail closed for security: if we cannot verify admin -> teacher
          // scanner access, assistant scanner access should not be granted.
          if (_isMissingTeacherAssignmentsTableError(e)) {
            return _finalizeTeacherScanContext(
              events: const [],
              contexts: const [],
              nowUtc: DateTime.now().toUtc(),
            );
          }
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

      final events = <Map<String, dynamic>>[];
      final seenEventIds = <String>{};
      for (final row in candidateRows) {
        final eventId = row['event_id']?.toString().trim() ?? '';
        final assignedBy = row['assigned_by_teacher_id']?.toString().trim() ?? '';
        if (eventId.isEmpty) continue;
        if (assignedBy.isEmpty) continue;
        if (!allowedTeacherEventPairs.contains('$eventId|$assignedBy')) {
          continue;
        }
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

      final nowUtc = DateTime.now().toUtc();
      final contexts = <Map<String, dynamic>>[];
      for (final event in events) {
        contexts.add(await _resolveSingleEventScanContext(event, nowUtc));
      }
      return _finalizeTeacherScanContext(
        events: events,
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
      work['event_for'] = (work['event_for']?.toString().trim().isNotEmpty ?? false)
          ? work['event_for']
          : 'All';

      final isSeminarBased =
          (work['event_mode']?.toString().trim() == 'seminar_based') ||
          sessions.isNotEmpty;
      work['event_mode'] = isSeminarBased ? 'seminar_based' : 'simple';
      work['event_structure'] = isSeminarBased
          ? (sessions.length > 1 ? 'two_seminars' : 'one_seminar')
          : 'simple';
      work['uses_sessions'] = isSeminarBased;

      final optionalColumns = [
        'event_mode',
        'event_structure',
        'uses_sessions',
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
          'error': 'Failed to create event: Unable to save event schema fields.',
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
      payload['session_no'] = i + 1;
      payload['sort_order'] = i;
      payload['scan_window_minutes'] =
          int.tryParse(source['scan_window_minutes']?.toString() ?? '') ?? 30;
      payload['attendance_window_minutes'] =
          int.tryParse(source['attendance_window_minutes']?.toString() ?? '') ??
          30;

      final topic = source['topic']?.toString().trim();
      final description = source['description']?.toString().trim();
      final location = source['location']?.toString().trim();
      if (topic != null && topic.isNotEmpty) payload['topic'] = topic;
      if (description != null && description.isNotEmpty) {
        payload['description'] = description;
      }
      if (location != null && location.isNotEmpty) payload['location'] = location;

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
        'attendance_window_minutes',
        'sort_order',
        'session_no',
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
        throw Exception('Unable to insert seminar ${i + 1} due to schema mismatch.');
      }
    }
  }

  // Get participants (registered students) for a specific event
  Future<List<Map<String, dynamic>>> getEventParticipants(
    String eventId,
  ) async {
    try {
      // Strategy 1: relational select with stable columns only.
      final response = await _supabase
          .from('event_registrations')
          .select(
            'id, registered_at, student_id, '
            'users(first_name, middle_name, last_name, suffix, email, student_id), '
            'tickets(*, attendance(*))',
          )
          .eq('event_id', eventId)
          .order('registered_at', ascending: false);

      final list = List<Map<String, dynamic>>.from(response);

      // If users relation is null, fetch user profiles separately.
      if (list.isNotEmpty && list[0]['users'] == null) {
        final enriched = await _enrichParticipantsWithUsers(list);
        return _enrichParticipantsWithSeminarAttendance(eventId, enriched);
      }

      return _enrichParticipantsWithSeminarAttendance(eventId, list);
    } catch (_) {
      // Strategy 2: if relational select fails, fetch base rows then enrich users.
      try {
        final base = await _supabase
            .from('event_registrations')
            .select('id, registered_at, student_id, tickets(*, attendance(*))')
            .eq('event_id', eventId)
            .order('registered_at', ascending: false);
        final enriched = await _enrichParticipantsWithUsers(
          List<Map<String, dynamic>>.from(base),
        );
        return _enrichParticipantsWithSeminarAttendance(eventId, enriched);
      } catch (_) {
        return [];
      }
    }
  }

  Future<bool> canTeacherManageAssistants(
    String eventId,
    String teacherId,
  ) async {
    try {
      final response = await _supabase
          .from('event_teacher_assignments')
          .select('id')
          .eq('event_id', eventId)
          .eq('teacher_id', teacherId)
          .eq('can_manage_assistants', true)
          .limit(1);
      return response.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> canTeacherScanEvent(String eventId, String teacherId) async {
    try {
      final response = await _supabase
          .from('event_teacher_assignments')
          .select('id')
          .eq('event_id', eventId)
          .eq('teacher_id', teacherId)
          .eq('can_scan', true)
          .limit(1);
      return response.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasTeacherAnyScanAccess(String teacherId) async {
    final now = DateTime.now().toUtc().toIso8601String();

    try {
      final assignmentRows = await _supabase
          .from('event_teacher_assignments')
          .select('event_id')
          .eq('teacher_id', teacherId)
          .eq('can_scan', true)
          .limit(50);

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
          .eq('status', 'published')
          .gte('end_at', now)
          .limit(1);
      return eventRows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> _enrichParticipantsWithUsers(
    List<Map<String, dynamic>> regs,
  ) async {
    if (regs.isEmpty) return regs;

    final ids = regs
        .map((r) => r['student_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();

    if (ids.isEmpty) return regs;

    try {
      final usersRes = await _supabase
          .from('users')
          .select(
            'id, first_name, middle_name, last_name, suffix, email, student_id',
          )
          .inFilter('id', ids);

      final users = List<Map<String, dynamic>>.from(usersRes);
      final byId = <String, Map<String, dynamic>>{};
      for (final u in users) {
        final uid = u['id']?.toString() ?? '';
        if (uid.isNotEmpty) byId[uid] = u;
      }

      final enriched = <Map<String, dynamic>>[];
      for (final reg in regs) {
        final item = Map<String, dynamic>.from(reg);
        final sid = item['student_id']?.toString() ?? '';
        if (sid.isNotEmpty && byId.containsKey(sid)) {
          final u = byId[sid]!;
          item['users'] = {
            'first_name': u['first_name'],
            'middle_name': u['middle_name'],
            'last_name': u['last_name'],
            'suffix': u['suffix'],
            'email': u['email'],
            'student_id': u['student_id'],
            // Keep compatibility with existing UI renderers.
            'id_number': u['id_number'] ?? u['student_id'],
            'course': u['course'],
            'year_level': u['year_level'],
          };
        }
        enriched.add(item);
      }
      return enriched;
    } catch (_) {
      return regs;
    }
  }

  // Get assistants (authorized student scanners) for a specific event
  Future<List<Map<String, dynamic>>> getEventAssistants(String eventId) async {
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
    if (assistants.isEmpty) return assistants;

    final ids = assistants
        .map((a) => a['student_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();

    if (ids.isEmpty) return assistants;

    try {
      final usersRes = await _supabase
          .from('users')
          .select('id, first_name, middle_name, last_name, suffix, student_id')
          .inFilter('id', ids);

      final users = List<Map<String, dynamic>>.from(usersRes);
      final byId = <String, Map<String, dynamic>>{};
      for (final u in users) {
        final uid = u['id']?.toString() ?? '';
        if (uid.isNotEmpty) byId[uid] = u;
      }

      final enriched = <Map<String, dynamic>>[];
      for (final a in assistants) {
        final item = Map<String, dynamic>.from(a);
        final sid = item['student_id']?.toString() ?? '';
        if (sid.isNotEmpty) {
          final u = byId[sid];
          if (u != null) {
            item['users'] = {
              'first_name': u['first_name'],
              'middle_name': u['middle_name'],
              'last_name': u['last_name'],
              'suffix': u['suffix'],
              'id_number': u['id_number'] ?? u['student_id'],
              'student_id': u['student_id'],
            };
          }
        }
        enriched.add(item);
      }
      return enriched;
    } catch (_) {
      return assistants;
    }
  }

  // Assign or re-assign assistant access for an event.
  Future<Map<String, dynamic>> assignEventAssistant({
    required String eventId,
    required String studentId,
    required String teacherId,
    bool allowScan = true,
  }) async {
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
          .eq('student_id', studentId)
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

    final payload = {
      'event_id': eventId,
      'student_id': studentId,
      'allow_scan': allowScan,
      'assigned_by_teacher_id': teacherId,
    };

    try {
      final res = await _supabase
          .from('event_assistants')
          .upsert(payload, onConflict: 'event_id,student_id')
          .select(
            'id, event_id, student_id, allow_scan, assigned_by_teacher_id',
          );

      final list = List<Map<String, dynamic>>.from(res);
      return {'ok': true, 'assistant': list.isNotEmpty ? list.first : payload};
    } catch (e) {
      if (_isMissingAssistantsTableError(e)) {
        return {
          'ok': false,
          'error':
              'Assistant feature is not set up yet in your database. Please apply the latest Supabase migration first.',
        };
      }
      // Fallback when unique constraint for onConflict is unavailable.
      try {
        final existing = await _supabase
            .from('event_assistants')
            .select(
              'id, event_id, student_id, allow_scan, assigned_by_teacher_id',
            )
            .eq('event_id', eventId)
            .eq('student_id', studentId)
            .limit(1);

        if (existing.isNotEmpty) {
          await _supabase
              .from('event_assistants')
              .update({
                'allow_scan': allowScan,
                'assigned_by_teacher_id': teacherId,
              })
              .eq('event_id', eventId)
              .eq('student_id', studentId);
          final item = Map<String, dynamic>.from(existing.first);
          item['allow_scan'] = allowScan;
          item['assigned_by_teacher_id'] = teacherId;
          return {'ok': true, 'assistant': item};
        }

        final inserted = await _supabase
            .from('event_assistants')
            .insert(payload)
            .select(
              'id, event_id, student_id, allow_scan, assigned_by_teacher_id',
            );
        final list = List<Map<String, dynamic>>.from(inserted);
        return {
          'ok': true,
          'assistant': list.isNotEmpty ? list.first : payload,
        };
      } catch (fallbackError) {
        if (_isMissingAssistantsTableError(fallbackError)) {
          return {
            'ok': false,
            'error':
                'Assistant feature is not set up yet in your database. Please apply the latest Supabase migration first.',
          };
        }
        return {
          'ok': false,
          'error': 'Failed to assign assistant. Please try again.',
          'debug': e.toString(),
        };
      }
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

    try {
      final normalizedId = assistantId?.toString() ?? '';
      if (normalizedId.isNotEmpty) {
        await _supabase
            .from('event_assistants')
            .update({
              'allow_scan': allowScan,
              'assigned_by_teacher_id': teacherId,
            })
            .eq('id', normalizedId);
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
    String teacherId,
  ) async {
    if (!ticketPayload.startsWith('PULSE-')) {
      return {
        'ok': false,
        'error': 'Invalid QR Code Format',
        'status': 'invalid',
      };
    }

    final ticketId = ticketPayload.replaceFirst('PULSE-', '').trim();

    try {
      final scanContext = await getTeacherScanContext(teacherId);
      if (scanContext['ok'] != true) {
        return {
          'ok': false,
          'error':
              scanContext['message']?.toString() ??
              'Unable to load scanner context.',
          'status': scanContext['status']?.toString() ?? 'error',
        };
      }

      final contextStatus = (scanContext['status']?.toString() ?? '')
          .toLowerCase();
      if (contextStatus != 'open') {
        return {
          'ok': false,
          'error':
              scanContext['message']?.toString() ??
              'Scanner is not open for this schedule.',
          'status': contextStatus.isEmpty ? 'closed' : contextStatus,
        };
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

      String ticketEventId = '';
      String registrationId = '';

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
            ticketEventId = reg['event_id']?.toString() ?? '';
          } else if (reg is List && reg.isNotEmpty && reg.first is Map) {
            ticketEventId = (reg.first as Map)['event_id']?.toString() ?? '';
          }
        }
      } catch (_) {
        // fallback query below
      }

      if (ticketEventId.isEmpty || registrationId.isEmpty) {
        final ticketBaseRes = await _supabase
            .from('tickets')
            .select('id, registration_id')
            .eq('id', ticketId)
            .limit(1);

        if (ticketBaseRes.isEmpty) {
          return {
            'ok': false,
            'error': 'Ticket not found in the system.',
            'status': 'invalid',
          };
        }

        registrationId =
            ticketBaseRes.first['registration_id']?.toString() ??
            registrationId;
        if (registrationId.isNotEmpty) {
          final regRes = await _supabase
              .from('event_registrations')
              .select('event_id')
              .eq('id', registrationId)
              .limit(1);
          if (regRes.isNotEmpty) {
            ticketEventId = regRes.first['event_id']?.toString() ?? '';
          }
        }
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
          'error': 'Ticket is not for the current active event/seminar.',
          'status': 'wrong_event',
        };
      }

      final nowIso = DateTime.now().toUtc().toIso8601String();
      final participantName = await _resolveParticipantNameForRegistration(
        registrationId,
      );
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
          session: session,
          participantName: participantName,
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
        return {
          'ok': false,
          'error': 'Ticket already checked in.',
          'status': 'already_checked_in',
        };
      }

      await _supabase
          .from('attendance')
          .update({
            'status': 'present',
            'check_in_at': nowIso,
            'last_scanned_at': nowIso,
          })
          .eq('ticket_id', ticketId);

      return {
        'ok': true,
        'ticket_id': ticketId,
        'status': 'present',
        'participant_name': participantName,
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
    String studentId,
  ) async {
    if (!ticketPayload.startsWith('PULSE-')) {
      return {
        'ok': false,
        'error': 'Invalid QR Code Format',
        'status': 'invalid',
      };
    }

    final ticketId = ticketPayload.replaceFirst('PULSE-', '').trim();

    try {
      final scanContext = await getStudentScanContext(studentId);
      if (scanContext['ok'] != true) {
        return {
          'ok': false,
          'error':
              scanContext['message']?.toString() ??
              'Unable to load scanner context.',
          'status': scanContext['status']?.toString() ?? 'error',
        };
      }

      final contextStatus = (scanContext['status']?.toString() ?? '')
          .toLowerCase();
      if (contextStatus != 'open') {
        return {
          'ok': false,
          'error':
              scanContext['message']?.toString() ??
              'Scanner is not open for this schedule.',
          'status': contextStatus.isEmpty ? 'closed' : contextStatus,
        };
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

      String ticketEventId = '';
      String registrationId = '';

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
            ticketEventId = reg['event_id']?.toString() ?? '';
          } else if (reg is List && reg.isNotEmpty && reg.first is Map) {
            ticketEventId = (reg.first as Map)['event_id']?.toString() ?? '';
          }
        }
      } catch (_) {
        // fallback query below
      }

      if (ticketEventId.isEmpty || registrationId.isEmpty) {
        final ticketBaseRes = await _supabase
            .from('tickets')
            .select('id, registration_id')
            .eq('id', ticketId)
            .limit(1);

        if (ticketBaseRes.isEmpty) {
          return {
            'ok': false,
            'error': 'Ticket not found in the system.',
            'status': 'invalid',
          };
        }

        registrationId =
            ticketBaseRes.first['registration_id']?.toString() ??
            registrationId;
        if (registrationId.isNotEmpty) {
          final regRes = await _supabase
              .from('event_registrations')
              .select('event_id')
              .eq('id', registrationId)
              .limit(1);
          if (regRes.isNotEmpty) {
            ticketEventId = regRes.first['event_id']?.toString() ?? '';
          }
        }
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
          'error': 'Ticket is not for the current active event/seminar.',
          'status': 'wrong_event',
        };
      }

      final nowIso = DateTime.now().toUtc().toIso8601String();
      final participantName = await _resolveParticipantNameForRegistration(
        registrationId,
      );
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
          session: session,
          participantName: participantName,
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
        return {
          'ok': false,
          'error': 'Ticket already checked in.',
          'status': 'already_checked_in',
        };
      }

      await _supabase
          .from('attendance')
          .update({
            'status': 'present',
            'check_in_at': nowIso,
            'last_scanned_at': nowIso,
          })
          .eq('ticket_id', ticketId);

      return {
        'ok': true,
        'ticket_id': ticketId,
        'status': 'present',
        'participant_name': participantName,
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
          'error': 'Ticket not found in the system.',
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

      if (eventPayloads.isNotEmpty) {
        await _supabase.from('evaluation_answers').upsert(eventPayloads);
      }
      if (sessionPayloads.isNotEmpty) {
        await _supabase
            .from('event_session_evaluation_answers')
            .upsert(sessionPayloads);
      }

      return {'ok': true};
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
          .select('status, check_in_at')
          .eq('ticket_id', ticketId)
          .limit(1);
      if (rows.isEmpty) return false;
      return _hasCheckInRecord(Map<String, dynamic>.from(rows.first));
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
            .select('session_id, status, check_in_at')
            .eq('registration_id', registrationId);
        for (final row in List<Map<String, dynamic>>.from(rows)) {
          if (!_hasCheckInRecord(row)) continue;
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
            .select('session_id, status, check_in_at')
            .eq('ticket_id', ticketId)
            .not('session_id', 'is', null);
        for (final row in List<Map<String, dynamic>>.from(rows)) {
          if (!_hasCheckInRecord(row)) continue;
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
              'No attended seminar sessions were found for this student.',
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
        'message': 'No attendance record found for this event.',
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
  }) async {
    final nowUtc = DateTime.now().toUtc();
    List<Map<String, dynamic>> publishedEvents = [];

    try {
      final response = await _supabase
          .from('events')
          .select()
          .inFilter('status', ['published', 'expired', 'finished', 'archived'])
          .order('end_at', ascending: false);
      // Evaluation visibility should follow registration + attendance eligibility,
      // not the list-level year filter, because students may already be registered
      // for older events whose targeting format changed over time.
      publishedEvents = List<Map<String, dynamic>>.from(response);
    } catch (_) {
      publishedEvents = [];
    }

    final visibleResults = await Future.wait(
      publishedEvents.map((event) async {
        final eventId = event['id']?.toString() ?? '';
        if (eventId.isEmpty) return null;

        List<Map<String, dynamic>> sessions = const [];
        if (_eventUsesSessions(event)) {
          sessions = await _fetchSessionsForEvent(eventId);
        }

        final effectiveEnd = _effectiveEventEndAt(event, sessions);
        if (effectiveEnd == null || effectiveEnd.isAfter(nowUtc)) {
          return null;
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

        return <String, dynamic>{
          ...event,
          if (sessions.isNotEmpty) 'sessions': sessions,
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

    return visible;
  }

  String _absenceScopeKey(String eventId, {String? sessionId}) {
    final sid = sessionId?.trim() ?? '';
    return sid.isEmpty ? '$eventId::event' : '$eventId::session::$sid';
  }

  Future<List<Map<String, dynamic>>> _fetchStudentRegistrationRowsWithEvents(
    String studentId,
  ) async {
    final selectVariants = <String>[
      'id,event_id,registered_at,events(id,title,start_at,end_at,status,location,event_mode,event_structure,uses_sessions)',
      'id,event_id,registered_at,events(id,title,start_at,end_at,status,location,event_structure,uses_sessions)',
      'id,event_id,registered_at,events(id,title,start_at,end_at,status,location,uses_sessions)',
      'id,event_id,registered_at,events(id,title,start_at,end_at,status,location)',
    ];

    for (final selectClause in selectVariants) {
      try {
        final rows = await _supabase
            .from('event_registrations')
            .select(selectClause)
            .eq('student_id', studentId)
            .order('registered_at', ascending: false);
        return List<Map<String, dynamic>>.from(rows);
      } catch (_) {
        // Try next projection for backward-compatible schemas.
      }
    }

    return [];
  }

  Future<Map<String, Map<String, dynamic>>> _loadStudentAbsenceReasonMap(
    String studentId,
  ) async {
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
        return mapped;
      }
      return mapped;
    }

    return mapped;
  }

  Future<List<Map<String, dynamic>>> getStudentPendingAbsenceScopes({
    required String studentId,
  }) async {
    if (studentId.trim().isEmpty) return [];

    final pending = <Map<String, dynamic>>[];
    final seenKeys = <String>{};
    final nowUtc = DateTime.now().toUtc();
    final reasonMap = await _loadStudentAbsenceReasonMap(studentId);

    final registrationRows = await _fetchStudentRegistrationRowsWithEvents(
      studentId,
    );
    if (registrationRows.isEmpty) {
      return [];
    }

    for (final reg in registrationRows) {
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
      String ticketId = '';
      try {
        final ticketRows = await _supabase
            .from('tickets')
            .select('id')
            .eq('registration_id', registrationId)
            .limit(1);
        if (ticketRows.isNotEmpty) {
          ticketId = ticketRows.first['id']?.toString() ?? '';
        }
      } catch (_) {
        // Leave ticketId empty when ticket lookup is unavailable.
      }

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
        } catch (_) {
          // Fallback to direct table reads for deployments without RPC.
        }

        if (!loadedFromSnapshot && await _supportsEventSessionAttendanceTable()) {
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
          } catch (_) {
            // Ignore fallback read failure and continue.
          }
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
        final lockAt = latestWindowClose ?? latestSessionEnd ?? _toUtcDate(event['end_at']);
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
      final closesAt = eventStartAt.add(const Duration(minutes: 30));
      if (!nowUtc.isAfter(closesAt)) {
        continue;
      }
      final eventEndAt = _toUtcDate(event['end_at']);
      final lockAt = eventEndAt ?? closesAt;
      if (!nowUtc.isAfter(lockAt)) {
        continue;
      }

      var present = false;
      if (ticketId.isNotEmpty) {
        try {
          final attendanceRows = await _supabase
              .from('attendance')
              .select('status,check_in_at')
              .eq('ticket_id', ticketId)
              .limit(1);
          if (attendanceRows.isNotEmpty) {
            present = _attendanceRecordCountsAsPresent(
              Map<String, dynamic>.from(attendanceRows.first),
            );
          }
        } catch (_) {
          present = false;
        }
      }

      if (present) continue;

      // Strict rule for simple events: only trigger if explicitly absent.
      bool explicitlyAbsent = false;
      if (ticketId.isNotEmpty) {
        try {
          final absentRows = await _supabase
              .from('attendance')
              .select('status')
              .eq('ticket_id', ticketId)
              .eq('status', 'absent')
              .limit(1);
          explicitlyAbsent = absentRows.isNotEmpty;
        } catch (_) {
          explicitlyAbsent = false;
        }
      }
      if (!explicitlyAbsent) continue;

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

      if (existingId.isNotEmpty) {
        await _supabase
            .from('attendance_absence_reasons')
            .update(payload)
            .eq('id', existingId);
      } else {
        await _supabase.from('attendance_absence_reasons').insert(payload);
      }

      return {'ok': true};
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
      final now = DateTime.now();
      await _supabase
          .from('attendance')
          .update({'check_out_at': now.toIso8601String()})
          .eq('ticket_id', ticketId);
      return {'ok': true, 'message': 'Check-out recorded!'};
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

