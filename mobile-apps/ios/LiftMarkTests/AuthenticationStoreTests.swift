import XCTest
@testable import LiftMark

@MainActor
final class AuthenticationStoreTests: XCTestCase {

    private var tokenStore: TokenStore!
    private var mockAPI: MockAPIClient!

    // Distinct service per run so we don't collide with real device keychain
    // entries or other parallel test runs.
    private var serviceKey: String!

    override func setUp() async throws {
        try await super.setUp()
        serviceKey = "app.liftmark.auth.tests.\(UUID().uuidString)"
        tokenStore = TokenStore(service: serviceKey)
        tokenStore.clear()
        mockAPI = MockAPIClient()
    }

    override func tearDown() async throws {
        tokenStore.clear()
        tokenStore = nil
        mockAPI = nil
        serviceKey = nil
        try await super.tearDown()
    }

    // MARK: - TokenStore round-trip

    func testTokenStoreRoundTripsAccessAndRefresh() {
        tokenStore.saveAccessToken("access-abc")
        tokenStore.saveRefreshToken("lm_refresh_xyz")

        XCTAssertEqual(tokenStore.loadAccessToken(), "access-abc")
        XCTAssertEqual(tokenStore.loadRefreshToken(), "lm_refresh_xyz")
    }

    func testTokenStoreOverwritesExistingValue() {
        tokenStore.saveAccessToken("first")
        tokenStore.saveAccessToken("second")
        XCTAssertEqual(tokenStore.loadAccessToken(), "second")
    }

    func testTokenStoreClearRemovesBoth() {
        tokenStore.saveAccessToken("a")
        tokenStore.saveRefreshToken("b")
        tokenStore.clear()
        XCTAssertNil(tokenStore.loadAccessToken())
        XCTAssertNil(tokenStore.loadRefreshToken())
    }

    func testTokenStoreLoadOnEmptyReturnsNil() {
        XCTAssertNil(tokenStore.loadAccessToken())
        XCTAssertNil(tokenStore.loadRefreshToken())
    }

    // MARK: - refreshIfNeeded

