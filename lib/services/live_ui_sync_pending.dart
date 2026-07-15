import 'package:shared_preferences/shared_preferences.dart';

/// Prefs-only helpers safe for the FCM background isolate.
class LiveUiSyncPending {
  LiveUiSyncPending._();

  static const pendingAtKey = 'pending_live_ui_sync_at';
  static const pendingReasonKey = 'pending_live_ui_sync_reason';

  static Future<void> mark([String reason = 'push']) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      pendingAtKey,
      DateTime.now().toUtc().toIso8601String(),
    );
    await prefs.setString(
      pendingReasonKey,
      reason.trim().isEmpty ? 'push' : reason.trim(),
    );
  }
}
