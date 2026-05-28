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
/// real codable machinery so snake_case conversion is exercised. One canned
/// response per call site is enough for the current tests.
final class MockAPIClient: APIClientProtocol, @unchecked Sendable {
    var sentPaths: [String] = []
    var nextDecodableResponse: [String: Any]?
    var nextError: Error?

    func send<Req: Encodable, Res: Decodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws -> Res {
        sentPaths.append(path)
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        guard let dict = nextDecodableResponse else {
            throw APIError.server(status: 500, message: "Mock: no response queued")
        }
        nextDecodableResponse = nil
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Res.self, from: data)
    }

    func sendEmpty<Req: Encodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws {
        sentPaths.append(path)
        if let nextError {
            self.nextError = nil
            throw nextError
        }
    }

    func sendData<Res: Decodable>(
        path: String,
        method: String,
        bodyData: Data,
        accessToken: String?
    ) async throws -> Res {
        sentPaths.append(path)
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        guard let dict = nextDecodableResponse else {
            throw APIError.server(status: 500, message: "Mock: no response queued")
        }
        nextDecodableResponse = nil
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Res.self, from: data)
    }
}
