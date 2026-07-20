import Foundation

// MARK: - Types

struct AnthropicError: Error {
    let message: String
    let type: String?
    let status: Int?
}

struct GenerateWorkoutResult {
    let success: Bool
    let workout: String?
    let error: AnthropicError?
}

struct AnthropicModel {
    let id: String
    let name: String
    let description: String
}

// MARK: - AnthropicService

final class AnthropicService: @unchecked Sendable {
    static let shared = AnthropicService()

    private static let apiURL = "https://api.anthropic.com/v1/messages"
    private static let apiVersion = "2023-06-01"
    private static let defaultModel = "claude-haiku-4-5-20251001"
    private static let maxTokens = 4096

    static let availableModels: [String: AnthropicModel] = [
        "haiku-4.5": AnthropicModel(
            id: "claude-haiku-4-5-20251001",
            name: "Claude Haiku 4.5",
            description: "Fastest & cheapest - $1/$5 per million tokens"
        ),
        "sonnet-4.5": AnthropicModel(
            id: "claude-sonnet-4-5-20250929",
            name: "Claude Sonnet 4.5",
            description: "More capable - $3/$15 per million tokens"
        ),
    ]

    private var apiKey: String?

    private init() {}

    // MARK: - Initialization

    /// Initialize with an API key.
    func initialize(apiKey: String) {
        guard !apiKey.isEmpty else { return }
        self.apiKey = apiKey
    }

    /// Check if the service is initialized.
    var isInitialized: Bool {
        apiKey != nil
    }

    /// Clear the API key and reset.
    func clear() {
        apiKey = nil
    }

    // MARK: - Generate Workout (fetch-based)

    /// Generate a workout using the Anthropic Messages API.
    func generateWorkout(apiKey: String, prompt: String, model: String? = nil) async -> GenerateWorkoutResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return failure(
                "API key is required. Please add your Anthropic API key in Settings.",
                type: "missing_api_key"
            )
        }

        switch buildRequest(key: key, prompt: prompt, model: model ?? Self.defaultModel) {
        case .failure(let error):
            return GenerateWorkoutResult(success: false, workout: nil, error: error)
        case .success(let request):
            return await performRequest(request)
        }
    }

    /// Build the Messages API URLRequest for a workout-generation prompt.
    private func buildRequest(key: String, prompt: String, model: String) -> Result<URLRequest, AnthropicError> {
        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        guard let url = URL(string: Self.apiURL) else {
            return .failure(AnthropicError(message: "Invalid API URL", type: "internal_error", status: nil))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            return .failure(AnthropicError(message: "Failed to encode request", type: "internal_error", status: nil))
        }

        return .success(request)
    }

    /// Execute the request and map the response (or transport error) to a result.
    private func performRequest(_ request: URLRequest) async -> GenerateWorkoutResult {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return failure("Invalid response", type: "network_error")
            }

            guard httpResponse.statusCode == 200 else {
                return errorResult(status: httpResponse.statusCode, data: data)
            }

            // Parse response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let text = firstBlock["text"] as? String else {
                return failure("No workout generated. Please try again.", type: "empty_response")
            }

            return GenerateWorkoutResult(success: true, workout: text, error: nil)

        } catch {
            Logger.shared.error(.network, "Failed to generate workout", error: error)

            return failure("Network error. Please check your connection and try again.", type: "network_error")
        }
    }

    /// Map a non-200 HTTP status (and error payload, when present) to a failure result.
    private func errorResult(status: Int, data: Data) -> GenerateWorkoutResult {
        let errorMessage: String
        let errorType: String

        switch status {
        case 401:
            errorMessage = "Invalid API key. Please check your Anthropic API key in Settings."
            errorType = "invalid_api_key"
        case 429:
            errorMessage = "Rate limit exceeded. Please try again in a moment."
            errorType = "rate_limit"
        case 400:
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = json["error"] as? [String: Any],
               let msg = errorObj["message"] as? String {
                errorMessage = msg
            } else {
                errorMessage = "Invalid request. Please try again."
            }
            errorType = "bad_request"
        default:
            errorMessage = "Anthropic API is currently unavailable. Please try again later."
            errorType = "server_error"
        }

        return failure(errorMessage, type: errorType, status: status)
    }

    private func failure(_ message: String, type: String, status: Int? = nil) -> GenerateWorkoutResult {
        GenerateWorkoutResult(
            success: false, workout: nil,
            error: AnthropicError(message: message, type: type, status: status)
        )
    }

    // MARK: - Verify API Key

    /// Verify an API key by making a minimal API call.
    func verifyApiKey(_ apiKey: String) async -> (valid: Bool, error: String?) {
        let result = await generateWorkout(apiKey: apiKey, prompt: "test")

        if result.success {
            return (valid: true, error: nil)
        }

        if let err = result.error {
            if err.status == 401 {
                return (valid: false, error: "Invalid API key")
            }
            return (valid: false, error: err.message)
        }

        return (valid: false, error: "Failed to verify API key")
    }
}