    func testRefreshIfNeededThrowsWhenNoAccessTokenAndNoRefreshToken() async {
        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)
        do {
            _ = try await store.refreshIfNeeded()
            XCTFail("Expected throw")
        } catch {
            // Expected: AuthError.unknown("No refresh token")
        }
    }

    func testRefreshIfNeededReturnsExistingTokenWhenNotExpired() async throws {
        let validToken = Self.makeJWT(expSecondsFromNow: 3600)
        tokenStore.saveAccessToken(validToken)
        tokenStore.saveRefreshToken("lm_refresh_old")

        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)

        let result = try await store.refreshIfNeeded()
        XCTAssertEqual(result, validToken)
        XCTAssertEqual(mockAPI.sentPaths.count, 0, "Should not have hit the network for a valid token")
    }

    // MARK: - sessionExpired (GH #143)

    func testRefreshUnauthorizedSetsSessionExpiredAndClearsTokens() async {
        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)

        let expiredToken = Self.makeJWT(expSecondsFromNow: -60)
        tokenStore.saveAccessToken(expiredToken)
        tokenStore.saveRefreshToken("lm_refresh_dead")

        mockAPI.nextError = APIError.unauthorized

        XCTAssertFalse(store.sessionExpired)

        do {
            _ = try await store.refreshIfNeeded()
            XCTFail("Expected unauthorized to propagate")
        } catch {
            // expected
        }

        XCTAssertTrue(store.sessionExpired, "Refresh 401 must flag the session as expired")
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertNil(tokenStore.loadAccessToken(), "Dead access token should be cleared")
        XCTAssertNil(tokenStore.loadRefreshToken(), "Dead refresh token should be cleared")
        // The expired-session path must NOT have touched the user-initiated
        // logout codepath. We assert it hit ONLY the refresh endpoint — never
        // /v1/auth/logout (which is what clears the outbox/inbox).
        XCTAssertEqual(mockAPI.sentPaths, ["/v1/auth/refresh"])
        XCTAssertFalse(
            mockAPI.sentPaths.contains("/v1/auth/logout"),
            "Expired session must not invoke the logout (outbox-clearing) codepath"
        )
    }

    func testSuccessfulLoginResetsSessionExpiredAndTriggersFlush() async throws {
        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)

        // Force the store into the expired state via a failed refresh.
        let expiredToken = Self.makeJWT(expSecondsFromNow: -60)
        tokenStore.saveAccessToken(expiredToken)
        tokenStore.saveRefreshToken("lm_refresh_dead")
        mockAPI.nextError = APIError.unauthorized
        _ = try? await store.refreshIfNeeded()
        XCTAssertTrue(store.sessionExpired)

        // A successful login must clear the flag and fire onAuthenticated so
        // the queued outbox pushes drain.
        var flushed = false
        store.onAuthenticated = { flushed = true }

        let newAccess = Self.makeJWT(expSecondsFromNow: 3600)
        mockAPI.nextDecodableResponse = [
            "access_jwt": newAccess,
            "refresh_token": "lm_refresh_new",
            "user": [
                "user_id": "user-test",
                "email": "a@b.co",
                "display_name": "Tester",
                "tier": "free",
            ],
        ]

        _ = try await store.login(email: "a@b.co", password: "pw")

        XCTAssertFalse(store.sessionExpired, "Successful login must reset sessionExpired")
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertTrue(flushed, "Successful login must trigger the outbox flush hook")
    }

    func testRefreshIfNeededCallsRefreshEndpointWhenExpired() async throws {
        // Construct the store before the keychain has any tokens so the
        // init-time rehydrate doesn't fire its own background refresh
        // (which would race this test's explicit refresh call).
        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)

        let expiredToken = Self.makeJWT(expSecondsFromNow: -60)
        tokenStore.saveAccessToken(expiredToken)
        tokenStore.saveRefreshToken("lm_refresh_old")

        let newAccess = Self.makeJWT(expSecondsFromNow: 3600)
        mockAPI.nextDecodableResponse = [
            "access_jwt": newAccess,
            "refresh_token": "lm_refresh_new",
        ]

        let result = try await store.refreshIfNeeded()
        XCTAssertEqual(result, newAccess)
        XCTAssertEqual(mockAPI.sentPaths, ["/v1/auth/refresh"])
        XCTAssertEqual(tokenStore.loadAccessToken(), newAccess)
        XCTAssertEqual(tokenStore.loadRefreshToken(), "lm_refresh_new")
    }

    // MARK: - Launch rehydration contract (spec/services/authentication.md)

    /// Case 3 (success): expired access token + valid refresh token →
    /// `restoreSession()` awaits a refresh and ends authenticated, NOT logged
    /// out. The refresh must have been awaited (tokens rotated) before
    /// restoration reports ready.
    func testLaunchWithExpiredAccessAndValidRefreshEndsAuthenticated() async throws {
        let expiredAccess = Self.makeJWT(expSecondsFromNow: -60)
        tokenStore.saveAccessToken(expiredAccess)
        tokenStore.saveRefreshToken("lm_refresh_valid")

        let freshAccess = Self.makeJWT(expSecondsFromNow: 3600)
        mockAPI.responses = [
            .success([
                "access_jwt": freshAccess,
                "refresh_token": "lm_refresh_rotated",
            ]),
        ]

        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)

        // Restoration is in flight immediately after init (access token stale).
        XCTAssertTrue(store.isRestoring, "Stale access token must enter restoring state")
        XCTAssertTrue(store.isAuthenticated, "User is reconstituted from claims, not logged out")

        await store.restoreSession()

        XCTAssertFalse(store.isRestoring, "Restoration must have settled")
        XCTAssertTrue(store.isReady)
        XCTAssertTrue(store.isAuthenticated, "Valid refresh must keep the user signed in")
        XCTAssertFalse(store.sessionExpired)
        XCTAssertEqual(mockAPI.sentPaths, ["/v1/auth/refresh"], "Refresh must have been awaited")
        XCTAssertEqual(tokenStore.loadAccessToken(), freshAccess, "Fresh access token persisted")
        XCTAssertEqual(tokenStore.loadRefreshToken(), "lm_refresh_rotated", "Rotated refresh token persisted")
    }

    /// Case 3 (401): expired access token + rejected/expired refresh token →
    /// logged out, `sessionExpired` set, dead tokens cleared.
    func testLaunchWithExpiredAccessAndRejectedRefreshLogsOut() async throws {
        let expiredAccess = Self.makeJWT(expSecondsFromNow: -60)
        tokenStore.saveAccessToken(expiredAccess)
        tokenStore.saveRefreshToken("lm_refresh_dead")

        mockAPI.responses = [.failure(APIError.unauthorized)]

        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)
        await store.restoreSession()

        XCTAssertFalse(store.isRestoring)
        XCTAssertFalse(store.isAuthenticated, "Rejected refresh must log the user out")
        XCTAssertTrue(store.sessionExpired, "Rejected refresh is an expired session")
        XCTAssertNil(tokenStore.loadAccessToken(), "Dead access token cleared")
        XCTAssertNil(tokenStore.loadRefreshToken(), "Dead refresh token cleared")
        XCTAssertEqual(mockAPI.sentPaths, ["/v1/auth/refresh"])
        XCTAssertFalse(
            mockAPI.sentPaths.contains("/v1/auth/logout"),
            "Expired session must not invoke the outbox-clearing logout path"
        )
    }

    /// Case 3 (transient): expired access token + network failure on refresh →
    /// stays authenticated-but-offline, NOT logged out, tokens preserved for a
    /// later retry.
    func testLaunchWithExpiredAccessAndNetworkFailureStaysAuthenticated() async throws {
        let expiredAccess = Self.makeJWT(expSecondsFromNow: -60, sub: "user-offline")
        tokenStore.saveAccessToken(expiredAccess)
        tokenStore.saveRefreshToken("lm_refresh_still_valid")

        mockAPI.responses = [.failure(APIError.transport(URLError(.notConnectedToInternet)))]

        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)
        await store.restoreSession()

        XCTAssertFalse(store.isRestoring)
        XCTAssertTrue(store.isAuthenticated, "Transient failure must NOT log the user out")
        XCTAssertFalse(store.sessionExpired, "Network failure is not an expired session")
        XCTAssertEqual(store.currentUser?.userId, "user-offline")
        XCTAssertEqual(
            tokenStore.loadAccessToken(), expiredAccess,
            "Access token preserved for retry"
        )
        XCTAssertEqual(
            tokenStore.loadRefreshToken(), "lm_refresh_still_valid",
            "Refresh token preserved — re-login NOT required"
        )
        XCTAssertEqual(mockAPI.sentPaths, ["/v1/auth/refresh"])
    }

    /// No tokens at all → logged out, restoration complete immediately, no
    /// network call.
    func testLaunchWithNoTokensIsLoggedOutImmediately() async {
        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)
        XCTAssertFalse(store.isRestoring, "Nothing to restore → not restoring")
        XCTAssertFalse(store.isAuthenticated)
        await store.restoreSession()
        XCTAssertEqual(mockAPI.sentPaths.count, 0, "No tokens → no network call")
    }

    /// Fresh (unexpired) access token → authenticated with no network call and
    /// no restoring state.
    func testLaunchWithFreshAccessTokenSkipsRefresh() async {
        let freshAccess = Self.makeJWT(expSecondsFromNow: 3600)
        tokenStore.saveAccessToken(freshAccess)
        tokenStore.saveRefreshToken("lm_refresh_x")

        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)
        XCTAssertFalse(store.isRestoring, "Fresh token needs no refresh")
        XCTAssertTrue(store.isAuthenticated)
        await store.restoreSession()
        XCTAssertEqual(mockAPI.sentPaths.count, 0, "Fresh token must not hit the network")
    }

    /// Single-flight: a launch restore in flight and a concurrent
    /// `refreshIfNeeded()` must share ONE refresh round-trip, never double-spend
    /// the rotating refresh token.
    func testConcurrentLaunchRestoreAndRefreshCoalesceToOneCall() async throws {
        let expiredAccess = Self.makeJWT(expSecondsFromNow: -60)
        tokenStore.saveAccessToken(expiredAccess)
        tokenStore.saveRefreshToken("lm_refresh_valid")

        let freshAccess = Self.makeJWT(expSecondsFromNow: 3600)
        mockAPI.responses = [
            .success([
                "access_jwt": freshAccess,
                "refresh_token": "lm_refresh_rotated",
            ]),
        ]
        // Hold the refresh open until both callers are parked on it.
        mockAPI.gate = true

        let store = AuthenticationStore(api: mockAPI, tokenStore: tokenStore)

        async let restore: Void = store.restoreSession()
        async let extra: String = store.refreshIfNeeded()

        // Let both tasks reach the gated network call, then release it.
        try await Task.sleep(nanoseconds: 50_000_000)
        mockAPI.openGate()

        _ = await restore
        let token = try await extra

        XCTAssertEqual(token, freshAccess)
        XCTAssertEqual(
            mockAPI.sentPaths, ["/v1/auth/refresh"],
            "Concurrent launch restore + refresh must coalesce to a single refresh call"
        )
    }

    // MARK: - JWT helpers

    /// Builds a minimally-valid unsigned JWT with the requested exp claim.
    /// The signature segment is junk — we don't verify locally.
    private static func makeJWT(expSecondsFromNow: TimeInterval, sub: String = "user-test") -> String {
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "sub": sub,
            "exp": Date().timeIntervalSince1970 + expSecondsFromNow,
        ]
        func b64(_ obj: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else {
                return ""
            }
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(header)).\(b64(payload)).signature-junk"
    }
}

