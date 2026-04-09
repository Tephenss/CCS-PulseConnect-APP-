import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math';

class EventService {
  final _supabase = Supabase.instance.client;

  bool _isMissingAssistantsTableError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('event_assistants') ||
        msg.contains('42p01') ||
        msg.contains('pgrst205');
  }

  // Get all active/published events (ongoing + upcoming, not yet ended)
  Future<List<Map<String, dynamic>>> getActiveEvents() async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final response = await _supabase
          .from('events')
          .select()
          .eq('status', 'published')
          .gte('end_at', now)
          .order('start_at', ascending: true);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }

  // Get expired events (already ended)
  Future<List<Map<String, dynamic>>> getExpiredEvents() async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final response = await _supabase
          .from('events')
          .select()
          .eq('status', 'published')
          .lt('end_at', now)
          .order('end_at', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }

  // Get upcoming events (future events)
  Future<List<Map<String, dynamic>>> getUpcomingEvents() async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final response = await _supabase
          .from('events')
          .select()
          .eq('status', 'published')
          .gte('start_at', now)
          .order('start_at', ascending: true)
          .limit(5);
      return List<Map<String, dynamic>>.from(response);
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
      final response = await _supabase
          .from('event_assistants')
          .select(
            'id, event_id, student_id, allow_scan, '
            'users(first_name, middle_name, last_name, suffix, student_id)'
          )
          .eq('event_id', eventId);

      final list = List<Map<String, dynamic>>.from(response);

      // If relation mapping didn't include users, enrich manually.
      if (list.isNotEmpty && list[0]['users'] == null) {
        return _enrichAssistantsWithUsers(list);
      }
      return list;
    } catch (e) {
      if (_isMissingAssistantsTableError(e)) {
        // Keep UI stable if migration is not yet applied.
        return [];
      }
      try {
        // Fallback if relational select fails due schema relation mismatch.
        final base = await _supabase
            .from('event_assistants')
            .select('id, event_id, student_id, allow_scan')
            .eq('event_id', eventId);
        final list = List<Map<String, dynamic>>.from(base);
        return _enrichAssistantsWithUsers(list);
      } catch (_) {
        return [];
      }
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
    bool allowScan = true,
  }) async {
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
    };

    try {
      final res = await _supabase
          .from('event_assistants')
          .upsert(payload, onConflict: 'event_id,student_id')
          .select('id, event_id, student_id, allow_scan');

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
            .select('id, event_id, student_id, allow_scan')
            .eq('event_id', eventId)
            .eq('student_id', studentId)
            .limit(1);

        if (existing.isNotEmpty) {
          await _supabase
              .from('event_assistants')
              .update({'allow_scan': allowScan})
              .eq('event_id', eventId)
              .eq('student_id', studentId);
          final item = Map<String, dynamic>.from(existing.first);
          item['allow_scan'] = allowScan;
          return {'ok': true, 'assistant': item};
        }

        final inserted = await _supabase
            .from('event_assistants')
            .insert(payload)
            .select('id, event_id, student_id, allow_scan');
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
    required bool allowScan,
  }) async {
    try {
      final normalizedId = assistantId?.toString() ?? '';
      if (normalizedId.isNotEmpty) {
        await _supabase
            .from('event_assistants')
            .update({'allow_scan': allowScan})
            .eq('id', normalizedId);
        return {'ok': true};
      }

      final eId = eventId?.toString() ?? '';
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

      // 2. Get event info via ticket → registration → event
      final ticketRes = await _supabase
          .from('tickets')
          .select('id, registration_id, event_registrations!inner(event_id, events!inner(*))')
          .eq('id', ticketId)
          .limit(1);

      Map<String, dynamic>? eventData;
      if (ticketRes.isNotEmpty) {
        final reg = ticketRes[0]['event_registrations'];
        if (reg != null) {
          eventData = reg['events'] as Map<String, dynamic>?;
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
            if (attendance['status'] == 'scanned' && attendance['check_out_at'] == null) {
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

          // Already scanned - allow check-out
          if (attendance['status'] == 'scanned') {
            if (attendance['check_out_at'] != null) {
              return {'ok': false, 'error': 'Ticket already fully used (checked in & out).', 'status': 'used'};
            }
            // Check-out
            await _supabase
                .from('attendance')
                .update({'check_out_at': now.toIso8601String()})
                .eq('ticket_id', ticketId);
            return {'ok': true, 'status': 'checked_out', 'message': 'Check-out successful!'};
          }

          // Determine if late
          bool isLate = false;
          if (graceMinutes > 0) {
            final graceDeadline = startAt.add(Duration(minutes: graceMinutes));
            isLate = now.isAfter(graceDeadline);
          } else {
            isLate = now.isAfter(startAt);
          }

          // Perform check-in
          await _supabase
              .from('attendance')
              .update({
                'status': 'scanned',
                'check_in_at': now.toIso8601String(),
              })
              .eq('ticket_id', ticketId);

          return {
            'ok': true,
            'ticket_id': ticketId,
            'status': isLate ? 'late' : 'on_time',
            'message': isLate ? 'Check-in successful (LATE)' : 'Check-in successful — On Time!',
          };
        }
      }

      // Fallback: no event timing data, just check in
      if (attendance['status'] == 'scanned') {
        return {'ok': false, 'error': 'Ticket has already been scanned.', 'status': 'used'};
      }

      await _supabase
          .from('attendance')
          .update({
            'status': 'scanned',
            'check_in_at': DateTime.now().toIso8601String(),
          })
          .eq('ticket_id', ticketId);

      return {'ok': true, 'ticket_id': ticketId, 'status': 'on_time', 'message': 'Check-in successful!'};
    } catch (e) {
      return {'ok': false, 'error': 'Check-in failed. Check internet connection.', 'status': 'error'};
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

