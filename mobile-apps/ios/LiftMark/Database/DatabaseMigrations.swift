import Foundation
import GRDB

/// GRDB `DatabaseMigrator` registration for LiftMark's schema — the sole source of
/// truth for the on-disk shape.
///
/// History: a one-time `MigratorBridge` once translated legacy `schema_version`-tracked
/// databases into GRDB's `grdb_migrations` bookkeeping, while the hand-rolled
/// `DatabaseManager.runMigrations` chain ran in parallel as a safety net. Both were
/// removed in GH #96 once telemetry proved every active device had bridged;
/// `v20_drop_legacy_schema_version` drops the now-unused `schema_version` table.
///
/// See spec/services/migrator.md.
enum DatabaseMigrations {

    /// Canonical migration identifiers, in order. This is a wire-level contract:
    /// identifiers must never be reordered or renamed after first ship (GRDB persists
    /// them as one row per identifier in `grdb_migrations`). See spec/services/migrator.md §1.
    static let identifiers: [String] = [
        "v1_bootstrap",
        "v2_sync_metadata_stats",
        "v3_developer_mode",
        "v4_soft_delete_gyms",
        "v5_countdown_sounds",
        "v6_session_set_side",
        "v7_accepted_disclaimer",
        "v8_updated_at_cksync",
        "v9_api_key_fk_indexes",
        "v10_distance_columns",
        "v11_gym_unique_fk_indexes",
        "v12_set_measurements",
        "v13_default_timer_countdown",
        "v14_default_weight_step_lbs",
        "v15_ai_prompt_toggles",
        "v16_workout_inbox",
        "v17_outbox_pending_queue",
        "v18_workout_inbox_drop_preparse",
        "v19_ck_record_metadata",
        "v20_drop_legacy_schema_version"
    ]

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_bootstrap") { db in
            // v1_bootstrap — full schema as of the original v1 schema.

