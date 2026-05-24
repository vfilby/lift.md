# Database Schema — Interop Contract

> Canonical SQLite DDL for the LiftMark `.db` backup format. Any app version or platform implementation that reads or writes `.db` files **must** conform to this schema.
>
> See also: [data-model.md](../data-model.md) for entity definitions and business rules, [import-export-schema.md](import-export-schema.md) for JSON and markdown formats.

---

## Overview

- **Format**: SQLite 3
- **File extension**: `.db`
- **Foreign keys**: `PRAGMA foreign_keys = ON`
- **Schema version**: Tracked in `grdb_migrations` (authoritative) and `schema_version` (legacy; still on disk during the bridge transition — see [`../services/migrator.md`](../services/migrator.md)).
- **Current version**: 16

### Version History

Observable changes per schema version. Full migration contract lives in [`migration-contract.md`](migration-contract.md); migrator orchestration in [`../services/migrator.md`](../services/migrator.md).

| Ver | Observable change |
|-----|-------------------|
| 1   | Bootstrap: create all core tables, 12 indexes, seed default `user_settings` row, orphan-equipment rescue. |
| 2   | `sync_metadata` += `last_uploaded`, `last_downloaded`, `last_conflicts`. |
| 3   | `user_settings` += `developer_mode_enabled`. |
| 4   | `gyms` / `gym_equipment` += `deleted_at`; invariant fix: exactly one non-deleted gym has `is_default = 1`. |
| 5   | `user_settings` += `countdown_sounds_enabled`. |
| 6   | `session_sets` += `side`. |
| 7   | `user_settings` += `has_accepted_disclaimer`. |
| 8   | `updated_at` added + backfilled on `workout_sessions`, `session_exercises`, `session_sets`, `template_exercises`, `template_sets`; `sync_engine_state` created. |
| 9   | `anthropic_api_key` wiped and column dropped; `gym_equipment` rebuilt with FK to `gyms(id) ON DELETE CASCADE`; `idx_workout_sessions_date` added; residual `updated_at` NULLs backfilled; `schema_version` de-duplicated; `sync_queue` and `sync_conflicts` dropped. |
| 10  | `template_sets` and `session_sets` += distance columns (`target_distance`, `target_distance_unit`; plus `actual_distance`, `actual_distance_unit` on `session_sets`). |
| 11  | Self-FK parent indexes added on `session_exercises`, `session_sets`, `template_exercises`; `gym_equipment` rebuilt with composite `UNIQUE (gym_id, name)` (global `UNIQUE (name)` relaxed). |
| 12  | Major reshape: `set_measurements` created; all measurement columns fanned out from `session_sets` / `template_sets`; both set tables rebuilt with measurement columns removed and lossy drop of `parent_set_id`, `drop_sequence`, `tempo`, `target_weight_unit` (see "Legacy columns removed in v12" below). |
| 13  | `user_settings` += `default_timer_countdown`. |
| 14  | `user_settings` += `default_weight_step_lbs` (REAL, default 2.5). |
| 15  | `user_settings` += `ai_prompt_include_format_pointer`, `ai_prompt_include_recent_workouts`, `ai_prompt_include_progression`, `ai_prompt_include_equipment` (INTEGER, default 1). |
| 16  | `workout_inbox` table created (device-local, not synced, not exported). |

### Forward Compatibility

- Newer schema versions add tables, columns, or indexes via migrations.
- An app receiving a `.db` file with a **higher** schema version than it supports **should reject the file** with a clear error rather than silently losing data.
- An app receiving a `.db` file with a **lower** schema version **must run its migration chain** to bring the file up to the current version before use.
- During the bridge transition, exported `.db` files carry both `schema_version` (legacy) and `grdb_migrations` (authoritative). Importers that understand both **should prefer `grdb_migrations`** as the source of truth; `schema_version` remains for backward compatibility with pre-bridge builds.

---

## Tables

### schema_version

**Status: legacy.** Retained on-disk during the bridge transition so that users who downgrade to a pre-bridge build still see the correct version and the old migrator no-ops. New authoritative bookkeeping lives in `grdb_migrations` (below). See [`../services/migrator.md`](../services/migrator.md) for removal timing (telemetry-gated).

Single-row table tracking the hand-rolled migration version.

```sql
CREATE TABLE IF NOT EXISTS schema_version (
  version INTEGER NOT NULL DEFAULT 0
);
```

