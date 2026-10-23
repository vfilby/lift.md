import XCTest
@testable import LiftMark

/// Real provider endpoints. Local only and opt-in: each test is skipped unless its
/// variable is in the test environment (pass with the `TEST_RUNNER_` prefix); CI never
/// sets them. Verification hits only free list-models endpoints, so a real key costs
/// nothing. Ollama is the free end-to-end environment — it also runs a full generation.
/// See spec/services/ai-providers.md ("Live provider tests").
///
///     TEST_RUNNER_LIFTMARK_LIVE_OLLAMA_URL=http://localhost:11434 \
///     TEST_RUNNER_LIFTMARK_LIVE_OLLAMA_MODEL=qwen2.5:0.5b \
///     TEST_RUNNER_LIFTMARK_LIVE_AI_NEGATIVE=1 \
///     xcodebuild test -scheme LiftMark -project LiftMark.xcodeproj -testPlan Full \
///       -only-testing:LiftMarkTests/AIProviderLiveTests \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'
final class AIProviderLiveTests: XCTestCase {
    private let service = AIProviderService(session: .shared)

    private func env(_ name: String) throws -> String {
        let value = ProcessInfo.processInfo.environment[name] ?? ""
        try XCTSkipIf(value.isEmpty, "Set TEST_RUNNER_\(name) to run")
        return value
    }

    // MARK: - Real keys (free list-models)

    func testAnthropicKeyVerifies() async throws {
        try await assertVerifies(AIProviderKey(provider: .anthropic, apiKey: env("LIFTMARK_LIVE_ANTHROPIC_KEY")))
    }

    func testOpenAIKeyVerifies() async throws {
        try await assertVerifies(AIProviderKey(provider: .openai, apiKey: env("LIFTMARK_LIVE_OPENAI_KEY")))
    }

    func testGeminiKeyVerifies() async throws {
        try await assertVerifies(AIProviderKey(provider: .gemini, apiKey: env("LIFTMARK_LIVE_GEMINI_KEY")))
    }

    private func assertVerifies(_ key: AIProviderKey) async {
        XCTAssertNil(key.formatError, "real \(key.provider) key fails the offline format check")
        let result = await service.verify(key)
        XCTAssertEqual(result.status, .verified, result.message ?? "")
        XCTAssertFalse(result.models.isEmpty)
    }

    // MARK: - Bogus keys (no account needed; guards auth-error shape drift)

    func testBogusHostedKeysAreRejected() async throws {
        _ = try env("LIFTMARK_LIVE_AI_NEGATIVE")
        let bogus = [
            AIProviderKey(provider: .anthropic, apiKey: "sk-ant-" + String(repeating: "a", count: 95)),
            AIProviderKey(provider: .openai, apiKey: "sk-proj-" + String(repeating: "b", count: 40)),
            AIProviderKey(provider: .gemini, apiKey: "AIza" + String(repeating: "c", count: 35)),
        ]
        for key in bogus {
            XCTAssertNil(key.formatError, "\(key.provider) bogus key should pass format so the network rejects it")
            let result = await service.verify(key)
            XCTAssertEqual(result.status, .invalid, "\(key.provider): \(result.message ?? "")")

            let generation = await service.generateWorkout(prompt: "x", key: key)
            XCTAssertEqual(generation.error?.kind, .invalidApiKey, "\(key.provider) generation with bogus key")
        }
    }

    // MARK: - Ollama end-to-end

    func testOllamaVerifyAndGenerate() async throws {
        let base = try env("LIFTMARK_LIVE_OLLAMA_URL")
        let model = ProcessInfo.processInfo.environment["LIFTMARK_LIVE_OLLAMA_MODEL"] ?? ""
        let key = AIProviderKey(provider: .ollama, model: model, baseURL: base)

        let verification = await service.verify(key)
        XCTAssertEqual(verification.status, .verified, verification.message ?? "")
        XCTAssertNil(key.modelAvailabilityError(installed: verification.models),
                     "model \(key.effectiveModel) not pulled; installed: \(verification.models)")

        let prompt = "Reply with only this markdown and nothing else:\n# Push Day\n## Bench Press\n- 135 x 5"
        let outcome = await service.generateWorkout(prompt: prompt, keys: [key])
        XCTAssertNil(outcome.error, outcome.error?.message ?? "")
        XCTAssertEqual(outcome.statusUpdates, [key.id: .verified])
        XCTAssertTrue(outcome.workout?.contains("Bench Press") == true, outcome.workout ?? "")
    }

    func testOllamaMissingModelIsModelNotFound() async throws {
        let base = try env("LIFTMARK_LIVE_OLLAMA_URL")
        let key = AIProviderKey(provider: .ollama, model: "liftmark-no-such-model", baseURL: base)
        let result = await service.generateWorkout(prompt: "x", key: key)
        XCTAssertEqual(result.error?.kind, .modelNotFound)
    }
}