// MARK: - Mock APIClient

/// Bare-bones mock: returns a JSON dictionary encoded/decoded through the
/// real codable machinery so snake_case conversion is exercised.
///
/// Two response modes:
/// - Legacy single-shot: set `nextDecodableResponse` / `nextError` (one call).
/// - Sequenced: set `responses` to a FIFO queue of `.success(dict)` /
///   `.failure(error)`. `responses` wins when non-empty.
///
/// `gate` parks every call until `openGate()` is invoked, so concurrency tests
/// can force two callers to overlap on the same in-flight request.
///
/// Exercised entirely on the `@MainActor` (the store's refresh runs there), so
/// the mutable state needs no extra locking; the `@unchecked Sendable` is only
/// to satisfy the protocol's `Sendable` requirement.
final class MockAPIClient: APIClientProtocol, @unchecked Sendable {
    enum Response {
        case success([String: Any])
        case failure(Error)
    }

    var sentPaths: [String] = []
    var nextDecodableResponse: [String: Any]?
    var nextError: Error?

    /// FIFO queue of sequenced responses. Takes precedence over the legacy
    /// single-shot fields when non-empty.
    var responses: [Response] = []

    /// When true, calls block (yielding the actor) until `openGate()`.
    var gate = false

    func openGate() { gate = false }

