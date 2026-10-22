import XCTest
@testable import LiftMark

/// Canned HTTP for `AIProviderService` — no real network. Routes by host (+ path for Ollama).
final class AIStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(Int, String)
        case transportError
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func set(_ newReplies: [String: Reply]) {
        lock.withLock { replies = newReplies; recorded = [] }
    }

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AIStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let route = (request.url?.host ?? "") + (request.url?.path ?? "")
        let reply: Reply? = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.replies.first { route.hasPrefix($0.key) }?.value
        }
        switch reply {
        case .http(let status, let body)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .transportError?, nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }
}

final class AIProviderServiceTests: XCTestCase {
    private typealias Fix = AIProviderFixtures

    private let service = AIProviderService(session: AIStubURLProtocol.session())

    private let anthropic = AIProviderKey(id: "a", provider: .anthropic, apiKey: AIProviderTests.validAnthropic,
                                          status: .verified)
    private let openai = AIProviderKey(id: "o", provider: .openai, apiKey: AIProviderTests.validOpenAI)
    private let gemini = AIProviderKey(id: "g", provider: .gemini, apiKey: AIProviderTests.validGemini,
                                       status: .verified)
    private let ollama = AIProviderKey(id: "l", provider: .ollama, baseURL: "http://ollama.test:11434")

    private let anthropicHost = "api.anthropic.com"
    private let openAIHost = "api.openai.com"
    private let geminiHost = "generativelanguage.googleapis.com"

    // MARK: - Verify

    func testVerifySuccessReturnsModels() async {
        AIStubURLProtocol.set([geminiHost: .http(200, Fix.geminiModels)])
        let result = await service.verify(gemini)
        XCTAssertEqual(result.status, .verified)
        XCTAssertEqual(result.models, ["gemini-2.5-flash", "gemini-2.5-pro"])
        XCTAssertNil(result.message)
        XCTAssertEqual(AIStubURLProtocol.requests.map(\.httpMethod), ["GET"], "one free GET, no generation")
    }

    func testVerifyRejectedKeyIsInvalid() async {
        AIStubURLProtocol.set([openAIHost: .http(401, Fix.openAIInvalidKey)])
        let result = await service.verify(openai)
        XCTAssertEqual(result.status, .invalid)
        XCTAssertEqual(result.models, [])
        XCTAssertTrue(result.message?.hasPrefix("OpenAI rejected this key. Incorrect API key provided") == true)
    }

    func testVerifyGeminiAPIKeyInvalidIsInvalid() async {
        AIStubURLProtocol.set([geminiHost: .http(400, Fix.geminiInvalidKey)])
        let result = await service.verify(gemini)
        XCTAssertEqual(result.status, .invalid)
    }

    func testVerifyForbiddenIsUnverifiedNotInvalid() async {
        AIStubURLProtocol.set([openAIHost: .http(403, Fix.openAIUnsupportedRegion)])
        let result = await service.verify(openai)
        XCTAssertEqual(result.status, .unverified)
    }

    func testForbiddenGenerationFallsBackWithoutMarkingInvalid() async {
        AIStubURLProtocol.set([
            openAIHost: .http(403, Fix.openAIUnsupportedRegion),
            geminiHost: .http(200, Fix.geminiGenerateContent),
        ])
        let outcome = await service.generateWorkout(prompt: "p", keys: [openai, gemini])
        XCTAssertEqual(outcome.keyId, "g")
        XCTAssertEqual(outcome.statusUpdates, [:], "403 must not mark the OpenAI key invalid")
    }

    func testVerifyServerErrorIsUnverified() async {
        AIStubURLProtocol.set([anthropicHost: .http(529, Fix.anthropicOverloaded)])
        let result = await service.verify(anthropic)
        XCTAssertEqual(result.status, .unverified)
        XCTAssertTrue(result.message?.contains("HTTP 529") == true)
    }

    func testVerifyTransportErrorIsUnverified() async {
        AIStubURLProtocol.set([:])
        let result = await service.verify(ollama)
        XCTAssertEqual(result.status, .unverified)
        XCTAssertTrue(result.message?.contains("http://ollama.test:11434") == true)
        XCTAssertTrue(result.message?.hasSuffix("It will be verified on first use.") == true)
    }

    func testVerifyMissingKeyMakesNoRequest() async {
        AIStubURLProtocol.set([:])
        let result = await service.verify(AIProviderKey(provider: .openai))
        XCTAssertEqual(result.status, .invalid)
        XCTAssertTrue(AIStubURLProtocol.requests.isEmpty)
    }

    // MARK: - Generate (single key)

    func testGenerateSuccessPerProvider() async {
        AIStubURLProtocol.set([
            anthropicHost: .http(200, Fix.anthropicMessage),
            openAIHost: .http(200, Fix.openAIChatCompletion),
            geminiHost: .http(200, Fix.geminiGenerateContent),
            "ollama.test/api/chat": .http(200, Fix.ollamaChat),
        ])
        let expected = [
            "a": "# Push Day\n## Bench Press\n- 135 x 5",
            "o": "# Pull Day\n## Row\n- 95 x 8",
            "g": "# Leg Day\n## Squat\n- 225 x 5",
            "l": "# Push Day",
        ]
        for key in [anthropic, openai, gemini, ollama] {
            let result = await service.generateWorkout(prompt: "p", key: key)
            XCTAssertTrue(result.success, "\(key.provider)")
            XCTAssertEqual(result.workout, expected[key.id])
        }
    }

