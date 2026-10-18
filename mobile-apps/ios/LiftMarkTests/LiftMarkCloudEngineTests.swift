import XCTest
@testable import LiftMark

/// `POST /v1/ai/plan/edit` client. See spec/services/ai-plan-editing.md
/// ("LiftMarkCloudEngine" and "Cloud API").
@MainActor
final class LiftMarkCloudEngineTests: XCTestCase {

    private var tokenStore: TokenStore!
    private var api: FakePlanEditAPIClient!

    override func setUp() async throws {
        try await super.setUp()
        tokenStore = TokenStore(service: "app.liftmark.ai.tests.\(UUID().uuidString)")
        tokenStore.clear()
        api = FakePlanEditAPIClient()
    }

    override func tearDown() async throws {
        tokenStore.clear()
        tokenStore = nil
        api = nil
        try await super.tearDown()
    }

    private func makeEngine(signedIn: Bool) -> LiftMarkCloudEngine {
        if signedIn {
            tokenStore.saveAccessToken(Self.makeJWT(expSecondsFromNow: 3600))
            tokenStore.saveRefreshToken("lm_refresh_test")
        }
        let auth = AuthenticationStore(api: api, tokenStore: tokenStore)
        XCTAssertEqual(auth.isAuthenticated, signedIn)
        return LiftMarkCloudEngine(authStore: auth, apiClient: api)
    }

    private func edit(
        _ engine: LiftMarkCloudEngine,
        instruction: String = "add a warm-up"
    ) async -> Result<PlanEditResult, PlanEditError> {
        do {
            return .success(try await engine.edit(PlanEditFixtures.request(instruction: instruction)))
        } catch let error as PlanEditError {
            return .failure(error)
        } catch {
            XCTFail("non-PlanEditError thrown: \(error)")
            return .failure(.model("\(error)"))
        }
    }

    // MARK: - Auth gate

    func testUnavailableWhenSignedOut() async {
        let engine = makeEngine(signedIn: false)
        let availability = await engine.availability()
        XCTAssertEqual(availability, .unavailable(reason: "Sign in to use LiftMark cloud"))
    }

    func testAvailableWhenSignedIn() async {
        let engine = makeEngine(signedIn: true)
        let availability = await engine.availability()
        XCTAssertEqual(availability, .available)
    }

    func testEditThrowsNotSignedInWithoutSession() async {
        let engine = makeEngine(signedIn: false)
        let result = await edit(engine)
        XCTAssertEqual(result, .failure(.notSignedIn))
        XCTAssertTrue(api.requests.isEmpty, "no network call when signed out")
    }

    // MARK: - Happy path

    func testSuccessDecodesResultAndQuota() async throws {
        let engine = makeEngine(signedIn: true)
        let edited = PlanEditFixtures.pushDay + "\n\n## Face Pull\n- x 15\n"
        api.responses = [.success([
            "plan_markdown": edited,
            "summary": "Added face pulls.",
            "warnings": ["server warning"],
            "quota": ["limit": 20, "remaining": 18, "reset_at": "2026-10-17T00:00:00.000Z", "in_grace": false],
            "model": "us.amazon.nova-2-lite-v1:0",
            "usage": ["input_tokens": 900, "output_tokens": 300],
        ])]

        let result = try await engine.edit(PlanEditFixtures.request(
            instruction: "add face pulls",
            history: [PlanEditTurn(role: .user, content: "hi")],
            context: PlanEditContext(units: .kg, equipment: ["cable"], recentSessions: "recent")
        ))

        XCTAssertEqual(result.engine, .liftMarkCloud)
        XCTAssertEqual(result.planMarkdown, edited)
        XCTAssertEqual(result.summary, "Added face pulls.")
        XCTAssertEqual(result.warnings, ["server warning"])
        XCTAssertEqual(result.quota?.limit, 20)
        XCTAssertEqual(result.quota?.remaining, 18)
        XCTAssertEqual(result.quota?.inGrace, false)
        XCTAssertEqual(result.quota?.resetAt, ISO8601DateFormatter().date(from: "2026-10-17T00:00:00Z"))

        // Request shape: snake_case, bearer token, correct route.
        let request = try XCTUnwrap(api.requests.first)
        XCTAssertEqual(request.path, "/v1/ai/plan/edit")
        XCTAssertEqual(request.method, "POST")
        XCTAssertNotNil(request.accessToken)
        XCTAssertEqual(request.body["plan_markdown"] as? String, PlanEditFixtures.pushDay)
        XCTAssertEqual(request.body["instruction"] as? String, "add face pulls")
        let history = try XCTUnwrap(request.body["history"] as? [[String: Any]])
        XCTAssertEqual(history.first?["role"] as? String, "user")
        XCTAssertEqual(history.first?["content"] as? String, "hi")
        let context = try XCTUnwrap(request.body["context"] as? [String: Any])
        XCTAssertEqual(context["units"] as? String, "kg")
        XCTAssertEqual(context["equipment"] as? [String], ["cable"])
        XCTAssertEqual(context["recent_sessions"] as? String, "recent")
        XCTAssertFalse(request.body.keys.contains("original_markdown"), "nil original is omitted")
    }

    func testOriginalMarkdownIsSentWhenSet() async throws {
        let engine = makeEngine(signedIn: true)
        api.responses = [.success(["plan_markdown": PlanEditFixtures.pushDay, "summary": "Restored."])]
        let edited = PlanEditFixtures.pushDay + "\n\n## Face Pull\n- x 15\n"

        _ = try await engine.edit(PlanEditRequest(
            planMarkdown: edited,
            originalMarkdown: PlanEditFixtures.pushDay,
            instruction: "put it back",
            history: [],
            context: PlanEditContext(units: .lbs)
        ))

        let request = try XCTUnwrap(api.requests.first)
        XCTAssertEqual(request.body["plan_markdown"] as? String, edited)
        XCTAssertEqual(request.body["original_markdown"] as? String, PlanEditFixtures.pushDay)
    }

