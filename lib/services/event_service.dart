import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:crypto/crypto.dart';
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
          .select('*, events(title, location, start_at, end_at), tickets(token)')
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
}
