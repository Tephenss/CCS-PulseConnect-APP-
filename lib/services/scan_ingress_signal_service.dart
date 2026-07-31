import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Listens to Firestore `scan_ingress_signals/{eventId}` (no PII).
/// PHP bumps `revision` on each scan ingress so clients can refresh roster
/// without polling Supabase.
class ScanIngressSignalService {
  ScanIngressSignalService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;
  final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>
      _subscriptions = {};

  void listenToEvent({
    required String eventId,
    required void Function(int revision) onRevision,
  }) {
    final id = eventId.trim();
    if (id.isEmpty) return;

    unawaited(cancelEvent(id));

    _subscriptions[id] = _db
        .collection('scan_ingress_signals')
        .doc(id)
        .snapshots()
        .listen(
      (snapshot) {
        if (!snapshot.exists) return;
        final data = snapshot.data();
        if (data == null || data.isEmpty) return;

        final raw = data['revision'];
        final revision = raw is int ? raw : int.tryParse('$raw') ?? 0;
        if (revision <= 0) return;
        onRevision(revision);
      },
      onError: (Object error, StackTrace stack) {
        debugPrint('ScanIngressSignalService.listenToEvent($id): $error');
      },
    );
  }

  Future<void> cancelEvent(String eventId) async {
    final id = eventId.trim();
    if (id.isEmpty) return;
    await _subscriptions.remove(id)?.cancel();
  }

  Future<void> cancelAll() async {
    final subs = _subscriptions.values.toList(growable: false);
    _subscriptions.clear();
    for (final sub in subs) {
      await sub.cancel();
    }
  }
}
