import XCTest

/// UI tests for the migrator-bridge alert/stall (GH #95).
///
/// Uses the `--seed-migrator-failure` launch arg to pre-populate UserDefaults so the
/// boot-time flow renders without needing to fake a real bridge failure. See
/// `LiftMarkApp.seedMigratorFailureFromLaunchArgs`.
final class MigratorBridgeAlertUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Disk-full is boot-blocking: the stall view must render instead of the tab bar
    /// so the user can't reach a partially-migrated DB. Asserts via the user-facing
    /// message text (spec §5.2 3.a copy, with byte-to-MB substitution).
    func testDiskFullStallViewReplacesTabsOnLaunch() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-data",
            "--seed-migrator-failure", "disk_full",
            "--seed-required-bytes", String(50 * 1024 * 1024)
        ]
        app.launch()

        let message = app.staticTexts["Free up ~50 MB and relaunch."]
        XCTAssertTrue(message.waitForExistence(timeout: UITestTiming.scaled(5)),
                      "disk-full stall message should render for boot-blocking failure")

        // Tab bar must NOT be present — app refuses to proceed.
        XCTAssertFalse(app.tabBars.firstMatch.exists,
                       "tab bar must be hidden when a boot-blocking failure is active")

        // Title from MigratorBridgeFailure.alertTitle.
        XCTAssertTrue(app.staticTexts["Storage Full"].exists)
    }

    /// Integrity-failure stall exposes the "Export Database for Support" action
    /// (spec §5.2 3.b). The share-sheet presentation itself isn't asserted — the
    /// button must simply be present and tappable.
    func testIntegrityFailureStallExposesSupportExport() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-data",
            "--seed-migrator-failure", "integrity_failed"
        ]
        app.launch()

        let title = app.staticTexts["Database Needs Attention"]
        XCTAssertTrue(title.waitForExistence(timeout: UITestTiming.scaled(5)),
                      "integrity-failure stall title should render")

        // SwiftUI Label-based buttons expose their label as the element name; prefer
        // the text lookup, but also try the accessibility identifier as a fallback.
        let exportButton = app.buttons["Export Database for Support"]
        let exportButtonById = app.buttons["migrator-stall-export-button"]
        XCTAssertTrue(exportButton.exists || exportButtonById.exists,
                      "integrity-failure stall must expose support export action")
        let button = exportButton.exists ? exportButton : exportButtonById
        XCTAssertTrue(button.isHittable)
    }
}
