import XCTest
import GRDB
@testable import LiftMark

/// Cross-check: each frozen seed DDL must be structurally equivalent to the schema produced
/// by running the live migration chain up to the same target version.
///
/// This is the gate that prevents silent drift between the live migrator and the frozen
/// fixtures — if a future migration changes a column or an index, the corresponding seed must
/// be updated in lockstep or these tests fail.
///
/// Comparison uses `SchemaSnapshot` (PRAGMA table_info + named indexes) so whitespace and
/// quote-style differences in DDL text do not cause spurious failures.
final class DatabaseMigrationCrossCheckTests: XCTestCase {

    private func captureSeedSnapshot(ddl: String) throws -> (SchemaSnapshot, DatabaseSeedLoader.LoadedSeed) {
        let loaded = try DatabaseSeedLoader.load(ddl: ddl)
        let q = try DatabaseSeedLoader.openQueue(at: loaded.path)
        let snap = try q.read { try SchemaSnapshot.capture($0) }
        return (snap, loaded)
    }

    private func captureLiveSnapshot(upTo version: Int) throws -> (SchemaSnapshot, DatabaseSeedLoader.LoadedSeed) {
        let loaded = try DatabaseSeedLoader.load(ddl: "")
        let q = try DatabaseSeedLoader.openQueue(at: loaded.path)
        // Fresh (empty) DB: nothing to stamp, so the migrator runs v1..vN from scratch.
        try DatabaseSeedLoader.migrate(q, upTo: DatabaseMigrations.identifiers[version - 1])
        let snap = try q.read { try SchemaSnapshot.capture($0) }
        return (snap, loaded)
    }

    private func assertSeedMatchesLive(ddl: String, version: Int,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let (seed, seedLoaded) = try captureSeedSnapshot(ddl: ddl)
        defer { DatabaseSeedLoader.cleanup(seedLoaded) }
        let (live, liveLoaded) = try captureLiveSnapshot(upTo: version)
        defer { DatabaseSeedLoader.cleanup(liveLoaded) }
        if let diff = seed.diff(vs: live, label: "v\(version)") {
            XCTFail(diff, file: file, line: line)
        }
    }

    func testV1SeedMatchesLiveMigrateToV1() throws {
        try assertSeedMatchesLive(ddl: DatabaseSeeds.v1DDL, version: 1)
    }

    func testV4SeedMatchesLiveMigrateToV4() throws {
        try assertSeedMatchesLive(ddl: DatabaseSeeds.v4DDL, version: 4)
    }

    func testV7SeedMatchesLiveMigrateToV7() throws {
        try assertSeedMatchesLive(ddl: DatabaseSeeds.v7DDL, version: 7)
    }

    func testV8SeedMatchesLiveMigrateToV8() throws {
        try assertSeedMatchesLive(ddl: DatabaseSeeds.v8DDL, version: 8)
    }

    func testV11SeedMatchesLiveMigrateToV11() throws {
        try assertSeedMatchesLive(ddl: DatabaseSeeds.v11DDL, version: 11)
    }

    func testV12SeedMatchesLiveMigrateToV12() throws {
        try assertSeedMatchesLive(ddl: DatabaseSeeds.v12DDL, version: 12)
    }

    func testV13SeedMatchesLiveMigrateToV13() throws {
        try assertSeedMatchesLive(ddl: DatabaseSeeds.v13DDL, version: 13)
    }
}
