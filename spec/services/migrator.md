# Migrator Service Specification

> LiftMark schema migrations run through GRDB's `DatabaseMigrator`. It is the **sole** mechanism and
> the authoritative record of which migrations have been applied (one row per identifier in
> `grdb_migrations`).
>
> Source-of-truth companions: [`../data/migration-contract.md`](../data/migration-contract.md) (rules and lossy-transform inventory), [`../data/database-schema.md`](../data/database-schema.md) (current shape), [`backup.md`](backup.md) (pre-upgrade backup), [`sentry.md`](sentry.md) (telemetry).

---

## Purpose

Keep migration orchestration out of bootstrap and make GRDB's `DatabaseMigrator` the single source of
truth for the on-disk schema. `DatabaseManager.database()` opens the queue, enables foreign keys, and
calls `DatabaseMigrations.migrator.migrate(dbQueue)` — nothing else.

Priorities, in order:

1. **Correctness.** The registered migrations are the exact, ordered DDL that produces the current schema from any prior state GRDB knows about.
2. **Auditability.** `grdb_migrations` answers "which migrations has this device applied?" per-identifier.
3. **No data loss.** Migrations that reshape data (v9, v11, v12 table rebuilds) preserve user rows; the upgrade-path tests (§5) pin this against frozen seeds.

---

## 1. Migration identifiers

GRDB persists applied migrations as one row per identifier in
`grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL)`. The identifier set is a wire-level contract:
**identifiers must never be reordered or renamed after first ship.** See
[`../data/migration-contract.md`](../data/migration-contract.md) §4.

