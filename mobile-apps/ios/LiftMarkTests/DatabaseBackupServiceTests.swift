import XCTest
import GRDB
@testable import LiftMark

final class DatabaseBackupServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure a clean database exists for each test
        _ = try? DatabaseManager.shared.database()
    }

    // MARK: - Export

    func testExportProducesFile() throws {
        let exportURL = try DatabaseBackupService.exportDatabase()
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        // Verify file name contains "liftmark_backup_"
        XCTAssertTrue(exportURL.lastPathComponent.hasPrefix("liftmark_backup_"))
        XCTAssertTrue(exportURL.lastPathComponent.hasSuffix(".db"))

        // Verify file is non-empty
        let attributes = try FileManager.default.attributesOfItem(atPath: exportURL.path)
        let fileSize = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 0)

        // Cleanup
        try? FileManager.default.removeItem(at: exportURL)
    }

    func testExportedFileIsValidDatabase() throws {
        let exportURL = try DatabaseBackupService.exportDatabase()
        XCTAssertTrue(DatabaseBackupService.validateDatabaseFile(at: exportURL))

        // Cleanup
        try? FileManager.default.removeItem(at: exportURL)
    }

    /// Regression test for the WAL data-loss bug.
    ///
    /// GRDB runs SQLite in WAL mode, so a freshly-committed row lives in the
    /// `liftmark.db-wal` sidecar until a checkpoint folds it into the main file.
    /// The old `exportDatabase()` did a `FileManager.copyItem` of ONLY the main
    /// `liftmark.db` file, so a WAL-resident write could be silently absent from
    /// the backup — and on a freshly-migrated DB, whole tables could be missing.
    ///
    /// To make the bug *deterministic* rather than checkpoint-timing-dependent,
    /// this test pins the WAL-resident precondition: it disables WAL
    /// auto-checkpointing, writes a uniquely-identifiable row, and proves the row
    /// is NOT visible in a raw copy of the main `liftmark.db` file alone (i.e. it
    /// genuinely lives in the WAL). It then exports and asserts the row IS present
    /// in the exported file.
    ///
    /// - Old copy-only export: the raw-main-file copy is exactly what export
    ///   produced, so the row is missing → assertion fails (bug reproduced).
    /// - `VACUUM INTO` fix: the live connection emits a consistent copy that
    ///   includes the WAL-resident row → assertion passes, every run.
    func testExportCapturesWALResidentWrites() throws {
        let db = try DatabaseManager.shared.database()
        let livePath = try DatabaseBackupService.getDatabasePath()
        let walPath = livePath.path + "-wal"

        // Put the live DB into WAL mode and stop auto-checkpoint, so the marker
        // write below stays resident in the `liftmark.db-wal` sidecar and is NOT
        // folded into the main `liftmark.db` file. This deterministically recreates
        // the WAL scenario the export must survive. Restored to DELETE at the end
        // so the shared singleton is left exactly as the other tests expect.
        try db.writeWithoutTransaction { database in
            _ = try String.fetchOne(database, sql: "PRAGMA journal_mode = WAL")
            try database.execute(sql: "PRAGMA wal_autocheckpoint = 0")
        }
        defer {
            try? db.writeWithoutTransaction { database in
                try database.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                _ = try String.fetchOne(database, sql: "PRAGMA journal_mode = DELETE")
            }
        }

        let markerId = "wal-export-regression-\(UUID().uuidString)"
        let now = ISO8601DateFormatter().string(from: Date())
        try db.write { database in
            try database.execute(
                sql: "INSERT INTO gyms (id, name, is_default, created_at, updated_at) VALUES (?, ?, 0, ?, ?)",
                arguments: [markerId, "WAL Regression Gym", now, now]
            )
        }

        // Precondition: the write must genuinely be WAL-resident. A raw copy of
        // ONLY the main db file (exactly what the old copy-only export produced)
        // must NOT contain the marker. If this ever fails, the test is no longer
        // exercising the WAL scenario and must be revisited.
        XCTAssertTrue(FileManager.default.fileExists(atPath: walPath),
                      "Precondition: a -wal sidecar should exist for the live DB")
        let rawMainCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("wal-precondition-\(UUID().uuidString).db")
        try? FileManager.default.removeItem(at: rawMainCopy)
        try FileManager.default.copyItem(at: livePath, to: rawMainCopy)
        defer { try? FileManager.default.removeItem(at: rawMainCopy) }
        let inRawMain = try countGyms(withId: markerId, inDatabaseAt: rawMainCopy.path)
        XCTAssertEqual(inRawMain, 0,
                       "Precondition: marker should be WAL-resident, absent from the main db file alone")

        // The fix under test: VACUUM INTO via the live connection.
        let exportURL = try DatabaseBackupService.exportDatabase()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        // VACUUM INTO must produce a single, self-contained file with no sidecars.
        let exportWal = exportURL.deletingLastPathComponent()
            .appendingPathComponent(exportURL.lastPathComponent + "-wal")
        let exportShm = exportURL.deletingLastPathComponent()
            .appendingPathComponent(exportURL.lastPathComponent + "-shm")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportWal.path),
                       "Export must not leave a -wal sidecar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportShm.path),
                       "Export must not leave a -shm sidecar")

        // The exported file must contain the WAL-resident row.
        let inExport = try countGyms(withId: markerId, inDatabaseAt: exportURL.path)
        XCTAssertEqual(inExport, 1, "Exported backup is missing a WAL-resident write — data loss bug")

        // And the export is a valid, importable database.
        XCTAssertTrue(DatabaseBackupService.validateDatabaseFile(at: exportURL))

        // Cleanup: remove the marker row so the shared singleton stays clean for
        // the other tests in this class. (Journal mode is restored in `defer`.)
        try db.write { database in
            try database.execute(sql: "DELETE FROM gyms WHERE id = ?", arguments: [markerId])
        }
    }

    // MARK: - Validate

    func testValidateAcceptsGoodDatabase() throws {
        // Export creates a known-good database file
        let exportURL = try DatabaseBackupService.exportDatabase()
        XCTAssertTrue(DatabaseBackupService.validateDatabaseFile(at: exportURL))

        // Cleanup
        try? FileManager.default.removeItem(at: exportURL)
    }

    func testValidateRejectsNonExistentFile() {
        let fakeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent.db")
        XCTAssertFalse(DatabaseBackupService.validateDatabaseFile(at: fakeURL))
    }

    func testValidateRejectsEmptyFile() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("empty.db")
        try? FileManager.default.removeItem(at: tempURL)
        FileManager.default.createFile(atPath: tempURL.path, contents: Data())
        XCTAssertFalse(DatabaseBackupService.validateDatabaseFile(at: tempURL))

        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testValidateRejectsTextFile() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("notadb.db")
        try? FileManager.default.removeItem(at: tempURL)
        try "This is not a database".write(to: tempURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(DatabaseBackupService.validateDatabaseFile(at: tempURL))

        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - Import

    func testImportReplacesData() throws {
        // Export the current database
        let exportURL = try DatabaseBackupService.exportDatabase()

        // Import it back (should succeed without error)
        try DatabaseBackupService.importDatabase(from: exportURL)

        // Verify database is still accessible after import
        let db = try DatabaseManager.shared.database()
        XCTAssertNotNil(db)

        // Cleanup
        try? FileManager.default.removeItem(at: exportURL)
    }

    // MARK: - Database Path

    func testGetDatabasePathReturnsValidPath() throws {
        let path = try DatabaseBackupService.getDatabasePath()
        XCTAssertTrue(path.path.contains("SQLite"))
        XCTAssertTrue(path.path.hasSuffix("liftmark.db"))
    }

    // MARK: - BackupError

    func testBackupErrorDescriptions() {
        let notFound = BackupError.databaseNotFound
        XCTAssertTrue(notFound.localizedDescription.contains("Database file not found"))

        let importFailed = BackupError.importFailed("test reason")
        XCTAssertTrue(importFailed.localizedDescription.contains("test reason"))
    }

    // MARK: - Helpers

    /// Opens the SQLite file at `path` and counts `gyms` rows with the given id.
    private func countGyms(withId gymId: String, inDatabaseAt path: String) throws -> Int {
        let queue = try DatabaseQueue(path: path)
        let count = try queue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM gyms WHERE id = ?", arguments: [gymId]) ?? 0
        }
        try queue.close()
        return count
    }
}