            // Template tables
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS workout_templates (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT,
                    tags TEXT,
                    default_weight_unit TEXT,
                    source_markdown TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    is_favorite INTEGER DEFAULT 0
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS template_exercises (
                    id TEXT PRIMARY KEY,
                    workout_template_id TEXT NOT NULL,
                    exercise_name TEXT NOT NULL,
                    order_index INTEGER NOT NULL,
                    notes TEXT,
                    equipment_type TEXT,
                    group_type TEXT,
                    group_name TEXT,
                    parent_exercise_id TEXT,
                    FOREIGN KEY (workout_template_id) REFERENCES workout_templates(id) ON DELETE CASCADE,
                    FOREIGN KEY (parent_exercise_id) REFERENCES template_exercises(id) ON DELETE CASCADE
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS template_sets (
                    id TEXT PRIMARY KEY,
                    template_exercise_id TEXT NOT NULL,
                    order_index INTEGER NOT NULL,
                    target_weight REAL,
                    target_weight_unit TEXT,
                    target_reps INTEGER,
                    target_time INTEGER,
                    target_rpe INTEGER,
                    rest_seconds INTEGER,
                    tempo TEXT,
                    is_dropset INTEGER DEFAULT 0,
                    is_per_side INTEGER DEFAULT 0,
                    is_amrap INTEGER DEFAULT 0,
                    notes TEXT,
                    FOREIGN KEY (template_exercise_id) REFERENCES template_exercises(id) ON DELETE CASCADE
                )
            """)

            // User settings
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS user_settings (
                    id TEXT PRIMARY KEY,
                    default_weight_unit TEXT NOT NULL DEFAULT 'lbs',
                    enable_workout_timer INTEGER DEFAULT 1,
                    auto_start_rest_timer INTEGER DEFAULT 1,
                    theme TEXT DEFAULT 'auto',
                    notifications_enabled INTEGER DEFAULT 1,
                    custom_prompt_addition TEXT,
                    anthropic_api_key TEXT,
                    anthropic_api_key_status TEXT DEFAULT 'not_set',
                    healthkit_enabled INTEGER DEFAULT 0,
                    live_activities_enabled INTEGER DEFAULT 1,
                    keep_screen_awake INTEGER DEFAULT 1,
                    show_open_in_claude_button INTEGER DEFAULT 0,
                    home_tiles TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
            """)

            // Gyms + equipment
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS gyms (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    is_default INTEGER DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS gym_equipment (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    is_available INTEGER DEFAULT 1,
                    last_checked_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    gym_id TEXT
                )
            """)

            // Session tables
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS workout_sessions (
                    id TEXT PRIMARY KEY,
                    workout_template_id TEXT,
                    name TEXT NOT NULL,
                    date TEXT NOT NULL,
                    start_time TEXT,
                    end_time TEXT,
                    duration INTEGER,
                    notes TEXT,
                    status TEXT NOT NULL DEFAULT 'in_progress',
                    FOREIGN KEY (workout_template_id) REFERENCES workout_templates(id) ON DELETE SET NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_exercises (
                    id TEXT PRIMARY KEY,
                    workout_session_id TEXT NOT NULL,
                    exercise_name TEXT NOT NULL,
                    order_index INTEGER NOT NULL,
                    notes TEXT,
                    equipment_type TEXT,
                    group_type TEXT,
                    group_name TEXT,
                    parent_exercise_id TEXT,
                    status TEXT NOT NULL DEFAULT 'pending',
                    FOREIGN KEY (workout_session_id) REFERENCES workout_sessions(id) ON DELETE CASCADE,
                    FOREIGN KEY (parent_exercise_id) REFERENCES session_exercises(id) ON DELETE CASCADE
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_sets (
                    id TEXT PRIMARY KEY,
                    session_exercise_id TEXT NOT NULL,
                    order_index INTEGER NOT NULL,
                    parent_set_id TEXT,
                    drop_sequence INTEGER,
                    target_weight REAL,
                    target_weight_unit TEXT,
                    target_reps INTEGER,
                    target_time INTEGER,
                    target_rpe INTEGER,
                    rest_seconds INTEGER,
                    actual_weight REAL,
                    actual_weight_unit TEXT,
                    actual_reps INTEGER,
                    actual_time INTEGER,
                    actual_rpe INTEGER,
                    completed_at TEXT,
                    status TEXT NOT NULL DEFAULT 'pending',
                    notes TEXT,
                    tempo TEXT,
                    is_dropset INTEGER DEFAULT 0,
                    is_per_side INTEGER DEFAULT 0,
                    FOREIGN KEY (session_exercise_id) REFERENCES session_exercises(id) ON DELETE CASCADE,
                    FOREIGN KEY (parent_set_id) REFERENCES session_sets(id) ON DELETE CASCADE
                )
            """)

            // Sync tables
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_metadata (
                    id TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    last_sync_date TEXT,
                    server_change_token TEXT,
                    sync_enabled INTEGER DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_queue (
                    id TEXT PRIMARY KEY,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT NOT NULL,
                    operation TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    attempts INTEGER DEFAULT 0,
                    last_attempt_at TEXT,
                    created_at TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_conflicts (
                    id TEXT PRIMARY KEY,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT NOT NULL,
                    local_data TEXT NOT NULL,
                    remote_data TEXT NOT NULL,
                    resolution TEXT NOT NULL,
                    resolved_at TEXT,
                    created_at TEXT NOT NULL
                )
            """)

            // v1 indexes
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_template_exercises_workout
                ON template_exercises(workout_template_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_template_sets_exercise
                ON template_sets(template_exercise_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_workout_templates_favorite
                ON workout_templates(is_favorite)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_session_exercises_session
                ON session_exercises(workout_session_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_session_exercises_name
                ON session_exercises(exercise_name)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_session_sets_exercise
                ON session_sets(session_exercise_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_workout_sessions_status
                ON workout_sessions(status)
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_name ON gym_equipment(name)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_gym ON gym_equipment(gym_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gyms_default ON gyms(is_default)")
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_sync_queue_entity
                ON sync_queue(entity_type, entity_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_sync_conflicts_entity
                ON sync_conflicts(entity_type, entity_id)
                """)

            // Orphaned equipment fixup
            let orphanCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM gym_equipment WHERE gym_id IS NULL"
            ) ?? 0
            if orphanCount > 0 {
                let now = ISO8601DateFormatter().string(from: Date())
                let orphanGymId = IDGenerator.generate()
                try db.execute(
                    sql: "INSERT INTO gyms (id, name, is_default, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                    arguments: [orphanGymId, "My Gym", 1, now, now]
                )
                try db.execute(
                    sql: "UPDATE gym_equipment SET gym_id = ? WHERE gym_id IS NULL",
                    arguments: [orphanGymId]
                )
            }

            // Default user_settings row
            let existingSettings = try Row.fetchOne(db, sql: "SELECT id FROM user_settings LIMIT 1")
            if existingSettings == nil {
                let now = ISO8601DateFormatter().string(from: Date())
                try db.execute(
                    sql: """
                        INSERT INTO user_settings (
                            id, default_weight_unit, enable_workout_timer, auto_start_rest_timer,
                            theme, notifications_enabled, created_at, updated_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [IDGenerator.generate(), "lbs", 1, 1, "auto", 1, now, now]
                )
            }
        }

        m.registerMigration("v2_sync_metadata_stats") { db in
            try db.execute(sql: "ALTER TABLE sync_metadata ADD COLUMN last_uploaded INTEGER DEFAULT 0")
            try db.execute(sql: "ALTER TABLE sync_metadata ADD COLUMN last_downloaded INTEGER DEFAULT 0")
            try db.execute(sql: "ALTER TABLE sync_metadata ADD COLUMN last_conflicts INTEGER DEFAULT 0")
        }

        m.registerMigration("v3_developer_mode") { db in
            try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN developer_mode_enabled INTEGER DEFAULT 0")
        }

        m.registerMigration("v4_soft_delete_gyms") { db in
            try db.execute(sql: "ALTER TABLE gyms ADD COLUMN deleted_at TEXT")
            try db.execute(sql: "ALTER TABLE gym_equipment ADD COLUMN deleted_at TEXT")

            let defaultCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM gyms WHERE is_default = 1 AND deleted_at IS NULL"
            ) ?? 0
            if defaultCount != 1 {
                try db.execute(sql: "UPDATE gyms SET is_default = 0 WHERE deleted_at IS NULL")
                let first = try Row.fetchOne(
                    db,
                    sql: "SELECT id FROM gyms WHERE deleted_at IS NULL ORDER BY name LIMIT 1"
                )
                if let id: String = first?["id"] {
                    try db.execute(sql: "UPDATE gyms SET is_default = 1 WHERE id = ?", arguments: [id])
                }
            }
        }

        m.registerMigration("v5_countdown_sounds") { db in
            try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN countdown_sounds_enabled INTEGER DEFAULT 1")
        }

        m.registerMigration("v6_session_set_side") { db in
            try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN side TEXT")
        }

        m.registerMigration("v7_accepted_disclaimer") { db in
            try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN has_accepted_disclaimer INTEGER DEFAULT 0")
        }

        m.registerMigration("v8_updated_at_cksync") { db in
            try db.execute(sql: "ALTER TABLE workout_sessions ADD COLUMN updated_at TEXT")
            try db.execute(sql: "ALTER TABLE session_exercises ADD COLUMN updated_at TEXT")
            try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN updated_at TEXT")
            try db.execute(sql: "ALTER TABLE template_exercises ADD COLUMN updated_at TEXT")
            try db.execute(sql: "ALTER TABLE template_sets ADD COLUMN updated_at TEXT")

            try db.execute(sql: """
                UPDATE workout_sessions SET updated_at = COALESCE(end_time, start_time, date || 'T00:00:00Z')
            """)
            try db.execute(sql: """
                UPDATE session_exercises SET updated_at = (
                    SELECT COALESCE(ws.end_time, ws.start_time)
                    FROM workout_sessions ws
                    WHERE ws.id = session_exercises.workout_session_id
                )
            """)
            try db.execute(sql: """
                UPDATE session_sets SET updated_at = COALESCE(completed_at, (
                    SELECT ws.start_time
                    FROM workout_sessions ws
                    JOIN session_exercises se ON se.workout_session_id = ws.id
                    WHERE se.id = session_sets.session_exercise_id
                ))
            """)
            try db.execute(sql: """
                UPDATE template_exercises SET updated_at = (
                    SELECT wt.updated_at
                    FROM workout_templates wt
                    WHERE wt.id = template_exercises.workout_template_id
                )
            """)
            try db.execute(sql: """
                UPDATE template_sets SET updated_at = (
                    SELECT wt.updated_at
                    FROM workout_templates wt
                    JOIN template_exercises te ON te.workout_template_id = wt.id
                    WHERE te.id = template_sets.template_exercise_id
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_engine_state (
                    id TEXT PRIMARY KEY DEFAULT 'default',
                    data BLOB NOT NULL
                )
            """)
        }

        m.registerMigration("v9_api_key_fk_indexes") { db in
            try db.execute(sql: "UPDATE user_settings SET anthropic_api_key = NULL")
            try db.execute(sql: "ALTER TABLE user_settings DROP COLUMN anthropic_api_key")

            try db.execute(sql: """
                CREATE TABLE gym_equipment_new (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    is_available INTEGER DEFAULT 1,
                    last_checked_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    gym_id TEXT,
                    deleted_at TEXT,
                    FOREIGN KEY (gym_id) REFERENCES gyms(id) ON DELETE CASCADE
                )
            """)
            try db.execute(sql: """
                INSERT INTO gym_equipment_new (
                    id, name, is_available, last_checked_at,
                    created_at, updated_at, gym_id, deleted_at
                )
                SELECT id, name, is_available, last_checked_at,
                       created_at, updated_at, gym_id, deleted_at
                FROM gym_equipment
            """)
            try db.execute(sql: "DROP TABLE gym_equipment")
            try db.execute(sql: "ALTER TABLE gym_equipment_new RENAME TO gym_equipment")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_name ON gym_equipment(name)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_gym ON gym_equipment(gym_id)")

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_workout_sessions_date
                ON workout_sessions(date DESC)
                """)

            let now = ISO8601DateFormatter().string(from: Date())
            try db.execute(
                sql: "UPDATE session_exercises SET updated_at = ? WHERE updated_at IS NULL",
                arguments: [now]
            )
            try db.execute(
                sql: "UPDATE session_sets SET updated_at = ? WHERE updated_at IS NULL",
                arguments: [now]
            )
            try db.execute(
                sql: "UPDATE template_exercises SET updated_at = ? WHERE updated_at IS NULL",
                arguments: [now]
            )
            try db.execute(
                sql: "UPDATE template_sets SET updated_at = ? WHERE updated_at IS NULL",
                arguments: [now]
            )

            // schema_version may not exist in the GRDB-migrator-from-scratch flow;
            // legacy pre-bridge DBs always had it. Dedup defensively when present.
            let hasSchemaVersion = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
            ) ?? 0
            if hasSchemaVersion > 0 {
                try db.execute(sql: """
                    DELETE FROM schema_version
                    WHERE rowid NOT IN (SELECT MIN(rowid) FROM schema_version)
                    """)
            }

            try db.execute(sql: "DROP TABLE IF EXISTS sync_queue")
            try db.execute(sql: "DROP TABLE IF EXISTS sync_conflicts")
        }

        m.registerMigration("v10_distance_columns") { db in
            try db.execute(sql: "ALTER TABLE template_sets ADD COLUMN target_distance REAL")
            try db.execute(sql: "ALTER TABLE template_sets ADD COLUMN target_distance_unit TEXT")

            try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN target_distance REAL")
            try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN target_distance_unit TEXT")
            try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN actual_distance REAL")
            try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN actual_distance_unit TEXT")
        }

        m.registerMigration("v11_gym_unique_fk_indexes") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_session_exercises_parent
                ON session_exercises(parent_exercise_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_session_sets_parent
                ON session_sets(parent_set_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_template_exercises_parent
                ON template_exercises(parent_exercise_id)
                """)

            try db.execute(sql: """
                CREATE TABLE gym_equipment_new (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    is_available INTEGER DEFAULT 1,
                    last_checked_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    gym_id TEXT,
                    deleted_at TEXT,
                    FOREIGN KEY (gym_id) REFERENCES gyms(id) ON DELETE CASCADE,
                    UNIQUE (gym_id, name)
                )
            """)
            try db.execute(sql: """
                INSERT INTO gym_equipment_new (
                    id, name, is_available, last_checked_at,
                    created_at, updated_at, gym_id, deleted_at
                )
                SELECT id, name, is_available, last_checked_at,
                       created_at, updated_at, gym_id, deleted_at
                FROM gym_equipment
            """)
            try db.execute(sql: "DROP TABLE gym_equipment")
            try db.execute(sql: "ALTER TABLE gym_equipment_new RENAME TO gym_equipment")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_name ON gym_equipment(name)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_gym ON gym_equipment(gym_id)")
        }

        m.registerMigration("v12_set_measurements") { db in
            // set_measurements table + indexes
            try db.execute(sql: """
                CREATE TABLE set_measurements (
                    id TEXT PRIMARY KEY,
                    set_id TEXT NOT NULL,
                    parent_type TEXT NOT NULL,
                    role TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    value REAL NOT NULL,
                    unit TEXT,
                    group_index INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT
                )
            """)
            try db.execute(sql: """
                CREATE INDEX idx_set_measurements_set
                ON set_measurements(set_id, parent_type)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_set_measurements_group
                ON set_measurements(set_id, group_index)
                """)

            // Session fan-out
            let sessionSets = try Row.fetchAll(db, sql: "SELECT * FROM session_sets")
            for row in sessionSets {
                try fanOutMeasurementsV12(
                    db,
                    row: row,
                    parentType: "session",
                    includeActual: true
                )
            }

            // Template fan-out (planned rows only have target columns)
            let templateSets = try Row.fetchAll(db, sql: "SELECT * FROM template_sets")
            for row in templateSets {
                try fanOutMeasurementsV12(
                    db,
                    row: row,
                    parentType: "planned",
                    includeActual: false
                )
            }

            // Rebuild session_sets
            try db.execute(sql: """
                CREATE TABLE session_sets_new (
                    id TEXT PRIMARY KEY,
                    session_exercise_id TEXT NOT NULL,
                    order_index INTEGER NOT NULL,
                    rest_seconds INTEGER,
                    completed_at TEXT,
                    status TEXT NOT NULL DEFAULT 'pending',
                    notes TEXT,
                    is_dropset INTEGER DEFAULT 0,
                    is_per_side INTEGER DEFAULT 0,
                    is_amrap INTEGER DEFAULT 0,
                    side TEXT,
                    updated_at TEXT,
                    FOREIGN KEY (session_exercise_id) REFERENCES session_exercises(id) ON DELETE CASCADE
                )
            """)
            try db.execute(sql: """
                INSERT INTO session_sets_new (
                    id, session_exercise_id, order_index, rest_seconds,
                    completed_at, status, notes,
                    is_dropset, is_per_side, is_amrap, side, updated_at
                )
                SELECT id, session_exercise_id, order_index, rest_seconds,
                       completed_at, status, notes,
                       is_dropset, is_per_side, 0, side, updated_at
                FROM session_sets
            """)
            try db.execute(sql: "DROP TABLE session_sets")
            try db.execute(sql: "ALTER TABLE session_sets_new RENAME TO session_sets")
            try db.execute(sql: """
                CREATE INDEX idx_session_sets_exercise
                ON session_sets(session_exercise_id)
                """)

            // Rebuild template_sets
            try db.execute(sql: """
                CREATE TABLE template_sets_new (
                    id TEXT PRIMARY KEY,
                    template_exercise_id TEXT NOT NULL,
                    order_index INTEGER NOT NULL,
                    rest_seconds INTEGER,
                    is_dropset INTEGER DEFAULT 0,
                    is_per_side INTEGER DEFAULT 0,
                    is_amrap INTEGER DEFAULT 0,
                    notes TEXT,
                    updated_at TEXT,
                    FOREIGN KEY (template_exercise_id) REFERENCES template_exercises(id) ON DELETE CASCADE
                )
            """)
            try db.execute(sql: """
                INSERT INTO template_sets_new (
                    id, template_exercise_id, order_index, rest_seconds,
                    is_dropset, is_per_side, is_amrap, notes, updated_at
                )
                SELECT id, template_exercise_id, order_index, rest_seconds,
                       is_dropset, is_per_side, is_amrap, notes, updated_at
                FROM template_sets
            """)
            try db.execute(sql: "DROP TABLE template_sets")
            try db.execute(sql: "ALTER TABLE template_sets_new RENAME TO template_sets")
            try db.execute(sql: """
                CREATE INDEX idx_template_sets_exercise
                ON template_sets(template_exercise_id)
                """)
        }

        m.registerMigration("v13_default_timer_countdown") { db in
            try db.execute(sql: """
                ALTER TABLE user_settings
                ADD COLUMN default_timer_countdown INTEGER DEFAULT 0
                """)
        }

        m.registerMigration("v14_default_weight_step_lbs") { db in
            try db.execute(sql: """
                ALTER TABLE user_settings
                ADD COLUMN default_weight_step_lbs REAL DEFAULT 2.5
                """)
        }

        m.registerMigration("v15_ai_prompt_toggles") { db in
            try db.execute(sql: """
                ALTER TABLE user_settings
                ADD COLUMN ai_prompt_include_format_pointer INTEGER DEFAULT 1
                """)
            try db.execute(sql: """
                ALTER TABLE user_settings
                ADD COLUMN ai_prompt_include_recent_workouts INTEGER DEFAULT 1
                """)
            try db.execute(sql: """
                ALTER TABLE user_settings
                ADD COLUMN ai_prompt_include_progression INTEGER DEFAULT 1
                """)
            try db.execute(sql: """
                ALTER TABLE user_settings
                ADD COLUMN ai_prompt_include_equipment INTEGER DEFAULT 1
                """)
        }

        m.registerMigration("v16_workout_inbox") { db in
            try db.execute(sql: """
                CREATE TABLE workout_inbox (
                    inbox_id              TEXT PRIMARY KEY NOT NULL,
                    fetched_at            TEXT NOT NULL,
                    created_at_server     TEXT NOT NULL,
                    source_token_id       TEXT,
                    lmwf_text             TEXT NOT NULL,
                    workout_json          TEXT NOT NULL,
                    summary_name          TEXT NOT NULL,
                    summary_exercise_count INTEGER NOT NULL DEFAULT 0,
                    summary_set_count     INTEGER NOT NULL DEFAULT 0
                )
                """)
        }

        m.registerMigration("v17_outbox_pending_queue") { db in
            try db.execute(sql: """
                CREATE TABLE outbox_pending_queue (
                    client_session_id   TEXT PRIMARY KEY NOT NULL,
                    enqueued_at         TEXT NOT NULL,
                    attempt_count       INTEGER NOT NULL DEFAULT 0,
                    next_attempt_after  TEXT,
                    last_error          TEXT
                )
                """)
        }

        // v18: slim workout_inbox — drop the persisted server pre-parse
        // (workout_json + summary_*). The table is a device-local cache
        // repopulated from the server on the next poll, so dropping &
        // recreating with lmwf_text + metadata only is clean and equivalent.
        // lmwf_text is now the single source of truth; the list summary is
        // derived in memory by parsing it on load.
        m.registerMigration("v18_workout_inbox_drop_preparse") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS workout_inbox")
            try db.execute(sql: """
                CREATE TABLE workout_inbox (
                    inbox_id              TEXT PRIMARY KEY NOT NULL,
                    fetched_at            TEXT NOT NULL,
                    created_at_server     TEXT NOT NULL,
                    source_token_id       TEXT,
                    lmwf_text             TEXT NOT NULL
                )
                """)
        }

        // v19: per-record CloudKit system-fields (change tag) cache. CKSyncEngine
        // persists only change tokens + pending record IDs, not the records
        // themselves, so the app must store each record's `encodedSystemFields`
        // and rehydrate the CKRecord from it on every subsequent upload —
        // otherwise updates carry a nil change tag and CloudKit rejects them with
        // `serverRecordChanged`, producing a permanent conflict loop.
        // See spec/services/cloudkit-sync.md.
        m.registerMigration("v19_ck_record_metadata") { db in
            try db.execute(sql: """
                CREATE TABLE ck_record_metadata (
                    record_name   TEXT PRIMARY KEY NOT NULL,
                    record_type   TEXT NOT NULL,
                    system_fields BLOB NOT NULL,
                    updated_at    TEXT NOT NULL
                )
                """)
        }

        // v20: drop the legacy `schema_version` table. The hand-rolled migration
        // chain and its one-time bridge (GH #79 / removed in #96) tracked progress
        // in `schema_version`; GRDB's `grdb_migrations` is now the sole bookkeeping.
        // `IF EXISTS` keeps this a no-op on fresh installs (which never create it).
        // See spec/services/migrator.md §6.
        m.registerMigration("v20_drop_legacy_schema_version") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS schema_version")
        }

        return m
    }

    private static func insertMeasurementV12(
        _ db: Database,
        setId: String,
        parentType: String,
        role: String,
        kind: String,
        value: Double,
        unit: String?,
        updatedAt: String?
    ) throws {
        let id = UUID().uuidString
        try db.execute(
            sql: """
            INSERT INTO set_measurements (
                id, set_id, parent_type, role, kind, value, unit, group_index, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)
            """,
            arguments: [id, setId, parentType, role, kind, value, unit, updatedAt]
        )
    }

    /// Fan one legacy `*_sets` row into per-measurement rows. `target_*` columns are always
    /// considered; `actual_*` columns only when `includeActual` is true (planned rows have none).
    private static func fanOutMeasurementsV12(
        _ db: Database,
        row: Row,
        parentType: String,
        includeActual: Bool
    ) throws {
        guard let setId: String = row["id"] else { return }
        let updatedAt: String? = row["updated_at"]

        try insertMeasurementsV12(
            db,
            row: row,
            setId: setId,
            parentType: parentType,
            role: "target",
            updatedAt: updatedAt
        )
        if includeActual {
            try insertMeasurementsV12(
                db,
                row: row,
                setId: setId,
                parentType: parentType,
                role: "actual",
                updatedAt: updatedAt
            )
        }
    }

    private static func insertMeasurementsV12(
        _ db: Database,
        row: Row,
        setId: String,
        parentType: String,
        role: String,
        updatedAt: String?
    ) throws {
        let prefix = role  // "target" or "actual"

        if let weight: Double = row["\(prefix)_weight"] {
            let unit: String? = row["\(prefix)_weight_unit"]
            try insertMeasurementV12(
                db, setId: setId, parentType: parentType, role: role,
                kind: "weight", value: weight, unit: unit, updatedAt: updatedAt
            )
        }
        if let reps: Int = row["\(prefix)_reps"] {
            try insertMeasurementV12(
                db, setId: setId, parentType: parentType, role: role,
                kind: "reps", value: Double(reps), unit: nil, updatedAt: updatedAt
            )
        }
        if let time: Int = row["\(prefix)_time"] {
            try insertMeasurementV12(
                db, setId: setId, parentType: parentType, role: role,
                kind: "time", value: Double(time), unit: "s", updatedAt: updatedAt
            )
        }
        if let distance: Double = row["\(prefix)_distance"] {
            let unit: String? = row["\(prefix)_distance_unit"]
            try insertMeasurementV12(
                db, setId: setId, parentType: parentType, role: role,
                kind: "distance", value: distance, unit: unit, updatedAt: updatedAt
            )
        }
        if let rpe: Int = row["\(prefix)_rpe"] {
            try insertMeasurementV12(
                db, setId: setId, parentType: parentType, role: role,
                kind: "rpe", value: Double(rpe), unit: nil, updatedAt: updatedAt
            )
        }
    }
}