    func testGenerateEmptyResponse() async {
        AIStubURLProtocol.set([geminiHost: .http(200, Fix.geminiNoText)])
        let result = await service.generateWorkout(prompt: "p", key: gemini)
        XCTAssertEqual(result.error?.kind, .emptyResponse)
    }

    func testGenerateMissingKey() async {
        AIStubURLProtocol.set([:])
        let result = await service.generateWorkout(prompt: "p", key: AIProviderKey(provider: .anthropic, apiKey: " "))
        XCTAssertEqual(result.error?.kind, .missingApiKey)
        XCTAssertEqual(result.error?.message, "API key is required. Add your Anthropic key in Settings.")
        XCTAssertTrue(AIStubURLProtocol.requests.isEmpty)
    }

    func testGenerateTransportError() async {
        AIStubURLProtocol.set([:])
        let result = await service.generateWorkout(prompt: "p", key: openai)
        XCTAssertEqual(result.error?.kind, .networkError)
    }

    // MARK: - Ordered fallback

    func testFallsBackToNextKey() async {
        AIStubURLProtocol.set([
            anthropicHost: .http(529, Fix.anthropicOverloaded),
            openAIHost: .http(200, Fix.openAIChatCompletion),
        ])
        let outcome = await service.generateWorkout(prompt: "p", keys: [anthropic, openai, gemini])
        XCTAssertEqual(outcome.workout, "# Pull Day\n## Row\n- 95 x 8")
        XCTAssertEqual(outcome.keyId, "o")
        XCTAssertEqual(outcome.statusUpdates, ["o": .verified], "unverified key that worked is promoted")
        XCTAssertEqual(AIStubURLProtocol.requests.compactMap(\.url?.host), [anthropicHost, openAIHost],
                       "stops at first success; gemini never called")
    }

    func testFirstSuccessWinsWithoutStatusChangeForVerifiedKey() async {
        AIStubURLProtocol.set([geminiHost: .http(200, Fix.geminiGenerateContent)])
        let outcome = await service.generateWorkout(prompt: "p", keys: [gemini, openai])
        XCTAssertEqual(outcome.keyId, "g")
        XCTAssertEqual(outcome.statusUpdates, [:])
    }

    func testSkipsInvalidKeys() async {
        var rejected = anthropic
        rejected.status = .invalid
        AIStubURLProtocol.set([geminiHost: .http(200, Fix.geminiGenerateContent)])
        let outcome = await service.generateWorkout(prompt: "p", keys: [rejected, gemini])
        XCTAssertEqual(outcome.keyId, "g")
        XCTAssertEqual(AIStubURLProtocol.requests.compactMap(\.url?.host), [geminiHost])
    }

    func testRejectedKeyReportedInvalidAndNextUsed() async {
        AIStubURLProtocol.set([
            anthropicHost: .http(401, Fix.anthropicInvalidKey),
            "ollama.test/api/chat": .http(200, Fix.ollamaChat),
        ])
        let outcome = await service.generateWorkout(prompt: "p", keys: [anthropic, ollama])
        XCTAssertEqual(outcome.keyId, "l")
        XCTAssertEqual(outcome.statusUpdates, ["a": .invalid, "l": .verified])
    }

    func testSingleFailurePassesThroughUnchanged() async {
        AIStubURLProtocol.set([openAIHost: .http(429, "{}")])
        let outcome = await service.generateWorkout(prompt: "p", keys: [openai])
        XCTAssertNil(outcome.workout)
        XCTAssertEqual(outcome.error?.kind, .rateLimit)
        XCTAssertEqual(outcome.error?.message, "OpenAI rate limit exceeded. Please try again in a moment.")
    }

    func testAllFailuresAggregated() async {
        AIStubURLProtocol.set([
            geminiHost: .http(400, Fix.geminiInvalidKey),
            "ollama.test/api/chat": .http(404, Fix.ollamaModelNotFound),
        ])
        let outcome = await service.generateWorkout(prompt: "p", keys: [gemini, ollama])
        XCTAssertNil(outcome.workout)
        XCTAssertEqual(outcome.error?.kind, .allProvidersFailed)
        XCTAssertEqual(outcome.error?.message,
                       "Gemini: Invalid Gemini API key. Check it in Settings.\nOllama: model 'nope' not found")
        XCTAssertEqual(outcome.statusUpdates, ["g": .invalid])
    }

    func testNoUsableKeys() async {
        var rejected = openai
        rejected.status = .invalid
        AIStubURLProtocol.set([:])
        for keys in [[], [rejected]] {
            let outcome = await service.generateWorkout(prompt: "p", keys: keys)
            XCTAssertEqual(outcome.error?.kind, .missingApiKey)
        }
        XCTAssertTrue(AIStubURLProtocol.requests.isEmpty)
    }
}
