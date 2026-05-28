import XCTest
@testable import LiftMark

final class WorkoutExportServiceTests: XCTestCase {

    let service = WorkoutExportService()

    // MARK: - buildSessionFileName

    func testBuildFileNameBasic() {
        let name = service.buildSessionFileName(name: "Push Day", date: "2024-01-15T10:30:00Z")
        XCTAssertEqual(name, "workout-push-day-2024-01-15.json")
    }

    func testBuildFileNameStripsSpecialChars() {
        let name = service.buildSessionFileName(name: "Upper Body (Chest & Back)", date: "2024-01-15")
        // Parentheses and & are stripped, spaces become dashes
        XCTAssertTrue(name.hasPrefix("workout-upper-body-chest"))
        XCTAssertTrue(name.contains("back"))
        XCTAssertTrue(name.hasSuffix(".json"))
        // Should not contain special characters
        XCTAssertFalse(name.contains("("))
        XCTAssertFalse(name.contains("&"))
    }

    func testBuildFileNameLowercases() {
        let name = service.buildSessionFileName(name: "PUSH DAY", date: "2024-01-15")
        XCTAssertTrue(name.contains("push-day"))
    }

    func testBuildFileNameCollapsesMultipleDashes() {
        let name = service.buildSessionFileName(name: "A --- B", date: "2024-01-15")
        // After removing special chars and collapsing dashes
        XCTAssertFalse(name.contains("---"))
    }

    func testBuildFileNameTruncatesLongNames() {
        let longName = String(repeating: "workout ", count: 20)
        let name = service.buildSessionFileName(name: longName, date: "2024-01-15")
        // Name portion should be at most 50 chars, plus prefix and date
        XCTAssertTrue(name.count < 100)
    }

    func testBuildFileNameHandlesEmptyName() {
        let name = service.buildSessionFileName(name: "", date: "2024-01-15")
        XCTAssertEqual(name, "workout-workout-2024-01-15.json")
    }

    func testBuildFileNameHandlesAllSpecialChars() {
        let name = service.buildSessionFileName(name: "!@#$%^&*()", date: "2024-01-15")
        XCTAssertTrue(name.contains("workout-"))
        XCTAssertTrue(name.hasSuffix(".json"))
    }

    func testBuildFileNameHandlesDiacritics() {
        let name = service.buildSessionFileName(name: "Café Workout", date: "2024-01-15")
        XCTAssertTrue(name.contains("cafe"))
    }

    func testBuildFileNameDateOnlyExtractsDatePart() {
        let name = service.buildSessionFileName(name: "Test", date: "2024-06-30T14:00:00Z")
        XCTAssertTrue(name.contains("2024-06-30"))
    }

    func testBuildFileNameHandlesDateWithoutTimePart() {
        let name = service.buildSessionFileName(name: "Test", date: "2024-01-15")
        XCTAssertEqual(name, "workout-test-2024-01-15.json")
    }

    // MARK: - buildPlanFileName (GH #146)

    func testBuildPlanFileNameBasic() {
        let name = service.buildPlanFileName(name: "Push Day")
        XCTAssertEqual(name, "plan-push-day.md")
    }

    func testBuildPlanFileNameHandlesEmptyName() {
        let name = service.buildPlanFileName(name: "")
        XCTAssertEqual(name, "plan-workout.md")
    }

    func testBuildPlanFileNameStripsSpecialChars() {
        let name = service.buildPlanFileName(name: "Upper Body (Chest & Back)")
        XCTAssertTrue(name.hasPrefix("plan-upper-body-chest"))
        XCTAssertTrue(name.hasSuffix(".md"))
        XCTAssertFalse(name.contains("("))
        XCTAssertFalse(name.contains("&"))
    }

    // MARK: - exportPlanAsMarkdown (GH #146)

    func testExportPlanAsMarkdownWritesRawSource() throws {
        let markdown = "# Push Day\n@tags: test\n\n## Bench Press\n- 135 x 5\n"
        let plan = WorkoutPlan(name: "Push Day", sourceMarkdown: markdown)

        let url = try service.exportPlanAsMarkdown(plan)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.lastPathComponent, "plan-push-day.md")
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, markdown, "Export must write the raw LMWF source verbatim")
    }

    func testExportPlanAsMarkdownThrowsWhenNoSource() {
        let plan = WorkoutPlan(name: "No Source", sourceMarkdown: nil)
        XCTAssertThrowsError(try service.exportPlanAsMarkdown(plan)) { error in
            XCTAssertEqual(error as? ExportError, .noMarkdownSource)
        }
    }

    func testExportPlanAsMarkdownThrowsWhenEmptySource() {
        let plan = WorkoutPlan(name: "Empty Source", sourceMarkdown: "")
        XCTAssertThrowsError(try service.exportPlanAsMarkdown(plan)) { error in
            XCTAssertEqual(error as? ExportError, .noMarkdownSource)
        }
    }
}
