import XCTest
@testable import LiftMark

@MainActor
final class SyncStatusStoreTests: XCTestCase {

    /// The observer is delivered on the main OperationQueue; spin the run loop once so the
    /// posted notification is processed before we assert.
    private func drainMainQueue() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    func testStartsIdle() {
        let store = SyncStatusStore()
        XCTAssertFalse(store.isSyncing)
    }

    func testReflectsActiveThenIdle() {
        let store = SyncStatusStore()

        NotificationCenter.default.post(
            name: .syncActivityDidChange, object: nil, userInfo: ["isActive": true]
        )
        drainMainQueue()
        XCTAssertTrue(store.isSyncing, "Should report syncing after an active notification")

        NotificationCenter.default.post(
            name: .syncActivityDidChange, object: nil, userInfo: ["isActive": false]
        )
        drainMainQueue()
        XCTAssertFalse(store.isSyncing, "Should report idle after an inactive notification")
    }

    func testMissingUserInfoTreatedAsIdle() {
        let store = SyncStatusStore()
        // Make it active first so we can observe the reset to false.
        NotificationCenter.default.post(
            name: .syncActivityDidChange, object: nil, userInfo: ["isActive": true]
        )
        drainMainQueue()
        XCTAssertTrue(store.isSyncing)

        NotificationCenter.default.post(name: .syncActivityDidChange, object: nil)
        drainMainQueue()
        XCTAssertFalse(store.isSyncing, "Absent isActive must default to idle, not crash")
    }
}
