# Migrator Service Specification

> Orchestrates LiftMark schema migrations via GRDB's `DatabaseMigrator`, with a one-time **bridge** that adapts legacy `schema_version`-tracked databases into `grdb_migrations` identifier bookkeeping.
>
> Source-of-truth companions: [`../data/migration-contract.md`](../data/migration-contract.md) (rules and lossy-transform inventory), [`../data/database-schema.md`](../data/database-schema.md) (v13 shape), [`backup.md`](backup.md) (pre-upgrade backup), [`sentry.md`](sentry.md) (telemetry).

---

## Purpose

Decouple migration orchestration from bootstrap and make GRDB's `DatabaseMigrator` the authoritative record of applied migrations. The hand-rolled `DatabaseManager.runMigrations` is retained only long enough for one run of the bridge per installed device; removal is telemetry-gated (§6).

Priorities, in order:

1. **Zero user data loss.** Every DB-modifying operation is preceded by a verified, restorable backup.
2. **Atomicity.** The bridge write and the first post-bridge migration commit in the same transaction — no observable partial state.
3. **Downgrade safety.** A user who installs a pre-bridge build after bridging must still be able to open the DB; hence `schema_version` stays on disk until the cleanup trigger (§6) fires.
4. **Visibility.** Telemetry is sufficient to prove "every active device has bridged" before cleanup ships.

---

## 1. Bridge semantics

### 1.1 Canonical migration identifiers

GRDB persists applied migrations as one row per identifier in `grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL)`. The identifier set is a wire-level contract: **identifiers must not change after first ship**. See [`../data/migration-contract.md`](../data/migration-contract.md) §4.

| Legacy `schema_version` | GRDB identifier               |
|-------------------------|-------------------------------|
| 1                       | `v1_bootstrap`                |
| 2                       | `v2_sync_metadata_stats`      |
| 3                       | `v3_developer_mode`           |
| 4                       | `v4_soft_delete_gyms`         |
| 5                       | `v5_countdown_sounds`         |
| 6                       | `v6_session_set_side`         |
| 7                       | `v7_accepted_disclaimer`      |
| 8                       | `v8_updated_at_cksync`        |
| 9                       | `v9_api_key_fk_indexes`       |
| 10                      | `v10_distance_columns`        |
| 11                      | `v11_gym_unique_fk_indexes`   |
| 12                      | `v12_set_measurements`        |
| 13                      | `v13_default_timer_countdown` |
| 14                      | `v14_default_weight_step_lbs` |
| 15                      | `v15_ai_prompt_toggles`       |
| 16                      | `v16_workout_inbox`           |
| 17                      | `v17_outbox_pending_queue`    |
| 18                      | `v18_workout_inbox_drop_preparse` |

Naming rule: `vN_<short_description>`. The numeric prefix matches the legacy `schema_version` value and the order `DatabaseMigrator` enforces.

### 1.2 Translation rule

> For any existing DB at `schema_version.version = N`, insert identifiers `v1_bootstrap` through `vN_*` (all identifiers whose legacy number ≤ N) into `grdb_migrations`. Do not insert higher-numbered rows.

### 1.3 Concrete cases

- **Fresh install** (`schema_version` absent or `version = 0`): bridge returns early. `DatabaseMigrator` runs `v1_bootstrap`..`v13_default_timer_countdown` as real migrations. After the migrator succeeds, write `schema_version.version = 13` so that a downgrade to a pre-bridge build still observes the expected version.
- **User at N = 13** (virtually all existing users): bridge inserts all 13 identifier rows into `grdb_migrations`.
- **User at 1 ≤ N < 13**: bridge completes the pending legacy migrations through v13 using the in-process legacy chain, then inserts v1..v13 identifier rows. (The population is near-zero because the legacy chain ran eagerly on every launch, but the design is correct for it.)
- **User at N > 13** (forward-time downgrade): bridge refuses. See §3.e.
- **Already bridged** (`grdb_migrations` populated): bridge detects this and hands off directly to `DatabaseMigrator`. After the migrator returns, the bridge writes `schema_version.version = currentVersion` so that the legacy `DatabaseManager.runMigrations` catch-up pass (still called from `database()` during the bridge era) observes the advanced schema and does not attempt to re-apply a migration that the migrator just ran. Without this write, a build that adds a new migration (e.g. v14 on top of a v13-bridged DB) crashes in the legacy chain with "duplicate column name".

