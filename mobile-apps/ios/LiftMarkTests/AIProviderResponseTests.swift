import XCTest
@testable import LiftMark

/// Contract tests against recorded/documented provider payloads (Fixtures/AIProviderFixtures.swift).
final class AIProviderResponseTests: XCTestCase {
    private typealias Fix = AIProviderFixtures

    // MARK: - Generated text

    func testAnthropicConcatenatesTextBlocks() {
        XCTAssertEqual(AIProviderAPI.parseGeneratedText(Fix.data(Fix.anthropicMessage), provider: .anthropic),
                       "# Push Day\n## Bench Press\n- 135 x 5")
    }

    func testOpenAIReadsFirstChoice() {
        XCTAssertEqual(AIProviderAPI.parseGeneratedText(Fix.data(Fix.openAIChatCompletion), provider: .openai),
                       "# Pull Day\n## Row\n- 95 x 8")
    }

    func testGeminiSkipsThoughtParts() {
        XCTAssertEqual(AIProviderAPI.parseGeneratedText(Fix.data(Fix.geminiGenerateContent), provider: .gemini),
                       "# Leg Day\n## Squat\n- 225 x 5")
    }

    func testGeminiThoughtOnlyIsEmpty() {
        XCTAssertNil(AIProviderAPI.parseGeneratedText(Fix.data(Fix.geminiNoText), provider: .gemini))
    }

    func testOllamaReadsMessageContent() {
        XCTAssertEqual(AIProviderAPI.parseGeneratedText(Fix.data(Fix.ollamaChat), provider: .ollama), "# Push Day")
    }

    func testWrongShapeOrGarbageIsNil() {
        for provider in AIProvider.allCases {
            XCTAssertNil(AIProviderAPI.parseGeneratedText(Data("not json".utf8), provider: provider))
            XCTAssertNil(AIProviderAPI.parseGeneratedText(Data("{}".utf8), provider: provider))
        }
        XCTAssertNil(AIProviderAPI.parseGeneratedText(Fix.data(Fix.ollamaChat), provider: .openai))
    }

    // MARK: - Model lists

    func testAnthropicModels() {
        XCTAssertEqual(AIProviderAPI.parseModelIds(Fix.data(Fix.anthropicModels), provider: .anthropic),
                       ["claude-haiku-4-5-20251001", "claude-sonnet-4-5-20250929"])
    }

    func testOpenAIModelsFilteredToChat() {
        XCTAssertEqual(AIProviderAPI.parseModelIds(Fix.data(Fix.openAIModels), provider: .openai),
                       ["chatgpt-4o-latest", "gpt-4.1", "gpt-5-mini", "o4-mini"])
    }

    func testGeminiModelsFilteredToGenerateContent() {
        XCTAssertEqual(AIProviderAPI.parseModelIds(Fix.data(Fix.geminiModels), provider: .gemini),
                       ["gemini-2.5-flash", "gemini-2.5-pro"])
    }

    func testOllamaModels() {
        XCTAssertEqual(AIProviderAPI.parseModelIds(Fix.data(Fix.ollamaTags), provider: .ollama),
                       ["llama3.2:latest", "qwen2.5:0.5b"])
    }

    func testModelListWrongShapeIsNil() {
        XCTAssertNil(AIProviderAPI.parseModelIds(Fix.data(Fix.anthropicInvalidKey), provider: .anthropic))
        XCTAssertNil(AIProviderAPI.parseModelIds(Data("[]".utf8), provider: .ollama))
    }

    // MARK: - Errors

    func testProviderMessageShapes() {
        XCTAssertEqual(AIProviderAPI.providerMessage(from: Fix.data(Fix.anthropicInvalidKey)), "invalid x-api-key")
        XCTAssertEqual(AIProviderAPI.providerMessage(from: Fix.data(Fix.geminiInvalidKey)),
                       "API key not valid. Please pass a valid API key.")
        XCTAssertEqual(AIProviderAPI.providerMessage(from: Fix.data(Fix.ollamaModelNotFound)), "model 'nope' not found")
        XCTAssertNil(AIProviderAPI.providerMessage(from: Data("<html>".utf8)))
    }

