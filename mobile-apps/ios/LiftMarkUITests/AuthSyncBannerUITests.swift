import XCTest

/// UI tests for the auth-sync banner (GH #143 banner fix).
///
/// Uses the `--seed-outbox-pending` / `--seed-session-expired` launch args
/// (see `LiftMarkApp.seedAuthSyncBannerFromLaunchArgs`) to render the banner
/// states without driving a real login / 401-refresh round-trip.
///
/// The two tests are mutually reinforcing: `testBannerShownForExpiredSession`
/// proves the same outbox seed *does* produce the banner when the session is
/// expired, so `testBannerHiddenForNeverSignedInUser` can't pass for the wrong
/// reason (a silently-broken seed).
final class AuthSyncBannerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The regression this fix targets: a user who has NEVER signed in but has
    /// completed (locally-queued) workouts must NOT see the sync nag, and the
    /// app must remain usable (tab bar present).
    func testBannerHiddenForNeverSignedInUser() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-data",
            "--seed-outbox-pending", "2"
            // NB: no --seed-session-expired → never-signed-in state.
        ]
        app.launch()

        // Tab bar should be present (app fully usable).
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: UITestTiming.scaled(5)),
                      "app should be usable on launch for a never-signed-in user")

        // The banner must be absent.
        XCTAssertFalse(app.buttons["auth-sync-banner"].exists,
                       "auth-sync banner must NOT show for a user who has never signed in")
    }

    /// A lapsed session with stranded workouts shows the banner, and the
    /// dismiss affordance is present so it can never permanently obscure the app.
    ///
    /// NOTE: this asserts the banner and its dismiss control *exist* and stay on
    /// screen — it does NOT tap dismiss. The banner is mounted in a top
    /// `safeAreaInset`, and XCUITest can't reliably synthesize touches into that
    /// region (every element there reports `isHittable == false` and taps don't
    /// land — verified empirically). The dismiss → hidden transition is instead
    /// covered by the unit test `AuthSyncBannerViewTests.testHiddenAfterDismiss`,
    /// which exercises the same `shouldShow(...)` decision the view renders from.
    func testBannerAndDismissShownForExpiredSession() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-data",
            "--seed-outbox-pending", "2",
            "--seed-session-expired"
        ]
        app.launch()

        let banner = app.buttons["auth-sync-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: UITestTiming.scaled(5)),
                      "auth-sync banner should show for an expired session with stranded workouts")

        // The dismiss control must be present and fully on screen (its frame must
        // not overflow the window — a real bug we fixed where the ✕ ran off the
        // right edge).
        let dismiss = app.buttons["auth-sync-banner-dismiss"]
        XCTAssertTrue(dismiss.exists, "dismiss control should be present so the banner is clearable")
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(dismiss.frame),
                      "dismiss ✕ must sit fully within the screen, not overflow the edge")
    }
}
