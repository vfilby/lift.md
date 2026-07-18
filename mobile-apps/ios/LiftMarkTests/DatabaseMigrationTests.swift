import XCTest
import GRDB
@testable import LiftMark

/// Upgrade-path tests for the GRDB `DatabaseMigrator` chain (`DatabaseMigrations.migrator`).
///
/// Each test loads a frozen seed (DDL + data) at a historical schema version, then runs the live
/// migrator to head and asserts both the universal invariants (§6a) and the behavior-specific
/// assertions (§6b) from the GRDB migration spec (GH #79).
///
/// Seeds are loaded via `DatabaseSeedLoader.migrate`, which first stamps `grdb_migrations` with the
/// identifiers v1..vN already implied by the seed's legacy `schema_version` — reproducing the
/// production reality after the now-deleted one-time bridge (GH #96) — and then runs the migrator.
///
/// Failures here pin **current** migration behavior — if a future migration intentionally
/// changes one of these invariants, update the assertion as part of that migration PR. They are
/// not a requirements spec; they are a regression guard for the migrator with SR1–SR4.
final class DatabaseMigrationTests: XCTestCase {

    // MARK: - Helpers

    /// Load a seed and run the live migrator to head, returning a queue on the same file.
    /// Caller is responsible for calling `DatabaseSeedLoader.cleanup` via the returned LoadedSeed.
    private func loadAndMigrate(ddl: String, data: String, upTo targetIdentifier: String? = nil)
        throws -> (DatabaseSeedLoader.LoadedSeed, DatabaseQueue)
    {
        let loaded = try DatabaseSeedLoader.load(ddl: ddl, data: data)
        let queue = try DatabaseSeedLoader.openQueue(at: loaded.path)
        try DatabaseSeedLoader.migrate(queue, upTo: targetIdentifier)
        return (loaded, queue)
    }

