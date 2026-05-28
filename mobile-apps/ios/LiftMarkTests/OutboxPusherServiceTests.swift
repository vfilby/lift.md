import XCTest
import GRDB
@testable import LiftMark

/// Tests for the GH #143 loud-failure + recovery behavior of the outbox
/// pusher: an auth failure must log to the device log, capture to Sentry once
/// per flush cycle, surface an observable `lastError`, and — critically —
/// leave the queued completions in place so they can drain after re-auth.
@MainActor
final class OutboxPusherServiceTests: XCTestCase {

    private var tokenStore: TokenStore!
    private var mockAPI: MockAPIClient!
    private var queue: OutboxPendingQueueRepository!

    override func setUp() async throws {
        try await super.setUp()
        DatabaseManager.shared.deleteDatabase()
        _ = Logger.shared
        // deleteDatabase() drops the file; Logger's singleton won't re-create
        // app_logs on its own, and the LogStore schema flag may be stale from a
        // prior suite. Re-create it so device-log assertions are reliable.
        ensureAppLogsTableExists()
        tokenStore = TokenStore(service: "app.liftmark.outbox.tests.\(UUID().uuidString)")
        tokenStore.clear()
        mockAPI = MockAPIClient()
        queue = OutboxPendingQueueRepository()
    }

    private func ensureAppLogsTableExists() {
        guard let db = try? DatabaseManager.shared.database() else { return }
        try? db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS app_logs (
                    id TEXT PRIMARY KEY,
                    timestamp TEXT NOT NULL,
                    level TEXT NOT NULL,
                    category TEXT NOT NULL,
                    message TEXT NOT NULL,
                    metadata TEXT,
                    stack_trace TEXT,
                    device_info TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
            """)
        }
    }

    override func tearDown() async throws {
        CrashReporter.captureErrorRecorder = nil
        tokenStore.clear()
        DatabaseManager.shared.deleteDatabase()
        tokenStore = nil
        mockAPI = nil
        queue = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeUnauthenticatedStore() -> AuthenticationStore {
        // No tokens → currentUser nil → !isAuthenticated.
        AuthenticationStore(api: mockAPI, tokenStore: tokenStore)
    }

    // MARK: - Auth failure: unauthenticated flush

    func testFlushWhileSignedOutKeepsQueueAndReportsLoudly() async throws {
        try queue.enqueue(clientSessionId: "sess-1")
        try queue.enqueue(clientSessionId: "sess-2")

        var captures: [(LogCategory, [String: String])] = []
        CrashReporter.captureErrorRecorder = { _, category, metadata in
            captures.append((category, metadata))
        }

        let auth = makeUnauthenticatedStore()
        XCTAssertFalse(auth.isAuthenticated)
        let pusher = OutboxPusherService(
            authStore: auth,
            apiClient: mockAPI,
            queue: queue
        )

        await pusher.flushIfAuthenticated()

        // Queue is preserved — completed workouts must NOT be lost.
        XCTAssertEqual(try queue.count(), 2, "Auth failure must not delete queued completions")
        XCTAssertEqual(pusher.pendingCount, 2)
        XCTAssertNotNil(pusher.lastError, "lastError must reflect the unsynced state")

        // Exactly one Sentry capture per flush cycle, tagged + carrying count.
        XCTAssertEqual(captures.count, 1, "Auth failure should capture once per cycle, not per item")
        XCTAssertEqual(captures.first?.0, .sync)
        XCTAssertEqual(captures.first?.1["tag"], "outbox_auth_failure")
        XCTAssertEqual(captures.first?.1["partialFailureCount"], "2")

        // Device log error must be written. The SQLite write is dispatched to a
        // background serial queue, so poll briefly for it to land rather than
        // asserting synchronously (which would race the write).
        let logged = await waitForSyncErrorLog(containing: "authentication required")
        XCTAssertTrue(logged, "Auth failure must write a device-log error entry")
    }

    /// Polls the SQLite log store for up to ~2s for a `.sync` error whose
    /// message contains `needle`. Logger writes are async (background queue).
    private func waitForSyncErrorLog(containing needle: String) async -> Bool {
        for _ in 0..<40 {
            let logs = Logger.shared.getLogs(limit: 200, level: .error, category: .sync)
            if logs.contains(where: { $0.message.contains(needle) }) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func testFlushWhileSignedOutWithEmptyQueueStaysQuiet() async throws {
        XCTAssertEqual(try queue.count(), 0)

        var captureCount = 0
        CrashReporter.captureErrorRecorder = { _, _, _ in captureCount += 1 }

        let auth = makeUnauthenticatedStore()
        let pusher = OutboxPusherService(authStore: auth, apiClient: mockAPI, queue: queue)

        await pusher.flushIfAuthenticated()

        // Nothing queued → nothing lost → no Sentry noise, no lastError.
        XCTAssertEqual(captureCount, 0)
        XCTAssertNil(pusher.lastError)
        XCTAssertEqual(pusher.pendingCount, 0)
    }
}
