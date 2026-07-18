import XCTest
@testable import LiftMark

/// Regression coverage for GH #70 — blank share sheet on first tap.
///
/// The fix moves share-sheet presentation off the SwiftUI `.sheet(item:)` path
/// and onto direct UIKit presentation via the `.shareSheet(item:)` modifier.
/// The presenter triggers on `ExportFile.id` changes and expects the file on
/// disk before it hands the URL to `UIActivityViewController`.
///
/// SwiftUI view-modifier presentation is not directly inspectable without a
/// third-party framework, so these tests pin the two contracts the modifier
/// depends on:
///   1. Each `ExportFile(url:)` yields a fresh identity so reassigning the
///      binding with a new URL re-fires presentation.
///   2. The file-producing services (`DatabaseBackupService.exportDatabase`,
///      `WorkoutExportService.exportUnifiedJson`) return a URL that already
///      exists on disk at the moment they return — the presenter's one-runloop
///      deferral then guarantees `UIActivityViewController` sees a flushed file.
final class ShareSheetTests: XCTestCase {

    // MARK: - ExportFile identity

    func testExportFileIdsAreUniquePerConstruction() {
        let url = URL(fileURLWithPath: "/tmp/liftmark_test.db")
        let first = ExportFile(url: url)
        let second = ExportFile(url: url)
        XCTAssertNotEqual(first.id, second.id,
            "Each ExportFile must have a unique id so reassigning the @State binding with the same URL still"
            + " triggers onChange(of: item?.id) in the ShareSheetPresenter.")
    }

    // MARK: - File readiness at return time

    func testDatabaseExportFileExistsOnDiskBeforeReturn() throws {
        _ = try? DatabaseManager.shared.database()

        let exportURL = try DatabaseBackupService.exportDatabase()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: exportURL.path),
            "exportDatabase() must produce a file that exists on disk before returning — the share"
            + " sheet presenter hands this URL to UIActivityViewController and the file must be"
            + " readable immediately."
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: exportURL.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0, "Exported database file must be non-empty.")
    }

    func testWorkoutExportFileExistsOnDiskBeforeReturn() throws {
        _ = try? DatabaseManager.shared.database()

        let service = WorkoutExportService()
        let exportURL = try service.exportUnifiedJson()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path),
            "exportUnifiedJson() must produce a file that exists on disk before returning so the share sheet"
            + " presenter can read it without race.")

        let attrs = try FileManager.default.attributesOfItem(atPath: exportURL.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0, "Exported JSON file must be non-empty.")
    }
}
