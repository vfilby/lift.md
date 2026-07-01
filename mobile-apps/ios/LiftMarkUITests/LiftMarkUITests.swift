import XCTest

/// Entry point for YAML-driven E2E tests.
///
/// Each test method loads and runs a corresponding YAML scenario from
/// `e2e-spec/scenarios/`. The scenarios are shared across platforms —
/// the same YAML files drive both Detox (React Native) and XCUITest (Swift).
final class LiftMarkUITests: XCTestCase {
    var app: XCUIApplication!
    var runner: TestSpecRunner!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()

        // iOS raises its AutoFill "Save Password?" sheet (springboard-owned)
        // after a real password login — e.g. the beta login round-trip — and it
        // covers the Settings Account controls. A UI-interruption monitor is the
        // process-agnostic way to dismiss it (querying springboard directly
        // times out its snapshot). The handler is scoped to the interrupting
        // element, so it stays cheap. Fires on the next app interaction (the
        // runner nudges one in scrollToHittable). Tapping "Not Now" leaves the
        // keychain untouched.
        addUIInterruptionMonitor(withDescription: "Save Password prompt") { element in
            for label in ["Not Now", "Not now"] {
                let button = element.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        // Paths are relative to the project root.
        // When running from Xcode, the source root is available via the build setting.
        // Adjust these paths based on your scheme's working directory.
        let projectRoot = ProcessInfo.processInfo.environment["PROJECT_DIR"]
            ?? (#filePath as NSString)
                .deletingLastPathComponent  // LiftMarkUITests/
                .appending("/../../..")      // -> project root (LiftMark/)

        let scenariosPath = (projectRoot as NSString).appendingPathComponent("e2e-spec/scenarios")
        let fixturesPath = (projectRoot as NSString).appendingPathComponent("e2e-spec/fixtures")

        runner = TestSpecRunner(app: app, scenariosPath: scenariosPath, fixturesPath: fixturesPath)

        // Map tab identifiers to their tab bar labels for SwiftUI tab lookup.
        // SwiftUI's .accessibilityIdentifier on tab content only works for
        // the active tab; inactive tabs must be found by their label text.
        runner.adapter.tabIdToLabel = [
            "tab-home": "lift.md",
            "tab-workouts": "Plans",
            "tab-history": "Workouts",
            "tab-settings": "Settings"
        ]
    }

    // MARK: - Scenario Tests

    func testSmoke() throws {
        runner.runScenario(named: "smoke")
    }

    func testTabs() throws {
        runner.runScenario(named: "tabs")
    }

    func testHomeTiles() throws {
        runner.runScenario(named: "home-tiles")
    }

    func testImportSimple() throws {
        runner.runScenario(named: "import-simple")
    }

    func testImportRobust() throws {
        runner.runScenario(named: "import-flow-robust")
    }

    func testWorkoutFlow() throws {
        runner.runScenario(named: "workout-flow")
    }

    func testActiveWorkout() throws {
        runner.runScenario(named: "active-workout-focused")
    }

    func testHistoryFlow() throws {
        runner.runScenario(named: "history-flow-robust")
    }

    func testHistoryExport() throws {
        runner.runScenario(named: "history-export")
    }

    func testPlanExport() throws {
        runner.runScenario(named: "plan-export")
    }

    func testShareTargetImport() throws {
        runner.runScenario(named: "share-target-import")
    }

    func testImportViaWorkouts() throws {
        runner.runScenario(named: "import-via-workouts")
    }

    func testDetailSettings() throws {
        runner.runScenario(named: "detail-settings")
    }

    func testUxImprovements() throws {
        runner.runScenario(named: "ux-improvements")
    }

    /// GH #264: editing a plan exercise must splice only that block into
    /// `sourceMarkdown`, not regenerate the whole plan and flatten section
    /// header levels (which broke the markdown and blocked re-saving).
    func testEditPlanPreservesStructure() throws {
        runner.runScenario(named: "edit-plan-preserves-structure")
    }

    func testDatabaseBackup() throws {
        runner.runScenario(named: "database-backup")
    }

    func testOnboarding() throws {
        runner.runScenario(named: "onboarding")
    }

    func testAIPromptSettings() throws {
        runner.runScenario(named: "ai-prompt-settings")
    }

    /// GH #279: first Settings → Account → Sign in tap must present the login
    /// sheet and keep it presented (no second tap).
    func testSettingsAccountLogin() throws {
        runner.runScenario(named: "settings-account-login")
    }

    /// Capture App Store screenshots. Invoke via `make screenshots` to land
    /// the PNGs under mobile-apps/ios/Screenshots/. Adds ~30s to a full
    /// `make test` run since the screenshot scenario is part of the suite.
    func testScreenshots() throws {
        runner.runScenario(named: "screenshots")
    }

    // MARK: - Beta backend e2e (Layer 3, GH #137)
    //
    // These exercise the real client↔server contract against the deployed beta
    // backend and run ONLY under the BetaE2E test plan — NOT Smoke or Full,
    // which have no backend. They expect LMWF_E2E_BASE_URL / LMWF_E2E_EMAIL /
    // LMWF_E2E_PASSWORD in the environment (forwarded by the test plan from the
    // CI workflow). Run locally with those set + the beta host reachable.
    // See spec/services/ios-e2e-beta.md.

    /// Real login-UI round-trip against beta (GH #137 / restored per GH #277).
    /// Starts from a clean signed-out state via `--reset-data` (order-
    /// independent) and drives Settings → Sign in → account-identity →
    /// sign-out/revoke. The first-tap sheet-drop bug it used to work around is
    /// fixed app-side (GH #279, stable-host sheet presentation), so the scenario
    /// taps sign-in once with no settle/re-tap workaround.
    func testBetaLogin() throws {
        runner.runScenario(named: "beta-login")
    }

    func testBetaInbox() throws {
        runner.runScenario(named: "beta-inbox")
    }

    func testBetaOutbox() throws {
        runner.runScenario(named: "beta-outbox")
    }

}
