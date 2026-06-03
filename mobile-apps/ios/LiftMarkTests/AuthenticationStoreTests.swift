import XCTest
@testable import LiftMark

@MainActor
final class AuthenticationStoreTests: XCTestCase {

    private var tokenStore: TokenStore!
    private var mockAPI: MockAPIClient!
    private var profileStore: ProfileStore!

    // Distinct service per run so we don't collide with real device keychain
    // entries or other parallel test runs.
    private var serviceKey: String!
    private var profileDefaults: UserDefaults!
    private var profileSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        serviceKey = "app.liftmark.auth.tests.\(UUID().uuidString)"
        tokenStore = TokenStore(service: serviceKey)
        tokenStore.clear()
        // Isolated UserDefaults suite per run so persisted-profile state can't
        // leak between tests or into the real app domain.
        profileSuiteName = "app.liftmark.profile.tests.\(UUID().uuidString)"
        profileDefaults = UserDefaults(suiteName: profileSuiteName)
        profileStore = ProfileStore(defaults: profileDefaults, key: "auth.lastKnownProfile")
        mockAPI = MockAPIClient()
    }

    override func tearDown() async throws {
        tokenStore.clear()
        tokenStore = nil
        mockAPI = nil
        profileStore = nil
        profileDefaults.removePersistentDomain(forName: profileSuiteName)
        profileDefaults = nil
        profileSuiteName = nil
        serviceKey = nil
        try await super.tearDown()
    }

    /// Builds a store wired to this test's isolated token + profile stores.
    private func makeStore() -> AuthenticationStore {
        AuthenticationStore(api: mockAPI, tokenStore: tokenStore, profileStore: profileStore)
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
        let store = makeStore()
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

        let store = makeStore()

        let result = try await store.refreshIfNeeded()
        XCTAssertEqual(result, validToken)
        XCTAssertEqual(mockAPI.sentPaths.count, 0, "Should not have hit the network for a valid token")
    }

    // MARK: - sessionExpired (GH #143)

    func testRefreshUnauthorizedSetsSessionExpiredAndClearsTokens() async {
        let store = makeStore()

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
        let store = makeStore()

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
        let store = makeStore()

        let expiredToken = Self.makeJWT(expSecondsFromNow: -60)
        tokenStore.saveAccessToken(expiredToken)
        tokenStore.saveRefreshToken("lm_refresh_old")

        let newAccess = Self.makeJWT(expSecondsFromNow: 3600)
        // refresh, then the self-healing /v1/me (currentUser is nil here:
        // no persisted profile and the store was built before any token).
        mockAPI.responses = [
            .success([
                "access_jwt": newAccess,
                "refresh_token": "lm_refresh_new",
            ]),
            .success([
                "user_id": "user-test",
                "primary_email": "rf@example.com",
                "display_name": "RF",
                "tier": "pro",
            ]),
        ]

        let result = try await store.refreshIfNeeded()
        XCTAssertEqual(result, newAccess)
        XCTAssertEqual(
            mockAPI.sentPaths, ["/v1/auth/refresh", "/v1/me"],
            "Refresh with no in-memory user must self-heal via /v1/me"
        )
        XCTAssertEqual(store.currentUser?.tier, .pro)
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
            // performRestore drives a best-effort /v1/me after the refresh.
            .success([
                "user_id": "user-test",
                "primary_email": "restored@example.com",
                "display_name": "Restored",
                "tier": "trial",
            ]),
        ]

        let store = makeStore()

        // Restoration is in flight immediately after init (access token stale).
        XCTAssertTrue(store.isRestoring, "Stale access token must enter restoring state")
        XCTAssertTrue(store.isAuthenticated, "User is reconstituted from claims, not logged out")

        await store.restoreSession()

        XCTAssertFalse(store.isRestoring, "Restoration must have settled")
        XCTAssertTrue(store.isReady)
        XCTAssertTrue(store.isAuthenticated, "Valid refresh must keep the user signed in")
        XCTAssertFalse(store.sessionExpired)
        XCTAssertEqual(
            mockAPI.sentPaths, ["/v1/auth/refresh", "/v1/me"],
            "Refresh awaited, then /v1/me fetched for the real profile"
        )
        XCTAssertEqual(store.currentUser?.tier, .trial, "Restore must adopt the real /v1/me tier")
        XCTAssertEqual(store.currentUser?.email, "restored@example.com")
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

        let store = makeStore()
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

        let store = makeStore()
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
        let store = makeStore()
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

        let store = makeStore()
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
            // performRestore's best-effort /v1/me after the gated refresh.
            .success([
                "user_id": "user-test",
                "primary_email": "c@example.com",
                "display_name": "C",
                "tier": "pro",
            ]),
        ]
        // Hold the refresh open until both callers are parked on it.
        mockAPI.gate = true

        let store = makeStore()

        async let restore: Void = store.restoreSession()
        async let extra: String = store.refreshIfNeeded()

        // Let both tasks reach the gated network call, then release it.
        try await Task.sleep(nanoseconds: 50_000_000)
        mockAPI.openGate()

        _ = await restore
        let token = try await extra

        XCTAssertEqual(token, freshAccess)
        XCTAssertEqual(
            mockAPI.sentPaths.filter { $0 == "/v1/auth/refresh" }.count, 1,
            "Concurrent launch restore + refresh must coalesce to a single refresh call"
        )
    }

    /// Single-flight (B-client): two concurrent `refreshIfNeeded()` callers,
    /// neither via the launch path, must share exactly ONE `/v1/auth/refresh`
    /// round-trip so the rotating refresh token is never double-spent.
    func testConcurrentRefreshIfNeededCallsCoalesceToOneRefresh() async throws {
        // Build the store with a fresh access token so init-time rehydration
        // does NOT start its own restore/refresh — we want to drive the two
        // refreshes explicitly. Then drop in an expired token so the explicit
        // calls actually refresh.
        let store = makeStore()

        let expiredAccess = Self.makeJWT(expSecondsFromNow: -60, sub: "user-sf")
        tokenStore.saveAccessToken(expiredAccess)
        tokenStore.saveRefreshToken("lm_refresh_sf")

        let freshAccess = Self.makeJWT(expSecondsFromNow: 3600, sub: "user-sf")
        mockAPI.responses = [
            .success([
                "access_jwt": freshAccess,
                "refresh_token": "lm_refresh_sf_rotated",
            ]),
            // currentUser is nil (no persisted profile, store built empty), so
            // the first refresh self-heals via /v1/me.
            .success([
                "user_id": "user-sf",
                "primary_email": "sf@example.com",
                "display_name": "SF",
                "tier": "trial",
            ]),
        ]
        mockAPI.gate = true

        async let first: String = store.refreshIfNeeded()
        async let second: String = store.refreshIfNeeded()

        try await Task.sleep(nanoseconds: 50_000_000)
        mockAPI.openGate()

        let tokenA = try await first
        let tokenB = try await second

        XCTAssertEqual(tokenA, freshAccess)
        XCTAssertEqual(tokenB, freshAccess, "Both callers must receive the single rotated token")
        XCTAssertEqual(
            mockAPI.sentPaths.filter { $0 == "/v1/auth/refresh" }.count, 1,
            "Two concurrent refreshIfNeeded callers must trigger exactly one /v1/auth/refresh"
        )
        XCTAssertEqual(
            tokenStore.loadRefreshToken(), "lm_refresh_sf_rotated",
            "The rotated refresh token must be persisted exactly once"
        )
    }

    // MARK: - Persisted profile (iOS auth hardening)

    /// Rehydration restores a persisted *trial-tier* user verbatim — real
    /// email + real tier — NOT the old hardcoded `.free` placeholder.
    func testRehydrateRestoresPersistedTrialUserNotFree() async {
        // Persist a trial user whose user_id matches the JWT `sub`.
        let trialEnds = Date().addingTimeInterval(7 * 86_400)
        let persisted = AuthenticatedUser(
            userId: "user-test",
            email: "trialist@example.com",
            displayName: "Trialist",
            tier: .trial,
            trialEndsAt: trialEnds
        )
        profileStore.save(persisted)

        // Fresh (unexpired) access token so rehydrate restores synchronously
        // and does NOT kick off a background refresh that races this assertion.
        let freshAccess = Self.makeJWT(expSecondsFromNow: 3600, sub: "user-test")
        tokenStore.saveAccessToken(freshAccess)
        tokenStore.saveRefreshToken("lm_refresh_x")

        let store = makeStore()

        XCTAssertFalse(store.isRestoring, "Fresh token needs no refresh")
        XCTAssertEqual(store.currentUser?.tier, .trial, "Must restore the real tier, not .free")
        XCTAssertEqual(store.currentUser?.email, "trialist@example.com", "Must restore the real email")
        XCTAssertEqual(store.currentUser?.displayName, "Trialist")
        XCTAssertEqual(store.currentUser?.trialEndsAt, trialEnds)
        XCTAssertEqual(mockAPI.sentPaths.count, 0, "No network call for a fresh token")
    }

    /// With no persisted profile, rehydration falls back to JWT claims (and the
    /// `.free` unknown-plan default) rather than crashing or showing nothing.
    func testRehydrateFallsBackToClaimsWhenNoPersistedProfile() async {
        let freshAccess = Self.makeJWT(expSecondsFromNow: 3600, sub: "user-claims")
        tokenStore.saveAccessToken(freshAccess)
        tokenStore.saveRefreshToken("lm_refresh_x")

        let store = makeStore()
        XCTAssertEqual(store.currentUser?.userId, "user-claims")
        XCTAssertEqual(store.currentUser?.tier, .free, "No profile → claims fallback uses .free default")
    }

    /// After a successful refresh that left `currentUser` nil (no persisted
    /// profile), `fetchMe()` populates `currentUser` from a mocked `/v1/me`.
    func testFetchMePopulatesCurrentUserAfterRefresh() async throws {
        // Start logged out (no tokens, no profile) → currentUser nil.
        let store = makeStore()
        XCTAssertNil(store.currentUser)

        // Put a fresh access token in place so withAuthorizedRequest inside
        // fetchMe does not need to refresh — it goes straight to /v1/me.
        let freshAccess = Self.makeJWT(expSecondsFromNow: 3600, sub: "user-me")
        tokenStore.saveAccessToken(freshAccess)
        tokenStore.saveRefreshToken("lm_refresh_me")

        let trialEnds = "2026-07-01T00:00:00.000Z"
        mockAPI.responses = [
            .success([
                "user_id": "user-me",
                "primary_email": "me@example.com",
                "display_name": "Me",
                "tier": "trial",
                "trial_ends_at": trialEnds,
            ]),
        ]

        await store.fetchMe()

        XCTAssertEqual(store.currentUser?.userId, "user-me")
        XCTAssertEqual(store.currentUser?.email, "me@example.com", "primary_email maps to email")
        XCTAssertEqual(store.currentUser?.tier, .trial)
        XCTAssertEqual(store.currentUser?.displayName, "Me")
        XCTAssertEqual(mockAPI.sentPaths, ["/v1/me"], "fetchMe must call GET /v1/me")
        // Profile must be persisted so a later relaunch restores it.
        XCTAssertEqual(profileStore.load()?.tier, .trial)
        XCTAssertEqual(profileStore.load()?.email, "me@example.com")
    }

    /// A transient `/v1/me` failure is swallowed: the user is NOT signed out
    /// and the persisted profile is preserved.
    func testFetchMeFailureIsBestEffort() async throws {
        let existing = AuthenticatedUser(
            userId: "user-keep",
            email: "keep@example.com",
            displayName: "Keep",
            tier: .pro,
            trialEndsAt: nil
        )
        profileStore.save(existing)

        let freshAccess = Self.makeJWT(expSecondsFromNow: 3600, sub: "user-keep")
        tokenStore.saveAccessToken(freshAccess)
        tokenStore.saveRefreshToken("lm_refresh_keep")

        let store = makeStore()
        XCTAssertEqual(store.currentUser?.tier, .pro)

        mockAPI.responses = [.failure(APIError.transport(URLError(.timedOut)))]
        await store.fetchMe()

        XCTAssertEqual(store.currentUser?.tier, .pro, "Transient /v1/me failure must not change the user")
        XCTAssertTrue(store.isAuthenticated, "fetchMe failure must NOT sign the user out")
        XCTAssertEqual(profileStore.load()?.tier, .pro, "Persisted profile must survive a /v1/me failure")
    }

    /// Logout clears the persisted profile; session-expiry keeps it.
    func testLogoutClearsProfileButExpiryKeepsIt() async throws {
        let user = AuthenticatedUser(
            userId: "user-test",
            email: "u@example.com",
            displayName: "U",
            tier: .trial,
            trialEndsAt: nil
        )
        profileStore.save(user)
        let expiredAccess = Self.makeJWT(expSecondsFromNow: -60)
        tokenStore.saveAccessToken(expiredAccess)
        tokenStore.saveRefreshToken("lm_refresh_dead")

        // Session expiry (refresh 401) must KEEP the profile.
        mockAPI.responses = [.failure(APIError.unauthorized)]
        let store = makeStore()
        await store.restoreSession()
        XCTAssertTrue(store.sessionExpired)
        XCTAssertNotNil(profileStore.load(), "Expired session keeps the profile for the re-auth UI")

        // Deliberate logout must CLEAR it.
        await store.logout()
        XCTAssertNil(profileStore.load(), "Logout must clear the persisted profile")
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
