import XCTest
@testable import LiftMark

/// Covers the auth-sync banner visibility decision (`AuthSyncBannerView.shouldShow`).
///
/// The load-bearing case is the regression for GH #143 follow-up: the banner
/// must NEVER show for a user who has simply never signed in (`sessionExpired ==
/// false`), only for a lapsed session whose completed workouts are stranded.
@MainActor
final class AuthSyncBannerViewTests: XCTestCase {

    // MARK: - Never-signed-in user (the bug being fixed)

    func testHiddenForNeverSignedInUserWithPendingWorkouts() {
        // A fresh user who has never authenticated accumulates completed
        // workouts locally. sessionExpired is false → no nag.
        XCTAssertFalse(
            AuthSyncBannerView.shouldShow(
                pendingCount: 2,
                sessionExpired: false,
                hasActiveSession: false,
                dismissed: false
            )
        )
    }

    // MARK: - Lapsed session (the case the banner exists for)

    func testShownForExpiredSessionWithPendingWorkouts() {
        XCTAssertTrue(
            AuthSyncBannerView.shouldShow(
                pendingCount: 1,
                sessionExpired: true,
                hasActiveSession: false,
                dismissed: false
            )
        )
    }

    func testHiddenWhenExpiredButQueueEmpty() {
        // Nothing stranded → nothing to nag about, even with a lapsed session.
        XCTAssertFalse(
            AuthSyncBannerView.shouldShow(
                pendingCount: 0,
                sessionExpired: true,
                hasActiveSession: false,
                dismissed: false
            )
        )
    }

    // MARK: - Suppressed during an active workout (GH #194)

    func testHiddenDuringActiveWorkout() {
        XCTAssertFalse(
            AuthSyncBannerView.shouldShow(
                pendingCount: 3,
                sessionExpired: true,
                hasActiveSession: true,
                dismissed: false
            )
        )
    }

    // MARK: - Dismissable (must never permanently obscure)

    func testHiddenAfterDismiss() {
        XCTAssertFalse(
            AuthSyncBannerView.shouldShow(
                pendingCount: 2,
                sessionExpired: true,
                hasActiveSession: false,
                dismissed: true
            )
        )
    }
}