    private func awaitGate() async {
        // Poll-yield rather than block the actor so overlapping callers can
        // both reach this point before the gate opens.
        while gate {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func nextDict() throws -> [String: Any] {
        if !responses.isEmpty {
            switch responses.removeFirst() {
            case .success(let dict): return dict
            case .failure(let error): throw error
            }
        }
        if let error = nextError {
            nextError = nil
            throw error
        }
        guard let dict = nextDecodableResponse else {
            throw APIError.server(status: 500, message: "Mock: no response queued")
        }
        nextDecodableResponse = nil
        return dict
    }

    private func decode<Res: Decodable>(_ dict: [String: Any]) throws -> Res {
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Res.self, from: data)
    }

    func send<Req: Encodable, Res: Decodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws -> Res {
        sentPaths.append(path)
        await awaitGate()
        return try decode(try nextDict())
    }

    func sendEmpty<Req: Encodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws {
        sentPaths.append(path)
        await awaitGate()
        if !responses.isEmpty {
            if case .failure(let error) = responses.removeFirst() { throw error }
            return
        }
        if let error = nextError {
            nextError = nil
            throw error
        }
    }

    func sendData<Res: Decodable>(
        path: String,
        method: String,
        bodyData: Data,
        accessToken: String?
    ) async throws -> Res {
        sentPaths.append(path)
        await awaitGate()
        return try decode(try nextDict())
    }
}
