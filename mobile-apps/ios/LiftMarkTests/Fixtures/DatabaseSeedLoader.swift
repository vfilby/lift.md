import Foundation
import GRDB
@testable import LiftMark

/// Loads a frozen DB seed (DDL + data) into a unique temp DB for migration upgrade-path tests.
///
/// Contract:
/// - One temp directory per seed load so parallel XCTest invocations don't collide.
/// - `PRAGMA foreign_keys = ON` matches the production `DatabaseManager` connection pragma.
/// - DDL and data are applied in a single transaction. If either throws, the temp file is left on disk
///   for post-mortem; the caller is responsible for teardown via `cleanup()`.
/// - Returned queue is opened against the temp file; the path is exposed so tests can run subsequent
///   migrations on the same file by constructing their own queue.
///
/// The `runWithMigrations` helper is the common path: seed → migrate → assert.
enum DatabaseSeedLoader {

    struct LoadedSeed {
        let path: String
        let directory: URL
    }

    /// Writes `ddl` and `data` (in that order) into a fresh temp DB and returns its path.
    /// Does NOT run migrations — callers invoke `migrate(_:upTo:)` if they want them.
    static func load(ddl: String, data: String = "") throws -> LoadedSeed {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("liftmark-migration-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("seed.db").path

        let dbQueue = try DatabaseQueue(path: dbPath)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        try dbQueue.write { db in
            if !ddl.isEmpty { try db.execute(sql: ddl) }
            if !data.isEmpty { try db.execute(sql: data) }
        }
        return LoadedSeed(path: dbPath, directory: tempDir)
    }

    /// Removes the temp directory containing a loaded seed. Safe to call on a missing directory.
    static func cleanup(_ loaded: LoadedSeed) {
        try? FileManager.default.removeItem(at: loaded.directory)
    }

    /// Opens a `DatabaseQueue` at the given path with the same pragma dance as production.
    static func openQueue(at path: String) throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return dbQueue
    }

    /// Applies the GRDB migrator to a loaded seed, reproducing the production
    /// post-bridge reality: every field DB was stamped into `grdb_migrations` by
    /// the one-time migrator bridge (removed in GH #96), after which the migrator
    /// is the sole owner of the schema. Reads the seed's legacy `schema_version`
    /// (if present) and stamps identifiers v1..vN as already-applied, then runs
    /// the migrator to `upTo` (default: head). On a fresh/empty seed (no
    /// `schema_version`) nothing is stamped and the full chain runs from scratch.
    static func migrate(_ dbQueue: DatabaseQueue, upTo targetIdentifier: String? = nil) throws {
        try stampAppliedFromLegacyVersion(dbQueue)
        let migrator = DatabaseMigrations.migrator
        if let targetIdentifier {
            try migrator.migrate(dbQueue, upTo: targetIdentifier)
        } else {
            try migrator.migrate(dbQueue)
        }
    }

    /// Stamps `grdb_migrations` with identifiers v1..vN, where N is the seed's
    /// legacy `schema_version.version`, mirroring what the deleted bridge did for
    /// an existing field DB. No-op when `schema_version` is absent or 0 (fresh DB).
    private static func stampAppliedFromLegacyVersion(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            let hasSchemaVersion = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
            ) ?? 0) > 0
            guard hasSchemaVersion else { return }
            let legacyVersion = try Int.fetchOne(db, sql: "SELECT version FROM schema_version LIMIT 1") ?? 0
            guard legacyVersion > 0 else { return }
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL)")
            for identifier in DatabaseMigrations.identifiers.prefix(legacyVersion) {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier]
                )
            }
        }
    }
}