    private func listTables(_ db: Database) throws -> [String] {
        // Excludes GRDB's own `grdb_migrations` bookkeeping table — golden shapes
        // describe app schema only.
        try Row.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type='table' AND name NOT LIKE 'sqlite_%'
              AND name != 'grdb_migrations'
            ORDER BY name
        """).map { $0["name"] as String }
    }

    private func listNamedIndexes(_ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type='index' AND sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
            ORDER BY name
        """).map { $0["name"] as String }
    }

    private func columnNames(_ db: Database, table: String) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String })
    }

    private func count(_ db: Database, table: String, where clause: String = "") throws -> Int {
        let sql = clause.isEmpty ? "SELECT COUNT(*) FROM \(table)" : "SELECT COUNT(*) FROM \(table) WHERE \(clause)"
        return try Int.fetchOne(db, sql: sql) ?? -1
    }

    // MARK: - Universal assertions (§6a)

    /// Applies the universal post-migration assertions to a just-migrated DB.
    private func assertUniversalInvariants(_ queue: DatabaseQueue, label: String) throws {
        try queue.read { db in
            // 1. Legacy schema_version table is dropped at head (v20).
            let schemaVersionTables = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
            ) ?? -1
            XCTAssertEqual(schemaVersionTables, 0, "\(label): schema_version should be dropped at v20")

            // 2. grdb_migrations records every registered identifier as applied.
            let appliedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? -1
            XCTAssertEqual(
                appliedCount,
                DatabaseMigrations.identifiers.count,
                "\(label): all migrator identifiers applied"
            )

            // 3. FK check
            let fkViolations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            XCTAssertEqual(fkViolations.count, 0, "\(label): foreign_key_check violations: \(fkViolations)")

            // 4. Integrity check
            let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            XCTAssertEqual(integrity, "ok", "\(label): integrity_check")

            // 5. Expected tables
            XCTAssertEqual(try listTables(db), MigrationGoldenShapes.expectedTablesAtHead, "\(label): tables")

            // 6. Expected named indexes
            let indexes = try listNamedIndexes(db).sorted()
            XCTAssertEqual(indexes, MigrationGoldenShapes.expectedIndexesAtHead, "\(label): indexes")

            // 7. Columns removed at v12 must not exist
            for (tbl, col) in MigrationGoldenShapes.columnsRemovedAtV12 {
                let cols = try columnNames(db, table: tbl)
                XCTAssertFalse(cols.contains(col), "\(label): \(tbl).\(col) should be removed at v12")
            }

            // 8. Tables removed at v9 must not exist
            let tables = Set(try listTables(db))
            for table in MigrationGoldenShapes.tablesRemovedAtV9 {
                XCTAssertFalse(tables.contains(table), "\(label): table \(table) should be removed at v9")
            }

            // 9. anthropic_api_key column removed at v9 (DROP COLUMN)
            let userCols = try columnNames(db, table: "user_settings")
            XCTAssertFalse(userCols.contains("anthropic_api_key"),
                           "\(label): user_settings.anthropic_api_key should be dropped at v9")
        }
    }

    // MARK: - v1 seed: full chain 1 → 13

    func testV1Seed_migratesToHead_universalInvariants() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v1DDL, data: DatabaseSeeds.v1Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try assertUniversalInvariants(queue, label: "v1→13")
    }

    /// Row count preservation: v1 has 8 template_sets + 6 session_sets. After the v12 fan-out,
    /// the set rows themselves survive (data is reshaped into `set_measurements`, not deleted).
    func testV1Seed_preservesSetRowCounts() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v1DDL, data: DatabaseSeeds.v1Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try queue.read { db in
            XCTAssertEqual(try count(db, table: "template_sets"), 8, "template_sets rows preserved")
            XCTAssertEqual(try count(db, table: "session_sets"), 6, "session_sets rows preserved")
            XCTAssertEqual(try count(db, table: "workout_sessions"), 2, "sessions preserved")
            XCTAssertEqual(try count(db, table: "template_exercises"), 4, "template_exercises preserved")
        }
    }

    /// ID preservation: every seeded ID (template, session, set) is still present post-migration.
    func testV1Seed_preservesIdentifiers() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v1DDL, data: DatabaseSeeds.v1Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try queue.read { db in
            let exists: (String, String) throws -> Bool = { tbl, id in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(tbl) WHERE id = ?", arguments: [id])) == 1
            }
            XCTAssertTrue(try exists("workout_templates", DatabaseSeeds.templatePushId))
            XCTAssertTrue(try exists("workout_templates", DatabaseSeeds.templatePullId))
            XCTAssertTrue(try exists("template_sets", DatabaseSeeds.tplSet1))
            XCTAssertTrue(try exists("template_sets", DatabaseSeeds.tplSet6))
            XCTAssertTrue(try exists("workout_sessions", DatabaseSeeds.sessionDoneId))
            XCTAssertTrue(try exists("session_sets", DatabaseSeeds.sesSet4))
        }
    }

    /// SR1/SR2/SR3 pinning: v12 silently drops dropset chain + tempo data. The v12 reshape behaves
    /// asymmetrically for is_amrap: **template_sets.is_amrap is preserved**, but
    /// **session_sets.is_amrap is forced to 0** (see the v12 migration — the template copy selects the
    /// column unchanged, the session copy substitutes the literal `0`). We pin both halves.
    func testV1Seed_v12DroppedFieldsAndIsAmrapAsymmetry() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v1DDL, data: DatabaseSeeds.v1Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try queue.read { db in
            // Template side: tplSet5 had is_amrap=1 at seed; v12 preserves it.
            let tplAmrap = try Int.fetchOne(
                db,
                sql: "SELECT is_amrap FROM template_sets WHERE id = ?",
                arguments: [DatabaseSeeds.tplSet5]
            )
            XCTAssertEqual(tplAmrap, 1, "template_sets.is_amrap preserved through v12")

            // Session side: all session_sets end up with is_amrap = 0 (literal substitution in v12).
            let maxSessionAmrap = try Int.fetchOne(db, sql: "SELECT MAX(is_amrap) FROM session_sets")
            XCTAssertEqual(maxSessionAmrap, 0, "SR3: v12 forces session_sets.is_amrap to 0")

            // SR1/SR2: tempo and drop_sequence columns are gone (asserted universally); verify they
            // also did NOT survive as measurement kinds in the fan-out.
            let ds = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM set_measurements WHERE kind = 'drop_sequence' OR kind = 'tempo'
            """) ?? -1
            XCTAssertEqual(ds, 0, "SR1/SR2: tempo/drop_sequence do not exist as measurement kinds")
        }
    }

    /// v12 fan-out: every non-NULL measurement column in the seed becomes ≥1 `set_measurements` row.
    /// v1 seed has mostly-populated rows — assert lower bound on fan-out counts per parent_type.
    func testV1Seed_v12FanoutProducesExpectedMeasurements() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v1DDL, data: DatabaseSeeds.v1Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try queue.read { db in
            let plannedCount = try count(db, table: "set_measurements", where: "parent_type = 'planned'")
            let sessionCount = try count(db, table: "set_measurements", where: "parent_type = 'session'")
            // 8 template_sets with varying populated fields → at least 1 measurement each.
            XCTAssertGreaterThanOrEqual(plannedCount, 8, "planned fan-out produced fewer rows than expected")
            // 6 session_sets, several with both target and actual populated → at least 6.
            XCTAssertGreaterThanOrEqual(sessionCount, 6, "session fan-out produced fewer rows than expected")

            // Specific: tplSet1 (135 lbs × 5 reps) must produce weight + reps measurements.
            let tplSet1Kinds = try Row.fetchAll(
                db,
                sql: "SELECT kind FROM set_measurements WHERE set_id = ? AND parent_type = 'planned' ORDER BY kind",
                arguments: [DatabaseSeeds.tplSet1]
            ).map { $0["kind"] as String }
            XCTAssertTrue(tplSet1Kinds.contains("weight"), "tplSet1 weight measurement")
            XCTAssertTrue(tplSet1Kinds.contains("reps"), "tplSet1 reps measurement")
        }
    }

    // MARK: - v4 seeds: default-gym behavior pinning

    func testV4ZeroDefaults_migratesToHead() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v4DDL, data: DatabaseSeeds.v4DataZeroDefaults)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try assertUniversalInvariants(queue, label: "v4-zero→13")
        try queue.read { db in
            // Pin current behavior: forward chain from v4 does NOT re-run the default-gym fix-up.
            // Both non-deleted gyms stay at is_default=0.
            let defaults = try count(db, table: "gyms", where: "is_default = 1 AND deleted_at IS NULL")
            XCTAssertEqual(defaults, 0, "zero-defaults preserved forward (no re-fixup)")
            XCTAssertEqual(try count(db, table: "gyms"), 2)
        }
    }

    func testV4TwoDefaults_migratesToHead() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v4DDL, data: DatabaseSeeds.v4DataTwoDefaults)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try assertUniversalInvariants(queue, label: "v4-two→13")
        try queue.read { db in
            // Pin current behavior: forward chain from v4 does NOT re-run the default-gym fix-up,
            // so BOTH gyms that were is_default=1 at seed stay at is_default=1.
            let defaults = try count(db, table: "gyms", where: "is_default = 1 AND deleted_at IS NULL")
            XCTAssertEqual(defaults, 2, "two-defaults preserved forward (no re-fixup)")
        }
    }

    // MARK: - v7 seed: per-side + soft-delete preservation

    func testV7Seed_migratesToHead_preservesSideAndDeletedAt() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v7DDL, data: DatabaseSeeds.v7Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try assertUniversalInvariants(queue, label: "v7→13")
        try queue.read { db in
            // v6 added session_sets.side — must survive v7/v8/v9/v10/v11/v12/v13
            XCTAssertTrue(try columnNames(db, table: "session_sets").contains("side"), "session_sets.side preserved")
            let sides = try Row.fetchAll(db, sql: "SELECT side FROM session_sets WHERE side IS NOT NULL")
                .map { $0["side"] as String }
            XCTAssertFalse(sides.isEmpty, "seeded side='left' row survives fan-out")
        }
    }

    // MARK: - v8 seed: updated_at + sync_engine_state BLOB not overwritten

    func testV8Seed_migratesToHead_preservesUpdatedAtAndSyncBlob() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v8DDL, data: DatabaseSeeds.v8Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try assertUniversalInvariants(queue, label: "v8→13")
        try queue.read { db in
            // v8 seed uses a distinctive updated_at=ts3; forward migrations must not stamp over it.
            let updatedAt = try String.fetchOne(
                db,
                sql: "SELECT updated_at FROM workout_templates WHERE id = ?",
                arguments: [DatabaseSeeds.templatePushId]
            )
            XCTAssertEqual(updatedAt, DatabaseSeeds.ts3,
                           "workout_templates.updated_at not overwritten by later migrations")

            // sync_engine_state BLOB must be byte-identical.
            let blob = try Data.fetchOne(db, sql: "SELECT data FROM sync_engine_state LIMIT 1")
            XCTAssertEqual(blob?.count, 16, "sync_engine_state.data BLOB preserved")
        }
    }

    // MARK: - v11 seed: composite UNIQUE (gym_id, name)

    func testV11Seed_migratesToHead_preservesSameNameDifferentGym() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v11DDL, data: DatabaseSeeds.v11Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try assertUniversalInvariants(queue, label: "v11→13")
        try queue.read { db in
            // v11 replaced the global UNIQUE(name) with composite UNIQUE(gym_id, name).
            // Seed has two "Barbell" rows at different gyms — both must survive.
            let barbellCount = try count(db, table: "gym_equipment", where: "name = 'Barbell'")
            XCTAssertEqual(barbellCount, 2, "same-name equipment across gyms preserved")
        }
    }

    // MARK: - v12 seed: fan-out already done — no new rows

    func testV12Seed_migratesToHead_noNewMeasurements() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v12DDL, data: DatabaseSeeds.v12Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try assertUniversalInvariants(queue, label: "v12→13")
        try queue.read { db in
            // v12 data is already post-fan-out; migrating 12→13 must not touch set_measurements.
            XCTAssertEqual(try count(db, table: "set_measurements"), 12, "v12 seed measurement count preserved")
        }
    }

    // MARK: - v13 seed: no-op

    func testV13Seed_migratesToHead_addsWeightStepAndAIPromptColumns() throws {
        let (loaded, queue) = try loadAndMigrate(ddl: DatabaseSeeds.v13DDL, data: DatabaseSeeds.v13Data)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        try assertUniversalInvariants(queue, label: "v13→head")
        try queue.read { db in
            XCTAssertEqual(try count(db, table: "workout_templates"), 1)
            XCTAssertEqual(try count(db, table: "gyms"), 1)
            // v14 adds default_weight_step_lbs with default 2.5 — existing user_settings row
            // must be backfilled by SQLite's ALTER TABLE default.
            let cols = try columnNames(db, table: "user_settings")
            XCTAssertTrue(cols.contains("default_weight_step_lbs"))
            let step = try Double.fetchOne(db, sql: "SELECT default_weight_step_lbs FROM user_settings LIMIT 1")
            XCTAssertEqual(step, 2.5)
            // v15 adds the 4 AI prompt inclusion toggles with default 1.
            XCTAssertTrue(cols.contains("ai_prompt_include_format_pointer"))
            XCTAssertTrue(cols.contains("ai_prompt_include_recent_workouts"))
            XCTAssertTrue(cols.contains("ai_prompt_include_progression"))
            XCTAssertTrue(cols.contains("ai_prompt_include_equipment"))
            let fp = try Int.fetchOne(db, sql: "SELECT ai_prompt_include_format_pointer FROM user_settings LIMIT 1")
            XCTAssertEqual(fp, 1)
        }
    }

}
