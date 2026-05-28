import XCTest
import GRDB
@testable import LiftMark

/// Tests for the GRDB DatabaseMigrator bridge (PR 3 of GH #79).
///
/// Covers the core scenarios from `spec/services/migrator.md` §1.3 + §3:
/// fresh install, existing-at-v13, existing-at-v<13, already-bridged, future-version
/// refusal, feature-flag disabled. Failure paths that can't be reliably triggered in
/// XCTest (disk full, OS-level I/O errors, app-killed-mid-bridge) are covered by
/// manual QA per the spec §7.2 Phase-1 checklist.
///
/// PR 2's migration tests (`DatabaseMigrationTests`) exercise the legacy chain and must
/// continue to pass unchanged — those are the safety net for the bridge's migrator bodies.
final class MigratorBridgeTests: XCTestCase {

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        // Ensure the bridge runs in each test without being blocked by the "already emitted"
        // guard from a previous test.
        clearMigratorUserDefaults()
        clearBackupDirectory()
        MigratorBridge.isEnabled = true
    }

    override func tearDown() {
        clearMigratorUserDefaults()
        clearBackupDirectory()
        MigratorBridge.isEnabled = true
        CrashReporter.migratorEventRecorder = nil
        super.tearDown()
    }

    private func clearBackupDirectory() {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        let dir = appSupport.appendingPathComponent("LiftMark", isDirectory: true)
        if fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }
    }

    private func clearMigratorUserDefaults() {
        let keys = [
            MigratorBridgeBackup.UserDefaultsKey.postSuccessfulLaunchCount,
            MigratorBridgeBackup.UserDefaultsKey.succeededEventSent,
            MigratorBridgeBackup.UserDefaultsKey.lastAttemptFailed,
            MigratorBridgeBackup.UserDefaultsKey.lastSuccessBuildNumber
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        MigratorBridgeFailure.clearPersisted()
    }

    // MARK: - Helpers

    /// Creates an empty DB at a temp path (no tables) for fresh-install scenarios.
    private func makeEmptyDB() throws -> (DatabaseSeedLoader.LoadedSeed, DatabaseQueue, URL) {
        let loaded = try DatabaseSeedLoader.load(ddl: "", data: "")
        let queue = try DatabaseSeedLoader.openQueue(at: loaded.path)
        return (loaded, queue, URL(fileURLWithPath: loaded.path))
    }

    /// Loads the given seed into a temp DB.
    private func loadSeed(ddl: String, data: String) throws -> (DatabaseSeedLoader.LoadedSeed, DatabaseQueue, URL) {
        let loaded = try DatabaseSeedLoader.load(ddl: ddl, data: data)
        let queue = try DatabaseSeedLoader.openQueue(at: loaded.path)
        return (loaded, queue, URL(fileURLWithPath: loaded.path))
    }

    private func rowCount(_ queue: DatabaseQueue, sql: String) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: sql) ?? -1
        }
    }

    private func identifiers(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    private func tables(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
            """)
        }
    }

    private func schemaVersion(_ queue: DatabaseQueue) throws -> Int? {
        try queue.read { db in
            let hasTable = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
            ) ?? 0 > 0
            guard hasTable else { return nil }
            return try Int.fetchOne(db, sql: "SELECT version FROM schema_version LIMIT 1")
        }
    }

    /// Runs the bridge and then the legacy chain — mirrors the production boot path.
    private func runBridgeAndLegacy(on queue: DatabaseQueue, liveDBURL: URL) throws -> MigratorBridge.Outcome {
        let outcome = try MigratorBridge.runIfNeeded(on: queue, liveDBURL: liveDBURL)
        try DatabaseManager.runMigrations(on: queue)
        return outcome
    }

    // MARK: - Fresh install

    func testFreshInstall_bridgeSkipsAndMigratorRunsFromScratch() throws {
        let (loaded, queue, url) = try makeEmptyDB()
        defer { DatabaseSeedLoader.cleanup(loaded) }

        let outcome = try runBridgeAndLegacy(on: queue, liveDBURL: url)

        XCTAssertEqual(outcome, .skippedFreshInstall)
        // Migrator ran — grdb_migrations should have all 13 identifiers (written by the
        // migrator itself, not by the bridge).
        XCTAssertEqual(try identifiers(queue), MigratorBridge.identifiers.sorted())
    }

    func testFreshInstall_resultingSchemaMatchesHead() throws {
        let (loaded, queue, url) = try makeEmptyDB()
        defer { DatabaseSeedLoader.cleanup(loaded) }

        _ = try runBridgeAndLegacy(on: queue, liveDBURL: url)

        let tablesPresent = try tables(queue)
        // schema_version + grdb_migrations + all required head tables should be present.
        for required in ["workout_templates", "template_sets", "session_sets",
                         "user_settings", "gyms", "set_measurements",
                         "sync_engine_state", "schema_version", "grdb_migrations"] {
            XCTAssertTrue(tablesPresent.contains(required), "missing \(required)")
        }
        // Old v9-dropped tables must not exist.
        XCTAssertFalse(tablesPresent.contains("sync_queue"))
        XCTAssertFalse(tablesPresent.contains("sync_conflicts"))
    }

    func testFreshInstall_schemaVersionIsHead() throws {
        let (loaded, queue, url) = try makeEmptyDB()
        defer { DatabaseSeedLoader.cleanup(loaded) }

        _ = try runBridgeAndLegacy(on: queue, liveDBURL: url)

        XCTAssertEqual(try schemaVersion(queue), DatabaseManager.currentSchemaVersion)
    }

    // MARK: - Existing-at-v13 (common case)

    func testExistingAtV13_bridgeWritesAll13IdentifierRows() throws {
        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        let outcome = try runBridgeAndLegacy(on: queue, liveDBURL: url)

        if case .bridged(let from, let inserted) = outcome {
            XCTAssertEqual(from, 13)
            XCTAssertEqual(inserted, 13)
        } else {
            XCTFail("expected .bridged, got \(outcome)")
        }
        XCTAssertEqual(try identifiers(queue), MigratorBridge.identifiers.sorted())
    }

    func testExistingAtV13_userDataUnchanged() throws {
        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        let before = try rowCount(queue, sql: "SELECT COUNT(*) FROM user_settings")
        _ = try runBridgeAndLegacy(on: queue, liveDBURL: url)
        let after = try rowCount(queue, sql: "SELECT COUNT(*) FROM user_settings")

        XCTAssertEqual(before, after)
        XCTAssertEqual(try schemaVersion(queue), DatabaseManager.currentSchemaVersion)
    }

    func testExistingAtV13_legacyRunMigrationsCompletesToHead() throws {
        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        _ = try MigratorBridge.runIfNeeded(on: queue, liveDBURL: url)
        // Legacy path runs post-bridge and advances schema_version from 13 to head.
        try DatabaseManager.runMigrations(on: queue)
        XCTAssertEqual(try schemaVersion(queue), DatabaseManager.currentSchemaVersion)
    }

    // MARK: - Existing-at-v<13 (rare, but the design accounts for it)

    func testExistingAtV11_bridgeWritesV1ToV11_thenMigratorCompletes() throws {
        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v11DDL, data: DatabaseSeeds.v11Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        let outcome = try runBridgeAndLegacy(on: queue, liveDBURL: url)

        if case .bridged(let from, let inserted) = outcome {
            XCTAssertEqual(from, 11)
            XCTAssertEqual(inserted, 11, "bridge writes v1..v11 — 11 identifier rows")
        } else {
            XCTFail("expected .bridged, got \(outcome)")
        }
        // After bridge + migrator, all identifiers should be present.
        XCTAssertEqual(try identifiers(queue), MigratorBridge.identifiers.sorted())
        XCTAssertEqual(try schemaVersion(queue), DatabaseManager.currentSchemaVersion)
    }

    func testExistingAtV11_endStateMatchesLegacyOnlyPath() throws {
        // Run the bridge path on one copy, the legacy-only path on another — compare end state.
        let (loadedBridge, queueBridge, urlBridge) = try loadSeed(ddl: DatabaseSeeds.v11DDL, data: DatabaseSeeds.v11Data)
        defer { DatabaseSeedLoader.cleanup(loadedBridge) }
        let (loadedLegacy, queueLegacy, _) = try loadSeed(ddl: DatabaseSeeds.v11DDL, data: DatabaseSeeds.v11Data)
        defer { DatabaseSeedLoader.cleanup(loadedLegacy) }

        _ = try runBridgeAndLegacy(on: queueBridge, liveDBURL: urlBridge)
        try DatabaseManager.runMigrations(on: queueLegacy)

        let bridgeTables = try tables(queueBridge).filter { $0 != "grdb_migrations" }
        let legacyTables = try tables(queueLegacy)
        XCTAssertEqual(bridgeTables, legacyTables, "table set at head must match across paths")

        // Compare key row counts.
        let countsBridge = try queueBridge.read { db in
            try [
                "user_settings": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_settings") ?? -1,
                "set_measurements": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM set_measurements") ?? -1,
                "gyms": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gyms") ?? -1
            ]
        }
        let countsLegacy = try queueLegacy.read { db in
            try [
                "user_settings": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_settings") ?? -1,
                "set_measurements": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM set_measurements") ?? -1,
                "gyms": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gyms") ?? -1
            ]
        }
        XCTAssertEqual(countsBridge, countsLegacy)
    }

    // MARK: - Already-bridged (idempotency)

    func testAlreadyBridged_subsequentBridgeCallIsSkipped() throws {
        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        _ = try runBridgeAndLegacy(on: queue, liveDBURL: url)
        let countBefore = try rowCount(queue, sql: "SELECT COUNT(*) FROM grdb_migrations")

        let secondOutcome = try MigratorBridge.runIfNeeded(on: queue, liveDBURL: url)

        XCTAssertEqual(secondOutcome, .skippedAlreadyBridged)
        let countAfter = try rowCount(queue, sql: "SELECT COUNT(*) FROM grdb_migrations")
        XCTAssertEqual(countBefore, countAfter, "already-bridged bridge call must not add rows")
    }

    /// Regression: when a user upgrades an app that has already bridged at version N-1
    /// to a build at version N, the bridge's `.skippedAlreadyBridged` path runs the migrator
    /// (which applies the new migration), then the legacy `runMigrations` catch-up must not
    /// re-apply the same ALTER TABLE. Prior to the fix this produced a duplicate-column
    /// SQLite error that took down `DatabaseManager.database()` entirely on every launch
    /// for every upgrading TestFlight user.
    func testAlreadyBridgedAtPriorVersion_doesNotDoubleApplyCurrentMigration() throws {
        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        // Simulate "this DB was bridged by a prior build whose head was v13":
        // populate grdb_migrations with v1..v13 (but not v14) and leave schema_version at 13.
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL)
            """)
            for identifier in MigratorBridge.identifiers.prefix(13) {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier]
                )
            }
        }

        // Running bridge + legacy from this state must succeed — bridge's migrator applies v14,
        // then legacy runMigrations must early-return instead of re-running migrateToV14.
        XCTAssertNoThrow(try runBridgeAndLegacy(on: queue, liveDBURL: url))
        XCTAssertEqual(try schemaVersion(queue), DatabaseManager.currentSchemaVersion)
        XCTAssertEqual(try identifiers(queue), MigratorBridge.identifiers.sorted())

        // The v14 column should exist exactly once and user_settings should still be queryable.
        let columns = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(user_settings)").compactMap { $0["name"] as String? }
        }
        XCTAssertEqual(columns.filter { $0 == "default_weight_step_lbs" }.count, 1)
    }

    func testAlreadyBridged_succeededEventEmittedExactlyOnce() throws {
        var capturedEvents: [String] = []
        CrashReporter.migratorEventRecorder = { event, _ in
            capturedEvents.append(event)
        }

        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        _ = try runBridgeAndLegacy(on: queue, liveDBURL: url)
        _ = try MigratorBridge.runIfNeeded(on: queue, liveDBURL: url)
        _ = try MigratorBridge.runIfNeeded(on: queue, liveDBURL: url)

        let successEvents = capturedEvents.filter { $0 == "migrator_bridge_succeeded" }
        XCTAssertEqual(successEvents.count, 1, "success event must fire exactly once per device per bridge")
    }

    // MARK: - Future-version refusal

    func testFutureVersion_bridgeRefuses() throws {
        let (loaded, queue, url) = try loadSeed(
            ddl: DatabaseSeeds.v17SyntheticDDL,
            data: DatabaseSeeds.v17SyntheticData
        )
        defer { DatabaseSeedLoader.cleanup(loaded) }

        XCTAssertThrowsError(try MigratorBridge.runIfNeeded(on: queue, liveDBURL: url)) { error in
            guard case MigratorBridgeError.refusedFutureVersion(let version) = error else {
                return XCTFail("expected refusedFutureVersion, got \(error)")
            }
            XCTAssertEqual(version, 19)
        }
    }

    func testFutureVersion_doesNotMutateDatabase() throws {
        let (loaded, queue, url) = try loadSeed(
            ddl: DatabaseSeeds.v17SyntheticDDL,
            data: DatabaseSeeds.v17SyntheticData
        )
        defer { DatabaseSeedLoader.cleanup(loaded) }

        let rowsBefore = try rowCount(queue, sql: "SELECT COUNT(*) FROM user_settings")
        _ = try? MigratorBridge.runIfNeeded(on: queue, liveDBURL: url)
        let rowsAfter = try rowCount(queue, sql: "SELECT COUNT(*) FROM user_settings")

        XCTAssertEqual(rowsBefore, rowsAfter)
        // schema_version unchanged
        XCTAssertEqual(try schemaVersion(queue), 19)
        // grdb_migrations table should NOT have been created.
        let bridgeTablePresent = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='grdb_migrations'"
            ) ?? 0
        }
        XCTAssertEqual(bridgeTablePresent, 0, "bridge table must not exist after refusal")
    }

    // MARK: - Feature flag

    func testFeatureFlagDisabled_bridgeShortCircuits() throws {
        MigratorBridge.isEnabled = false
        defer { MigratorBridge.isEnabled = true }

        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        let outcome = try MigratorBridge.runIfNeeded(on: queue, liveDBURL: url)
        XCTAssertEqual(outcome, .skippedFeatureFlagDisabled)
        // grdb_migrations table should not exist.
        let bridgeTablePresent = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='grdb_migrations'"
            ) ?? 0
        }
        XCTAssertEqual(bridgeTablePresent, 0)
    }

    func testFeatureFlagDisabled_legacyPathStillRunsCleanly() throws {
        MigratorBridge.isEnabled = false
        defer { MigratorBridge.isEnabled = true }

        // Use v1 seed so the legacy chain has real work to do.
        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v1DDL, data: DatabaseSeeds.v1Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        _ = try MigratorBridge.runIfNeeded(on: queue, liveDBURL: url)
        try DatabaseManager.runMigrations(on: queue)

        XCTAssertEqual(try schemaVersion(queue), DatabaseManager.currentSchemaVersion)
    }

    // MARK: - Sentry event catalog

    func testBridge_emitsExpectedEventSequence() throws {
        var capturedEvents: [String] = []
        CrashReporter.migratorEventRecorder = { event, _ in
            capturedEvents.append(event)
        }

        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        _ = try runBridgeAndLegacy(on: queue, liveDBURL: url)

        XCTAssertTrue(capturedEvents.contains("migrator_bridge_attempted"))
        XCTAssertTrue(capturedEvents.contains("migrator_bridge_succeeded"))
        // migrator_bridge_backup_succeeded is intentionally a breadcrumb,
        // not an event — backup completion is informational and doesn't
        // need to count against the Sentry event cap. The end-of-bridge
        // `migrator_bridge_succeeded` event records the overall outcome.
        XCTAssertFalse(capturedEvents.contains("migrator_bridge_backup_succeeded"))
    }

    func testFutureVersion_emitsRefusedEvent() throws {
        var capturedEvents: [String] = []
        CrashReporter.migratorEventRecorder = { event, _ in
            capturedEvents.append(event)
        }

        let (loaded, queue, url) = try loadSeed(
            ddl: DatabaseSeeds.v17SyntheticDDL,
            data: DatabaseSeeds.v17SyntheticData
        )
        defer { DatabaseSeedLoader.cleanup(loaded) }

        _ = try? MigratorBridge.runIfNeeded(on: queue, liveDBURL: url)
        XCTAssertTrue(capturedEvents.contains("migrator_bridge_refused_future_version"))
    }

    // MARK: - Backup primitive unit tests

    func testBackupPrimitive_createsFileAtApplicationSupportPath() throws {
        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        let backup = try MigratorBridgeBackup.create(from: queue, liveDBURL: url)
        defer { try? FileManager.default.removeItem(at: backup.url) }

        XCTAssertTrue(backup.url.path.contains("Application Support"))
        XCTAssertTrue(backup.url.path.hasSuffix("pre-grdb-bridge.bak.db"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.url.path))
        XCTAssertGreaterThan(backup.sizeBytes, 0)
    }

    func testBackupPrimitive_staleBackupIsRenamedNotOverwritten() throws {
        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }

        // Create a "stale" prior backup.
        let stale = try MigratorBridgeBackup.create(from: queue, liveDBURL: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.url.path))

        // Pre-flight should move the stale out of the way.
        try MigratorBridgeBackup.preflight(liveDBURL: url, liveDbQueue: queue)

        // Original backup file is gone from the primary path …
        let originalExists = FileManager.default.fileExists(atPath: stale.url.path)
        XCTAssertFalse(originalExists, "stale backup should be renamed out of the primary path")

        // … but a .prev-<iso> sibling should exist.
        let dir = stale.url.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let renamedCount = contents.filter { $0.hasPrefix("pre-grdb-bridge.bak.db.prev-") }.count
        XCTAssertGreaterThanOrEqual(renamedCount, 1)

        // Cleanup
        for name in contents where name.hasPrefix("pre-grdb-bridge.bak.db") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Failure persistence (PR 4, GH #95)

    /// Future-version refusal must persist the future-version failure case with
    /// the offending schema version so the launch alert can surface it.
    func testFutureVersion_persistsFailureForAlertUI() throws {
        let (loaded, queue, url) = try loadSeed(
            ddl: DatabaseSeeds.v17SyntheticDDL,
            data: DatabaseSeeds.v17SyntheticData
        )
        defer { DatabaseSeedLoader.cleanup(loaded) }

        _ = try? MigratorBridge.runIfNeeded(on: queue, liveDBURL: url)

        let persisted = MigratorBridgeFailure.loadPersisted()
        XCTAssertEqual(persisted?.failure, .futureVersion)
        XCTAssertEqual(persisted?.context.fromVersion, 19)
    }

    /// A successful bridge must clear a stale lastAttemptFailed + failure case
    /// left by a prior failed launch — otherwise the alert keeps firing forever.
    func testSuccessfulBridge_clearsPersistedFailure() throws {
        // Simulate a prior failed launch.
        MigratorBridgeFailure.persist(.backupFailed)
        XCTAssertNotNil(MigratorBridgeFailure.loadPersisted())

        let (loaded, queue, url) = try loadSeed(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        _ = try runBridgeAndLegacy(on: queue, liveDBURL: url)

        XCTAssertNil(MigratorBridgeFailure.loadPersisted(),
                     "successful bridge must clear stale failure state")
    }

    /// Fresh install path must also clear any stale failure record, since the
    /// alert container keys off the persisted state regardless of how the DB
    /// reached its current version.
    func testFreshInstall_clearsPersistedFailure() throws {
        MigratorBridgeFailure.persist(.bridgeWriteFailed)
        XCTAssertNotNil(MigratorBridgeFailure.loadPersisted())

        let (loaded, queue, url) = try makeEmptyDB()
        defer { DatabaseSeedLoader.cleanup(loaded) }
        _ = try MigratorBridge.runIfNeeded(on: queue, liveDBURL: url)

        XCTAssertNil(MigratorBridgeFailure.loadPersisted())
    }
}
