import XCTest
@testable import LiftMark

/// Verifies the Developer section's visibility follows `developerModeEnabled`
/// in every build configuration (Debug and Release alike) — see
/// spec/screens/settings.md "Developer Mode Activation". These tests run in a
/// DEBUG configuration, so they would have failed under the old
/// `#if DEBUG return filtered` short-circuit that always showed Developer.
final class SettingsSectionTests: XCTestCase {

    func testDeveloperHiddenWhenModeDisabled_iPhone() {
        let settings = UserSettings(developerModeEnabled: false)
        let sections = SettingsSection.visibleSections(settings: settings, forIPad: false)
        XCTAssertFalse(sections.contains(.developer),
                       "Developer section must be hidden when developer mode is off")
    }

    func testDeveloperShownWhenModeEnabled_iPhone() {
        let settings = UserSettings(developerModeEnabled: true)
        let sections = SettingsSection.visibleSections(settings: settings, forIPad: false)
        XCTAssertTrue(sections.contains(.developer),
                      "Developer section must be shown when developer mode is on")
    }

    func testDeveloperHiddenWhenModeDisabled_iPad() {
        let settings = UserSettings(developerModeEnabled: false)
        let sections = SettingsSection.visibleSections(settings: settings, forIPad: true)
        XCTAssertFalse(sections.contains(.developer),
                       "Developer section must be hidden on iPad when developer mode is off")
    }

    func testDeveloperShownWhenModeEnabled_iPad() {
        let settings = UserSettings(developerModeEnabled: true)
        let sections = SettingsSection.visibleSections(settings: settings, forIPad: true)
        XCTAssertTrue(sections.contains(.developer),
                      "Developer section must be shown on iPad when developer mode is on")
    }
}
