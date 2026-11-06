import Foundation

// MARK: - Errors

enum AIProviderErrorKind: String, Sendable {
    case missingApiKey = "missing_api_key"
    case invalidApiKey = "invalid_api_key"
    case permissionDenied = "permission_denied"
    case modelNotFound = "model_not_found"
    case rateLimit = "rate_limit"
    case badRequest = "bad_request"
    case serverError = "server_error"
    case emptyResponse = "empty_response"
    case networkError = "network_error"
    case internalError = "internal_error"
    case allProvidersFailed = "all_providers_failed"
}

struct AIProviderError: Error, Equatable, Sendable {
    let message: String
    let kind: AIProviderErrorKind
    var status: Int?
}

// MARK: - AIProviderAPI

/// Pure request builders and response parsers for each BYOK provider. No I/O —
/// `AIProviderService` owns the network. See spec/services/ai-providers.md.
enum AIProviderAPI {
    static let anthropicVersion = "2023-06-01"
    static let anthropicMaxTokens = 4096
    /// OpenAI/Gemini defaults are reasoning models; reasoning tokens count against this.
    static let reasoningMaxTokens = 16000
    static let generateTimeout: TimeInterval = 120
    static let verifyTimeout: TimeInterval = 15

    private static let anthropicBase = "https://api.anthropic.com/v1"
    private static let openAIBase = "https://api.openai.com/v1"
    private static let geminiBase = "https://generativelanguage.googleapis.com/v1beta"

    // MARK: - Generate

    /// Build the single-turn generation request. Nil only for an unparseable Ollama URL.
    static func generateRequest(for key: AIProviderKey, prompt: String) -> URLRequest? {
        let model = key.effectiveModel
        let message: [String: Any] = ["role": "user", "content": prompt]
        let url: URL?
        let body: [String: Any]

        switch key.provider {
        case .anthropic:
            url = URL(string: "\(anthropicBase)/messages")
            body = ["model": model, "max_tokens": anthropicMaxTokens, "messages": [message]]
        case .openai:
            url = URL(string: "\(openAIBase)/chat/completions")
            body = ["model": model, "max_completion_tokens": reasoningMaxTokens, "messages": [message]]
        case .gemini:
            url = URL(string: "\(geminiBase)/models/\(geminiModelPathComponent(model)):generateContent")
            body = [
                "contents": [["role": "user", "parts": [["text": prompt]]]],
                "generationConfig": ["maxOutputTokens": reasoningMaxTokens],
            ]
        case .ollama:
            url = ollamaURL(key, path: "/api/chat")
            body = ["model": model, "stream": false, "messages": [message]]
        }

        guard let url, let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = authorizedRequest(url: url, key: key, timeout: generateTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    // MARK: - Verify

    /// Build the free list-models request used to verify a credential without spending tokens.
    static func verifyRequest(for key: AIProviderKey) -> URLRequest? {
        let url: URL?
        switch key.provider {
        case .anthropic: url = URL(string: "\(anthropicBase)/models?limit=100")
        case .openai: url = URL(string: "\(openAIBase)/models")
        case .gemini: url = URL(string: "\(geminiBase)/models?pageSize=1000")
        case .ollama: url = ollamaURL(key, path: "/api/tags")
        }
        guard let url else { return nil }
        var request = authorizedRequest(url: url, key: key, timeout: verifyTimeout)
        request.httpMethod = "GET"
        return request
    }

    // MARK: - Helpers

    private static func authorizedRequest(url: URL, key: AIProviderKey, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        switch key.provider {
        case .anthropic:
            request.setValue(key.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .openai:
            request.setValue("Bearer \(key.apiKey)", forHTTPHeaderField: "Authorization")
        case .gemini:
            request.setValue(key.apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .ollama:
            if !key.apiKey.isEmpty {
                request.setValue("Bearer \(key.apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    private static func ollamaURL(_ key: AIProviderKey, path: String) -> URL? {
        guard let base = key.effectiveBaseURL, AIProvider.isValidBaseURL(base) else { return nil }
        return URL(string: base + path)
    }

    /// Gemini puts the model in the path; accept a pasted `models/` prefix and escape the rest.
    static func geminiModelPathComponent(_ model: String) -> String {
        let bare = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return bare.addingPercentEncoding(withAllowedCharacters: allowed) ?? bare
    }
}
