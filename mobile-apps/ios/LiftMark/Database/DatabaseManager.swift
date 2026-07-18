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

    private init() {}

    /// Resolves the live database file URL without opening a connection.
    /// Exposed for diagnostic flows that need a path to share even when the DB
    /// can't be opened. Returns `nil` if the Documents directory can't be resolved.
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

        // Apply schema migrations. GRDB's `DatabaseMigrator` is the sole source of
        // truth for the schema; `grdb_migrations` tracks which identifiers have run.
        // (The legacy hand-rolled `schema_version` chain and its one-time bridge were
        // removed in GH #96; `v20_drop_legacy_schema_version` drops the old table.)
        // See spec/services/migrator.md.
        try DatabaseMigrations.migrator.migrate(dbQueue)

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
                Logger.shared.error(
                    .database, "DatabaseQueue.close() failed; falling back to ARC teardown", error: error)
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
                try db.execute(sql: "DELETE FROM ck_record_metadata")
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
}
