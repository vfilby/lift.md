import Foundation

// MARK: - Results

struct GenerateWorkoutResult: Sendable {
    let workout: String?
    let error: AIProviderError?

    var success: Bool { workout != nil }

    static func failure(_ error: AIProviderError) -> GenerateWorkoutResult {
        GenerateWorkoutResult(workout: nil, error: error)
    }
}

/// Result of an ordered multi-key generation, plus any key status changes the caller should persist.
struct AIGenerationOutcome: Sendable {
    let workout: String?
    let error: AIProviderError?
    /// The key that produced `workout`.
    let keyId: String?
    /// Keys rejected with an auth error → `.invalid`; unverified keys that succeeded → `.verified`.
    let statusUpdates: [String: AIKeyStatus]
}

struct AIKeyVerification: Equatable, Sendable {
    let status: AIKeyStatus
    /// Model ids from the provider's list-models endpoint (empty unless verified).
    let models: [String]
    let message: String?
}

// MARK: - AIProviderService

/// Talks to BYOK LLM providers. Verification uses each provider's free
/// list-models endpoint so entering a key never spends tokens.
/// See spec/services/ai-providers.md.
final class AIProviderService: Sendable {
    static let shared = AIProviderService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Generate (single key)

    func generateWorkout(prompt: String, key: AIProviderKey) async -> GenerateWorkoutResult {
        let name = key.provider.displayName
        if key.provider.requiresApiKey && key.apiKey.isEmpty {
            return .failure(AIProviderError(
                message: "API key is required. Add your \(name) key in Settings.", kind: .missingApiKey
            ))
        }
        guard let request = AIProviderAPI.generateRequest(for: key, prompt: prompt) else {
            return .failure(AIProviderError(message: "Invalid \(name) server URL.", kind: .internalError))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Logger.shared.error(.network, "Failed to generate workout via \(name)", error: error)
            return .failure(AIProviderAPI.networkError(for: key))
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(AIProviderAPI.networkError(for: key))
        }
        guard http.statusCode == 200 else {
            return .failure(AIProviderAPI.error(status: http.statusCode, data: data, key: key))
        }
        guard let text = AIProviderAPI.parseGeneratedText(data, provider: key.provider) else {
            return .failure(AIProviderError(
                message: "No workout generated. Please try again.", kind: .emptyResponse, status: 200
            ))
        }
        return GenerateWorkoutResult(workout: text, error: nil)
    }

    // MARK: - Generate (ordered fallback)

    /// Try non-invalid keys in list order; the first success wins.
    func generateWorkout(prompt: String, keys: [AIProviderKey]) async -> AIGenerationOutcome {
        let usable = keys.filter { $0.status != .invalid }
        guard !usable.isEmpty else {
            let error = AIProviderError(
                message: "No working AI provider key. Add one in Settings.", kind: .missingApiKey
            )
            return AIGenerationOutcome(workout: nil, error: error, keyId: nil, statusUpdates: [:])
        }

        var failures: [(provider: AIProvider, error: AIProviderError)] = []
        var statusUpdates: [String: AIKeyStatus] = [:]

        for key in usable {
            let result = await generateWorkout(prompt: prompt, key: key)
            if let workout = result.workout {
                if key.status != .verified { statusUpdates[key.id] = .verified }
                return AIGenerationOutcome(workout: workout, error: nil, keyId: key.id, statusUpdates: statusUpdates)
            }
            let error = result.error ?? AIProviderError(message: "Generation failed", kind: .internalError)
            if error.kind == .invalidApiKey { statusUpdates[key.id] = .invalid }
            failures.append((key.provider, error))
        }

        return AIGenerationOutcome(
            workout: nil, error: Self.combine(failures), keyId: nil, statusUpdates: statusUpdates
        )
    }

    private static func combine(_ failures: [(provider: AIProvider, error: AIProviderError)]) -> AIProviderError {
        if failures.count == 1, let only = failures.first { return only.error }
        let lines = failures.map { "\($0.provider.displayName): \($0.error.message)" }
        return AIProviderError(message: lines.joined(separator: "\n"), kind: .allProvidersFailed)
    }

    // MARK: - Verify

    /// Verify a credential via the provider's free list-models endpoint (no tokens spent).
    func verify(_ key: AIProviderKey) async -> AIKeyVerification {
        let name = key.provider.displayName
        if key.provider.requiresApiKey && key.apiKey.isEmpty {
            return AIKeyVerification(status: .invalid, models: [], message: "API key is required.")
        }
        guard let request = AIProviderAPI.verifyRequest(for: key) else {
            return AIKeyVerification(status: .invalid, models: [], message: "Invalid server URL.")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Logger.shared.info(.network, "Could not verify \(name) key: \(error.localizedDescription)")
            return AIKeyVerification(
                status: .unverified, models: [],
                message: AIProviderAPI.networkError(for: key).message + " It will be verified on first use."
            )
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 {
            let models = AIProviderAPI.parseModelIds(data, provider: key.provider) ?? []
            return AIKeyVerification(status: .verified, models: models, message: nil)
        }
        if AIProviderAPI.isInvalidCredential(status: status, data: data, provider: key.provider) {
            let detail = AIProviderAPI.providerMessage(from: data).map { " \($0)" } ?? ""
            return AIKeyVerification(status: .invalid, models: [], message: "\(name) rejected this key.\(detail)")
        }
        return AIKeyVerification(
            status: .unverified, models: [],
            message: "Couldn't verify with \(name) (HTTP \(status)). It will be verified on first use."
        )
    }
}