    func testSuccessWithoutOptionalFieldsStillDecodes() async throws {
        let engine = makeEngine(signedIn: true)
        api.responses = [.success(["plan_markdown": PlanEditFixtures.pushDay, "summary": "No change."])]
        let result = try await engine.edit(PlanEditFixtures.request())
        XCTAssertEqual(result.warnings, [])
        XCTAssertNil(result.quota)
    }

    func testSuccessWithUnparseableMarkdownThrowsOutputDidNotParse() async {
        let engine = makeEngine(signedIn: true)
        api.responses = [.success(["plan_markdown": "garbage without a header", "summary": "?"])]
        let result = await edit(engine)
        guard case .failure(.outputDidNotParse(let errors)) = result else {
            return XCTFail("expected outputDidNotParse, got \(result)")
        }
        XCTAssertFalse(errors.isEmpty)
    }

    // MARK: - Status mapping

    func testStatusMapping() async {
        let cases: [(APIError, PlanEditError)] = [
            (.server(status: 402, message: "Subscription required"), .subscriptionRequired),
            (.server(status: 413, message: "Too large"), .planTooLarge),
            (.server(status: 422, message: "Model output did not parse"),
             .outputDidNotParse(["Model output did not parse"])),
            (.server(status: 429, message: "Daily AI limit reached"), .quotaExhausted(resetAt: nil)),
            (.server(status: 502, message: "Bedrock throttled"), .model("Bedrock throttled")),
            (.server(status: 504, message: "Model timed out"), .model("Model timed out")),
            (.unauthorized, .notSignedIn),
            (.forbidden(message: "Token lacks ai:edit scope"), .model("Token lacks ai:edit scope")),
            (.edgeBlocked(status: 403), .network),
            (.transport(URLError(.notConnectedToInternet)), .network),
        ]
        for (apiError, expected) in cases {
            XCTAssertEqual(LiftMarkCloudEngine.mapError(apiError), expected, "mapping for \(apiError)")
        }
    }

    func testServerErrorsSurfaceThroughEdit() async {
        let engine = makeEngine(signedIn: true)
        api.responses = [.failure(APIError.server(status: 402, message: "Subscription required"))]
        let result = await edit(engine)
        XCTAssertEqual(result, .failure(.subscriptionRequired))
    }

    func testTransportFailureMapsToNetwork() async {
        let engine = makeEngine(signedIn: true)
        api.responses = [.failure(APIError.transport(URLError(.timedOut)))]
        let result = await edit(engine)
        XCTAssertEqual(result, .failure(.network))
    }

    func testOversizedInstructionFailsBeforeNetwork() async {
        let engine = makeEngine(signedIn: true)
        let result = await edit(engine, instruction: String(repeating: "x", count: 3_000))
        XCTAssertEqual(result, .failure(.planTooLarge))
        XCTAssertTrue(api.requests.isEmpty)
    }

    // MARK: - Helpers

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
}

// MARK: - Fake API client

/// Records every request (with its body encoded exactly as `APIClient` would,
/// snake_case) and replays scripted responses.
private final class FakePlanEditAPIClient: APIClientProtocol, @unchecked Sendable {
    struct Request {
        let path: String
        let method: String
        let body: [String: Any]
        let accessToken: String?
    }

    enum Response {
        case success([String: Any])
        case failure(Error)
    }

    var requests: [Request] = []
    var responses: [Response] = []

    private func record<Req: Encodable>(path: String, method: String, body: Req?, accessToken: String?) throws {
        var json: [String: Any] = [:]
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(body)
            json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        requests.append(Request(path: path, method: method, body: json, accessToken: accessToken))
    }

    private func next<Res: Decodable>() throws -> Res {
        guard !responses.isEmpty else {
            throw APIError.server(status: 500, message: "Fake: no response queued")
        }
        switch responses.removeFirst() {
        case .failure(let error):
            throw error
        case .success(let dict):
            let data = try JSONSerialization.data(withJSONObject: dict)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            decoder.dateDecodingStrategy = .custom { dateDecoder in
                let string = try dateDecoder.singleValueContainer().decode(String.self)
                if let date = fractional.date(from: string) ?? plain.date(from: string) { return date }
                throw DecodingError.dataCorruptedError(
                    in: try dateDecoder.singleValueContainer(),
                    debugDescription: "Not an ISO8601 date: \(string)"
                )
            }
            do {
                return try decoder.decode(Res.self, from: data)
            } catch {
                throw APIError.decoding(error)
            }
        }
    }

    func send<Req: Encodable, Res: Decodable>(
        path: String, method: String, body: Req?, accessToken: String?
    ) async throws -> Res {
        try record(path: path, method: method, body: body, accessToken: accessToken)
        return try next()
    }

    func sendEmpty<Req: Encodable>(path: String, method: String, body: Req?, accessToken: String?) async throws {
        try record(path: path, method: method, body: body, accessToken: accessToken)
        if !responses.isEmpty, case .failure(let error) = responses.removeFirst() { throw error }
    }

    func sendData<Res: Decodable>(
        path: String, method: String, bodyData: Data, accessToken: String?
    ) async throws -> Res {
        let json = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
        requests.append(Request(path: path, method: method, body: json, accessToken: accessToken))
        return try next()
    }
}
