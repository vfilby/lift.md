import Foundation

// MARK: - Wire types

/// Body of `POST /v1/ai/plan/edit`. `APIClient` encodes keys in snake_case.
struct PlanEditCloudRequest: Encodable, Equatable {
    let planMarkdown: String
    let instruction: String
    let history: [PlanEditTurn]
    let context: PlanEditContext

    init(_ request: PlanEditRequest) {
        planMarkdown = request.planMarkdown
        instruction = request.instruction
        history = request.history
        context = request.context
    }
}

/// 200 body. `model` and `usage` are informational and optional so a server
/// that omits them still decodes.
struct PlanEditCloudResponse: Decodable, Equatable {
    struct Usage: Decodable, Equatable {
        let inputTokens: Int?
        let outputTokens: Int?
    }

    let planMarkdown: String
    let summary: String
    let warnings: [String]?
    /// 2 when the server needed its repair turn.
    let attempts: Int?
    let quota: PlanEditQuota?
    let model: String?
    let usage: Usage?
}

// MARK: - Engine

/// `liftMarkCloud`: the getlift.md API fronting Amazon Bedrock. Requires a
/// signed-in session; auth and refresh go through
/// `AuthenticationStore.withAuthorizedRequest` exactly like `InboxPollerService`.
/// See `spec/services/ai-plan-editing.md` ("LiftMarkCloudEngine").
@MainActor
final class LiftMarkCloudEngine: PlanEditEngine {
    static let path = "/v1/ai/plan/edit"
    static let signInReason = "Sign in to use LiftMark cloud"

    nonisolated let kind: PlanEditEngineKind = .liftMarkCloud
    nonisolated let displayName = "LiftMark cloud"

    private let authStore: AuthenticationStore
    private let apiClient: APIClientProtocol

    init(authStore: AuthenticationStore, apiClient: APIClientProtocol) {
        self.authStore = authStore
        self.apiClient = apiClient
    }

    /// Available whenever signed in. Quota is only known after a call; the
    /// session caches the last `PlanEditQuota` for the header label.
    func availability() async -> PlanEditEngineAvailability {
        authStore.isAuthenticated ? .available : .unavailable(reason: Self.signInReason)
    }

    func edit(_ request: PlanEditRequest) async throws -> PlanEditResult {
        guard authStore.isAuthenticated else { throw PlanEditError.notSignedIn }
        try PlanEditPrompt.checkSizeLimits(request)

        let body = PlanEditCloudRequest(request)
        let response: PlanEditCloudResponse
        do {
            response = try await authStore.withAuthorizedRequest { token in
                try await self.apiClient.send(
                    path: Self.path,
                    method: "POST",
                    body: body,
                    accessToken: token
                ) as PlanEditCloudResponse
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw PlanEditError.cancelled }
            let mapped = Self.mapError(error)
            Logger.shared.error(.network, "ai plan edit failed", error: error)
            throw mapped
        }

        return try Self.result(from: response)
    }

    // MARK: - Mapping

    /// The server already validated the markdown; parse again anyway so the
    /// result carries local parser warnings and the diff can be built from it.
    static func result(from response: PlanEditCloudResponse) throws -> PlanEditResult {
        let markdown = PlanEditPrompt.stripOuterCodeFence(response.planMarkdown)
        let parsed = MarkdownParser.parseWorkout(markdown)
        guard parsed.success else {
            throw PlanEditError.outputDidNotParse(parsed.errors)
        }
        var warnings = response.warnings ?? []
        for warning in parsed.warnings where !warnings.contains(warning) {
            warnings.append(warning)
        }
        return PlanEditResult(
            planMarkdown: markdown,
            summary: response.summary,
            warnings: warnings,
            engine: .liftMarkCloud,
            quota: response.quota
        )
    }

    /// HTTP status → `PlanEditError` per the service spec's response table.
    static func mapError(_ error: Error) -> PlanEditError {
        if let planEditError = error as? PlanEditError { return planEditError }
        guard let apiError = error as? APIError else {
            return .model(error.localizedDescription)
        }
        switch apiError {
        case .unauthorized:
            return .notSignedIn
        case .forbidden(let message):
            return .model(message ?? "This account can't use AI editing.")
        case .edgeBlocked, .transport:
            return .network
        case .notFound:
            return .model("AI editing isn't available on this server.")
        case .conflict(let message):
            return .model(message ?? "The request conflicted with another change.")
        case .decoding:
            return .model("LiftMark returned an unexpected response.")
        case .server(let status, let message):
            return mapServerStatus(status, message: message)
        }
    }

    private static func mapServerStatus(_ status: Int, message: String?) -> PlanEditError {
        switch status {
        case 402:
            return .subscriptionRequired
        case 413:
            return .planTooLarge
        case 422:
            return .outputDidNotParse(message.map { [$0] } ?? [])
        case 429:
            // `APIError.server` carries only the error message, not the quota
            // body, so the reset time is unknown here; the header label keeps
            // showing the last cached quota's reset time.
            return .quotaExhausted(resetAt: nil)
        case 500...599:
            return .model(message ?? "LiftMark's AI service hit a problem. Try again shortly.")
        default:
            return .model(message ?? "LiftMark returned an unexpected error (\(status)).")
        }
    }
}