    func testInvalidCredentialDetection() {
        XCTAssertTrue(AIProviderAPI.isInvalidCredential(status: 401, data: Fix.data(Fix.anthropicInvalidKey),
                                                        provider: .anthropic))
        XCTAssertTrue(AIProviderAPI.isInvalidCredential(status: 401, data: Fix.data(Fix.openAIInvalidKey),
                                                        provider: .openai))
        XCTAssertFalse(AIProviderAPI.isInvalidCredential(status: 403, data: Data(), provider: .anthropic),
                       "403 (region / permission) doesn't condemn the key")
        XCTAssertTrue(AIProviderAPI.isInvalidCredential(status: 400, data: Fix.data(Fix.geminiInvalidKey),
                                                        provider: .gemini))
        XCTAssertFalse(AIProviderAPI.isInvalidCredential(status: 400, data: Fix.data(Fix.geminiBadRequest),
                                                         provider: .gemini))
        XCTAssertFalse(AIProviderAPI.isInvalidCredential(status: 400, data: Fix.data(Fix.geminiInvalidKey),
                                                         provider: .openai), "API_KEY_INVALID is Gemini-only")
    }

    func testErrorMapping() {
        let openai = AIProviderKey(provider: .openai, apiKey: "k", model: "gpt-nope")
        XCTAssertEqual(AIProviderAPI.error(status: 401, data: Fix.data(Fix.openAIInvalidKey), key: openai).kind,
                       .invalidApiKey)
        let notFound = AIProviderAPI.error(status: 404, data: Fix.data(Fix.openAIModelNotFound), key: openai)
        XCTAssertEqual(notFound.kind, .modelNotFound)
        XCTAssertTrue(notFound.message.contains("gpt-nope"))
        XCTAssertEqual(AIProviderAPI.error(status: 429, data: Data(), key: openai).message,
                       "OpenAI rate limit exceeded. Please try again in a moment.")
        let quota = AIProviderAPI.error(status: 429, data: Fix.data(Fix.openAIInsufficientQuota), key: openai)
        XCTAssertEqual(quota.kind, .rateLimit)
        XCTAssertEqual(quota.message, "You exceeded your current quota, please check your plan and billing details.")
        let forbidden = AIProviderAPI.error(status: 403, data: Fix.data(Fix.openAIUnsupportedRegion), key: openai)
        XCTAssertEqual(forbidden.kind, .permissionDenied)
        XCTAssertEqual(forbidden.message, "Country, region, or territory not supported")
        XCTAssertEqual(AIProviderAPI.error(status: 403, data: Data(), key: openai).message,
                       "OpenAI denied access for this key.")
        XCTAssertEqual(AIProviderAPI.error(status: 529, data: Fix.data(Fix.anthropicOverloaded), key: openai).kind,
                       .serverError)

        let gemini = AIProviderKey(provider: .gemini, apiKey: "k")
        let invalid = AIProviderAPI.error(status: 400, data: Fix.data(Fix.geminiInvalidKey), key: gemini)
        XCTAssertEqual(invalid.kind, .invalidApiKey)
        XCTAssertEqual(invalid.message, "Invalid Gemini API key. Check it in Settings.")
        let bad = AIProviderAPI.error(status: 400, data: Fix.data(Fix.geminiBadRequest), key: gemini)
        XCTAssertEqual(bad.kind, .badRequest)
        XCTAssertEqual(bad.message, "Invalid JSON payload received.")

        let ollama = AIProviderKey(provider: .ollama, model: "nope")
        let missing = AIProviderAPI.error(status: 404, data: Fix.data(Fix.ollamaModelNotFound), key: ollama)
        XCTAssertEqual(missing.kind, .modelNotFound)
        XCTAssertEqual(missing.message, "model 'nope' not found")
        XCTAssertEqual(AIProviderAPI.error(status: 404, data: Data(), key: ollama).message,
                       "Model \"nope\" was not found on Ollama.")
    }

    func testNetworkErrorMessages() {
        XCTAssertEqual(AIProviderAPI.networkError(for: AIProviderKey(provider: .gemini, apiKey: "k")).message,
                       "Couldn't reach Gemini. Check your connection.")
        let ollama = AIProviderAPI.networkError(for: AIProviderKey(provider: .ollama, baseURL: "http://nas:11434"))
        XCTAssertEqual(ollama.kind, .networkError)
        XCTAssertTrue(ollama.message.contains("http://nas:11434"))
    }
}