---

### grdb_migrations

**Status: authoritative** going forward. Owned and written by GRDB's `DatabaseMigrator`. One row per applied migration identifier. See [`../services/migrator.md`](../services/migrator.md) for the canonical identifier list and bridge semantics.

```sql
CREATE TABLE IF NOT EXISTS grdb_migrations (
  identifier TEXT PRIMARY KEY NOT NULL
);
```

Identifiers (v1..v15), in application order:

```
v1_bootstrap
v2_sync_metadata_stats
v3_developer_mode
v4_soft_delete_gyms
v5_countdown_sounds
v6_session_set_side
v7_accepted_disclaimer
v8_updated_at_cksync
v9_api_key_fk_indexes
v10_distance_columns
v11_gym_unique_fk_indexes
v12_set_measurements
v13_default_timer_countdown
v14_default_weight_step_lbs
v15_ai_prompt_toggles
```

The mapping is a wire-level contract — identifiers **must not change** after first ship. Canonical definition in [`../services/migrator.md`](../services/migrator.md).

---

### workout_templates

Workout plan definitions. Maps to the **WorkoutPlan** entity.

```sql
CREATE TABLE IF NOT EXISTS workout_templates (
  id                  TEXT PRIMARY KEY,
  name                TEXT NOT NULL,
  description         TEXT,
  tags                TEXT,                 -- JSON array of strings
  default_weight_unit TEXT,                 -- 'lbs' or 'kg'
  source_markdown     TEXT,                 -- Original LMWF markdown
  created_at          TEXT NOT NULL,        -- ISO 8601
  updated_at          TEXT NOT NULL,        -- ISO 8601
  is_favorite         INTEGER DEFAULT 0     -- Boolean: 0 or 1
);
```

---

### template_exercises

Exercises within a workout plan. Maps to the **PlannedExercise** entity.

```sql
CREATE TABLE IF NOT EXISTS template_exercises (
  id                   TEXT PRIMARY KEY,
  workout_template_id  TEXT NOT NULL,
  exercise_name        TEXT NOT NULL,
  order_index          INTEGER NOT NULL,
  notes                TEXT,
  equipment_type       TEXT,
  group_type           TEXT,                 -- 'superset' or 'section'
  group_name           TEXT,
  parent_exercise_id   TEXT,
  FOREIGN KEY (workout_template_id) REFERENCES workout_templates(id) ON DELETE CASCADE,
  FOREIGN KEY (parent_exercise_id) REFERENCES template_exercises(id) ON DELETE CASCADE
);
```

---

### template_sets

Target sets within a planned exercise. Maps to the **PlannedSet** entity. Shape shown is **post-v12** (measurement columns removed; `set_measurements` is the source of truth for targets).

```sql
CREATE TABLE IF NOT EXISTS template_sets (
  id                    TEXT PRIMARY KEY,
  template_exercise_id  TEXT NOT NULL,
  order_index           INTEGER NOT NULL,
  rest_seconds          INTEGER,
  is_dropset            INTEGER DEFAULT 0,
  is_per_side           INTEGER DEFAULT 0,
  is_amrap              INTEGER DEFAULT 0,
  notes                 TEXT,
  updated_at            TEXT,                 -- Added in v8
  FOREIGN KEY (template_exercise_id) REFERENCES template_exercises(id) ON DELETE CASCADE
);
```

---

### workout_sessions

Actual workout instances. Maps to the **WorkoutSession** entity.

```sql
CREATE TABLE IF NOT EXISTS workout_sessions (
  id                   TEXT PRIMARY KEY,
  workout_template_id  TEXT,
  name                 TEXT NOT NULL,
  date                 TEXT NOT NULL,
  start_time           TEXT,
  end_time             TEXT,
  duration             INTEGER,
  notes                TEXT,
  status               TEXT NOT NULL DEFAULT 'in_progress',
  FOREIGN KEY (workout_template_id) REFERENCES workout_templates(id) ON DELETE SET NULL
);
```

---

### session_exercises

Exercises within a workout session. Maps to the **SessionExercise** entity.

