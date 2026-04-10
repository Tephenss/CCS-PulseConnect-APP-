import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math';

class EventService {
  final _supabase = Supabase.instance.client;

  bool _isMissingAssistantsTableError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('pgrst201') || msg.contains('ambiguous')) return false;
    return (msg.contains('event_assistants') && msg.contains('does not exist')) ||
        msg.contains('42p01') ||
        msg.contains('pgrst205');
  }

  bool _isMissingTeacherAssignmentsTableError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('pgrst201') || msg.contains('ambiguous')) return false;
    return (msg.contains('event_teacher_assignments') && msg.contains('does not exist')) ||
        msg.contains('42p01') ||
        msg.contains('pgrst205');
  }

  bool _isCheckedInStatus(dynamic rawStatus) {
    final status = (rawStatus?.toString() ?? '').toLowerCase();
    return status == 'scanned' ||
        status == 'present' ||
        status == 'late' ||
        status == 'early';
  }

  // Helper to filter events by target year level
  List<Map<String, dynamic>> _filterByYearLevel(List<Map<String, dynamic>> events, String? yearLevel) {
    if (yearLevel == null || yearLevel.isEmpty) return events;
    return events.where((e) {
      final target = e['event_for']?.toString().toLowerCase();
      if (target == null || target == 'all' || target == 'none' || target.isEmpty) return true;
      return target == yearLevel;
    }).toList();
  }

  static const Duration _minSecondsBeforeCheckout = Duration(seconds: 20);

  // Get all active/published events (ongoing + upcoming, not yet ended)
  Future<List<Map<String, dynamic>>> getActiveEvents({String? yearLevel}) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final response = await _supabase
          .from('events')
          .select()
          .eq('status', 'published')
          .gte('end_at', now)
          .order('start_at', ascending: true);
      final list = List<Map<String, dynamic>>.from(response);
      return _filterByYearLevel(list, yearLevel);
    } catch (e) {
      return [];
    }
  }

  // Get expired events (already ended)
  Future<List<Map<String, dynamic>>> getExpiredEvents({String? yearLevel}) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final response = await _supabase
          .from('events')
          .select()
          .eq('status', 'published')
          .lt('end_at', now)
          .order('end_at', ascending: false);
      final list = List<Map<String, dynamic>>.from(response);
      return _filterByYearLevel(list, yearLevel);
    } catch (e) {
      return [];
    }
  }

  // Get upcoming events (future events)
  Future<List<Map<String, dynamic>>> getUpcomingEvents({String? yearLevel}) async {
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
      final filtered = _filterByYearLevel(list, yearLevel);
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
      String eventId, String userId) async {
    try {
      // 1. Check if already registered
      final existing = await _supabase
          .from('event_registrations')
          .select('id')
          .eq('event_id', eventId)
          .eq('student_id', userId)
          .limit(1);

      if (existing.isNotEmpty) {
        return {'ok': false, 'error': 'You are already registered for this event.'};
      }

      // 2. Create registration
      final regRes = await _supabase.from('event_registrations').insert({
        'event_id': eventId,
        'student_id': userId,
      }).select().single();

      final regId = regRes['id'];

      // 3. Create ticket
      final token = _generateToken();
      final ticketRes = await _supabase.from('tickets').insert({
        'registration_id': regId,
        'token': token,
      }).select().single();

      final ticketId = ticketRes['id'];

      // 4. Create attendance
      await _supabase.from('attendance').insert({
        'ticket_id': ticketId,
        'status': 'unscanned',
      });

      return {'ok': true};
    } catch (e) {
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
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
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
      final response = await _supabase
          .from('certificates')
          .select('*, events(title, start_at)')
          .eq('student_id', userId)
          .order('issued_at', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
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
    try {
      // 1. Get events assigned to this teacher
      final assigned = await _supabase
          .from('event_teacher_assignments')
          .select('event_id, events(*)')
          .eq('teacher_id', teacherId);

      // 2. Get events created by this teacher (proposals/results)
      final created = await _supabase
          .from('events')
          .select()
          .eq('created_by', teacherId);

      final merged = <String, Map<String, dynamic>>{};

      // Add assigned events
      for (final row in List<Map<String, dynamic>>.from(assigned)) {
        final event = row['events'];
        if (event is Map) {
          final item = Map<String, dynamic>.from(event);
          final eventId = item['id']?.toString() ?? '';
          if (eventId.isNotEmpty) {
            merged[eventId] = item;
          }
        }
      }

      // Add/Overwrite with created events (to ensure we have creator context)
      for (final event in List<Map<String, dynamic>>.from(created)) {
        final eventId = event['id']?.toString() ?? '';
        if (eventId.isNotEmpty) {
          merged[eventId] = event;
        }
      }

      final list = merged.values.toList();
      list.sort((a, b) {
        final dateA = DateTime.tryParse(a['start_at']?.toString() ?? '') ?? DateTime(2000);
        final dateB = DateTime.tryParse(b['start_at']?.toString() ?? '') ?? DateTime(2000);
        return dateB.compareTo(dateA); // Descending (latest first)
      });

      return list;
    } catch (e) {
      if (_isMissingTeacherAssignmentsTableError(e)) {
        return getTeacherEvents(teacherId);
      }
      return [];
    }
  }

  // Get only UPCOMING accessible events for a specific teacher, max 5 limit
  Future<List<Map<String, dynamic>>> getTeacherUpcomingEvents(String teacherId) async {
    try {
      final allAccessible = await getTeacherAccessibleEvents(teacherId);
      final now = DateTime.now().toUtc();
      
      final upcoming = allAccessible.where((e) {
        if ((e['status']?.toString() ?? '').toLowerCase() != 'published') return false;
        final start = DateTime.tryParse(e['start_at']?.toString() ?? '');
        if (start == null) return false;
        return start.isAfter(now) || start.isAtSameMomentAs(now);
      }).toList();

      // Return ascending for upcoming
      upcoming.sort((a, b) {
        final dateA = DateTime.tryParse(a['start_at']?.toString() ?? '') ?? DateTime(2000);
        final dateB = DateTime.tryParse(b['start_at']?.toString() ?? '') ?? DateTime(2000);
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
      // Event status should forcefully start as 'pending' for Admin approval
      payload['status'] = 'pending';
      
      final response = await _supabase
          .from('events')
          .insert(payload)
          .select()
          .single();
      return {'ok': true, 'event': response};
    } catch (e) {
      return {'ok': false, 'error': 'Failed to create event: ${e.toString()}'};
    }
  }

  // Get participants (registered students) for a specific event
  Future<List<Map<String, dynamic>>> getEventParticipants(String eventId) async {
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
        return _enrichParticipantsWithUsers(list);
      }

      return list;
    } catch (_) {
      // Strategy 2: if relational select fails, fetch base rows then enrich users.
      try {
        final base = await _supabase
            .from('event_registrations')
            .select('id, registered_at, student_id, tickets(*, attendance(*))')
            .eq('event_id', eventId)
            .order('registered_at', ascending: false);
        return _enrichParticipantsWithUsers(List<Map<String, dynamic>>.from(base));
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
          .select('id, first_name, middle_name, last_name, suffix, email, student_id')
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
          .select('id, event_id, student_id, allow_scan, assigned_by_teacher_id')
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
          .select('id, event_id, student_id, allow_scan, assigned_by_teacher_id');

      final list = List<Map<String, dynamic>>.from(res);
      return {
        'ok': true,
        'assistant': list.isNotEmpty ? list.first : payload,
      };
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
            .select('id, event_id, student_id, allow_scan, assigned_by_teacher_id')
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
            .select('id, event_id, student_id, allow_scan, assigned_by_teacher_id');
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
            .update({'allow_scan': allowScan})
            .eq('id', normalizedId);
        return {'ok': true};
      }

      final sId = studentId?.toString() ?? '';
      if (eId.isEmpty || sId.isEmpty) {
        return {'ok': false, 'error': 'Missing assistant identity.'};
      }

      await _supabase
          .from('event_assistants')
          .update({'allow_scan': allowScan})
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
      String eventId = '';

      try {
        final ticketRes = await _supabase
            .from('tickets')
            .select('id, event_registrations!inner(event_id)')
            .eq('id', ticketId)
            .limit(1);

        if (ticketRes.isNotEmpty) {
          final reg = ticketRes.first['event_registrations'];
          eventId = reg is Map ? reg['event_id']?.toString() ?? '' : '';
        }
      } catch (_) {
        // Fallback path for deployments where this relation select fails.
      }

      if (eventId.isEmpty) {
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

        final registrationId = ticketBaseRes.first['registration_id']?.toString() ?? '';
        if (registrationId.isNotEmpty) {
          final regRes = await _supabase
              .from('event_registrations')
              .select('event_id')
              .eq('id', registrationId)
              .limit(1);
          if (regRes.isNotEmpty) {
            eventId = regRes.first['event_id']?.toString() ?? '';
          }
        }
      }

      if (eventId.isEmpty) {
        return {
          'ok': false,
          'error': 'Event lookup failed for this ticket.',
          'status': 'invalid',
        };
      }

      final canScan = await canTeacherScanEvent(eventId, teacherId);
      if (!canScan) {
        return {
          'ok': false,
          'error': 'You are not assigned to scan this event.',
          'status': 'forbidden',
        };
      }

      return checkInParticipant(ticketPayload);
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
      };
    }
  }

  // Check in a participant via their ticket token/ID
  // Enhanced with time validation matching JADX QRCheckInActivity logic
  Future<Map<String, dynamic>> checkInParticipant(String ticketPayload) async {
    try {
      // Expecting payload like "PULSE-{UUID}"
      if (!ticketPayload.startsWith('PULSE-')) {
        return {'ok': false, 'error': 'Invalid QR Code Format', 'status': 'invalid'};
      }

      final ticketId = ticketPayload.replaceFirst('PULSE-', '').trim();

      // 1. Find attendance record + ticket + registration + event
      final existingParams = await _supabase
          .from('attendance')
          .select('*')
          .eq('ticket_id', ticketId)
          .limit(1);

      if (existingParams.isEmpty) {
        return {'ok': false, 'error': 'Ticket not found in the system.', 'status': 'invalid'};
      }

      final attendance = existingParams[0];
      final isCheckedIn = _isCheckedInStatus(attendance['status']);

      // 2. Get event info via ticket -> registration -> event
      Map<String, dynamic>? eventData;
      try {
        final ticketRes = await _supabase
            .from('tickets')
            .select('id, registration_id, event_registrations!inner(event_id, events!inner(*))')
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
            final registrationId = ticketBaseRes.first['registration_id']?.toString() ?? '';
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
        final startAt = eventData['start_at'] != null ? DateTime.tryParse(eventData['start_at']) : null;
        final endAt = eventData['end_at'] != null ? DateTime.tryParse(eventData['end_at']) : null;
        final graceMinutes = int.tryParse(eventData['grace_time']?.toString() ?? '0') ?? 0;

        if (startAt != null) {
          // Too early check - more than 30 minutes before start
          if (now.isBefore(startAt.subtract(const Duration(minutes: 30)))) {
            return {
              'ok': false,
              'error': 'Event hasn\'t started yet. Check-in opens 30 minutes before the event.',
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
              return {'ok': true, 'status': 'checked_out', 'message': 'Check-out recorded! Event has ended.'};
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
              return {'ok': false, 'error': 'Ticket already fully used (checked in & out).', 'status': 'used'};
            }

            final checkInAt = attendance['check_in_at'] != null
                ? DateTime.tryParse(attendance['check_in_at'].toString())
                : null;
            if (checkInAt != null && now.difference(checkInAt).abs() < _minSecondsBeforeCheckout) {
              return {
                'ok': false,
                'error': 'Already checked in. Please wait a few seconds before scanning again.',
                'status': 'already_checked_in',
              };
            }

            await _supabase
                .from('attendance')
                .update({'check_out_at': now.toIso8601String()})
                .eq('ticket_id', ticketId);
            return {'ok': true, 'status': 'checked_out', 'message': 'Check-out successful!'};
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
          final checkInStatus = isEarly ? 'early' : (isLate ? 'late' : 'present');
          final checkInMessage = isEarly
              ? 'Check-in successful (EARLY)'
              : (isLate ? 'Check-in successful (LATE)' : 'Check-in successful - On Time!');

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
        return {'ok': false, 'error': 'Ticket has already been scanned.', 'status': 'used'};
      }

      await _supabase
          .from('attendance')
          .update({
            'status': 'present',
            'check_in_at': DateTime.now().toIso8601String(),
          })
          .eq('ticket_id', ticketId);

      return {'ok': true, 'ticket_id': ticketId, 'status': 'present', 'message': 'Check-in successful!'};
    } catch (e) {
      final msg = e.toString().toLowerCase();
      final likelyOffline = msg.contains('socketexception') ||
          msg.contains('timed out') ||
          msg.contains('failed host lookup') ||
          msg.contains('network');

      String errorMessage = likelyOffline
          ? 'Check-in failed. Check internet connection.'
          : 'Check-in failed. Please try again.';

      if (!likelyOffline) {
        if (msg.contains('attendance_status_check')) {
          errorMessage = 'Check-in failed due to attendance status mismatch.';
        } else if (msg.contains('permission denied') || msg.contains('row level security')) {
          errorMessage = 'Check-in failed due to access policy. Please contact admin.';
        }
      }

      return {
        'ok': false,
        'error': errorMessage,
        'status': 'error',
      };
    }
  }

  // Get evaluation questions for an event
  Future<List<Map<String, dynamic>>> getEvaluationQuestions(String eventId) async {
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
      final payloads = answers.map((ans) => {
        'event_id': eventId,
        'question_id': ans['question_id'],
        'student_id': studentId,
        'answer_text': ans['answer_text'].toString(),
        'submitted_at': DateTime.now().toIso8601String(),
      }).toList();

      if (payloads.isEmpty) return {'ok': false, 'error': 'No answers provided.'};

      await _supabase.from('evaluation_answers').upsert(payloads);

      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': 'Evaluation submission failed.'};
    }
  }

  // Check if evaluation is already submitted
  Future<bool> isEvaluationSubmitted(String eventId, String studentId) async {
    try {
      final res = await _supabase
          .from('evaluation_answers')
          .select('id')
          .eq('event_id', eventId)
          .eq('student_id', studentId)
          .limit(1);
      return res.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  // Get student's submitted answers for an event
  Future<List<Map<String, dynamic>>> getStudentAnswers(String eventId, String studentId) async {
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
