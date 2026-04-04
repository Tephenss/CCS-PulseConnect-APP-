import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math';

class EventService {
  final _supabase = Supabase.instance.client;

  // Get all active/published events (that haven't started yet)
  Future<List<Map<String, dynamic>>> getActiveEvents() async {
    try {
      final now = DateTime.now().toIso8601String();
      final response = await _supabase
          .from('events')
          .select()
          .eq('status', 'published')
          .gte('start_at', now)
          .order('start_at', ascending: true);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }

  // Get expired events (past events)
  Future<List<Map<String, dynamic>>> getExpiredEvents() async {
    try {
      final now = DateTime.now().toIso8601String();
      final response = await _supabase
          .from('events')
          .select()
          .eq('status', 'published')
          .lt('start_at', now)
          .order('start_at', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }

  // Get upcoming events (future events)
  Future<List<Map<String, dynamic>>> getUpcomingEvents() async {
    try {
      final now = DateTime.now().toIso8601String();
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
      // Strategy 1: Try joining users directly (works if FK is named 'student_id' → users.id)
      final response = await _supabase
          .from('event_registrations')
          .select(
            'id, registered_at, student_id, '
            'users(first_name, last_name, email, id_number, course, year_level), '
            'tickets(*, attendance(*))'
          )
          .eq('event_id', eventId)
          .order('registered_at', ascending: false);
      
      final list = List<Map<String, dynamic>>.from(response);
      
      // If no users data came through, try fetching user profiles separately
      if (list.isNotEmpty && list[0]['users'] == null) {
        // Strategy 2: Fetch user data separately per registration
        final enriched = <Map<String, dynamic>>[];
        for (final reg in list) {
          final studentId = reg['student_id']?.toString() ?? '';
          if (studentId.isNotEmpty) {
            try {
              final userRes = await _supabase
                  .from('users')
                  .select('first_name, last_name, email, id_number, course, year_level')
                  .eq('id', studentId)
                  .limit(1);
              final enrichedReg = Map<String, dynamic>.from(reg);
              enrichedReg['users'] = userRes.isNotEmpty ? userRes[0] : null;
              enriched.add(enrichedReg);
            } catch (_) {
              enriched.add(reg);
            }
          } else {
            enriched.add(reg);
          }
        }
        return enriched;
      }
      
      return list;
    } catch (e) {
      return [];
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
