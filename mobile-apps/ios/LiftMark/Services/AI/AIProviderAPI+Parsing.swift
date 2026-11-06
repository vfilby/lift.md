import Foundation

extension AIProviderAPI {

    // MARK: - Generated Text

    /// Extract the generated text from a 200 response. Nil when absent or blank.
    static func parseGeneratedText(_ data: Data, provider: AIProvider) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let text: String?
        switch provider {
        case .anthropic:
            let blocks = json["content"] as? [[String: Any]] ?? []
            text = blocks
                .filter { ($0["type"] as? String ?? "text") == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
        case .openai:
            let choices = json["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            text = message?["content"] as? String
        case .gemini:
            let candidates = json["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            text = parts
                .filter { ($0["thought"] as? Bool) != true }
                .compactMap { $0["text"] as? String }
                .joined()
        case .ollama:
            let message = json["message"] as? [String: Any]
            text = message?["content"] as? String
        }

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: - Model Lists

    /// Extract sorted model ids from a list-models response. Nil when the body isn't the expected shape.
    static func parseModelIds(_ data: Data, provider: AIProvider) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let ids: [String]?
        switch provider {
        case .anthropic:
            ids = (json["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        case .openai:
            ids = (json["data"] as? [[String: Any]])?
                .compactMap { $0["id"] as? String }
                .filter(isOpenAIChatModel)
        case .gemini:
            ids = (json["models"] as? [[String: Any]])?.compactMap { model in
                let methods = model["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent"), let name = model["name"] as? String else { return nil }
                return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            }
        case .ollama:
            ids = (json["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        }
        return ids?.sorted()
    }

    /// `/v1/models` lists embeddings, TTS, image models, etc. Keep only chat-completion models.
    static func isOpenAIChatModel(_ id: String) -> Bool {
        let prefixes = ["gpt-", "chatgpt-", "o1", "o3", "o4"]
        let excluded = ["audio", "realtime", "transcribe", "tts", "image", "search"]
        return prefixes.contains { id.hasPrefix($0) } && !excluded.contains { id.contains($0) }
    }

    // MARK: - Errors

    /// The provider's own error message: `error.message` (Anthropic/OpenAI/Gemini) or a top-level `error` string (Ollama).
    static func providerMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return json["error"] as? String
    }

    /// 401 everywhere; Gemini reports a bad key as 400 with reason `API_KEY_INVALID`.
    /// 403 is deliberately excluded: region blocks and per-model permission errors
    /// return it for keys that are otherwise fine, and an invalid key is skipped for good.
    static func isInvalidCredential(status: Int, data: Data, provider: AIProvider) -> Bool {
        if status == 401 { return true }
        guard provider == .gemini, status == 400 else { return false }
        return String(data: data, encoding: .utf8)?.contains("API_KEY_INVALID") == true
    }

    /// Map a non-200 generation response to a user-facing error naming the provider.
    static func error(status: Int, data: Data, key: AIProviderKey) -> AIProviderError {
        let name = key.provider.displayName
        let message = providerMessage(from: data)

        if isInvalidCredential(status: status, data: data, provider: key.provider) {
            return AIProviderError(
                message: "Invalid \(name) API key. Check it in Settings.", kind: .invalidApiKey, status: status
            )
        }
        switch status {
        case 403:
            return AIProviderError(
                message: message ?? "\(name) denied access for this key.", kind: .permissionDenied, status: status
            )
        case 404:
            return AIProviderError(
                message: message ?? "Model \"\(key.effectiveModel)\" was not found on \(name).",
                kind: .modelNotFound, status: status
            )
        case 429:
            // Prefer the provider's text: OpenAI's 429 also means "out of credits" (insufficient_quota).
            return AIProviderError(
                message: message ?? "\(name) rate limit exceeded. Please try again in a moment.",
                kind: .rateLimit, status: status
            )
        case 400:
            return AIProviderError(
                message: message ?? "Invalid request. Please try again.", kind: .badRequest, status: status
            )
        default:
            return AIProviderError(
                message: "\(name) is currently unavailable. Please try again later.", kind: .serverError, status: status
            )
        }
    }

    static func networkError(for key: AIProviderKey) -> AIProviderError {
        let message: String
        if key.provider == .ollama {
            message = "Couldn't reach Ollama at \(key.effectiveBaseURL ?? AIProvider.defaultOllamaBaseURL). "
                + "Is the server running and reachable from this device?"
        } else {
            message = "Couldn't reach \(key.provider.displayName). Check your connection."
        }
        return AIProviderError(message: message, kind: .networkError)
    }
}
