import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'event_service.dart';
import 'notification_service.dart';

/// Broadcasts debounced live-data refresh signals for events-related screens.
class EventLiveService {
  EventLiveService._();

  static final EventLiveService instance = EventLiveService._();

  final _supabase = Supabase.instance.client;
  final _controller = StreamController<String>.broadcast();

  RealtimeChannel? _channel;
  String? _activeUserId;
  Timer? _debounceTimer;
  bool _started = false;

  Stream<String> get changes => _controller.stream;

  void _schedule(
    String reason, {
    Duration delay = const Duration(milliseconds: 120),
  }) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(delay, () {
      EventService.invalidateEventListCache();
      // Requirement review status lives outside list cache — clear it on live pulses.
      if (reason.contains('student_requirements') ||
          reason.contains('student_submissions') ||
          reason.contains('registration_access') ||
          reason.startsWith('push:')) {
        EventService().clearStudentRequirementsCache();
      }
      NotificationService().invalidateLiveCaches();
      unawaited(NotificationService().refresh(force: true));
      if (!_controller.isClosed) {
        _controller.add(reason);
      }
    });
  }

  /// Instant UI sync when FCM arrives (often ahead of Supabase realtime).
  void pulseFromPush([String reason = 'push']) {
    final label = reason.trim().isEmpty ? 'push' : 'push:$reason';
    // Zero delay — push means the write already happened server-side.
    _schedule(label, delay: Duration.zero);
  }

  /// Faster targeted pulse for document review (approve/decline).
  void pulseStudentRequirementsReview({
    required String eventId,
    required String type,
  }) {
    final id = eventId.trim();
    final kind = type.trim().toLowerCase();
    if (id.isNotEmpty) {
      EventService().clearStudentRequirementsCache(id);
    } else {
      EventService().clearStudentRequirementsCache();
    }
    final reason = id.isEmpty
        ? 'push:$kind'
        : 'push:$kind:$id';
    _schedule(reason, delay: Duration.zero);
  }

  void start({String? userId}) {
    final nextUserId = (userId ?? '').trim();
    if (_started && _activeUserId == nextUserId) {
      return;
    }

    stop();
    _activeUserId = nextUserId.isEmpty ? null : nextUserId;
    _started = true;

    final channelName = 'pulse_event_live:${_activeUserId ?? 'guest'}';
    _channel = _supabase.channel(channelName);

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'events',
      callback: (_) => _schedule('events'),
    );

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_registrations',
      callback: (_) => _schedule('registrations'),
    );

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_registration_access',
      callback: (_) => _schedule('registration_access'),
    );

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_sessions',
      callback: (_) => _schedule('sessions'),
    );

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'tickets',
      callback: (_) => _schedule('tickets'),
    );

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'certificates',
      callback: (_) => _schedule('certificates'),
    );

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_teacher_assignments',
      callback: (_) => _schedule('teacher_assignments'),
    );

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_student_requirements',
      callback: (_) => _schedule('student_requirements'),
    );

    // Approve/decline patches this table — without it, UI stays on Under Review.
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_student_submissions',
      callback: (_) => _schedule('student_submissions'),
    );

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_proposal_requirements',
      callback: (_) => _schedule('proposal_requirements'),
    );

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_proposal_submissions',
      callback: (_) => _schedule('proposal_submissions'),
    );

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'attendance',
      callback: (_) => _schedule('attendance'),
    );

    if (_activeUserId != null) {
      _channel!.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'user_notifications',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'user_id',
          value: _activeUserId!,
        ),
        callback: (_) => _schedule('inbox'),
      );

      _channel!.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'event_assistants',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'student_id',
          value: _activeUserId!,
        ),
        callback: (_) => _schedule('assistants'),
      );
    }

    _channel!.subscribe();
  }

  void stop() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _channel?.unsubscribe();
    _channel = null;
    _activeUserId = null;
    _started = false;
  }
}
