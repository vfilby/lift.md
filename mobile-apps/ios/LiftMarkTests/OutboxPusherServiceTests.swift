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
    private var planRepo: WorkoutPlanRepository!
    private var sessionRepo: SessionRepository!

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
        planRepo = WorkoutPlanRepository()
        sessionRepo = SessionRepository()
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
        planRepo = nil
        sessionRepo = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeUnauthenticatedStore() -> AuthenticationStore {
        // No tokens → currentUser nil → !isAuthenticated.
        AuthenticationStore(api: mockAPI, tokenStore: tokenStore)
    }

    /// A store with a live, unexpired access token so `pushOne` actually
    /// reaches the API call (and we exercise the error-mapping in pushOne's
    /// catch chain rather than the unauthenticated short-circuit).
    private func makeAuthenticatedStore() -> AuthenticationStore {
        tokenStore.saveAccessToken(Self.makeJWT(expSecondsFromNow: 3600))
        tokenStore.saveRefreshToken("lm_refresh_test")
        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)
        XCTAssertTrue(store.isAuthenticated)
        return store
    }

    /// Build a minimal completed session so `pushOne` finds a durable row for
    /// the queued `clientSessionId` (otherwise it drops the row as "session no
    /// longer exists"). Returns the session id to enqueue.
    private func makeCompletedSession() throws -> String {
        let plan = WorkoutPlan(
            name: "Edge Test",
            exercises: [PlannedExercise(
                workoutPlanId: "plan",
                exerciseName: "Bench",
                orderIndex: 0,
                sets: [PlannedSet(
                    plannedExerciseId: "ex",
                    orderIndex: 0,
                    targetWeight: 135,
                    targetWeightUnit: .lbs,
                    targetReps: 5
                )]
            )]
        )
        try planRepo.create(plan)
        let (session, _) = try sessionRepo.createFromPlan(plan)
        for exercise in session.exercises {
            for set in exercise.sets {
                try sessionRepo.updateSessionSet(
                    set.id,
                    actualWeight: set.targetWeight,
                    actualWeightUnit: .lbs,
                    actualReps: set.targetReps,
                    actualTime: nil,
                    actualRpe: nil,
                    status: .completed
                )
            }
        }
        try sessionRepo.complete(session.id)
        return session.id
    }

    private static func makeJWT(expSecondsFromNow: TimeInterval, sub: String = "user-test") -> String {
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "sub": sub,
            "exp": Date().timeIntervalSince1970 + expSecondsFromNow,
        ]
        func b64(_ obj: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "" }
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(header)).\(b64(payload)).signature-junk"
    }

    // MARK: - 403 disambiguation: edge block vs. real API forbidden

    /// An edge/WAF 403 (`APIError.edgeBlocked`) is transient infra — the row
    /// must be PRESERVED and a retry scheduled, never silently dropped.
    func testEdgeBlocked403PreservesQueueRowAndRetries() async throws {
        let sessionId = try makeCompletedSession()
        try queue.enqueue(clientSessionId: sessionId)

        var captures: [(LogCategory, [String: String])] = []
        CrashReporter.captureErrorRecorder = { _, category, metadata in
            captures.append((category, metadata))
        }

        mockAPI.nextError = APIError.edgeBlocked(status: 403)

        let pusher = OutboxPusherService(
            authStore: makeAuthenticatedStore(),
            apiClient: mockAPI,
            queue: queue
        )

        await pusher.flushIfAuthenticated()

        // Row must survive an edge block — the completed workout is not lost.
        XCTAssertEqual(try queue.count(), 1, "Edge block must NOT delete the queued completion")
        XCTAssertEqual(pusher.pendingCount, 1)

        // Captured to Sentry, tagged + carrying status/session, category .network.
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.0, .network)
        XCTAssertEqual(captures.first?.1["tag"], "outbox_edge_blocked")
        XCTAssertEqual(captures.first?.1["status"], "403")
        XCTAssertEqual(captures.first?.1["clientSessionId"], sessionId)
    }

    /// A real API 403 (`APIError.forbidden` with a JSON message) IS terminal —
    /// the row is dropped (and the drop is now also captured to Sentry).
    func testRealApiForbidden403RemovesQueueRow() async throws {
        let sessionId = try makeCompletedSession()
        try queue.enqueue(clientSessionId: sessionId)

        var captures: [(LogCategory, [String: String])] = []
        CrashReporter.captureErrorRecorder = { _, category, metadata in
            captures.append((category, metadata))
        }

        mockAPI.nextError = APIError.forbidden(message: "quota exceeded")

        let pusher = OutboxPusherService(
            authStore: makeAuthenticatedStore(),
            apiClient: mockAPI,
            queue: queue
        )

        await pusher.flushIfAuthenticated()

        // Real 403 is permanent → row removed.
        XCTAssertEqual(try queue.count(), 0, "A real API 403 should remove the queue row")
        XCTAssertEqual(pusher.pendingCount, 0)
        XCTAssertEqual(pusher.lastError, "quota exceeded")

        // The drop is observable in Sentry (Problem D).
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.1["tag"], "outbox_push_403")
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

    /// GH #265: the core unanswered question — after a 401 strands a completed
    /// workout, does a successful re-login actually DRAIN it, or is the workout
    /// lost? This proves the recovery half of GH #143 end-to-end: enqueue →
    /// 401 strand (queue preserved, alert fired) → `login()` → the recovery
    /// flush pushes the stranded row → queue empties. The prior tests only
    /// proved the queue is *preserved* and that `onAuthenticated` *fires*;
    /// neither proved the stranded row reaches the server after re-auth.
    func testStrandedWorkoutDrainsAfterReLogin() async throws {
        let sessionId = try makeCompletedSession()
        try queue.enqueue(clientSessionId: sessionId)

        var captures: [(LogCategory, [String: String])] = []
        CrashReporter.captureErrorRecorder = { _, category, metadata in
            captures.append((category, metadata))
        }

        // --- Strand: flush while signed out. ---
        let auth = makeUnauthenticatedStore()
        XCTAssertFalse(auth.isAuthenticated)
        let pusher = OutboxPusherService(authStore: auth, apiClient: mockAPI, queue: queue)

        await pusher.flushIfAuthenticated()

        // The completed workout is stranded but PRESERVED, and the field
        // signature from GH #265 fired exactly once: one capture, tagged
        // `outbox_auth_failure`, `partialFailureCount: 1`. The API was never
        // reached — nothing could push while signed out.
        XCTAssertEqual(try queue.count(), 1, "Auth failure must not delete the queued completion")
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.1["tag"], "outbox_auth_failure")
        XCTAssertEqual(captures.first?.1["partialFailureCount"], "1")
        XCTAssertTrue(mockAPI.sentPaths.isEmpty, "Nothing should push while signed out")

        // --- Recover: a successful login, then the recovery flush drains it. ---
        // Sequence the two round-trips the recovery makes: the login itself,
        // then the outbox push of the previously-stranded row.
        mockAPI.responses = [
            .success([                                  // POST /v1/auth/password/login
                "access_jwt": Self.makeJWT(expSecondsFromNow: 3600),
                "refresh_token": "lm_refresh_live",
                "user": [
                    "user_id": "user-test",
                    "email": "a@b.co",
                    "display_name": "Tester",
                    "tier": "free",
                ],
            ]),
            .success([                                  // POST /v1/workouts/outbox
                "outbox_id": "ob-1",
                "client_session_id": sessionId,
                "dedup_hit": false,
            ]),
        ]

        _ = try await auth.login(email: "a@b.co", password: "pw")
        // `login()` fires `onAuthenticated`, which in `LiftMarkApp` drains the
        // queue. Drive that same recovery flush deterministically here (the
        // app's hook is a fire-and-forget Task; the existing
        // AuthenticationStore test already proves it fires on login).
        await pusher.flushIfAuthenticated()

        // The stranded workout reached the server and its queue row is gone.
        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertEqual(
            mockAPI.sentPaths,
            ["/v1/auth/password/login", "/v1/workouts/outbox"],
            "Recovery must push the stranded row after login"
        )
        XCTAssertEqual(try queue.count(), 0, "Re-auth must drain the stranded completed workout")
        XCTAssertEqual(pusher.pendingCount, 0)
        XCTAssertNil(pusher.lastError, "A clean recovery flush clears lastError")
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

    // MARK: - Forced flush bypasses the retry backoff

    /// A manual "Sync now" (`flushIfAuthenticated(force: true)`) must push an
    /// item parked behind a future `next_attempt_after`, while the normal
    /// automatic flush (eligible-only) leaves it untouched.
    func testForcedFlushPushesItemParkedBehindBackoff() async throws {
        let sessionId = try makeCompletedSession()
        try queue.enqueue(clientSessionId: sessionId)

        // Park the item far in the future — the automatic flush, which reads
        // `eligibleItems()`, must NOT consider it eligible.
        let future = Date().addingTimeInterval(3600)
        try queue.recordTransientFailure(
            clientSessionId: sessionId,
            nextAttemptAfter: future,
            lastError: "Server error (503)"
        )

        // Sanity: eligibleItems() skips it, allItems() includes it.
        XCTAssertTrue(try queue.eligibleItems().isEmpty, "Future backoff must be skipped by eligibleItems()")
        XCTAssertEqual(try queue.allItems().count, 1, "allItems() must ignore next_attempt_after")

        let pusher = OutboxPusherService(
            authStore: makeAuthenticatedStore(),
            apiClient: mockAPI,
            queue: queue
        )

        // 1) Normal (non-forced) flush: nothing is eligible, so the API is never
        //    hit and the row survives.
        await pusher.flushIfAuthenticated()
        XCTAssertTrue(mockAPI.sentPaths.isEmpty, "Eligible-only flush must skip a parked item")
        XCTAssertEqual(try queue.count(), 1, "Eligible-only flush must leave the parked row in place")
        XCTAssertEqual(pusher.pendingCount, 1)

        // 2) Forced flush: queue a successful push response, force-flush, and the
        //    parked row is pushed and removed despite its future backoff.
        mockAPI.nextDecodableResponse = [
            "outbox_id": "ob-1",
            "client_session_id": sessionId,
            "dedup_hit": false,
        ]
        await pusher.flushIfAuthenticated(force: true)

        XCTAssertEqual(mockAPI.sentPaths, ["/v1/workouts/outbox"], "Forced flush must push the parked item")
        XCTAssertEqual(try queue.count(), 0, "Forced flush must drain the queue past the backoff")
        XCTAssertEqual(pusher.pendingCount, 0)
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