### 1.4 What the bridge does NOT do

- **Does NOT drop `schema_version`.** The table and its row persist after bridging. Removal happens in a future `v14_drop_legacy_schema_version` migration after the cleanup trigger (§6) fires.
- **Does NOT modify user data rows.** The bridge writes only to `grdb_migrations` (and, on fresh install, a single `schema_version.version = 13` row).
- **Does NOT close or reopen the connection.** The bridge runs inside the same `DatabaseQueue.write { … }` as the first post-bridge migration, so the two commit atomically.

### 1.5 Transaction phases

All three phases inside one `dbQueue.write`:

1. **Pre-check.** Read `schema_version.version` (or detect absence). Read `grdb_migrations` existence.
2. **Bridge write.** If `grdb_migrations` is empty AND `schema_version.version > 0`, `CREATE TABLE IF NOT EXISTS grdb_migrations` and `INSERT OR IGNORE INTO grdb_migrations (identifier) VALUES …` for identifiers v1..vN.
3. **Migrator hand-off.** Call `migrator.migrate(db)`. GRDB's own transaction semantics take over for any subsequent real migrations.

A throw anywhere rolls back the whole transaction.

---

## 2. Backup contract

### 2.1 Location

```
<Application Support>/LiftMark/pre-grdb-bridge.bak.db
```

Resolved via `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LiftMark/pre-grdb-bridge.bak.db")`.

Rationale:

