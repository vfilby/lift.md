import Foundation
import GRDB
import Logging

/// Manages the SQLite database using GRDB, including migrations.
/// Schema matches the React Native app exactly (see spec/data/database-schema.md).
final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private var dbQueue: DatabaseQueue?
    private let dbLock = NSLock()

    private static let dbName = "liftmark.db"
    static let currentSchemaVersion = 18

    private init() {}

    /// Resolves the live database file URL without opening a connection.
    /// Exposed for diagnostic flows (e.g. the migrator bridge support-export action)
    /// that need a path to share even when the DB can't be opened. Returns `nil` if
    /// the Documents directory can't be resolved.
    static func liveDatabaseURL() -> URL? {
        guard let documentsURL = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return documentsURL
            .appendingPathComponent("SQLite", isDirectory: true)
            .appendingPathComponent(dbName)
    }

    // MARK: - Public API

    /// Returns the database queue, creating/migrating if needed.
    func database() throws -> DatabaseQueue {
        dbLock.lock()
        defer { dbLock.unlock() }

        if let dbQueue { return dbQueue }

        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let sqliteDir = documentsURL.appendingPathComponent("SQLite", isDirectory: true)
        try fileManager.createDirectory(at: sqliteDir, withIntermediateDirectories: true)

        let dbPath = sqliteDir.appendingPathComponent(Self.dbName).path

        // Route GRDB statement/profile events through swift-log so SQL traffic
        // can land in the same SQLite `app_logs` store as the rest of the app.
        //
        // Opt-in via the `LIFTMARK_SQL_TRACE=1` environment variable — otherwise
        // tracing every SQL statement creates an infinite feedback loop
        // (each log INSERT fires a trace → writes another log row → another trace…).
        // Also skips statements that touch `app_logs` itself as belt-and-suspenders
        // protection if a developer enables the flag.
        var configuration = Configuration()
        if ProcessInfo.processInfo.environment["LIFTMARK_SQL_TRACE"] == "1" {
            configuration.prepareDatabase { db in
                // `liftmark.database` label routes to the `.database` category via
                // SQLiteLogHandler.fromLabel, matching DebugLogsView's existing filter.
                var grdbLogger = Logging.Logger(label: LogCategory.database.loggerLabel)
                grdbLogger.logLevel = .debug
                db.trace(options: .statement) { event in
                    let desc = "\(event)"
                    if desc.contains("app_logs") { return }
                    grdbLogger.debug(Logging.Logger.Message(stringLiteral: desc))
                }
            }
        }
        let dbQueue = try DatabaseQueue(path: dbPath, configuration: configuration)

        // Defense-in-depth for the on-device workout DB (see SECURITY_ASSESSMENT L12).
        // The genuinely sensitive secrets live in the Keychain; this hardens the
        // SQLite file (workout history) at rest and keeps it out of unencrypted
        // desktop / iCloud backups. Best-effort: failures are logged, not fatal —
        // the app must still open even if the filesystem rejects an attribute.
        Self.protectDatabaseFiles(at: URL(fileURLWithPath: dbPath), containerDirectory: sqliteDir)

        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        // Run the GRDB migrator bridge before the legacy chain. When the bridge completes
        // (or short-circuits), the legacy `runMigrations` call below either no-ops (because
        // the bridge ensured `schema_version.version = 13`) or catches up a pre-bridge DB
        // that hit the feature-flag rollback path. See spec/services/migrator.md.
        if MigratorBridge.isEnabled {
            let liveDBURL = URL(fileURLWithPath: dbPath)
            try MigratorBridge.runIfNeeded(on: dbQueue, liveDBURL: liveDBURL)
        }

        try Self.runMigrations(on: dbQueue)
        self.dbQueue = dbQueue
        return dbQueue
    }

    // MARK: - At-rest protection

    /// Hardens the SQLite database store at rest (SECURITY_ASSESSMENT L12).
    ///
    /// Operates on the *containing directory* only, never the open DB files:
    ///
    /// 1. Sets an explicit `NSFileProtection` class on the directory so files
    ///    created in it inherit encryption at rest.
    ///    `.completeUntilFirstUserAuthentication` is the safe default — it keeps
    ///    the DB readable for background tasks (push/CloudKit sync) after the
    ///    first unlock following a reboot, unlike `.complete`. (Files with no
    ///    explicit class already default to this, so this is belt-and-braces.)
    /// 2. Marks the directory as excluded from backup, which covers the whole
    ///    store — `liftmark.db` and its `-wal`/`-shm` sidecars — so workout
    ///    history is never copied into unencrypted iTunes/Finder backups.
    ///
    /// Deliberately NOT touching the live db / `-wal` / `-shm` files: mutating
    /// their attributes while GRDB holds them open in WAL mode perturbs
    /// checkpoint state (it regressed DatabaseBackupServiceTests). Hardening the
    /// directory subtree achieves the same guarantees without reaching into the
    /// open SQLite files.
    ///
    /// Best-effort and idempotent — applied on every open. Failures are logged
    /// but never thrown: an attribute we can't set must not stop the app from
    /// launching.
    private static func protectDatabaseFiles(at dbURL: URL, containerDirectory: URL) {
        // (1) File-protection class on the directory (inherited by its files).
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: containerDirectory.path
            )
        } catch {
            Logger.shared.error(.database, "Failed to set file protection on SQLite directory", error: error)
        }

        // (2) Exclude the whole store directory (db + -wal + -shm) from backup.
        excludeFromBackup(containerDirectory)
    }

    /// Sets `isExcludedFromBackup = true` on a file/directory URL. Best-effort.
    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            Logger.shared.error(.database, "Failed to exclude \(url.lastPathComponent) from backup", error: error)
        }
    }

    /// Write a clean, fully-consistent, self-contained copy of the live database
    /// to `destinationURL` using SQLite's `VACUUM INTO`.
    ///
    /// GRDB runs the database in WAL mode, so committed data (including, on a
    /// freshly-migrated DB, whole `CREATE TABLE` statements) can still live in the
    /// `-wal` sidecar until a checkpoint folds it into the main file. A plain
    /// `FileManager.copyItem` of only `liftmark.db` therefore risks producing a
    /// backup that is missing recent writes — or entire tables. `VACUUM INTO`
    /// instead has the *live* connection emit a brand-new database file that
    /// reflects the complete, current logical state regardless of WAL position,
    /// and — unlike `Database.backup(to:)` — yields a single file with **no**
    /// `-wal`/`-shm` sidecars, which is exactly what a shareable export needs.
    ///
    /// `VACUUM` cannot run inside a transaction, so this uses
    /// `writeWithoutTransaction`. The destination path must not already exist;
    /// callers are responsible for removing any stale file first. The live DB's
    /// WAL mode is left untouched.
    func vacuumInto(_ destinationURL: URL) throws {
        let dbQueue = try database()
        try dbQueue.writeWithoutTransaction { db in
            // Single-quote-escape the path for safe interpolation into the SQL
            // string literal (VACUUM INTO takes a literal, not a bound parameter).
            let escapedPath = destinationURL.path.replacingOccurrences(of: "'", with: "''")
            try db.execute(sql: "VACUUM INTO '\(escapedPath)'")
        }
    }

    /// Close the database connection.
    ///
    /// Deterministically tears down the underlying SQLite connection (and its
    /// vnode-watcher dispatch source) before releasing the queue reference, so
    /// callers that intend to mutate the backing file (rename / replace / delete)
    /// don't trip Apple's `SQLITE_IOERR_VNODE` check on a still-open connection.
    /// See GH #104.
    func close() {
        dbLock.lock()
        defer { dbLock.unlock() }
        // Synchronously close the SQLite handle. If GRDB throws (typically
        // because statements are still in-flight) we fall back to ARC teardown
        // on deinit — same behavior as before this fix, which is the flake-prone
        // path. Log so we can tell from telemetry whether this fallback ever
        // fires in production.
        if let queue = dbQueue {
            do {
                try queue.close()
            } catch {
                Logger.shared.error(.database, "DatabaseQueue.close() failed; falling back to ARC teardown", error: error)
            }
        }
        dbQueue = nil
    }

    /// Reset all data for test isolation. Opens the database if needed,
    /// truncates all tables, then closes and deletes the file.
    func deleteDatabase() {
        // Open the DB (creates it if needed) so we can truncate data.
        // This handles the case where the connection doesn't exist yet.
        if let dbQueue = try? database() {
            try? dbQueue.write { db in
                // Order matters: children first due to foreign keys
                try db.execute(sql: "DELETE FROM sync_engine_state")
                try db.execute(sql: "DELETE FROM sync_metadata")
                try db.execute(sql: "DELETE FROM set_measurements")
                try db.execute(sql: "DELETE FROM session_sets")
                try db.execute(sql: "DELETE FROM session_exercises")
                try db.execute(sql: "DELETE FROM workout_sessions")
                try db.execute(sql: "DELETE FROM template_sets")
                try db.execute(sql: "DELETE FROM template_exercises")
                try db.execute(sql: "DELETE FROM workout_templates")
                try db.execute(sql: "DELETE FROM gym_equipment")
                try db.execute(sql: "DELETE FROM gyms")
                try db.execute(sql: "DELETE FROM user_settings")
            }
        }

        // Also close and delete the file for a complete reset
        close()
        let fileManager = FileManager.default
        guard let documentsURL = try? fileManager.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        let sqliteDir = documentsURL.appendingPathComponent("SQLite").path
        try? fileManager.removeItem(atPath: sqliteDir)
    }

    // MARK: - Migrations

    /// Runs the hand-rolled migration chain on a `DatabaseQueue`, opening its own write transaction.
    ///
    /// Test and bridge-entry surface. Production callers use `database()`, which funnels here.
    /// `upTo` is intended for test cross-checks that need to stop at an intermediate version; production code
    /// always uses the default (`currentSchemaVersion`).
    static func runMigrations(on dbQueue: DatabaseQueue, upTo targetVersion: Int = currentSchemaVersion) throws {
        try dbQueue.write { db in
            try runMigrations(db, upTo: targetVersion)
        }
    }

    /// Runs the hand-rolled migration chain inside an existing write transaction.
    ///
    /// The GRDB bridge (see `spec/services/migrator.md` §1.5) calls this inside its own
    /// `dbQueue.write { … }` so bridge-write + legacy catch-up commit atomically.
    static func runMigrations(_ db: Database, upTo targetVersion: Int = currentSchemaVersion) throws {
        // Create version tracking table
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER NOT NULL DEFAULT 0
            )
        """)

        let row = try Row.fetchOne(db, sql: "SELECT version FROM schema_version LIMIT 1")
        var currentVersion: Int
        if let row {
            currentVersion = row["version"]
        } else {
            try db.execute(sql: "INSERT INTO schema_version (version) VALUES (0)")
            currentVersion = 0
        }

        if currentVersion >= targetVersion { return }

        if currentVersion < 1 && targetVersion >= 1 { try migrateToV1(db) }
        if currentVersion < 2 && targetVersion >= 2 { try migrateToV2(db) }
        if currentVersion < 3 && targetVersion >= 3 { try migrateToV3(db) }
        if currentVersion < 4 && targetVersion >= 4 { try migrateToV4(db) }
        if currentVersion < 5 && targetVersion >= 5 { try migrateToV5(db) }
        if currentVersion < 6 && targetVersion >= 6 { try migrateToV6(db) }
        if currentVersion < 7 && targetVersion >= 7 { try migrateToV7(db) }
        if currentVersion < 8 && targetVersion >= 8 { try migrateToV8(db) }
        if currentVersion < 9 && targetVersion >= 9 { try migrateToV9(db) }
        if currentVersion < 10 && targetVersion >= 10 { try migrateToV10(db) }
        if currentVersion < 11 && targetVersion >= 11 { try migrateToV11(db) }
        if currentVersion < 12 && targetVersion >= 12 { try migrateToV12(db) }
        if currentVersion < 13 && targetVersion >= 13 { try migrateToV13(db) }
        if currentVersion < 14 && targetVersion >= 14 { try migrateToV14(db) }
        if currentVersion < 15 && targetVersion >= 15 { try migrateToV15(db) }
        if currentVersion < 16 && targetVersion >= 16 { try migrateToV16(db) }
        if currentVersion < 17 && targetVersion >= 17 { try migrateToV17(db) }
        if currentVersion < 18 && targetVersion >= 18 { try migrateToV18(db) }

        try db.execute(sql: "UPDATE schema_version SET version = ?", arguments: [targetVersion])
    }

    private static func migrateToV1(_ db: Database) throws {
        try createTemplateTables(db)
        try createUserSettingsTable(db)
        try createGymTables(db)
        try createSessionTables(db)
        try createSyncTables(db)
        try createV1Indexes(db)
        try migrateOrphanedEquipment(db)
        try seedDefaultUserSettings(db)
    }

    private static func createTemplateTables(_ db: Database) throws {
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
    }

    private static func createUserSettingsTable(_ db: Database) throws {
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
    }

    private static func createGymTables(_ db: Database) throws {
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
    }

    private static func createSessionTables(_ db: Database) throws {
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
    }

    private static func createSyncTables(_ db: Database) throws {
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
    }

    private static func createV1Indexes(_ db: Database) throws {
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_template_exercises_workout ON template_exercises(workout_template_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_template_sets_exercise ON template_sets(template_exercise_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_workout_templates_favorite ON workout_templates(is_favorite)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_session_exercises_session ON session_exercises(workout_session_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_session_exercises_name ON session_exercises(exercise_name)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_session_sets_exercise ON session_sets(session_exercise_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_workout_sessions_status ON workout_sessions(status)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_name ON gym_equipment(name)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_gym ON gym_equipment(gym_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gyms_default ON gyms(is_default)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sync_queue_entity ON sync_queue(entity_type, entity_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sync_conflicts_entity ON sync_conflicts(entity_type, entity_id)")
    }

    private static func migrateOrphanedEquipment(_ db: Database) throws {
        let orphanCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gym_equipment WHERE gym_id IS NULL") ?? 0
        if orphanCount > 0 {
            let now = ISO8601DateFormatter().string(from: Date())
            let orphanGymId = IDGenerator.generate()
            try db.execute(
                sql: "INSERT INTO gyms (id, name, is_default, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [orphanGymId, "My Gym", 1, now, now]
            )
            try db.execute(sql: "UPDATE gym_equipment SET gym_id = ? WHERE gym_id IS NULL", arguments: [orphanGymId])
        }
    }

    private static func seedDefaultUserSettings(_ db: Database) throws {
        let existingSettings = try Row.fetchOne(db, sql: "SELECT id FROM user_settings LIMIT 1")
        if existingSettings == nil {
            let now = ISO8601DateFormatter().string(from: Date())
            try db.execute(
                sql: """
                    INSERT INTO user_settings (id, default_weight_unit, enable_workout_timer, auto_start_rest_timer, theme, notifications_enabled, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [IDGenerator.generate(), "lbs", 1, 1, "auto", 1, now, now]
            )
        }
    }

    private static func migrateToV2(_ db: Database) throws {
        // Add last sync stat columns to sync_metadata for displaying sync history in UI
        try db.execute(sql: "ALTER TABLE sync_metadata ADD COLUMN last_uploaded INTEGER DEFAULT 0")
        try db.execute(sql: "ALTER TABLE sync_metadata ADD COLUMN last_downloaded INTEGER DEFAULT 0")
        try db.execute(sql: "ALTER TABLE sync_metadata ADD COLUMN last_conflicts INTEGER DEFAULT 0")
    }

    private static func migrateToV3(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN developer_mode_enabled INTEGER DEFAULT 0")
    }

    private static func migrateToV5(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN countdown_sounds_enabled INTEGER DEFAULT 1")
    }

    private static func migrateToV6(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN side TEXT")
    }

    private static func migrateToV7(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN has_accepted_disclaimer INTEGER DEFAULT 0")
    }

    private static func migrateToV8(_ db: Database) throws {
        // Add updated_at columns for CKSyncEngine migration
        try db.execute(sql: "ALTER TABLE workout_sessions ADD COLUMN updated_at TEXT")
        try db.execute(sql: "ALTER TABLE session_exercises ADD COLUMN updated_at TEXT")
        try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN updated_at TEXT")
        try db.execute(sql: "ALTER TABLE template_exercises ADD COLUMN updated_at TEXT")
        try db.execute(sql: "ALTER TABLE template_sets ADD COLUMN updated_at TEXT")

        // Backfill from existing timestamps
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

        // Sync engine state table for CKSyncEngine
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sync_engine_state (
                id TEXT PRIMARY KEY DEFAULT 'default',
                data BLOB NOT NULL
            )
        """)
    }

    private static func migrateToV9(_ db: Database) throws {
        // 1. Clear legacy API key data from user_settings (keys now live in Keychain)
        try db.execute(sql: "UPDATE user_settings SET anthropic_api_key = NULL")
        // SQLite 3.35.0+ supports DROP COLUMN; safe on iOS 16+
        try db.execute(sql: "ALTER TABLE user_settings DROP COLUMN anthropic_api_key")

        // 2. Recreate gym_equipment with FOREIGN KEY on gym_id (ON DELETE CASCADE)
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
            INSERT INTO gym_equipment_new (id, name, is_available, last_checked_at, created_at, updated_at, gym_id, deleted_at)
            SELECT id, name, is_available, last_checked_at, created_at, updated_at, gym_id, deleted_at
            FROM gym_equipment
        """)
        try db.execute(sql: "DROP TABLE gym_equipment")
        try db.execute(sql: "ALTER TABLE gym_equipment_new RENAME TO gym_equipment")
        // Re-create indexes that were on the old table
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_name ON gym_equipment(name)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_gym ON gym_equipment(gym_id)")

        // 3. Add index on workout_sessions(date) for query performance
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_workout_sessions_date ON workout_sessions(date DESC)")

        // 4. Ensure updated_at has no NULLs in child tables
        let now = ISO8601DateFormatter().string(from: Date())
        try db.execute(sql: "UPDATE session_exercises SET updated_at = ? WHERE updated_at IS NULL", arguments: [now])
        try db.execute(sql: "UPDATE session_sets SET updated_at = ? WHERE updated_at IS NULL", arguments: [now])
        try db.execute(sql: "UPDATE template_exercises SET updated_at = ? WHERE updated_at IS NULL", arguments: [now])
        try db.execute(sql: "UPDATE template_sets SET updated_at = ? WHERE updated_at IS NULL", arguments: [now])

        // 5. Fix schema_version: ensure exactly one row
        try db.execute(sql: "DELETE FROM schema_version WHERE rowid NOT IN (SELECT MIN(rowid) FROM schema_version)")

        // 6. Drop unused sync tables (replaced by CKSyncEngine)
        try db.execute(sql: "DROP TABLE IF EXISTS sync_queue")
        try db.execute(sql: "DROP TABLE IF EXISTS sync_conflicts")
    }

    private static func migrateToV4(_ db: Database) throws {
        // Soft-delete support for gyms and gym_equipment to prevent CloudKit sync
        // from re-inserting deleted records.
        try db.execute(sql: "ALTER TABLE gyms ADD COLUMN deleted_at TEXT")
        try db.execute(sql: "ALTER TABLE gym_equipment ADD COLUMN deleted_at TEXT")

        // Ensure exactly one gym is marked as default
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

    private static func migrateToV10(_ db: Database) throws {
        // Add distance columns to template_sets
        try db.execute(sql: "ALTER TABLE template_sets ADD COLUMN target_distance REAL")
        try db.execute(sql: "ALTER TABLE template_sets ADD COLUMN target_distance_unit TEXT")

        // Add distance columns to session_sets
        try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN target_distance REAL")
        try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN target_distance_unit TEXT")
        try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN actual_distance REAL")
        try db.execute(sql: "ALTER TABLE session_sets ADD COLUMN actual_distance_unit TEXT")
    }

    private static func migrateToV11(_ db: Database) throws {
        // 1. Add missing indexes on self-referential FK columns used for supersets/dropsets
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_session_exercises_parent ON session_exercises(parent_exercise_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_session_sets_parent ON session_sets(parent_set_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_template_exercises_parent ON template_exercises(parent_exercise_id)")

        // 2. Change gym_equipment UNIQUE constraint from global name to composite (gym_id, name)
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
            INSERT INTO gym_equipment_new (id, name, is_available, last_checked_at, created_at, updated_at, gym_id, deleted_at)
            SELECT id, name, is_available, last_checked_at, created_at, updated_at, gym_id, deleted_at
            FROM gym_equipment
        """)
        try db.execute(sql: "DROP TABLE gym_equipment")
        try db.execute(sql: "ALTER TABLE gym_equipment_new RENAME TO gym_equipment")
        // Re-create indexes that were on the old table
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_name ON gym_equipment(name)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_gym_equipment_gym ON gym_equipment(gym_id)")
    }

    // MARK: - V12: SetMeasurement — decouple metrics from set rows

    private static func migrateToV12(_ db: Database) throws {
        try createSetMeasurementsTable(db)
        try migrateSessionSetMeasurements(db)
        try migrateTemplateSetMeasurements(db)
        try rebuildSessionSetsSchema(db)
        try rebuildTemplateSetsSchema(db)
    }

    private static func createSetMeasurementsTable(_ db: Database) throws {
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
        try db.execute(sql: "CREATE INDEX idx_set_measurements_set ON set_measurements(set_id, parent_type)")
        try db.execute(sql: "CREATE INDEX idx_set_measurements_group ON set_measurements(set_id, group_index)")
    }

    private static func migrateSessionSetMeasurements(_ db: Database) throws {
        let sessionSets = try Row.fetchAll(db, sql: "SELECT * FROM session_sets")
        for row in sessionSets {
            guard let setId: String = row["id"] else { continue }
            let updatedAt: String? = row["updated_at"]

            // Target measurements
            if let w: Double = row["target_weight"] {
                let unit: String? = row["target_weight_unit"]
                try insertMeasurementV12(db, setId: setId, parentType: "session", role: "target", kind: "weight", value: w, unit: unit, updatedAt: updatedAt)
            }
            if let r: Int = row["target_reps"] {
                try insertMeasurementV12(db, setId: setId, parentType: "session", role: "target", kind: "reps", value: Double(r), unit: nil, updatedAt: updatedAt)
            }
            if let t: Int = row["target_time"] {
                try insertMeasurementV12(db, setId: setId, parentType: "session", role: "target", kind: "time", value: Double(t), unit: "s", updatedAt: updatedAt)
            }
            if let d: Double = row["target_distance"] {
                let unit: String? = row["target_distance_unit"]
                try insertMeasurementV12(db, setId: setId, parentType: "session", role: "target", kind: "distance", value: d, unit: unit, updatedAt: updatedAt)
            }
            if let rpe: Int = row["target_rpe"] {
                try insertMeasurementV12(db, setId: setId, parentType: "session", role: "target", kind: "rpe", value: Double(rpe), unit: nil, updatedAt: updatedAt)
            }

            // Actual measurements
            if let w: Double = row["actual_weight"] {
                let unit: String? = row["actual_weight_unit"]
                try insertMeasurementV12(db, setId: setId, parentType: "session", role: "actual", kind: "weight", value: w, unit: unit, updatedAt: updatedAt)
            }
            if let r: Int = row["actual_reps"] {
                try insertMeasurementV12(db, setId: setId, parentType: "session", role: "actual", kind: "reps", value: Double(r), unit: nil, updatedAt: updatedAt)
            }
            if let t: Int = row["actual_time"] {
                try insertMeasurementV12(db, setId: setId, parentType: "session", role: "actual", kind: "time", value: Double(t), unit: "s", updatedAt: updatedAt)
            }
            if let d: Double = row["actual_distance"] {
                let unit: String? = row["actual_distance_unit"]
                try insertMeasurementV12(db, setId: setId, parentType: "session", role: "actual", kind: "distance", value: d, unit: unit, updatedAt: updatedAt)
            }
            if let rpe: Int = row["actual_rpe"] {
                try insertMeasurementV12(db, setId: setId, parentType: "session", role: "actual", kind: "rpe", value: Double(rpe), unit: nil, updatedAt: updatedAt)
            }
        }
    }

    private static func migrateTemplateSetMeasurements(_ db: Database) throws {
        let templateSets = try Row.fetchAll(db, sql: "SELECT * FROM template_sets")
        for row in templateSets {
            guard let setId: String = row["id"] else { continue }
            let updatedAt: String? = row["updated_at"]

            if let w: Double = row["target_weight"] {
                let unit: String? = row["target_weight_unit"]
                try insertMeasurementV12(db, setId: setId, parentType: "planned", role: "target", kind: "weight", value: w, unit: unit, updatedAt: updatedAt)
            }
            if let r: Int = row["target_reps"] {
                try insertMeasurementV12(db, setId: setId, parentType: "planned", role: "target", kind: "reps", value: Double(r), unit: nil, updatedAt: updatedAt)
            }
            if let t: Int = row["target_time"] {
                try insertMeasurementV12(db, setId: setId, parentType: "planned", role: "target", kind: "time", value: Double(t), unit: "s", updatedAt: updatedAt)
            }
            if let d: Double = row["target_distance"] {
                let unit: String? = row["target_distance_unit"]
                try insertMeasurementV12(db, setId: setId, parentType: "planned", role: "target", kind: "distance", value: d, unit: unit, updatedAt: updatedAt)
            }
            if let rpe: Int = row["target_rpe"] {
                try insertMeasurementV12(db, setId: setId, parentType: "planned", role: "target", kind: "rpe", value: Double(rpe), unit: nil, updatedAt: updatedAt)
            }
        }
    }

    private static func rebuildSessionSetsSchema(_ db: Database) throws {
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
            INSERT INTO session_sets_new (id, session_exercise_id, order_index, rest_seconds, completed_at, status, notes, is_dropset, is_per_side, is_amrap, side, updated_at)
            SELECT id, session_exercise_id, order_index, rest_seconds, completed_at, status, notes, is_dropset, is_per_side, 0, side, updated_at
            FROM session_sets
        """)
        try db.execute(sql: "DROP TABLE session_sets")
        try db.execute(sql: "ALTER TABLE session_sets_new RENAME TO session_sets")
        try db.execute(sql: "CREATE INDEX idx_session_sets_exercise ON session_sets(session_exercise_id)")
    }

    private static func rebuildTemplateSetsSchema(_ db: Database) throws {
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
            INSERT INTO template_sets_new (id, template_exercise_id, order_index, rest_seconds, is_dropset, is_per_side, is_amrap, notes, updated_at)
            SELECT id, template_exercise_id, order_index, rest_seconds, is_dropset, is_per_side, is_amrap, notes, updated_at
            FROM template_sets
        """)
        try db.execute(sql: "DROP TABLE template_sets")
        try db.execute(sql: "ALTER TABLE template_sets_new RENAME TO template_sets")
        try db.execute(sql: "CREATE INDEX idx_template_sets_exercise ON template_sets(template_exercise_id)")
    }

    // MARK: - V13: default_timer_countdown user setting

    private static func migrateToV13(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN default_timer_countdown INTEGER DEFAULT 0")
    }

    // MARK: - V14: default_weight_step_lbs user setting

    private static func migrateToV14(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN default_weight_step_lbs REAL DEFAULT 2.5")
    }

    // MARK: - V15: AI prompt inclusion toggles

    private static func migrateToV15(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN ai_prompt_include_format_pointer INTEGER DEFAULT 1")
        try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN ai_prompt_include_recent_workouts INTEGER DEFAULT 1")
        try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN ai_prompt_include_progression INTEGER DEFAULT 1")
        try db.execute(sql: "ALTER TABLE user_settings ADD COLUMN ai_prompt_include_equipment INTEGER DEFAULT 1")
    }

    // MARK: - V16: workout_inbox (device-local, not synced)

    private static func migrateToV16(_ db: Database) throws {
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

    // MARK: - V17: outbox_pending_queue (device-local push queue)

    private static func migrateToV17(_ db: Database) throws {
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

    // MARK: - V18: slim workout_inbox (drop persisted server pre-parse)

    /// Drops the `workout_json` / `summary_*` columns from `workout_inbox`.
    /// The table is a device-local cache repopulated from the server on the
    /// next poll, so dropping & recreating with `lmwf_text` + metadata only
    /// is cleaner (and equivalent) to per-column `ALTER`. `lmwf_text` is now
    /// the single source of truth — the summary is derived in memory by
    /// parsing it on load (see `InboxItem.Summary`).
    private static func migrateToV18(_ db: Database) throws {
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

    private static func insertMeasurementV12(_ db: Database, setId: String, parentType: String, role: String, kind: String, value: Double, unit: String?, updatedAt: String?) throws {
        let id = UUID().uuidString
        try db.execute(
            sql: "INSERT INTO set_measurements (id, set_id, parent_type, role, kind, value, unit, group_index, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)",
            arguments: [id, setId, parentType, role, kind, value, unit, updatedAt]
        )
    }
}
