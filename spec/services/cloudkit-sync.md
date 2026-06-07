# CloudKit Sync Service Specification

## Purpose

Provide iCloud sync capabilities via CloudKit for data synchronization across devices. This enables users to access their workout data on multiple iOS devices signed into the same iCloud account.

The native Swift app provides iCloud sync using CloudKit.

## iCloud Container

- **Container identifier**: `iCloud.com.eff3.liftmark`
- **Database**: Private database (user's own data, not shared)

## Entitlements

The iOS app target MUST include the following entitlements:

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
  <string>iCloud.com.eff3.liftmark</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
  <string>CloudDocuments</string>
</array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array>
  <string>iCloud.com.eff3.liftmark</string>
</array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>$(TeamIdentifierPrefix)com.eff3.liftmark</string>
```

### Current Entitlement Status

| App Target | File | Status |
|------------|------|--------|
| Swift | `mobile-apps/ios/LiftMark/LiftMark.entitlements` | **Missing** — only has HealthKit entitlements |

**Action required**: Add iCloud entitlements to `mobile-apps/ios/LiftMark/LiftMark.entitlements`.

## Account Status

The service can report the current iCloud account status as one of:

- `available` — iCloud account is signed in and accessible.
- `noAccount` — No iCloud account configured on the device.
- `restricted` — iCloud access is restricted (e.g., parental controls).
- `couldNotDetermine` — Status could not be determined.
- `temporarilyUnavailable` — iCloud is temporarily unavailable (map to `couldNotDetermine` in app logic).
- `error` — An error occurred checking status.

### Account Status Implementation Notes

- **Swift**: Use `CKContainer.accountStatus()` async API. Handle `temporarilyUnavailable` by mapping to `couldNotDetermine`.
- **Simulator handling**: On simulator, CloudKit may fail. Return `noAccount` for simulator-specific errors rather than crashing.

## CloudKit Record Types

The app MUST use these exact CloudKit record type names and field mappings.

### Record Type: `WorkoutPlan`

Maps to the `WorkoutPlan` entity in the data model.

| CloudKit Field | Type | Maps To |
|----------------|------|---------|
| `name` | String | `name` |
| `planDescription` | String | `description` |
| `tags` | String (JSON array) | `tags` |
| `defaultWeightUnit` | String | `defaultWeightUnit` |
| `sourceMarkdown` | String | `sourceMarkdown` |
| `isFavorite` | Int64 (0/1) | `isFavorite` |
| `createdAt` | Date | `createdAt` |
| `updatedAt` | Date | `updatedAt` |

**Record ID**: Use the entity's `id` (UUID string) as the CloudKit record name.

**Note**: Field is named `planDescription` (not `description`) because `description` is reserved in some CloudKit contexts.

### Record Type: `PlannedExercise`

| CloudKit Field | Type | Maps To |
|----------------|------|---------|
| `workoutPlanId` | Reference (`WorkoutPlan`) | `workoutPlanId` |
| `exerciseName` | String | `exerciseName` |
| `orderIndex` | Int64 | `orderIndex` |
| `notes` | String | `notes` |
| `equipmentType` | String | `equipmentType` |
| `groupType` | String | `groupType` |
| `groupName` | String | `groupName` |
| `parentExerciseId` | String | `parentExerciseId` |

### Record Type: `PlannedSet`

| CloudKit Field | Type | Maps To |
|----------------|------|---------|
| `plannedExerciseId` | Reference (`PlannedExercise`) | `plannedExerciseId` |
| `orderIndex` | Int64 | `orderIndex` |
| `targetWeight` | Double | `targetWeight` |
| `targetWeightUnit` | String | `targetWeightUnit` |
| `targetReps` | Int64 | `targetReps` |
| `targetTime` | Int64 | `targetTime` |
| `targetRpe` | Double | `targetRpe` |
| `restSeconds` | Int64 | `restSeconds` |
| `tempo` | String | `tempo` |
| `isDropset` | Int64 (0/1) | `isDropset` |
| `isPerSide` | Int64 (0/1) | `isPerSide` |
| `isAmrap` | Int64 (0/1) | `isAmrap` |
| `notes` | String | `notes` |

### Record Type: `WorkoutSession`

| CloudKit Field | Type | Maps To |
|----------------|------|---------|
| `workoutPlanId` | String | `workoutPlanId` |
| `name` | String | `name` |
| `date` | String (ISO date) | `date` |
| `startTime` | Date | `startTime` |
| `endTime` | Date | `endTime` |
| `duration` | Int64 | `duration` |
| `notes` | String | `notes` |
| `status` | String | `status` |

**Note**: `workoutPlanId` is stored as a plain String (not a CKReference) because the referenced plan may have been deleted.

### Record Type: `SessionExercise`

| CloudKit Field | Type | Maps To |
|----------------|------|---------|
| `workoutSessionId` | Reference (`WorkoutSession`) | `workoutSessionId` |
| `exerciseName` | String | `exerciseName` |
| `orderIndex` | Int64 | `orderIndex` |
| `notes` | String | `notes` |
| `equipmentType` | String | `equipmentType` |
| `groupType` | String | `groupType` |
| `groupName` | String | `groupName` |
| `parentExerciseId` | String | `parentExerciseId` |
| `status` | String | `status` |

### Record Type: `SessionSet`

| CloudKit Field | Type | Maps To |
|----------------|------|---------|
| `sessionExerciseId` | Reference (`SessionExercise`) | `sessionExerciseId` |
| `orderIndex` | Int64 | `orderIndex` |
| `parentSetId` | String | `parentSetId` |
| `dropSequence` | Int64 | `dropSequence` |
| `targetWeight` | Double | `targetWeight` |
| `targetWeightUnit` | String | `targetWeightUnit` |
| `targetReps` | Int64 | `targetReps` |
| `targetTime` | Int64 | `targetTime` |
| `targetRpe` | Double | `targetRpe` |
| `restSeconds` | Int64 | `restSeconds` |
| `actualWeight` | Double | `actualWeight` |
| `actualWeightUnit` | String | `actualWeightUnit` |
| `actualReps` | Int64 | `actualReps` |
| `actualTime` | Int64 | `actualTime` |
| `actualRpe` | Double | `actualRpe` |
| `completedAt` | Date | `completedAt` |
| `status` | String | `status` |
| `notes` | String | `notes` |
| `tempo` | String | `tempo` |
| `isDropset` | Int64 (0/1) | `isDropset` |
| `isPerSide` | Int64 (0/1) | `isPerSide` |

### Record Type: `UserSettings`

| CloudKit Field | Type | Maps To |
|----------------|------|---------|
| `defaultWeightUnit` | String | `defaultWeightUnit` |
| `enableWorkoutTimer` | Int64 (0/1) | `enableWorkoutTimer` |
| `autoStartRestTimer` | Int64 (0/1) | `autoStartRestTimer` |
| `theme` | String | `theme` |
| `notificationsEnabled` | Int64 (0/1) | `notificationsEnabled` |
| `customPromptAddition` | String | `customPromptAddition` |
| `healthKitEnabled` | Int64 (0/1) | `healthKitEnabled` |
| `liveActivitiesEnabled` | Int64 (0/1) | `liveActivitiesEnabled` |
| `keepScreenAwake` | Int64 (0/1) | `keepScreenAwake` |
| `showOpenInClaudeButton` | Int64 (0/1) | `showOpenInClaudeButton` |
| `homeTiles` | String (JSON array) | `homeTiles` |
| `updatedAt` | Date | `updatedAt` |

**Record ID**: Fixed value `"user-settings"` (singleton).

**Note**: `anthropicApiKey` is NEVER synced. It is stored in platform-native secure storage only. `anthropicApiKeyStatus` is also not synced — each device verifies independently.

### Record Type: `Gym`

| CloudKit Field | Type | Maps To |
|----------------|------|---------|
| `name` | String | `name` |
| `isDefault` | Int64 (0/1) | `isDefault` |
| `createdAt` | Date | `createdAt` |
| `updatedAt` | Date | `updatedAt` |

### Record Type: `GymEquipment`

| CloudKit Field | Type | Maps To |
|----------------|------|---------|
| `gymId` | Reference (`Gym`) | `gymId` |
| `name` | String | `name` |
| `isAvailable` | Int64 (0/1) | `isAvailable` |
| `lastCheckedAt` | Date | `lastCheckedAt` |
| `createdAt` | Date | `createdAt` |
| `updatedAt` | Date | `updatedAt` |

## Timestamp Serialization

Date fields are stored in CloudKit as native `TIMESTAMP` values, but locally (and in the
app's models) they are ISO8601 **strings**. Two formats are in circulation:

- **Locally written** timestamps use a bare `ISO8601DateFormatter()` → **whole seconds**, e.g. `2026-06-02T16:32:00Z`.
- **Synced** timestamps are re-serialized by `CKRecordMapper.dateToISO` with `.withFractionalSeconds` → **fractional seconds**, e.g. `2026-06-02T16:32:00.000Z`.

A bare `ISO8601DateFormatter().date(from:)` returns `nil` on a fractional-second string.
Therefore **all parsing of these timestamps for display or logic MUST be tolerant of both
forms** — use the shared `ISO8601.parse` helper (tries fractional, then whole seconds),
never a bare `ISO8601DateFormatter`.

**Regression history**: A workout completed on one device showed its start time correctly
on that device but, after syncing, lost its time on the receiving device — the History list
row collapsed to "Day · duration" (with a dangling separator) and the detail header fell
back to the raw `date` string. Root cause was a strict (`ISO8601DateFormatter()`) parser in
the History views choking on the fractional-second strings produced by the sync round-trip.
The data was present; only the parse failed.

**Tests** (`SessionDateDisplayTests`): a fractional-second `startTime` parses and yields a
formatted time; a whole-second `startTime` parses; an unparseable/absent `startTime` falls
back to the formatted calendar date (never the raw string).

## Sync Strategy

### Current Implementation: CKSyncEngine + Record System-Fields

The app syncs via **`CKSyncEngine`** against the private database, custom zone `LiftMarkData`. The engine drives fetch/send cycles and persists its serialized state (database/zone change tokens + the set of pending record IDs) in the `sync_engine_state` table. The Phase 1/2/3 description below predates this and is retained only for historical context.

#### Record System-Fields Persistence (change tags) — REQUIRED invariant

`CKSyncEngine`'s serialized state does **not** store records or their `recordChangeTag`s — persisting them is the app's responsibility. The app keeps a per-record cache:

- Table `ck_record_metadata(record_name PK, record_type, system_fields BLOB, updated_at)` — one row per CloudKit record, all record types. `system_fields` is `CKRecord.encodedSystemFields` (record ID, zone, and current change tag; no user fields).

Invariants:

1. **Rehydrate on upload.** When building a `CKRecord` to upload (`CKRecordMapper.baseRecord` → `toCKRecord`), if a metadata row exists for the record name, the `CKRecord` MUST be reconstructed from the stored `system_fields` (so it carries the current change tag) and then have its data fields written. A fresh `CKRecord` is built ONLY when no metadata row exists (a genuinely new record CloudKit will create).
2. **Persist on confirm.** System fields MUST be saved whenever CloudKit hands us an authoritative record: (a) each `event.savedRecords` after a successful upload, (b) **unconditionally** in `mergeIncoming` for every fetched record — even when the row-merge is skipped because local is newer/unchanged (the server tag is still the token our next upload needs), and (c) from `error.serverRecord` on a `serverRecordChanged` conflict (handled via `mergeIncoming`).
3. **Remove on delete.** Drop the metadata row on a confirmed delete (local `event.deletedRecordIDs`, or an incoming deletion).

**Why:** without this, every upload builds a fresh tagless `CKRecord`; CloudKit rejects any update to an already-existing record with `serverRecordChanged`; the resolver re-uploads (still tagless) and conflicts again — a permanent loop that jams the pending queue and starves all other uploads (observed: ~92% SetMeasurement conflict rate, an ~8.6k-deep queue with ~0 net drain, completed workouts never reaching other devices). With durable tags, `serverRecordChanged` becomes a rare true-conflict (genuine concurrent edits) that converges in one cycle.

#### One-time recovery (`fullUploadVersion` = 5)

Devices jammed by the pre-fix loop have a large stale pending queue and no stored system fields. On a `fullUploadVersion` bump the app performs an **ordered reset → re-fetch → re-upload** (before creating the engine, so it restarts fresh):

1. `DELETE FROM sync_engine_state` and clear `ck_record_metadata`. **No data tables are touched — no data loss.**
2. The engine restarts with nil state → full zone re-fetch → `mergeIncoming` repopulates `ck_record_metadata` with authoritative tags. Merges key on stable UUID PKs (update-in-place, no duplication); locally-newer rows survive (LWW keeps local on newer/tie).
3. Only **after** the first fetch completes (`.didFetchChanges`) does the app re-upload local rows (`scheduleFullUpload`) — now with correct tags — and bump the stored version. The account-change full-upload is deferred during the recovery window. The version is bumped only after the deferred upload is scheduled, so an app kill mid-recovery simply re-runs it (idempotent).

### Phase 1: Full Download-then-Upload (superseded — historical)

The sync runs in **download-first** order to avoid an upload storm when another device (or app version) has already synced records to the CloudKit container:

1. **Download**: Fetch all CloudKit records → deserialize → merge into local database (last-writer-wins). `fetchRecords` MUST paginate through all cursor pages to ensure every record is downloaded.
2. **Upload new-only**: Serialize local records that do NOT already exist on the server → save as CloudKit records. Records already present on the server were resolved in step 1 and are NOT re-uploaded. `localIds` MUST only contain IDs confirmed on the server (from the download phase or from successful uploads). Failed uploads MUST NOT be included in `localIds`.
3. **Local deletes**: Records present locally but absent from the server were deleted on another device → delete locally. Correct delete behavior depends on complete remote fetching (pagination) and accurate `localIds`.
4. **No remote deletes in Phase 1**: Without a sync queue there is no reliable way to distinguish "record deleted locally" from "record recently added by another device". Remote deletes are deferred to Phase 2 to avoid accidental data loss.
5. **Conflict resolution**: Last-writer-wins based on `updatedAt` timestamp (applied during download merge).

**Why download-first?** If an upload-first strategy is used, every record that already exists on the server triggers a `serverRecordChanged` error, requiring a fetch + retry per record — O(2N) CloudKit API calls instead of O(N).

**Sync triggers**: App launch, foreground transition, manual "Sync Now" button, and 5-minute background polling.

### Phase 2: Change Tracking (Future)

Future enhancement using the existing `sync_queue` and `sync_metadata` tables:

- Track local changes via repository hooks (`afterCreateHook`, `afterUpdateHook`, `afterDeleteHook`)
- Use CloudKit `serverChangeToken` for incremental fetch
- Support `CKSubscription` for push notifications on remote changes
- Automatic sync on app launch and background refresh

### Phase 3: Real-Time Sync (Future)

- `CKDatabaseSubscription` for real-time change notifications
- Background app refresh for periodic sync
- Optimistic UI updates with conflict resolution

## Sync Order

Entities must be synced in dependency order to satisfy foreign key constraints:

**Upload order**:
1. `Gym`
2. `GymEquipment`
3. `WorkoutPlan`
4. `PlannedExercise`
5. `PlannedSet`
6. `WorkoutSession`
7. `SessionExercise`
8. `SessionSet`
9. `UserSettings`

**Download order**: Same order (parent records before children).

## Conflict Resolution (Phase 1)

Simple last-writer-wins strategy:

1. Compare local `updatedAt` with remote `updatedAt`
2. If remote is newer → overwrite local
3. If local is newer → overwrite remote
4. If equal → no action needed

For `UserSettings` (singleton): merge field-by-field, taking the newer value for each field independently.

## Foreign Key Validation in Merge Functions

All merge functions for child records (`PlannedExercise`, `PlannedSet`, `SessionExercise`, `SessionSet`, `GymEquipment`) MUST validate that required foreign key values are non-empty before inserting a new record.

**Rule**: When merging a remote record, the FK value is resolved via this fallback chain:
1. `referenceId()` from the CloudKit record
2. Existing local record's FK value (if updating)
3. Empty string `""` (fallback)

If the resolved FK value is empty AND no existing local record exists (i.e., this would be a new insert), the merge MUST skip the record and log an error. Inserting a record with an empty FK causes foreign key constraint failures and potential data corruption.

If an existing record already has a valid FK, an update with empty remote FK should retain the existing value (the fallback chain handles this naturally).

**Affected merge functions and their required FK fields**:
- `mergePlannedExercise`: `workoutTemplateId` (FK to `WorkoutPlan`)
- `mergePlannedSet`: `templateExerciseId` (FK to `PlannedExercise`)
- `mergeSessionExercise`: `workoutSessionId` (FK to `WorkoutSession`)
- `mergeSessionSet`: `sessionExerciseId` (FK to `SessionExercise`)
- `mergeGymEquipment`: `gymId` (FK to `Gym`)

**Tests** (`CloudKitSyncProtectionTests`):
1. Merge function skips insert when FK reference is missing (returns false, no DB insert)
2. Merge function allows update when existing record has valid FK even if remote FK is nil
3. Each affected merge function is covered

## Delete Handling

### Phase 1 (current)

Only **server-to-local** deletes are propagated:

- Record exists locally but not on server → was deleted on another device → **delete locally**
- Record exists on server but not locally → **do nothing** (could be a record newly added by another device; cannot distinguish without change tracking)
- **First sync safety**: Skip all delete processing on first sync entirely.
- **Prerequisite**: Delete handling depends on two invariants: (1) `fetchRecords` must paginate through all cursor pages so `remoteIds` is complete, and (2) `localIds` must only contain IDs confirmed on the server (downloaded or successfully uploaded). Violating either invariant causes false positives that delete valid local data.

### Active Session Protection

During sync, all records belonging to an `in_progress` workout session MUST be excluded from:

1. **Delete processing** (`handleLocalDeletes`) — never delete a `WorkoutSession` with `status = 'in_progress'`, nor any `SessionExercise` or `SessionSet` belonging to it
2. **Download merge overwrite** — never overwrite local session-tier records (`WorkoutSession`, `SessionExercise`, `SessionSet`) that belong to an active session with remote data

#### Parent WorkoutPlan Protection

When a session is active and has a `workoutTemplateId` (FK to a `WorkoutPlan`), the parent plan's records MUST also be protected from deletion and merge overwrite during sync:

- The `WorkoutPlan` referenced by `workoutTemplateId`
- All `PlannedExercise` records belonging to that plan
- All `PlannedSet` records belonging to those exercises

**Rationale**: The active session's structure is derived from the parent plan. If sync deletes or overwrites the plan's exercises/sets while a session is in progress, the session UI may show stale or missing template data. The plan records must remain stable until the session completes.

**Implementation**: `getActiveSessionProtectedIds()` must query for the parent plan's records when `workoutTemplateId` is non-nil, and include them in the `byRecordType` mapping under `WorkoutPlan`, `PlannedExercise`, and `PlannedSet` keys.

**Tests** (`CloudKitSyncProtectionTests`):
1. Protected IDs include parent plan, its exercises, and its sets when session has `workoutTemplateId`
2. Protected IDs do NOT include plan records when session has no `workoutTemplateId`

Sync of non-session data (plans not linked to active session, gyms, settings, completed sessions) proceeds normally even when a workout is active.

**Rationale**: The active session is the user's live working state. Remote data is always stale relative to the local active session. Sync runs frequently (foreground transitions, 5-minute polling) and the remote snapshot may not include records created since the download phase began — deleting or overwriting them would destroy the user's in-progress work.

### Sync Session Guard

A secondary safety net that wraps every sync operation to detect and restore data loss in active workout sessions, regardless of whether the primary Active Session Protection works correctly.

**Flow**:
1. Before `syncAll()`: snapshot the in-progress session (session row, all exercise rows, all set rows)
2. After `syncAll()` returns (before posting `syncCompleted`): compare current DB state against snapshot
3. If any exercise or set IDs from the snapshot are missing: re-insert them from the snapshot

**Behavior**:
- No active session → skip snapshot/validation entirely
- All IDs present after sync → log "intact", no action
- Missing IDs detected → log as `DATA LOSS` error, restore rows, log as `RESTORED`
- Restore failure → log as `RESTORE FAILED` error, sync continues normally

**Edge cases**:
- User adds exercises during sync: new IDs are not in the snapshot, so they are not flagged as missing
- User deletes during sync: guard restores the deleted rows (acceptable false positive — safer than data loss)
- Session itself deleted by sync: full restore of session + all children
- Snapshot failure: returns nil, guard is skipped

**Logging** (all `.sync` category, `[sync-guard]` prefix):

| Event | Level | Pattern |
|-------|-------|---------|
| No active session | debug | `[sync-guard] No active session, skipping snapshot` |
| Snapshot taken | debug | `[sync-guard] Snapshot: session={id}, exercises={n}, sets={n}` |
| Session intact | debug | `[sync-guard] Intact after sync: exercises={n}, sets={n}` |
| Data loss detected | error | `[sync-guard] DATA LOSS: missing {n} exercises {ids}, {n} sets {ids}` |
| Restored | error | `[sync-guard] RESTORED {n} exercises, {n} sets` |
| Restore failed | error | `[sync-guard] RESTORE FAILED: {error}` |

**Tests** (`SyncSessionGuardTests`):
1. Snapshot captures active session with correct IDs and counts
2. Snapshot returns nil when no active session
3. Snapshot excludes completed sessions
4. Validate returns true when session is intact
5. Validate detects and restores missing exercises
6. Validate detects and restores missing sets
7. Restore preserves newly-added exercises not in original snapshot

### Plan Exercise Deduplication

During merge, `mergePlannedExercise` and `mergePlannedSet` must guard against inserting duplicate child records for the same workout plan.

**Problem**: `PlannedExercise` and `PlannedSet` records lack `updatedAt` timestamps. If sync delivers the same logical exercise with a different CloudKit record ID (e.g., after a plan was reprocessed from markdown), merge inserts a second copy — duplicating exercises in the plan.

**Deduplication rule for `mergePlannedExercise`**:
- Before inserting a new exercise (record ID not found locally), check if an exercise with the same `(workoutTemplateId, exerciseName, orderIndex)` already exists.
- If a match exists, **skip the insert** and log a warning. The local record is authoritative.

**Deduplication rule for `mergePlannedSet`**:
- Before inserting a new set (record ID not found locally), check if a set with the same `(templateExerciseId, orderIndex)` already exists.
- If a match exists, **skip the insert** and log a warning.

**Tests** (`CloudKitSyncProtectionTests`):
1. `mergePlannedExercise` skips insert when duplicate (same plan, name, orderIndex) already exists locally
2. `mergePlannedSet` skips insert when duplicate (same exercise, orderIndex) already exists locally
3. `mergePlannedExercise` allows insert when no duplicate exists
4. `mergePlannedExercise` allows update of existing record (same record ID)

### Phase 2 (future — requires sync_queue)

Once change tracking is in place, both directions are supported:

- Record exists locally but not on server → deleted remotely → delete locally
- Record exists on server but not locally AND was previously synced → deleted locally → delete from server

### First Sync Detection

A device is performing its "first sync" when `sync_metadata.last_sync_date` is NULL. In this case:
- Download all remote records and merge with local data
- Upload only local records that don't exist on the server
- Skip all delete processing
- Set `last_sync_date` after completion (regardless of individual record errors)

## Error Handling

- All sync operations return safe default values on failure (null, empty collections, or false); they never throw exceptions.
- Errors are logged via the app's Logger for debugging.
- Simulator and development environment errors are treated as non-fatal and result in degraded but functional behavior.
- Network errors should be retried with exponential backoff (max 3 attempts).
- CloudKit rate limiting (CKError.requestRateLimited) should respect the `retryAfterSeconds` value.
- Transient CloudKit account-state errors (`CKError.accountTemporarilyUnavailable`, code 36) MUST NOT be reported to the crash reporter. They indicate the iCloud account is in a temporary state (per Apple, wait for `CKAccountChanged` and retry); they are not actionable and would otherwise generate high-volume Sentry noise during account warm-up. Log at info level and treat as non-fatal at every CK call site (zone create, fetch, save).
- `CKError.serverRejectedRequest` (code 2006) on a record save indicates schema drift — typically a field on the local record that the deployed CloudKit container schema does not recognize, or a type mismatch. The error MUST be reported to the crash reporter with the failing record's `recordType`, the comma-joined sorted list of field keys present on the rejected record (`recordFields` metadata), and `tag: "schema-drift-suspected"` so the next occurrence identifies which schema element is missing without needing to reproduce locally. The same `recordFields` metadata SHOULD also be attached to the catch-all CK save error path so any future unexpected error code carries the same diagnostic payload.

## UI Requirements

The iCloud Sync settings screen (see `spec/screens/settings.md`, sub-screen: iCloud Sync) MUST display meaningful content at all times. An empty screen is a bug. At minimum, the screen must show:

1. The current iCloud account status (with a colored badge and human-readable description)
2. Explanatory text about what iCloud Sync does
3. Guidance for the user based on their current status (e.g., "Sign in to iCloud to enable sync")

### UI Refresh

The sync settings screen MUST refresh its displayed sync stats (last sync date, uploaded/downloaded counts) whenever a background sync completes — not only when the screen first appears. Subscribe to the `syncCompleted` notification and reload stats from persistent storage on receipt.

### Live List Updates During Sync

List views (workout history, plans) MUST update **as records arrive**, not only when the
entire fetch finishes. A long multi-batch sync (e.g. a month of history on a fresh device)
otherwise leaves the list frozen until the end, forcing the user to pull-to-refresh
repeatedly.

- The sync engine posts `.syncRecordsMerged` (userInfo `["changedRecordTypes": Set<String>]`)
  after **each** incoming batch is merged, in addition to the single `.syncCompleted` at the
  end of the fetch cycle.
- The app reloads the affected stores on **both** notifications. An empty `changedRecordTypes`
  set means "reload everything".

### Sync Activity Indicator

The app exposes an app-wide observable sync-activity flag (`SyncStatusStore.isSyncing`) so any
screen can show a background-sync indicator.

- The sync engine posts `.syncActivityDidChange` (userInfo `["isActive": Bool]`) on the 0→1
  transition (a fetch or send cycle started) and the 1→0 transition (the last in-flight cycle
  finished). An internal counter keeps the flag true while an overlapping fetch and send are
  both active.
- The History (Workouts) list shows a slim "Syncing…" bar (`sync-status-bar`) while
  `isSyncing` is true.

**Tests** (`SyncStatusStoreTests`): the store reports idle initially, true after an
`isActive: true` notification, false after `isActive: false`, and treats a missing `isActive`
as idle.

### Pull-to-Refresh Triggers a Remote Fetch

Pull-to-refresh on a synced list MUST trigger an actual CloudKit fetch
(`CKSyncEngineManager.fetchChanges(manual: true)`), not merely re-read the local database.
A manual pull bypasses the automatic-fetch rate limit. Reading only the local DB can never
surface a genuinely new remote record, which was the original "the latest workout didn't
sync until I refreshed (and even then it didn't)" report.

See `spec/screens/settings.md` for the complete iCloud Sync sub-screen layout specification.

## Service Interface

The app MUST implement a CloudKit service with the following capabilities:

```
CloudKitService {
  // Account
  initialize() → bool
  getAccountStatus() → AccountStatus

  // CRUD
  saveRecord(record) → record | null
  fetchRecord(recordId, recordType) → record | null
  fetchRecords(recordType) → record[]   // MUST paginate using CKQueryOperation.Cursor — CloudKit returns max ~100 records per query batch
  deleteRecord(recordId, recordType) → bool

  // Sync (Phase 1)
  syncAll() → SyncResult
}

SyncResult {
  success: bool
  uploaded: number
  downloaded: number
  conflicts: number
  errors: string[]
  timestamp: datetime
}
```

## Implementation Checklist

- [ ] Add iCloud entitlements to `mobile-apps/ios/LiftMark/LiftMark.entitlements`
- [ ] Add iCloud capability in Xcode project settings
- [ ] Verify `CloudKitService.swift` uses container `iCloud.com.eff3.liftmark`
- [ ] Implement `syncAll()` method using the record type mappings above
- [ ] Wire up Sync Settings UI to actual sync operations
- [ ] Test on physical device (CloudKit requires real iCloud account)
- [ ] Test conflict resolution with simultaneous edits
- [ ] Test first-sync behavior on a new device
- [ ] Test sync with large datasets (100+ workout plans, 500+ sessions)
