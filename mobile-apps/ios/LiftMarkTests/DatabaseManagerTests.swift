import XCTest
import GRDB
@testable import LiftMark

final class DatabaseManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    // MARK: - Initialization

    func testDatabaseReturnsValidQueue() throws {
        let db = try DatabaseManager.shared.database()
        XCTAssertNotNil(db)
    }

    func testDatabaseReturnsSameInstance() throws {
        let db1 = try DatabaseManager.shared.database()
        let db2 = try DatabaseManager.shared.database()
        XCTAssertTrue(db1 === db2, "database() should return the same DatabaseQueue instance")
    }

    // MARK: - Foreign Keys Pragma

    func testForeignKeysEnabled() throws {
        let db = try DatabaseManager.shared.database()
        let foreignKeysOn = try db.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        XCTAssertEqual(foreignKeysOn, 1, "Foreign keys pragma should be enabled")
    }

    func testForeignKeyCascadeDeleteWorks() throws {
        let db = try DatabaseManager.shared.database()

        // Insert a workout template, then a template exercise referencing it
        let now = ISO8601DateFormatter().string(from: Date())
        let templateId = UUID().uuidString
        let exerciseId = UUID().uuidString

        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO workout_templates (id, name, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [templateId, "Test Template", now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO template_exercises (id, workout_template_id, exercise_name, order_index)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [exerciseId, templateId, "Bench Press", 0]
            )
        }

        // Delete the parent template — cascade should remove the exercise
        try db.write { db in
            try db.execute(sql: "DELETE FROM workout_templates WHERE id = ?", arguments: [templateId])
        }

        let orphanCount = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM template_exercises WHERE id = ?", arguments: [exerciseId])
        }
        XCTAssertEqual(orphanCount, 0, "Cascade delete should remove child template_exercises")
    }

    // MARK: - Migration bookkeeping

    /// GRDB's `grdb_migrations` is the sole schema bookkeeping after the legacy
    /// `schema_version` chain was removed (GH #96). All registered identifiers
    /// must be applied after the migrator runs.
    func testAllMigrationsAreApplied() throws {
        let db = try DatabaseManager.shared.database()
        let applied = try db.read { db in
            try Set(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        }
        XCTAssertEqual(applied, Set(DatabaseMigrations.identifiers), "All migrator identifiers should be applied")
    }

    /// The legacy `schema_version` table is dropped by `v20_drop_legacy_schema_version`.
    func testLegacySchemaVersionTableIsDropped() throws {
        let db = try DatabaseManager.shared.database()
        let exists = try db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_version'")) ?? 0
        }
        XCTAssertEqual(exists, 0, "schema_version should be dropped at v20")
    }

    // MARK: - Table Creation

    func testAllExpectedTablesExist() throws {
        let db = try DatabaseManager.shared.database()
        let expectedTables: Set<String> = [
            "workout_templates",
            "template_exercises",
            "template_sets",
            "user_settings",
            "gyms",
            "gym_equipment",
            "workout_sessions",
            "session_exercises",
            "session_sets",
            "sync_metadata",
            "sync_engine_state"
        ]

        let actualTables: Set<String> = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
            return Set(rows.map { $0["name"] as String })
        }

        for table in expectedTables {
            XCTAssertTrue(actualTables.contains(table), "Expected table '\(table)' to exist, but it was not found. Actual tables: \(actualTables)")
        }
    }

    func testDroppedTablesDoNotExist() throws {
        let db = try DatabaseManager.shared.database()
        let droppedTables = ["sync_queue", "sync_conflicts"]

        let actualTables: Set<String> = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            return Set(rows.map { $0["name"] as String })
        }

        for table in droppedTables {
            XCTAssertFalse(actualTables.contains(table), "Table '\(table)' should have been dropped in migration V9")
        }
    }

    // MARK: - Indexes

    func testExpectedIndexesExist() throws {
        let db = try DatabaseManager.shared.database()
        let expectedIndexes = [
            "idx_template_exercises_workout",
            "idx_template_sets_exercise",
            "idx_workout_templates_favorite",
            "idx_session_exercises_session",
            "idx_session_exercises_name",
            "idx_session_sets_exercise",
            "idx_workout_sessions_status",
            "idx_gym_equipment_name",
            "idx_gym_equipment_gym",
            "idx_gyms_default",
            "idx_workout_sessions_date"
        ]

        let actualIndexes: Set<String> = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
            return Set(rows.map { $0["name"] as String })
        }

        for index in expectedIndexes {
            XCTAssertTrue(actualIndexes.contains(index), "Expected index '\(index)' to exist")
        }
    }

    // MARK: - Default Data Seeding

    func testDefaultUserSettingsAreSeeded() throws {
        let db = try DatabaseManager.shared.database()
        let result = try db.read { db -> (weightUnit: String, theme: String, timerEnabled: Int)? in
            guard let row = try Row.fetchOne(db, sql: "SELECT default_weight_unit, theme, enable_workout_timer FROM user_settings LIMIT 1") else {
                return nil
            }
            return (
                weightUnit: row["default_weight_unit"],
                theme: row["theme"],
                timerEnabled: row["enable_workout_timer"]
            )
        }
        XCTAssertNotNil(result, "Default user settings should be seeded")
        XCTAssertEqual(result?.weightUnit, "lbs")
        XCTAssertEqual(result?.theme, "auto")
        XCTAssertEqual(result?.timerEnabled, 1)
    }

    // MARK: - deleteDatabase

    func testDeleteDatabaseClearsAllData() throws {
        let db = try DatabaseManager.shared.database()

        // Insert test data
        let now = ISO8601DateFormatter().string(from: Date())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO workout_templates (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, "Test", now, now]
            )
        }

        // Verify data exists
        let countBefore = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout_templates")
        }
        XCTAssertGreaterThan(countBefore ?? 0, 0)

        // Delete and re-open
        DatabaseManager.shared.deleteDatabase()
        let freshDb = try DatabaseManager.shared.database()

        let countAfter = try freshDb.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout_templates")
        }
        XCTAssertEqual(countAfter, 0, "All workout_templates should be deleted after deleteDatabase()")
    }

    func testDeleteDatabaseAllowsReinitialization() throws {
        _ = try DatabaseManager.shared.database()
        DatabaseManager.shared.deleteDatabase()

        // Should be able to get a new database without error
        let db = try DatabaseManager.shared.database()
        XCTAssertNotNil(db)

        // Schema should be fully migrated again (all identifiers applied).
        let applied = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? -1
        }
        XCTAssertEqual(applied, DatabaseMigrations.identifiers.count)
    }

    // MARK: - Close

    func testCloseAndReopenReturnsNewInstance() throws {
        let db1 = try DatabaseManager.shared.database()
        DatabaseManager.shared.close()
        let db2 = try DatabaseManager.shared.database()
        XCTAssertFalse(db1 === db2, "After close(), database() should return a new DatabaseQueue")
    }

    // MARK: - Column Verification (V9 migrations)

    func testAnthropicApiKeyColumnRemoved() throws {
        let db = try DatabaseManager.shared.database()
        let columns: [String] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(user_settings)")
            return rows.map { $0["name"] as String }
        }
        XCTAssertFalse(columns.contains("anthropic_api_key"), "anthropic_api_key column should be dropped in V9")
    }

    func testSessionSetsHasSideColumn() throws {
        let db = try DatabaseManager.shared.database()
        let columns: [String] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(session_sets)")
            return rows.map { $0["name"] as String }
        }
        XCTAssertTrue(columns.contains("side"), "session_sets should have 'side' column from V6 migration")
    }

    // MARK: - V13: default_timer_countdown

    func testUserSettingsHasDefaultTimerCountdownColumn() throws {
        let db = try DatabaseManager.shared.database()
        let columns: [String] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(user_settings)")
            return rows.map { $0["name"] as String }
        }
        XCTAssertTrue(columns.contains("default_timer_countdown"), "user_settings should have 'default_timer_countdown' column from V13 migration")
    }

    func testDefaultTimerCountdownDefaultsToZero() throws {
        let db = try DatabaseManager.shared.database()
        let value: Int? = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT default_timer_countdown FROM user_settings LIMIT 1")
        }
        XCTAssertEqual(value, 0, "Seeded user_settings row should default default_timer_countdown to 0 (count-up)")
    }

    func testSettingsRepositoryDefaultTimerCountdownRoundtrip() throws {
        _ = try DatabaseManager.shared.database()
        let repo = SettingsRepository()

        // Initial: should load with defaultTimerCountdown = false
        guard var settings = try repo.get() else {
            XCTFail("Expected seeded settings row")
            return
        }
        XCTAssertFalse(settings.defaultTimerCountdown, "Newly-seeded settings should have defaultTimerCountdown = false")

        // Flip to true and persist
        settings.defaultTimerCountdown = true
        try repo.update(settings)

        // Re-read and assert persisted
        let reloaded = try repo.get()
        XCTAssertEqual(reloaded?.defaultTimerCountdown, true, "defaultTimerCountdown should persist across reads")
    }

    func testUpdatedAtColumnsExist() throws {
        let db = try DatabaseManager.shared.database()
        let tablesWithUpdatedAt = ["workout_sessions", "session_exercises", "session_sets", "template_exercises", "template_sets"]

        for table in tablesWithUpdatedAt {
            let columns: [String] = try db.read { db in
                let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                return rows.map { $0["name"] as String }
            }
            XCTAssertTrue(columns.contains("updated_at"), "\(table) should have 'updated_at' column from V8 migration")
        }
    }
}
