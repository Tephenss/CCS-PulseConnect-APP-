import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_cache_service.dart';
import 'event_service.dart';
import 'notification_service.dart';
import 'public_catalog_service.dart';

/// Broadcasts debounced live-data refresh signals for events-related screens.
class EventLiveService {
  EventLiveService._();

  static final EventLiveService instance = EventLiveService._();

  final _supabase = Supabase.instance.client;
  final _controller = StreamController<String>.broadcast();
  final Connectivity _connectivity = Connectivity();

  RealtimeChannel? _channel;
  String? _activeUserId;
  Timer? _debounceTimer;
  bool _started = false;

  Stream<String> get changes => _controller.stream;

  Future<bool> _isOfflineNow() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return results.isEmpty ||
          results.every((result) => result == ConnectivityResult.none);
    } catch (_) {
      // Prefer offline-safe behavior when connectivity status is unknown.
      return true;
    }
  }

  void _schedule(
    String reason, {
    Duration delay = const Duration(milliseconds: 120),
  }) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(delay, () async {
      // While offline, keep warm memory/disk caches and only soft-signal UI
      // so screens can reload from cache without wiping lists.
      final offline = await _isOfflineNow();
      if (offline) {
        if (!_controller.isClosed) {
          _controller.add('offline:$reason');
        }
        return;
      }

      // Soft-invalidate only in-flight fetch coalescing — keep disk + warm memory
      // until a successful refresh replaces them. Hard-clearing memory during
      // flaky connectivity made tickets/events flash empty offline.
      AppCacheService().cancelInFlightPrefix('fetch:');
      // Archive/delete/publish must drop list caches so empty fetches can clear UI.
      if (reason == 'events' ||
          reason.startsWith('events:') ||
          reason.startsWith('push:')) {
        EventService.invalidateEventListCache();
        unawaited(PublicCatalogService.instance.invalidateLocal());
      }
      // New registrations/tickets must drop TTL cache or Tickets tab stays stale.
      if (reason == 'tickets' ||
          reason == 'registrations' ||
          reason.startsWith('tickets:') ||
          reason.startsWith('registrations:') ||
          reason.contains('registrations') ||
          reason.contains('tickets')) {
        unawaited(EventService().invalidateMyTicketsCache());
      }
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

  /// Local write completed on this device (register / checkout) — refresh UIs.
  void pulseLocal([String reason = 'tickets']) {
    final label = reason.trim().isEmpty ? 'tickets' : reason.trim();
    _schedule(label, delay: Duration.zero);
  }

  /// Tickets tab only — skip notification/catalog side effects.
  void pulseTicketsUi() {
    unawaited(() async {
      await EventService().invalidateMyTicketsCache();
      AppCacheService().cancelInFlightPrefix('fetch:tickets:');
      if (!_controller.isClosed) {
        _controller.add('tickets');
      }
    }());
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

    // Proposal requirements remain SELECT-open after 052; documents/submissions
    // and student requirement tables are locked — do not Realtime-subscribe
    // (anon auth fails → Postgres ERROR spam on every connect).
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'event_proposal_requirements',
      callback: (_) => _schedule('proposal_requirements'),
    );

    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'attendance',
      callback: (_) => _schedule('attendance'),
    );

    // Inbox / student docs: locked after 048 — poll via BFF / FCM instead.
    if (_activeUserId != null) {
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
