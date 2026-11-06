import Foundation

// MARK: - AIProvider

/// A bring-your-own-key LLM provider. See spec/services/ai-providers.md.
enum AIProvider: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openai
    case gemini
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .ollama: return "Ollama"
        }
    }

    /// Longer label for the provider picker.
    var pickerLabel: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI (ChatGPT)"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (self-hosted)"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-haiku-4-5-20251001"
        case .openai: return "gpt-5-mini"
        case .gemini: return "gemini-2.5-flash"
        case .ollama: return "llama3.2"
        }
    }

    /// Ollama is self-hosted and needs no key; the others reject requests without one.
    var requiresApiKey: Bool { self != .ollama }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .gemini: return "AIza…"
        case .ollama: return "Token (optional)"
        }
    }

    static let defaultOllamaBaseURL = "http://localhost:11434"

    // MARK: - Format Validation

    private var keyPattern: String? {
        switch self {
        case .anthropic: return #"^sk-ant-[a-zA-Z0-9_-]{95,}$"#
        case .openai: return #"^sk-[A-Za-z0-9_-]{20,}$"#
        case .gemini: return #"^AIza[0-9A-Za-z_-]{35}$"#
        case .ollama: return nil
        }
    }

    /// Offline format check. Input is trimmed first. Ollama accepts any (or no) token.
    func isValidKeyFormat(_ apiKey: String) -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyPattern else { return true }
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: keyPattern, options: .regularExpression) != nil
    }

    var keyFormatHint: String {
        switch self {
        case .anthropic: return "Anthropic API keys start with \"sk-ant-\"."
        case .openai: return "OpenAI API keys start with \"sk-\"."
        case .gemini: return "Gemini API keys start with \"AIza\" and are 39 characters long."
        case .ollama: return "Enter the Ollama server URL, e.g. http://192.168.1.10:11434."
        }
    }

    /// True when `baseURL` is an http(s) URL with a host. Only meaningful for Ollama.
    static func isValidBaseURL(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return false
        }
        return true
    }
}

// MARK: - AIKeyStatus

enum AIKeyStatus: String, Codable, Hashable, CaseIterable, Sendable {
    /// Provider accepted the credential (verification call or a successful generation).
    case verified
    /// Format is valid but the free verification call couldn't complete; checked on first use.
    case unverified
    /// Provider rejected the credential. Skipped during generation.
    case invalid
}

// MARK: - AIProviderKey

/// One entry in the user's ordered BYOK list. Stored (with secrets) only in the Keychain.
struct AIProviderKey: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var provider: AIProvider
    var apiKey: String
    var model: String
    var baseURL: String?
    var status: AIKeyStatus

    init(
        id: String = UUID().uuidString,
        provider: AIProvider,
        apiKey: String = "",
        model: String = "",
        baseURL: String? = nil,
        status: AIKeyStatus = .unverified
    ) {
        self.id = id
        self.provider = provider
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.status = status
    }

    /// The configured model, or the provider default when blank.
    var effectiveModel: String {
        model.isEmpty ? provider.defaultModel : model
    }

    /// Ollama server root without a trailing slash; nil for hosted providers.
    var effectiveBaseURL: String? {
        guard provider == .ollama else { return nil }
        var base = baseURL.flatMap { $0.isEmpty ? nil : $0 } ?? AIProvider.defaultOllamaBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// `••••` plus the last four characters, or the server URL for Ollama.
    var maskedHint: String {
        if provider == .ollama { return effectiveBaseURL ?? "" }
        guard apiKey.count > 4 else { return "••••" }
        return "••••" + apiKey.suffix(4)
    }
}

// MARK: - Draft Validation

extension AIProviderKey {
    /// Offline check run before any network call; nil when the draft can be verified.
    var formatError: String? {
        if provider == .ollama {
            return AIProvider.isValidBaseURL(effectiveBaseURL ?? "") ? nil : provider.keyFormatHint
        }
        return provider.isValidKeyFormat(apiKey) ? nil : provider.keyFormatHint
    }

    /// Ollama's model list is authoritative (it's the user's own server), so a model that
    /// isn't pulled there is caught at save time. Call only with a *verified* model list. Hosted providers accept aliases that
    /// their list endpoints omit, so they're not checked.
    func modelAvailabilityError(installed models: [String]) -> String? {
        guard provider == .ollama else { return nil }
        let model = effectiveModel
        if models.isEmpty {
            return "No models are installed on this Ollama server. Run \"ollama pull \(model)\" first."
        }
        guard !models.contains(model), !models.contains("\(model):latest") else { return nil }
        return "Model \"\(model)\" isn't installed on this Ollama server. Pick one from the list."
    }
}
