import XCTest
@testable import LiftMark

/// Offline format rules and `AIProviderKey` helpers — spec/services/ai-providers.md.
final class AIProviderTests: XCTestCase {

    static let validAnthropic = "sk-ant-" + String(repeating: "a", count: 95)
    static let validOpenAI = "sk-proj-" + String(repeating: "A1_-", count: 10)
    static let validGemini = "AIza" + String(repeating: "B", count: 35)

    // MARK: - Anthropic format

    func testAnthropicAcceptsValidKey() {
        XCTAssertTrue(AIProvider.anthropic.isValidKeyFormat(Self.validAnthropic))
        XCTAssertTrue(AIProvider.anthropic.isValidKeyFormat("sk-ant-" + String(repeating: "aB1_-", count: 20)))
    }

    func testAnthropicLengthBoundary() {
        XCTAssertTrue(AIProvider.anthropic.isValidKeyFormat("sk-ant-" + String(repeating: "x", count: 95)))
        XCTAssertFalse(AIProvider.anthropic.isValidKeyFormat("sk-ant-" + String(repeating: "x", count: 94)))
        XCTAssertFalse(AIProvider.anthropic.isValidKeyFormat("sk-ant-"))
    }

    func testAnthropicRejectsWrongPrefixAndCase() {
        XCTAssertFalse(AIProvider.anthropic.isValidKeyFormat("sk-wrong-" + String(repeating: "a", count: 95)))
        XCTAssertFalse(AIProvider.anthropic.isValidKeyFormat("SK-ANT-" + String(repeating: "a", count: 95)))
    }

    func testAnthropicRejectsSpecialCharsAndInternalWhitespace() {
        XCTAssertFalse(AIProvider.anthropic.isValidKeyFormat("sk-ant-" + String(repeating: "a", count: 90) + "!@#$%"))
        let spaced = "sk-ant-" + String(repeating: "a", count: 47) + " " + String(repeating: "a", count: 47)
        XCTAssertFalse(AIProvider.anthropic.isValidKeyFormat(spaced))
    }

    func testAllKeyedProvidersTrimSurroundingWhitespace() {
        XCTAssertTrue(AIProvider.anthropic.isValidKeyFormat("\n\t " + Self.validAnthropic + " \n"))
        XCTAssertTrue(AIProvider.openai.isValidKeyFormat("  " + Self.validOpenAI + "\n"))
        XCTAssertTrue(AIProvider.gemini.isValidKeyFormat("\t" + Self.validGemini + " "))
    }

    func testKeyedProvidersRejectEmptyAndWhitespace() {
        for provider in AIProvider.allCases where provider.requiresApiKey {
            XCTAssertFalse(provider.isValidKeyFormat(""), "\(provider)")
            XCTAssertFalse(provider.isValidKeyFormat("   "), "\(provider)")
            XCTAssertFalse(provider.isValidKeyFormat("not-an-api-key"), "\(provider)")
        }
    }

    // MARK: - OpenAI format

    func testOpenAIAcceptsProjectServiceAccountAndLegacyKeys() {
        XCTAssertTrue(AIProvider.openai.isValidKeyFormat(Self.validOpenAI))
        XCTAssertTrue(AIProvider.openai.isValidKeyFormat("sk-svcacct-" + String(repeating: "z", count: 40)))
        XCTAssertTrue(AIProvider.openai.isValidKeyFormat("sk-" + String(repeating: "Q", count: 48)))
    }

    func testOpenAIRejectsShortOrMisprefixed() {
        XCTAssertFalse(AIProvider.openai.isValidKeyFormat("sk-short"))
        XCTAssertFalse(AIProvider.openai.isValidKeyFormat("pk-" + String(repeating: "a", count: 40)))
        XCTAssertFalse(AIProvider.openai.isValidKeyFormat("sk-" + String(repeating: "a", count: 20) + " x"))
    }

    // MARK: - Gemini format

    func testGeminiRequiresExactly39Chars() {
        XCTAssertTrue(AIProvider.gemini.isValidKeyFormat(Self.validGemini))
        XCTAssertFalse(AIProvider.gemini.isValidKeyFormat("AIza" + String(repeating: "B", count: 34)))
        XCTAssertFalse(AIProvider.gemini.isValidKeyFormat("AIza" + String(repeating: "B", count: 36)))
    }

    func testGeminiRejectsWrongPrefix() {
        XCTAssertFalse(AIProvider.gemini.isValidKeyFormat("AIzb" + String(repeating: "B", count: 35)))
        XCTAssertFalse(AIProvider.gemini.isValidKeyFormat(Self.validAnthropic))
    }

    // MARK: - Ollama

    func testOllamaNeedsNoKey() {
        XCTAssertFalse(AIProvider.ollama.requiresApiKey)
        XCTAssertTrue(AIProvider.ollama.isValidKeyFormat(""))
        XCTAssertTrue(AIProvider.ollama.isValidKeyFormat("any-token"))
    }

    func testBaseURLValidation() {
        XCTAssertTrue(AIProvider.isValidBaseURL("http://localhost:11434"))
        XCTAssertTrue(AIProvider.isValidBaseURL("http://192.168.1.10:11434/"))
        XCTAssertTrue(AIProvider.isValidBaseURL(" https://ollama.example.com "))
        XCTAssertFalse(AIProvider.isValidBaseURL(""))
        XCTAssertFalse(AIProvider.isValidBaseURL("localhost:11434"))
        XCTAssertFalse(AIProvider.isValidBaseURL("ftp://host"))
        XCTAssertFalse(AIProvider.isValidBaseURL("http://"))
    }