| Identifier                          | Summary |
|-------------------------------------|---------|
| `v1_bootstrap`                      | Full v1 schema (templates, sessions, gyms, sync, settings) + seed defaults |
| `v2_sync_metadata_stats`            | Sync stat columns on `sync_metadata` |
| `v3_developer_mode`                 | `developer_mode_enabled` |
| `v4_soft_delete_gyms`               | `deleted_at` on gyms/equipment + default-gym fixup |
| `v5_countdown_sounds`               | `countdown_sounds_enabled` |
| `v6_session_set_side`               | `session_sets.side` |
| `v7_accepted_disclaimer`            | `has_accepted_disclaimer` |
| `v8_updated_at_cksync`              | `updated_at` columns + `sync_engine_state` (CKSyncEngine) |
| `v9_api_key_fk_indexes`             | Drop legacy API key column; rebuild `gym_equipment` with FK; drop legacy sync tables |
| `v10_distance_columns`              | Distance columns on template/session sets |
| `v11_gym_unique_fk_indexes`         | Composite `UNIQUE(gym_id, name)`; parent-FK indexes |
| `v12_set_measurements`              | `set_measurements` table + fan-out; slim `*_sets` |
| `v13_default_timer_countdown`       | `default_timer_countdown` |
| `v14_default_weight_step_lbs`       | `default_weight_step_lbs` |
| `v15_ai_prompt_toggles`             | AI-prompt inclusion toggles |
| `v16_workout_inbox`                 | `workout_inbox` table |
| `v17_outbox_pending_queue`          | `outbox_pending_queue` table |
| `v18_workout_inbox_drop_preparse`   | Slim `workout_inbox` to `lmwf_text` + metadata |
| `v19_ck_record_metadata`            | `ck_record_metadata` (per-record CloudKit system fields) |
| `v20_drop_legacy_schema_version`    | `DROP TABLE IF EXISTS schema_version` (legacy bookkeeping retirement, GH #96) |

Naming rule: `vN_<short_description>`. The numeric prefix is sequential and matches the order
`DatabaseMigrator` enforces. It is **not** a stored version number — there is no integer schema version
on disk anymore (see §3).

Adding a migration is one `m.registerMigration("vN_…") { db in … }` block appended to
`DatabaseMigrations.migrator`, plus its identifier in `DatabaseMigrations.identifiers`, plus a
cross-check/upgrade-path test update (§5).

---

## 2. Registration model

Each identifier is registered as an **individual** `DatabaseMigrator` migration with a real body in
`DatabaseMigrations.swift`. Fresh installs run `v1_bootstrap`..`v20_*` in order from an empty DB.

### 2.1 Why not a single collapsed `v1_bootstrap`

Rejected: a single `v1_bootstrap` containing the cumulative DDL. It loses audit granularity
(`grdb_migrations` could no longer answer "which devices crossed v9 → v10"), diverges from the
per-version test seeds, and worsens onboarding — `v11_gym_unique_fk_indexes` is self-documenting,
`v1_bootstrap` is not. GRDB's `merging:` consolidation is deferred to a much later cleanup gated on
"we never need to debug v1..vN individually again."

### 2.2 Migration bodies

- `v1_bootstrap` contains the full v1 schema DDL. It runs on fresh installs.
- `v2_*`..`v19_*` each apply one incremental change (column adds, table rebuilds, data fan-out).
- `v20_drop_legacy_schema_version` drops the legacy `schema_version` table with `IF EXISTS`, so it is a
  no-op on fresh installs (which never created it) and a one-time cleanup on devices that carried the
  legacy table forward from the bridge era (§4).

---

## 3. No integer schema version on disk

The app no longer tracks an integer schema version. `grdb_migrations` is the only bookkeeping. The
legacy `schema_version` table — written by the removed hand-rolled `DatabaseManager.runMigrations`
chain — is dropped by `v20_drop_legacy_schema_version`.

Consequences:

- There is no "future version refusal." If a database carries `grdb_migrations` rows for identifiers a
  build does not know about, GRDB simply has no pending registered migrations to run and proceeds. The
  bridge-era downgrade-safety machinery (which kept `schema_version` on disk for pre-bridge builds) is
  gone; downgrading to a pre-bridge build is no longer supported.
- Tests that need to simulate "a device at legacy version N" stamp `grdb_migrations` with identifiers
  v1..vN before running the migrator (see `DatabaseSeedLoader.migrate`), reproducing exactly what the
  one-time bridge did in the field.

---

## 4. History — the one-time bridge (removed in GH #96)

This section is retained for institutional memory; the code it describes no longer exists.

GRDB's `DatabaseMigrator` shipped (GH #83, "PR 3") behind a one-time **`MigratorBridge`** that
translated legacy `schema_version`-tracked databases into `grdb_migrations` rows, while the original
hand-rolled `DatabaseManager.runMigrations` chain ran in parallel as a safety net. The bridge:

- For a device at legacy `schema_version.version = N`, wrote identifier rows `v1_bootstrap`..`vN_*` into
  `grdb_migrations`, then handed off to the migrator for `v(N+1)..` real migrations.
- Took a verified, restorable pre-bridge backup (`backup.md`) and emitted a `migrator_*` Sentry event
  family gated on a `migratorMetadataAllowlist` in `CrashReporter`.
- Was telemetry-gated for removal: ≥90 days since first TestFlight ship, ≥95% device bridge coverage,
  zero unexplained `migrator_*_failed`, and an App Store release cycle of clean soak.

Once those gates were met, **PR 5 (GH #96)** removed, in one revert-safe commit:

- The bridge classes (`MigratorBridge`, `MigratorBridgeBackup`, `MigratorBridgeFailure`) and the boot
  alert UI (`MigratorBridgeAlertView`, GH #95).
- `DatabaseManager.runMigrations` and every `migrateToVN` body (now duplicated only as the migrator's
  registered bodies, which remain the source of truth).
- All `schema_version` writes, plus `v20_drop_legacy_schema_version` to drop the table itself.
- The per-launch `UserDefaults` trackers (`lastSuccessBuildNumber`, `lastAttemptFailed`,
  `succeededEventSent`, `postSuccessfulLaunchCount`) and the `migratorMetadataAllowlist` /
  `captureMigratorEvent` Sentry plumbing.

The v1..vN `DatabaseMigrator` registrations were **retained** — they are idempotent for any
already-bridged DB and required for fresh installs.

> Spec errata (corrected here): the bridge-era §1.5 claimed "all three phases inside one `dbQueue.write`."
> That was not literally achievable — GRDB's `DatabaseMigrator.migrate` opens its own transaction(s),
> so the bridge wrote identifier rows and ran the migrator in adjacent transactions, relying on
> idempotent retry (not a single atomic write) for crash-safety. Moot post-removal; recorded so the
> historical claim is not mistaken for current design.

---

## 5. Tests

- **Upgrade-path tests** (`LiftMarkTests/DatabaseMigrationTests.swift`) load a frozen seed at a historical
  version, stamp `grdb_migrations` to v1..vN (via `DatabaseSeedLoader.migrate`, mirroring the old bridge),
  run the migrator to head, and assert universal invariants (FK/integrity checks, expected tables/indexes,
  legacy `schema_version` dropped, all identifiers applied) plus behavior-specific assertions (v12 fan-out,
  v9 dedup, v11 composite-unique preservation, …). Seeds live in `LiftMarkTests/Fixtures/Seeds/`.
- **Cross-check tests** (`DatabaseMigrationCrossCheckTests.swift`) diff each frozen seed's schema against
  the schema produced by running the migrator to the same version, so the seeds and live migrator cannot
  drift. `SchemaSnapshot` excludes the `schema_version` / `grdb_migrations` bookkeeping tables.
- **DatabaseManager tests** (`DatabaseManagerTests.swift`) assert that opening the DB applies every
  registered identifier and that `schema_version` is absent at head.

---

## 6. Dependencies

- **GRDB.swift** — `DatabaseMigrator` (and, historically, `DatabaseReader.backup(to:)`). See [`../ios-project.md`](../ios-project.md) for the version floor.
- **Sentry** — schema-migration failures now surface as ordinary unhandled errors/crashes, not a bespoke event family. The migrator metadata allowlist was removed with the bridge (see [`sentry.md`](sentry.md)).