```sql
CREATE TABLE IF NOT EXISTS session_exercises (
  id                   TEXT PRIMARY KEY,
  workout_session_id   TEXT NOT NULL,
  exercise_name        TEXT NOT NULL,
  order_index          INTEGER NOT NULL,
  notes                TEXT,
  equipment_type       TEXT,
  group_type           TEXT,
  group_name           TEXT,
  parent_exercise_id   TEXT,
  status               TEXT NOT NULL DEFAULT 'pending',
  FOREIGN KEY (workout_session_id) REFERENCES workout_sessions(id) ON DELETE CASCADE,
  FOREIGN KEY (parent_exercise_id) REFERENCES session_exercises(id) ON DELETE CASCADE
);
```

---

### session_sets

Individual sets within a session exercise. Maps to the **SessionSet** entity. Shape shown is **post-v12** (measurement columns and dropset chain removed; `set_measurements` is the source of truth for targets and actuals).

```sql
CREATE TABLE IF NOT EXISTS session_sets (
  id                   TEXT PRIMARY KEY,
  session_exercise_id  TEXT NOT NULL,
  order_index          INTEGER NOT NULL,
  rest_seconds         INTEGER,
  completed_at         TEXT,
  status               TEXT NOT NULL DEFAULT 'pending',
  notes                TEXT,
  is_dropset           INTEGER DEFAULT 0,
  is_per_side          INTEGER DEFAULT 0,
  is_amrap             INTEGER DEFAULT 0,
  side                 TEXT,                 -- 'left' or 'right' for expanded per-side timed sets, NULL otherwise
  updated_at           TEXT,                 -- Added in v8
  FOREIGN KEY (session_exercise_id) REFERENCES session_exercises(id) ON DELETE CASCADE
);
```

#### Legacy columns removed in v12

Migration v12 rebuilt both `session_sets` and `template_sets` and **silently dropped** the following columns. Any data they held is lost (see [`migration-contract.md`](migration-contract.md) for the lossy-transformation inventory, SR1–SR4):

- `session_sets.parent_set_id` — dropset chain parent reference. Dropset relationships expressible via the new `set_measurements` model are not automatically reconstructed.
- `session_sets.drop_sequence` — dropset ordering index. Lost.
- `session_sets.tempo` — tempo annotation. Lost.
- `session_sets.target_weight`, `target_weight_unit`, `target_reps`, `target_time`, `target_rpe`, `actual_weight`, `actual_weight_unit`, `actual_reps`, `actual_time`, `actual_rpe` — fanned out into `set_measurements` rows with `parent_type = 'session'`.
- `template_sets.target_weight`, `target_weight_unit`, `target_reps`, `target_time`, `target_rpe`, `tempo` — targets fanned out into `set_measurements` rows with `parent_type = 'planned'`; `tempo` is **lost**.

The `FOREIGN KEY (parent_set_id)` self-reference and the `idx_session_sets_parent` index are no longer present post-v12.

---

### set_measurements

Unified measurement store for planned targets and session actuals. Introduced in v12. Source of truth for weight / reps / time / distance / rpe values at both the template and session level.

```sql
CREATE TABLE IF NOT EXISTS set_measurements (
  id            TEXT PRIMARY KEY,
  set_id        TEXT NOT NULL,                   -- session_sets.id or template_sets.id
  parent_type   TEXT NOT NULL,                   -- 'session' or 'planned'
  role          TEXT NOT NULL,                   -- 'target' or 'actual'
  kind          TEXT NOT NULL,                   -- 'weight' | 'reps' | 'time' | 'distance' | 'rpe'
  value         REAL NOT NULL,
  unit          TEXT,                            -- 'lbs' | 'kg' | 's' | 'km' | 'mi' | NULL (for reps/rpe)
  group_index   INTEGER NOT NULL DEFAULT 0,
  updated_at    TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_set_measurements_set   ON set_measurements(set_id, parent_type);
CREATE INDEX IF NOT EXISTS idx_set_measurements_kind  ON set_measurements(kind);
```

Notes:
- `parent_type = 'planned'` rows carry only `role = 'target'` (no actuals on templates).
- `parent_type = 'session'` rows carry both `target` and `actual` as they are recorded.
- `group_index` is always `0` for rows produced by the v12 fan-out; reserved for future grouping semantics.
- There is no DB-level foreign key on `set_id` because it polymorphically references two tables; referential integrity is enforced at the application layer.

---

### user_settings

Singleton preferences table. Maps to the **UserSettings** entity.