    // MARK: - Metadata

    func testEveryProviderHasDisplayMetadata() {
        for provider in AIProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty)
            XCTAssertFalse(provider.pickerLabel.isEmpty)
            XCTAssertFalse(provider.defaultModel.isEmpty)
            XCTAssertFalse(provider.keyPlaceholder.isEmpty)
            XCTAssertFalse(provider.keyFormatHint.isEmpty)
        }
    }

    func testDefaultModels() {
        XCTAssertEqual(AIProvider.anthropic.defaultModel, "claude-haiku-4-5-20251001")
        XCTAssertEqual(AIProvider.openai.defaultModel, "gpt-5-mini")
        XCTAssertEqual(AIProvider.gemini.defaultModel, "gemini-2.5-flash")
        XCTAssertEqual(AIProvider.ollama.defaultModel, "llama3.2")
    }

    // MARK: - AIProviderKey helpers

    func testInitTrimsInputs() {
        let key = AIProviderKey(provider: .openai, apiKey: "  sk-abc \n", model: " gpt-4.1 ", baseURL: " x ")
        XCTAssertEqual(key.apiKey, "sk-abc")
        XCTAssertEqual(key.model, "gpt-4.1")
        XCTAssertEqual(key.baseURL, "x")
        XCTAssertEqual(key.status, .unverified)
    }

    func testEffectiveModelFallsBackToDefault() {
        XCTAssertEqual(AIProviderKey(provider: .gemini).effectiveModel, "gemini-2.5-flash")
        XCTAssertEqual(AIProviderKey(provider: .gemini, model: "gemini-2.5-pro").effectiveModel, "gemini-2.5-pro")
    }

    func testEffectiveBaseURL() {
        XCTAssertNil(AIProviderKey(provider: .openai, baseURL: "http://x").effectiveBaseURL)
        XCTAssertEqual(AIProviderKey(provider: .ollama).effectiveBaseURL, "http://localhost:11434")
        XCTAssertEqual(AIProviderKey(provider: .ollama, baseURL: "").effectiveBaseURL, "http://localhost:11434")
        XCTAssertEqual(AIProviderKey(provider: .ollama, baseURL: "http://10.0.0.2:11434//").effectiveBaseURL,
                       "http://10.0.0.2:11434")
    }

    func testMaskedHint() {
        XCTAssertEqual(AIProviderKey(provider: .openai, apiKey: Self.validOpenAI).maskedHint,
                       "••••" + Self.validOpenAI.suffix(4))
        XCTAssertEqual(AIProviderKey(provider: .openai, apiKey: "abc").maskedHint, "••••")
        XCTAssertEqual(AIProviderKey(provider: .ollama, baseURL: "http://nas.local:11434").maskedHint,
                       "http://nas.local:11434")
    }

    func testFormatError() {
        XCTAssertNil(AIProviderKey(provider: .anthropic, apiKey: Self.validAnthropic).formatError)
        XCTAssertEqual(AIProviderKey(provider: .anthropic, apiKey: "sk-nope").formatError,
                       AIProvider.anthropic.keyFormatHint)
        XCTAssertEqual(AIProviderKey(provider: .gemini, apiKey: Self.validOpenAI).formatError,
                       AIProvider.gemini.keyFormatHint)
        XCTAssertNil(AIProviderKey(provider: .ollama).formatError)
        XCTAssertEqual(AIProviderKey(provider: .ollama, baseURL: "nas:11434").formatError,
                       AIProvider.ollama.keyFormatHint)
    }

    func testModelAvailabilityErrorOnlyForOllama() {
        let installed = ["llama3.2:latest", "qwen2.5:0.5b"]
        XCTAssertNil(AIProviderKey(provider: .ollama).modelAvailabilityError(installed: installed),
                     "blank model → llama3.2 matches llama3.2:latest")
        XCTAssertNil(AIProviderKey(provider: .ollama, model: "qwen2.5:0.5b")
            .modelAvailabilityError(installed: installed))
        XCTAssertNotNil(AIProviderKey(provider: .ollama, model: "mistral").modelAvailabilityError(installed: installed))
        XCTAssertEqual(AIProviderKey(provider: .ollama).modelAvailabilityError(installed: []),
                       "No models are installed on this Ollama server. Run \"ollama pull llama3.2\" first.")
        XCTAssertNil(AIProviderKey(provider: .anthropic, model: "claude-haiku-4-5")
            .modelAvailabilityError(installed: ["claude-haiku-4-5-20251001"]),
                     "hosted providers accept aliases their list omits")
    }

    func testCodableRoundTrip() throws {
        let keys = [
            AIProviderKey(provider: .anthropic, apiKey: Self.validAnthropic, status: .verified),
            AIProviderKey(provider: .ollama, model: "qwen2.5:0.5b", baseURL: "http://nas.local:11434",
                          status: .invalid),
        ]
        let decoded = try JSONDecoder().decode([AIProviderKey].self, from: JSONEncoder().encode(keys))
        XCTAssertEqual(decoded, keys)
    }
}
