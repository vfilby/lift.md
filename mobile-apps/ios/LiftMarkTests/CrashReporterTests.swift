import XCTest
@testable import LiftMark

/// Tests for CrashReporter's pure helpers. The SentrySDK-touching paths
/// are verified via the manual runbook documented in spec/services/sentry.md.
final class CrashReporterTests: XCTestCase {

    func test_filter_dropsNonAllowlistedKeys() {
        let input: [String: String] = [
            "recordType": "WorkoutPlan",
            "errorCode": "12",
            "userName": "Alice",
            "workoutTitle": "Push Day"
        ]
        let allowlist: Set<String> = ["recordType", "errorCode"]
        let filtered = CrashReporter.filter(metadata: input, allowlist: allowlist)
        XCTAssertEqual(filtered, ["recordType": "WorkoutPlan", "errorCode": "12"])
    }

    func test_filter_handlesNilMetadata() {
        let filtered = CrashReporter.filter(metadata: nil, allowlist: ["recordType"])
        XCTAssertTrue(filtered.isEmpty)
    }

    func test_truncate_leavesShortContentUntouched() {
        let input = "small"
        XCTAssertEqual(CrashReporter.truncate(input, limit: 100), "small")
    }

    func test_truncate_clipsOversizedContent() {
        let input = String(repeating: "x", count: 100)
        let out = CrashReporter.truncate(input, limit: 10)
        XCTAssertTrue(out.hasSuffix("…[truncated]"))
        XCTAssertTrue(out.utf8.count <= 10 + "\n…[truncated]".utf8.count)
    }

    func test_start_withoutDSNDoesNotCrash() {
        // CrashReporter.start() reads SentryDSN from Info.plist. In unit-test bundle
        // the key is absent, so start() should take the early-return path.
        CrashReporter.shared.start()
        // No assertion — the contract is "does not throw or crash".
    }

    func test_setEnabledPersistsToUserDefaults() {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: CrashReporter.crashReportingEnabledKey) as? Bool
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: CrashReporter.crashReportingEnabledKey)
            } else {
                defaults.removeObject(forKey: CrashReporter.crashReportingEnabledKey)
            }
        }

        CrashReporter.shared.setEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: CrashReporter.crashReportingEnabledKey))
        XCTAssertFalse(CrashReporter.isCrashReportingEnabled)

        CrashReporter.shared.setEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: CrashReporter.crashReportingEnabledKey))
    }

    // MARK: - Once-per-build capture throttling (spec/services/sentry.md)

    func test_shouldCapture_throttlesRepeatsWithinABuild() {
        CrashReporter.resetOncePerBuildThrottle()
        defer { CrashReporter.resetOncePerBuildThrottle() }

        XCTAssertTrue(CrashReporter.shouldCapture(key: "outbox-auth-failure", build: "100"),
                      "First sighting of a key on a build must capture")
        XCTAssertFalse(CrashReporter.shouldCapture(key: "outbox-auth-failure", build: "100"),
                       "Repeat of the same key on the same build must be throttled")
        XCTAssertTrue(CrashReporter.shouldCapture(key: "ck-fail-12-UserSettings", build: "100"),
                      "A different key on the same build is independent")
    }

    func test_shouldCapture_resetsWhenBuildChanges() {
        CrashReporter.resetOncePerBuildThrottle()
        defer { CrashReporter.resetOncePerBuildThrottle() }

        XCTAssertTrue(CrashReporter.shouldCapture(key: "outbox-auth-failure", build: "100"))
        XCTAssertTrue(CrashReporter.shouldCapture(key: "outbox-auth-failure", build: "101"),
                      "A new build must re-capture an already-known key")
        XCTAssertFalse(CrashReporter.shouldCapture(key: "outbox-auth-failure", build: "101"))
    }
}
