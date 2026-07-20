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