```sql
CREATE TABLE IF NOT EXISTS user_settings (
  id                          TEXT PRIMARY KEY,
  default_weight_unit         TEXT NOT NULL DEFAULT 'lbs',
  enable_workout_timer        INTEGER DEFAULT 1,
  auto_start_rest_timer       INTEGER DEFAULT 1,
  theme                       TEXT DEFAULT 'auto',
  notifications_enabled       INTEGER DEFAULT 1,
  custom_prompt_addition      TEXT,
  anthropic_api_key           TEXT,
  anthropic_api_key_status    TEXT DEFAULT 'not_set',
  healthkit_enabled           INTEGER DEFAULT 0,
  live_activities_enabled     INTEGER DEFAULT 1,
  keep_screen_awake           INTEGER DEFAULT 1,
  show_open_in_claude_button  INTEGER DEFAULT 0,
  home_tiles                  TEXT,
  developer_mode_enabled      INTEGER DEFAULT 0,     -- Boolean: hidden developer menu
  countdown_sounds_enabled    INTEGER DEFAULT 1,     -- Boolean: audible countdown ticks
  has_accepted_disclaimer     INTEGER DEFAULT 0,     -- Boolean: onboarding disclaimer accepted
  default_timer_countdown     INTEGER DEFAULT 0,     -- Boolean: initial mode for ExerciseTimerView (0 = count-up, 1 = count-down)
  default_weight_step_lbs     REAL DEFAULT 2.5,      -- Weight stepper increment for lbs sets (2.5 or 5.0); kg sets always use 2.5
  ai_prompt_include_format_pointer  INTEGER DEFAULT 1,  -- Boolean: include brief LMWF format pointer + spec.md URL in AI prompt
  ai_prompt_include_recent_workouts INTEGER DEFAULT 1,  -- Boolean: include compact summary of last 5 workouts in AI prompt
  ai_prompt_include_progression     INTEGER DEFAULT 1,  -- Boolean: include trajectory of top-5-by-frequency exercises (compounds preferred) in AI prompt
  ai_prompt_include_equipment       INTEGER DEFAULT 1,  -- Boolean: include selected-gym equipment list in AI prompt
  created_at                  TEXT NOT NULL,
  updated_at                  TEXT NOT NULL
);
```

---

### gyms

Gym locations. Maps to the **Gym** entity.

```sql
CREATE TABLE IF NOT EXISTS gyms (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  is_default  INTEGER DEFAULT 0,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT                              -- Added in v4
);
```

Invariant (enforced by v4 migration and application code): **exactly one** non-soft-deleted gym has `is_default = 1`.

---

### gym_equipment

Equipment availability per gym. Maps to the **GymEquipment** entity. Shape shown is **post-v11** (composite unique constraint; FK to `gyms(id) ON DELETE CASCADE` added in v9).

```sql
CREATE TABLE IF NOT EXISTS gym_equipment (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  is_available    INTEGER DEFAULT 1,
  last_checked_at TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL,
  gym_id          TEXT,
  deleted_at      TEXT,                         -- Added in v4
  UNIQUE (gym_id, name),                        -- Replaced global UNIQUE(name) in v11
  FOREIGN KEY (gym_id) REFERENCES gyms(id) ON DELETE CASCADE
);
```

---

### sync_metadata

```sql
CREATE TABLE IF NOT EXISTS sync_metadata (
  id TEXT PRIMARY KEY, device_id TEXT NOT NULL, last_sync_date TEXT,
  server_change_token TEXT, sync_enabled INTEGER DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  last_uploaded   INTEGER DEFAULT 0,            -- Added in v2
  last_downloaded INTEGER DEFAULT 0,            -- Added in v2
  last_conflicts  INTEGER DEFAULT 0             -- Added in v2
);
```

### sync_engine_state

Opaque CKSyncEngine state blob, written by `CKSyncEngineManager`. Introduced in v8.

```sql
CREATE TABLE IF NOT EXISTS sync_engine_state (
  id   TEXT PRIMARY KEY DEFAULT 'default',
  data BLOB NOT NULL
);
```

### workout_inbox

Device-local table holding workouts pushed to this user from outside the app (e.g., Claude Code via PAT) that have not yet been promoted to a plan or discarded. Introduced in v16. See [`../services/workout-inbox.md`](../services/workout-inbox.md).

**Not synced via CloudKit** and **excluded from `.db` backup exports** — the server (`/v1/workouts?status=pending`) is the source of truth; a fresh install repopulates by polling.

