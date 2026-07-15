import 'package:shared_preferences/shared_preferences.dart';

import 'event_live_service.dart';
import 'live_ui_sync_pending.dart';

/// Bridges FCM (which may arrive while Flutter UI code is not running)
/// to the in-app live refresh bus.
class LiveUiSync {
  LiveUiSync._();

  static Future<void> markPending([String reason = 'push']) {
    return LiveUiSyncPending.mark(reason);
  }

  /// Run now, and clear any pending flag set while backgrounded.
  static Future<void> syncNow([String fallbackReason = 'push']) async {
    final prefs = await SharedPreferences.getInstance();
    final pendingReason = prefs.getString(LiveUiSyncPending.pendingReasonKey);
    final hadPending = prefs.containsKey(LiveUiSyncPending.pendingAtKey);
    if (hadPending) {
      await prefs.remove(LiveUiSyncPending.pendingAtKey);
      await prefs.remove(LiveUiSyncPending.pendingReasonKey);
    }
    final reason = (pendingReason ?? fallbackReason).trim();
    EventLiveService.instance.pulseFromPush(
      reason.isEmpty ? fallbackReason : reason,
    );
  }
}
