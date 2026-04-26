# Mobile Background Worker Plan

## Goal

Move PulseConnect from "auto-sync when app is active/resumed" toward "best-effort sync even when the app is not in the foreground", while keeping offline attendance secure and predictable.

## Current State

- Offline scanner cache and queue already exist.
- The app can:
  - warm scanner snapshots while online,
  - validate cached QR data offline,
  - queue offline attendance,
  - auto-sync when the app comes back online and is active again.
- The app does not yet have a dedicated OS background worker for replaying queued scans while fully backgrounded or fully closed.

## Target Architecture

### Shared flow

1. `OfflineScanStore` remains the source of truth for pending scan ops.
2. Add a `BackgroundSyncCoordinator` service in Flutter to expose one entry point:
   - `runPendingAttendanceSync()`
3. That coordinator will:
   - load current logged-in user/session,
   - inspect pending queue,
   - replay queued scan ops using existing `EventService` APIs,
   - refresh scanner snapshot after successful sync,
   - write a lightweight backup after each worker pass.

### Android path

- Use `workmanager` plugin.
- Register:
  - periodic job for queue replay,
  - one-off expedited job after a new offline scan is queued,
  - optional connectivity-constrained job for retry.
- Store worker metadata:
  - last run time,
  - last success time,
  - last failure reason.

### iOS path

- Use `workmanager` iOS background support plus native `BGTaskScheduler` registration.
- Register:
  - app refresh task for lightweight queue replay,
  - processing task only if needed and allowed by the final deployment profile.
- iOS must be treated as best-effort:
  - task execution timing is OS-controlled,
  - fully closed-app sync cannot be guaranteed like Android.

## Suggested Implementation Phases

### Phase 1: Shared coordinator

- Create `BackgroundSyncCoordinator`.
- Make it call:
  - `OfflineSyncService.syncPendingQueue(...)`
  - `OfflineSyncService.refreshSnapshotForCurrentScanner(...)`
  - `OfflineBackupService.autoBackupIfConfigured()`
- Persist last worker run info in `SharedPreferences`.

### Phase 2: Android worker

- Add `workmanager` dependency.
- Initialize worker dispatcher in `main.dart`.
- Enqueue:
  - periodic sync every 15 minutes,
  - one-off sync after offline attendance is queued.
- Add constraints:
  - network required for replay,
  - battery-not-low preferred.

### Phase 3: iOS worker

- Register background task identifiers in Xcode capabilities.
- Add background fetch / processing modes.
- Wire iOS task callback to the same shared Flutter coordinator.
- Keep runtime small and fail fast if there is no queue or no valid session.

### Phase 4: UX visibility

- Add a small worker status section in scanner/admin debug UI:
  - last background sync
  - last success
  - pending queue count
  - last worker error

## Data Rules

- Never write attendance directly from the worker without existing queue validation.
- Worker only replays already-queued operations.
- Unknown QR codes are still blocked offline.
- Conflict responses such as `already_checked_in` must mark queue rows resolved, not re-queued forever.

## Reliability Rules

- One worker run at a time.
- Backoff sequence:
  - 15s
  - 60s
  - 5m
  - periodic worker retry
- Skip heavy snapshot refresh if there is no valid scanner assignment.

## Security Rules

- Keep the backup lightweight and scoped to essential app/session/offline scanner data.
- Do not store raw camera images or arbitrary app caches in worker payloads.
- Keep logs scrubbed:
  - no raw QR payloads in debug output
  - no sensitive personal fields in worker crash logs

## Acceptance Criteria

- Android:
  - offline scan can be queued,
  - app moves to background,
  - worker eventually syncs the queue when network is available.
- iOS:
  - offline scan can be queued,
  - app resume path always syncs immediately,
  - background worker performs best-effort replay when iOS grants execution time.
- UI:
  - scanner shows last online sync and offline readiness clearly.

## Notes

- "Fully closed-app sync" on iOS is never absolute. The OS decides when or whether to wake the app.
- For truly immediate closed-app delivery, a hosted backend relay plus push-triggered wake flow is the long-term direction.