```sql
CREATE TABLE IF NOT EXISTS workout_inbox (
  inbox_id              TEXT PRIMARY KEY NOT NULL,   -- server ULID
  fetched_at            TEXT NOT NULL,               -- ISO8601, when this device first stored it
  created_at_server     TEXT NOT NULL,               -- ISO8601, server-side created_at
  source_token_id       TEXT,                        -- PAT ULID or "session"
  lmwf_text             TEXT NOT NULL,               -- original markdown
  workout_json          TEXT NOT NULL,               -- full parsed WorkoutPlan (JSON)
  summary_name          TEXT NOT NULL,               -- denormalized for list rendering
  summary_exercise_count INTEGER NOT NULL DEFAULT 0,
  summary_set_count     INTEGER NOT NULL DEFAULT 0
);
```

Upsert key is `inbox_id` — re-polling the same item is a no-op.

---

### Removed tables: `sync_queue`, `sync_conflicts`

Both tables existed in v1 and were **dropped in v9** (replaced by `sync_engine_state` + CKSyncEngine). Any rows they contained at v8-or-earlier time are lost during the v9 upgrade. Referenced here for historical clarity — they are not part of the v13 schema.

---

## Indexes

Post-v13 index set. Some parent-FK indexes present at v11 were dropped by v12's table rebuild and **not** re-created — see [`migration-contract.md`](migration-contract.md) SR1 for details.

```sql
CREATE INDEX IF NOT EXISTS idx_template_exercises_workout     ON template_exercises(workout_template_id);
CREATE INDEX IF NOT EXISTS idx_template_sets_exercise         ON template_sets(template_exercise_id);
CREATE INDEX IF NOT EXISTS idx_workout_templates_favorite     ON workout_templates(is_favorite);
CREATE INDEX IF NOT EXISTS idx_session_exercises_session      ON session_exercises(workout_session_id);
CREATE INDEX IF NOT EXISTS idx_session_exercises_name         ON session_exercises(exercise_name);
CREATE INDEX IF NOT EXISTS idx_session_exercises_parent       ON session_exercises(parent_exercise_id); -- v11
CREATE INDEX IF NOT EXISTS idx_session_sets_exercise          ON session_sets(session_exercise_id);
CREATE INDEX IF NOT EXISTS idx_workout_sessions_status        ON workout_sessions(status);
CREATE INDEX IF NOT EXISTS idx_workout_sessions_date          ON workout_sessions(date DESC);           -- v9
CREATE INDEX IF NOT EXISTS idx_gym_equipment_gym              ON gym_equipment(gym_id);
CREATE INDEX IF NOT EXISTS idx_gyms_default                   ON gyms(is_default);
CREATE INDEX IF NOT EXISTS idx_set_measurements_set           ON set_measurements(set_id, parent_type); -- v12
CREATE INDEX IF NOT EXISTS idx_set_measurements_kind          ON set_measurements(kind);                -- v12
```

---

## Column Type Conventions

| SQLite Type | Application Type | Notes |
|-------------|-----------------|-------|
| `TEXT` | string | All IDs are UUIDs as text |
| `TEXT` (JSON) | string[] / object | `tags`, `home_tiles` stored as JSON strings |
| `INTEGER` | boolean | 0 = false, 1 = true |
| `INTEGER` | number | Reps, time (seconds), RPE |
| `REAL` | number | Weight values |
| `TEXT` | string (ISO 8601) | All date/datetime fields |

---

## Data Integrity

### Foreign Key Cascades

| Parent | Child | On Delete |
|--------|-------|-----------|
| `workout_templates` | `template_exercises` | CASCADE |
| `template_exercises` | `template_sets` | CASCADE |
| `template_exercises` | `template_exercises` (self) | CASCADE |
| `workout_templates` | `workout_sessions` | SET NULL |
| `workout_sessions` | `session_exercises` | CASCADE |
| `session_exercises` | `session_sets` | CASCADE |
| `session_exercises` | `session_exercises` (self) | CASCADE |
| `gyms` | `gym_equipment` | CASCADE (FK added in v9; prior to v9 this was application-level) |

### Application-Level Cascades

| Parent | Child | Notes |
|--------|-------|-------|
| `session_sets` / `template_sets` | `set_measurements` | No DB-level FK (polymorphic `set_id`). Application code deletes measurements before the parent set. |
