import XCTest
@testable import LiftMark

/// Conformance tests that run the same example files used by the TypeScript validator
/// through the Swift parser. This ensures both implementations agree on what is valid
/// and what is invalid LMWF.
///
/// Example files live at: liftmark-workout-format/examples/{valid,errors}/
/// New examples added there are automatically picked up by these tests.
final class ParserConformanceTests: XCTestCase {

    private var examplesURL: URL!

    override func setUpWithError() throws {
        let projectRoot = try XCTUnwrap(findProjectRoot(), "Could not find project root")
        examplesURL = projectRoot
            .appendingPathComponent("liftmark-workout-format")
            .appendingPathComponent("examples")

        // Sanity check: the directories exist
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: examplesURL.appendingPathComponent("valid").path,
                                           isDirectory: &isDir) && isDir.boolValue,
            "examples/valid/ directory not found at \(examplesURL.path)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: examplesURL.appendingPathComponent("errors").path,
                                           isDirectory: &isDir) && isDir.boolValue,
            "examples/errors/ directory not found at \(examplesURL.path)"
        )
    }

    // MARK: - Valid Examples

    func testAllValidExamplesParseSuccessfully() throws {
        let validDir = examplesURL.appendingPathComponent("valid")
        let files = try markdownFiles(in: validDir)
        XCTAssertGreaterThan(files.count, 0, "No valid example files found")

        var failures: [String] = []
        for file in files {
            let markdown = try String(contentsOf: file, encoding: .utf8)
            let result = MarkdownParser.parseWorkout(markdown)
            if !result.success {
                failures.append("\(file.lastPathComponent): \(result.errors.joined(separator: "; "))")
            }
        }

        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(files.count) valid examples failed:\n" + failures.joined(separator: "\n"))
        }
    }

    // MARK: - Error Examples

    func testAllErrorExamplesFailValidation() throws {
        let errorsDir = examplesURL.appendingPathComponent("errors")
        let files = try markdownFiles(in: errorsDir)
        XCTAssertGreaterThan(files.count, 0, "No error example files found")

        var failures: [String] = []
        for file in files {
            let markdown = try String(contentsOf: file, encoding: .utf8)
            let result = MarkdownParser.parseWorkout(markdown)
            if result.success {
                failures.append("\(file.lastPathComponent): expected failure but parsed successfully")
            }
        }

        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(files.count) error examples unexpectedly passed:\n"
                + failures.joined(separator: "\n"))
        }
    }

    // MARK: - Warning Examples

    /// Files in examples/warnings/ must parse successfully AND emit at least one warning.
    func testAllWarningExamplesParseWithWarnings() throws {
        let files = try markdownFiles(in: examplesURL.appendingPathComponent("warnings"))
        XCTAssertGreaterThan(files.count, 0, "No warning example files found")

        var failures: [String] = []
        for file in files {
            let result = MarkdownParser.parseWorkout(try String(contentsOf: file, encoding: .utf8))
            if !result.success {
                failures.append("\(file.lastPathComponent): \(result.errors.joined(separator: "; "))")
            } else if result.warnings.isEmpty {
                failures.append("\(file.lastPathComponent): expected warnings but got none")
            }
        }

        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(files.count) warning examples failed:\n" + failures.joined(separator: "\n"))
        }
    }

    /// Spec TC-W01..W03: the documented warnings fire on the documented lines.
    func testWarningExamplesEmitDocumentedWarnings() throws {
        let standalone = "on its own line and has no effect"
        let ignored = "Line ignored"
        let cases: [(file: String, marker: String, lines: [Int])] = [
            ("tc-standalone-rest-modifier.md", standalone, [4]),
            ("tc-standalone-modifiers-everywhere.md", standalone, [2, 5, 9, 18]),
            ("tc-standalone-modifiers-everywhere.md", ignored, []),
            ("tc-text-after-sets-ignored.md", ignored, [6]),
        ]
        for testCase in cases {
            let url = examplesURL.appendingPathComponent("warnings").appendingPathComponent(testCase.file)
            let result = MarkdownParser.parseWorkout(try String(contentsOf: url, encoding: .utf8))
            let lines = result.warnings
                .filter { $0.contains(testCase.marker) }
                .compactMap { $0.firstMatch(of: /^Line (\d+):/).flatMap { Int($0.1) } }
            XCTAssertEqual(lines, testCase.lines, "\(testCase.file) [\(testCase.marker)]")
            let sets = result.data?.exercises.flatMap(\.sets) ?? []
            XCTAssertTrue(sets.allSatisfy { $0.restSeconds == nil && !$0.isDropset }, testCase.file)
        }
    }

    // MARK: - Helpers

    private func markdownFiles(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func findProjectRoot() -> URL? {
        // Walk up from source file: LiftMarkTests/ → ios/ → mobile-apps/ → project root
        let sourceFile = URL(fileURLWithPath: #filePath)
        var dir = sourceFile.deletingLastPathComponent() // LiftMarkTests/
        dir = dir.deletingLastPathComponent() // ios/
        dir = dir.deletingLastPathComponent() // mobile-apps/
        dir = dir.deletingLastPathComponent() // project root

        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("liftmark-workout-format").path) {
            return dir
        }

        // Fallback: walk up from test bundle
        dir = Bundle(for: type(of: self)).bundleURL
        for _ in 0..<15 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("liftmark-workout-format").path) {
                return dir
            }
        }
        return nil
    }
}