- **Not Caches.** `URL.cachesDirectory` is OS-evictable under storage pressure and is unsafe for a pre-bridge backup. Note: `DatabaseBackupService.exportDatabase()` currently writes to Caches — that path is for **user-initiated** exports only and is not reused here. (Cache-dir export is a pre-existing concern flagged separately; it is not fixed in this work.)
- **Not Documents.** Documents is user-visible in Files.app; users could rename or delete the file during the window when it is the only copy of their data.
- **Application Support** is iCloud-backed-up by default, not Files-visible, not OS-evictable. Correct semantics. Any carve-out via `NSURLIsExcludedFromBackupKey` at the target level must be verified at implementation time (see [bridge design open items](#10-open-items--verification-at-implementation-time)).

### 2.2 Copy mechanism — `Database.backup(to:)`, NOT `FileManager.copyItem`

Use GRDB's wrapper over the SQLite Online Backup API:

```swift
try dbQueue.backup(to: backupDbQueue)
```

Reasons `copyItem` is unsafe:
- The live DB may have an open WAL file or in-flight transactions dirtying pages; a raw file copy can produce a torn backup.
- The SQLite Online Backup API locks the source page-by-page and produces a guaranteed-consistent destination. It is the standard safe-backup primitive.

### 2.3 Pre-flight checks (in order)

Before starting the backup copy:

1. **Disk free ≥ 2× live DB size.** If not, abort without touching anything. Emit `migrator_bridge_skipped_disk_full`.
2. **Stale prior backup?** If `pre-grdb-bridge.bak.db` already exists, rename to `pre-grdb-bridge.bak.db.prev-<iso8601>` rather than overwrite. Keep both until success.
3. **Source DB integrity.** Run `PRAGMA integrity_check` on the live DB. If ≠ `"ok"`, abort and emit `migrator_bridge_skipped_integrity_failed`. Pre-existing corruption is not ours to silently fix.

### 2.4 Post-backup verification

After the backup copy completes, re-open the backup file as a `DatabaseQueue` and confirm all four:

1. `PRAGMA integrity_check` returns `"ok"`.
2. `DatabaseBackupService.validateDatabaseFile(at:)` passes (SQLite header, required tables).
3. Row count per required table matches the live DB.
4. The backup's `schema_version.version` matches the live DB's (smoke test against truncation).

Only after all four pass does the bridge proceed to the transaction phase (§1.5).

### 2.5 Retention policy

The backup survives the bridge transaction. Deletion triggers (any of):

- **Successful bridge + 7 successful app launches** with no `migrator_*_failed` events in same-device telemetry. Tracked via `UserDefaults` key `migrator.bridge.postSuccessfulLaunchCount`.
- **User-initiated** via Settings → Debug → "Delete GRDB bridge backup".
- **App uninstall.** Application Support is removed with the app bundle.

Rationale: 7 launches comfortably covers latent FK-violation paths that don't trigger every launch. Disk cost is negligible vs. the cost of deleting our only recovery artifact too soon.

### 2.6 Restore procedure

Shipped code, not a manual process. Invoked only by the failure paths in §3. Steps:

1. `DatabaseManager.shared.close()`.
2. Rename live DB to `<Documents>/SQLite/liftmark.db.failed-<iso8601>` (retained as a second safety copy; do not delete).
3. `FileManager.copyItem` from `pre-grdb-bridge.bak.db` to `<Documents>/SQLite/liftmark.db` (destination is no longer hot; copy is safe here).
4. Reopen via `DatabaseManager.shared.database()` — runs the **old** `runMigrations` path, which is a no-op on a restored DB that was already at v13.
5. Set `UserDefaults` flag `migrator.bridge.lastAttemptFailed = true`. The app shows a one-time alert on next launch and leaves the flag set until the next successful bridge attempt.

Key invariant: **the bridge is the sole writer of `grdb_migrations`**. Restore reverts to pre-bridge state; no ghost rows.

---

## 3. Failure matrix

Every failure has a detection signal, user-facing behavior, Sentry event, and recovery path. "Tell the user to reinstall" is **never** a recovery path — reinstalling wipes Application Support and loses the one backup.

| # | Case | Detection | User-facing | Sentry event | Recovery |
|---|------|-----------|-------------|--------------|----------|
| 3.a | Disk full / pre-flight fails | §2.3 #1 | "Free up ~{2×dbSize} MB and relaunch." App stalls on loading. No DB traffic. | `migrator_bridge_skipped_disk_full` | User frees space, relaunches. No data touched. |
| 3.b | Pre-existing corruption | `PRAGMA integrity_check` ≠ `"ok"` | "Your local workout database reports an inconsistency. LiftMark will not upgrade until this is resolved. Tap here to export a copy for support." | `migrator_bridge_skipped_integrity_failed` | Support-assisted. Bridge refuses to run migrations on a corrupt DB. |
| 3.c | Backup write/verification fails | throw from `dbQueue.backup` or failure in §2.4 | "LiftMark couldn't create a safety backup. Your data is unchanged. Please try again." App refuses to proceed. | `migrator_bridge_backup_failed` (with `verificationStep`) | Do NOT retry on the same launch. Next launch re-runs pre-flight. Partial backup renamed to `.prev-<iso>` for support. |
| 3.d | Bridge SQL fails | throw during §1.5 phase 2 | "Database upgrade couldn't complete. Your data has been restored from backup. Please try again." | `migrator_bridge_write_failed` (with `lastIdentifier`) | Auto-restore per §2.6. Transaction rollback is primary defense; restore is the safety belt. |
| 3.e.1 | First post-bridge migration throws (future v14+) | throw inside `migrator.migrate(db)` | "Database upgrade failed and has been rolled back. Your data is unchanged." | `migrator_post_bridge_migration_failed` (with `failedIdentifier`) | Transaction rollback leaves live DB unchanged. Retry on next launch once fix ships. |
| 3.e.2 | `schema_version.version > 13` | Pre-check | "This database was written by a newer version of LiftMark. Update the app to continue." App refuses to proceed. | `migrator_bridge_refused_future_version` | Wait for upgrade. |
| 3.f | FK violation at commit | `SQLITE_CONSTRAINT_FOREIGNKEY` (extended 787) | Same as 3.e.1 | `migrator_post_bridge_fk_violation` (with `failedIdentifier`, `fkTable`) | Transaction rollback. Investigate before re-enabling. |
| 3.g | Build number changed since last successful bridge | New build launch: `grdb_migrations` populated AND `schema_version` present AND `lastSuccessBuildNumber` differs | None — fires for any build transition (upgrade, downgrade, or non-numeric change). | On relaunch with a different build: `migrator_bridge_build_number_changed` (informational, with `direction` = `upgrade` / `downgrade` / `changed`) | None needed. This is why `schema_version` is retained (§1.4). The downgrade case is what motivates the breadcrumb; the upgrade/changed cases are recorded for completeness. |
| 3.h | App killed mid-bridge | Next launch: `grdb_migrations` populated → treat as success. Empty → retry. | None. | `migrator_bridge_resumed_after_kill` breadcrumb on retry. | Idempotent retry. Reuse the verified backup rather than regenerate. |
| 3.i | Bridge ran → downgrade → upgrade-forward | Compound of 3.g + forward: `grdb_migrations` populated, `schema_version = 13`. | None. | `migrator_bridge_skipped_already_done` | None. No re-entry. |

### Rejected recovery paths

- **"Reinstall."** Reinstall removes Application Support → wipes the pre-bridge backup → wipes the live DB. Never surface this.
- **"Recreate from scratch."** Any "just start fresh" fallback is a data-loss bug with a kind face.

---

## 4. DatabaseMigrator registration model

Each of v1..v13 is registered as an **individual** `DatabaseMigrator` migration with a real body. For existing users, the bridge writes the `vN_*` identifier rows so the migrator skips those migrations. Users on lower legacy versions (rare) still get the remaining chain executed by the migrator.

### 4.1 Why not a single collapsed `v1_bootstrap`

Rejected alternatives:

- A single `v1_bootstrap` containing the cumulative v13 DDL, with the bridge writing a single row. Loses audit granularity (`grdb_migrations` could no longer answer "which users crossed v9 → v10"), diverges from the per-version test seeds, and worsens onboarding: `v11_gym_unique_fk_indexes` is self-documenting, `v1_bootstrap` is not.
- GRDB's `merging:` option for identifier consolidation. Defer to a much later cleanup gated on "we never need to debug v1..v13 individually again."

### 4.2 Migration bodies

- `v1_bootstrap` contains the full v1 schema DDL as `DatabaseManager.migrateToV1` does today. It runs on fresh installs post-switch.
- `v2_sync_metadata_stats`..`v13_default_timer_countdown` each mirror the current `migrateToVN` bodies exactly. No behavioral change.

### 4.3 Fresh-install path

1. `schema_version` absent.
2. `grdb_migrations` absent.
3. Bridge detects fresh install, emits `migrator_bridge_skipped_fresh_install`, returns.
4. `DatabaseMigrator` runs v1..v13 in order.
5. After the migrator commits, write `schema_version.version = 13` so a downgrade still sees the expected version.

### 4.4 Future cleanup

When §6's trigger fires, we remove:

- The bridge class and its call site.
- `DatabaseManager.runMigrations` and the `schema_version` writes.
- The `schema_version` table, via a new `v14_drop_legacy_schema_version` migration.
- The per-launch `UserDefaults` trackers.

The registered v1..v13 migrations remain. They are idempotent no-ops for any already-bridged DB.

---

## 5. Telemetry

All events share `category: .database`. Events and allowlist live here; mechanism (the `CrashReporter.beforeSend` sanitizer) lives in [`sentry.md`](sentry.md).

### 5.1 Metadata allowlist (`migratorMetadataAllowlist`)

Defined in `CrashReporter` as a compile-time `Set<String>`. Without it, `beforeSend` sanitizes these keys away.

Keys:

| Key | Purpose |
|-----|---------|
| `fromVersion` | Starting `schema_version.version` (Int as String) |
| `toIdentifier` | Highest bridge identifier written (String) |
| `bridgedIdentifierCount` | Count of identifier rows inserted (Int as String) |
| `durationMs` | Wall-clock duration (Int as String) |
| `backupPath` | Path only, never user content (String) |
| `backupSizeBytes` | Int as String |
| `dbSizeBytes` | Int as String |
| `freeBytes` | Int as String |
| `verificationStep` | One of `integrity`, `header`, `tables`, `rowCount` |
| `failedIdentifier` | String |
| `fkTable` | String (already allowlisted for sync; reused) |
| `errorDomain`, `errorCode` | String / Int (already allowlisted for sync; reused) |
| `integrityCheckOutput` | Truncated to 2 KB; SQLite's integrity_check emits structural messages only |
| `resumeReason` | For §3.h breadcrumb |

### 5.2 Event catalog

Positive-path events:

| Event                                      | When                                                          | Payload                                                              |
|--------------------------------------------|---------------------------------------------------------------|----------------------------------------------------------------------|
| `migrator_bridge_attempted`                | Entry to bridge, after pre-flight passes                      | `fromVersion`, `dbSizeBytes`                                          |
| `migrator_bridge_succeeded`                | After transaction commit, before returning                    | `fromVersion`, `toIdentifier`, `bridgedIdentifierCount`, `durationMs` |
| `migrator_bridge_build_number_changed`     | See §3.g                                                      | `buildNumber`, previous `lastSuccessBuildNumber`, `direction`         |

> `migrator_bridge_skipped_fresh_install` and `migrator_bridge_skipped_already_done` were previously emitted as Sentry events but were demoted to breadcrumbs because they fire on every launch for every already-bridged user, which generated high-volume info-level noise in Sentry. See §5.3.1 for the revised cleanup-trigger approach.

> `migrator_bridge_backup_succeeded` was previously emitted as an event but was demoted to a breadcrumb — backup completion is informational, doesn't need to count against the Sentry event cap, and the end-of-bridge `migrator_bridge_succeeded` event already records the overall outcome. Asserted by `MigratorBridgeTests.testBridge_emitsExpectedEventSequence`.

Failure events (one per §3 row):

| Event                                         | §3 case |
|-----------------------------------------------|---------|
| `migrator_bridge_skipped_disk_full`           | 3.a     |
| `migrator_bridge_skipped_integrity_failed`    | 3.b     |
| `migrator_bridge_backup_failed`               | 3.c     |
| `migrator_bridge_write_failed`                | 3.d     |
| `migrator_post_bridge_migration_failed`       | 3.e.1   |
| `migrator_bridge_refused_future_version`      | 3.e.2   |
| `migrator_post_bridge_fk_violation`           | 3.f     |
| `migrator_bridge_restore_succeeded`           | Emitted after §2.6 completes |
| `migrator_bridge_restore_failed`              | Emitted if §2.6 itself throws — escalates to `tag: "data_loss"` |

Breadcrumbs (not events):

- `bridge.preflight.begin` / `bridge.preflight.end`
- `bridge.backup.begin` / `bridge.backup.end`
- `migrator_bridge_backup_succeeded` (payload: `backupSizeBytes`, `backupPath`, `durationMs`)
- `bridge.write.begin` / `bridge.write.end`
- `bridge.resumed_after_kill` (§3.h)
- `migrator_bridge_skipped_fresh_install`
- `migrator_bridge_skipped_already_done`

### 5.3 `migrator_bridge_succeeded` — cleanup-trigger event

The single event that drives §6. Requirements:

- **Emitted exactly once per device per bridge.** Guard via `UserDefaults.migrator.bridge.succeededEventSent`. A downgrade-then-upgrade re-emission is acceptable; in steady state the event count equals the unique bridged-device count.
- **Carries `fromVersion`** so we can disaggregate "already at v13" from "caught up from v<13".
- **Carries `buildNumber`** (auto-attached) so Sentry queries for "devices seen in build X but no success event" are straightforward.

### 5.3.1 Cleanup-trigger signal (revised)

The previous §6 cleanup check (3) compared `migrator_bridge_skipped_already_done` event counts across build numbers to detect lingering pre-bridge traffic. That event is now a breadcrumb, so the check must be re-derived from the `migrator_bridge_succeeded` event's `buildNumber` tag instead: any device emitting sync errors without a corresponding `succeeded` tag at a bridge-containing build is a lingering pre-bridge install. Re-add a rate-limited `skipped_already_done` event (once per buildNumber per device, via UserDefaults) before re-evaluating cleanup readiness if the `succeeded`-only signal is insufficient.

### 5.4 Alert tag

Every failure event sets `scope.setTag("data_integrity_risk", "true")` except `build_number_changed`. This supports a single Sentry alert rule on the tag.

---

## 6. Cleanup trigger — telemetry-gated

Cleanup = removing `DatabaseManager.runMigrations`, removing the bridge class, and shipping `v14_drop_legacy_schema_version`.

We ship the cleanup build when **all** of the following hold:

1. At least **90 consecutive days** have passed since the bridge was first released to TestFlight (absolute floor for infrequent-use devices).
2. In the Sentry query `event:migrator_bridge_succeeded AND environment:(testflight OR release)`, the most recent 30 days of events show **≥ 95%** of all devices currently emitting any event (measured by Sentry `device.id`) have a `migrator_bridge_succeeded` event at some point in history.
3. **Zero** lingering pre-bridge traffic per §5.3.1 (the original `skipped_already_done`-count check is superseded; use the `migrator_bridge_succeeded` `buildNumber` coverage signal instead).
4. **Zero** `migrator_bridge_*_failed` events in the last 30 days are unreproduced or unexplained.

The rule is intentionally conservative: the wrong side of the decision is shipping cleanup while a user still has an un-bridged DB.

---

## 7. Rollout

### 7.1 No remote config; build-level gate

No remote-config infrastructure is introduced for this one-shot migration. Rollback mechanism: compile-time constant `MigratorBridge.isEnabled` (default `true`). Flipping to `false` in a hotfix build cuts a new TestFlight in ~20 minutes.

No runtime opt-out in Settings: correctness upgrades should not be user-toggleable.

### 7.2 Canary plan

- **Phase 0** (internal): build-and-run locally; upgrade-path tests (PR 2) must be green.
- **Phase 1** (TestFlight internal, ~1 week): owner devices only. Verify `migrator_bridge_succeeded` fires with `fromVersion = 13`, backup file appears in Application Support, manual downgrade to previous TestFlight build still opens the DB cleanly (§3.g).
- **Phase 2** (TestFlight external, ~2 weeks): existing external tester group. Watch Sentry for:
  - Any `migrator_bridge_*_failed` → pause rollout.
  - `migrator_bridge_succeeded` without preceding `migrator_bridge_backup_succeeded` → pause (should be impossible by construction).
  - `migrator_bridge_restore_failed` with `tag: "data_loss"` → immediate pause + incident.
- **Phase 3** (App Store): once Phase 2 is clean for ≥14 days with ≥20 unique-device bridges, ship to general release. Continue monitoring for at least one more release cycle before touching the bridge code again.

### 7.3 Rollback criteria

Hotfix with `MigratorBridge.isEnabled = false` if:

- Any `migrator_bridge_restore_failed` with `tag: "data_loss"` — one is enough.
- `migrator_bridge_backup_failed` rate > 1% of bridge attempts over any rolling 24h window after Phase 1.
- Any `migrator_post_bridge_fk_violation`.

Rollback means the old `runMigrations` path keeps running. Because the bridge is idempotent and keeps `schema_version` consistent, re-enabling later is safe.

---

## 8. Dependencies

- **GRDB.swift** — see [`../ios-project.md`](../ios-project.md) for the version floor. Features required: `DatabaseMigrator` and `DatabaseReader.backup(to:)`.
- **Sentry** — see [`sentry.md`](sentry.md) for the `beforeSend` sanitizer and the migrator metadata allowlist.
- **DatabaseBackupService** (`Services/DatabaseBackupService.swift`) — the bridge reuses its `validateDatabaseFile(at:)` logic and required-tables list against the just-written backup file. The bridge does **not** reuse `exportDatabase()` (cache-dir location is unsafe for a safety backup).

---

## 9. Tests

- **Upgrade-path tests** (`LiftMarkTests/DatabaseMigrationTests.swift`, shipped in PR 2) pin the current behavior of the hand-rolled chain end-to-end and the idempotency of re-invocation. Seeds under `test-fixtures/db-seeds/`; see [`../../test-fixtures/db-seeds/README.md`](../../test-fixtures/db-seeds/README.md).
- **Bridge tests** (shipped in PR 3) assert the transaction semantics, the failure matrix (§3), and the restore path (§2.6).
- **Manual QA** covers paths XCTest can't reach: app-killed-mid-bridge (§3.h), cross-build downgrade (§3.g). Documented as a Phase-1 checklist (§7.2).

---

## 10. Open items / verification at implementation time

- **Application Support & `NSURLIsExcludedFromBackupKey`.** Verify the app's current target-level settings for Application Support do not exclude the directory from iCloud backup. If they do, the pre-bridge backup loses its device-migration safety net; carve out a per-file attribute.
- **GRDB version floor.** `DatabaseMigrator` and `Database.backup(to:)` are both available in GRDB 6.x. Confirm [`../ios-project.md`](../ios-project.md)'s documented floor is tight enough when implementing.
- **`DatabaseBackupService.exportDatabase()` cache-dir target.** Out of scope for this work; tracked separately. The bridge uses Application Support regardless.
