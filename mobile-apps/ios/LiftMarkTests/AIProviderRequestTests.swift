import XCTest
@testable import LiftMark

/// Request shape per provider — spec/services/ai-providers.md "Generation" / "Free verification call".
final class AIProviderRequestTests: XCTestCase {

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func userMessage(_ body: [String: Any]) -> [String: String]? {
        (body["messages"] as? [[String: String]])?.first
    }

    // MARK: - Generate

    func testAnthropicGenerateRequest() throws {
        let key = AIProviderKey(provider: .anthropic, apiKey: "sk-ant-key")
        let request = AIProviderAPI.generateRequest(for: key, prompt: "Plan legs")
        XCTAssertEqual(request?.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-key")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request?.timeoutInterval, AIProviderAPI.generateTimeout)

        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5-20251001")
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertEqual(userMessage(json), ["role": "user", "content": "Plan legs"])
    }

    func testOpenAIGenerateRequest() throws {
        let key = AIProviderKey(provider: .openai, apiKey: "sk-proj-key", model: "gpt-4.1")
        let request = AIProviderAPI.generateRequest(for: key, prompt: "Plan pull")
        XCTAssertEqual(request?.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-proj-key")

        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "gpt-4.1")
        XCTAssertEqual(json["max_completion_tokens"] as? Int, 16000)
        XCTAssertNil(json["max_tokens"], "reasoning models reject max_tokens")
        XCTAssertEqual(userMessage(json), ["role": "user", "content": "Plan pull"])
    }

    func testGeminiGenerateRequest() throws {
        let key = AIProviderKey(provider: .gemini, apiKey: "AIzaKey")
        let request = AIProviderAPI.generateRequest(for: key, prompt: "Plan push")
        XCTAssertEqual(
            request?.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        )
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-goog-api-key"), "AIzaKey")
        XCTAssertNil(request?.url?.query, "key goes in a header, never the URL")

        let json = try body(request)
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["role"] as? String, "user")
        XCTAssertEqual((contents.first?["parts"] as? [[String: String]])?.first?["text"], "Plan push")
        XCTAssertEqual((json["generationConfig"] as? [String: Int])?["maxOutputTokens"], 16000)
    }

    func testGeminiModelPathEncoding() {
        XCTAssertEqual(AIProviderAPI.geminiModelPathComponent("models/gemini-2.5-pro"), "gemini-2.5-pro")
        XCTAssertEqual(AIProviderAPI.geminiModelPathComponent("weird/model name"), "weird%2Fmodel%20name")
    }

    func testOllamaGenerateRequest() throws {
        let key = AIProviderKey(provider: .ollama, model: "qwen2.5:0.5b", baseURL: "http://nas.local:11434/")
        let request = AIProviderAPI.generateRequest(for: key, prompt: "Plan core")
        XCTAssertEqual(request?.url?.absoluteString, "http://nas.local:11434/api/chat")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"), "no token → no auth header")

        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "qwen2.5:0.5b")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(userMessage(json), ["role": "user", "content": "Plan core"])
    }

    func testOllamaSendsBearerWhenTokenSet() {
        let key = AIProviderKey(provider: .ollama, apiKey: "proxy-token")
        let request = AIProviderAPI.generateRequest(for: key, prompt: "x")
        XCTAssertEqual(request?.url?.absoluteString, "http://localhost:11434/api/chat")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer proxy-token")
    }

    func testOllamaInvalidBaseURLYieldsNoRequest() {
        let key = AIProviderKey(provider: .ollama, baseURL: "not a url")
        XCTAssertNil(AIProviderAPI.generateRequest(for: key, prompt: "x"))
        XCTAssertNil(AIProviderAPI.verifyRequest(for: key))
    }

    func testBlankModelUsesProviderDefault() throws {
        for provider in [AIProvider.anthropic, .openai, .ollama] {
            let json = try body(AIProviderAPI.generateRequest(for: AIProviderKey(provider: provider, apiKey: "k"),
                                                              prompt: "x"))
            XCTAssertEqual(json["model"] as? String, provider.defaultModel, "\(provider)")
        }
    }

    // MARK: - Verify (free list-models)

    func testVerifyRequests() {
        let cases: [(AIProviderKey, String)] = [
            (AIProviderKey(provider: .anthropic, apiKey: "a"), "https://api.anthropic.com/v1/models?limit=100"),
            (AIProviderKey(provider: .openai, apiKey: "o"), "https://api.openai.com/v1/models"),
            (AIProviderKey(provider: .gemini, apiKey: "g"),
             "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"),
            (AIProviderKey(provider: .ollama, baseURL: "http://10.0.0.5:11434"), "http://10.0.0.5:11434/api/tags"),
        ]
        for (key, url) in cases {
            let request = AIProviderAPI.verifyRequest(for: key)
            XCTAssertEqual(request?.url?.absoluteString, url)
            XCTAssertEqual(request?.httpMethod, "GET", "verification must never POST a generation")
            XCTAssertNil(request?.httpBody)
            XCTAssertEqual(request?.timeoutInterval, AIProviderAPI.verifyTimeout)
        }
    }

    func testVerifyRequestAuthHeaders() {
        let anthropic = AIProviderAPI.verifyRequest(for: AIProviderKey(provider: .anthropic, apiKey: "a"))
        XCTAssertEqual(anthropic?.value(forHTTPHeaderField: "x-api-key"), "a")
        XCTAssertEqual(anthropic?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let openai = AIProviderAPI.verifyRequest(for: AIProviderKey(provider: .openai, apiKey: "o"))
        XCTAssertEqual(openai?.value(forHTTPHeaderField: "Authorization"), "Bearer o")
        let gemini = AIProviderAPI.verifyRequest(for: AIProviderKey(provider: .gemini, apiKey: "g"))
        XCTAssertEqual(gemini?.value(forHTTPHeaderField: "x-goog-api-key"), "g")
    }
}
