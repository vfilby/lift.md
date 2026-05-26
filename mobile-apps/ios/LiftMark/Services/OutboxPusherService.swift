import Foundation
import UIKit

// MARK: - Wire Types

private struct OutboxPushResponse: Decodable {
    let outboxId: String
    let clientSessionId: String
    let dedupHit: Bool
}

// MARK: - OutboxPusherService

/// Pushes completed sessions to the server outbox so external agents
/// (Claude Code, ChatGPT, scripts) can read recent training history. See
/// `spec/services/workout-outbox.md`.
///
/// Lifecycle:
/// - `enqueue(clientSessionId:)` is called from `SessionStore.completeSession`
///   the moment a workout is marked completed (durably, inside the same flow).
///   A best-effort flush kicks off immediately.
/// - `flushIfAuthenticated()` is also called on app foreground and on the
///   Settings "Sync now" tap.
/// - One in-flight flush at a time (`isFlushing` gate); items are drained
///   oldest-first, sequentially.
///
/// Failure handling:
/// - 2xx → row deleted.
/// - 4xx (not 429) → row deleted (bad payload, no point retrying).
/// - 5xx / 429 / network → bump attempt count, set next_attempt_after,
///   leave the row in place. Backoff: 30s, 2m, 10m, 30m, 2h (capped).
@MainActor
@Observable
final class OutboxPusherService {
    let authStore: AuthenticationStore
    let apiClient: APIClientProtocol
    let queue: OutboxPendingQueueRepository
    let sessionRepository: SessionRepository
    let exportService: WorkoutExportService

    private(set) var isFlushing: Bool = false
    private(set) var pendingCount: Int = 0
    private(set) var lastFlushAt: Date?
    private(set) var lastError: String?

    init(
        authStore: AuthenticationStore,
        apiClient: APIClientProtocol,
        queue: OutboxPendingQueueRepository = OutboxPendingQueueRepository(),
        sessionRepository: SessionRepository = SessionRepository(),
        exportService: WorkoutExportService = WorkoutExportService()
    ) {
        self.authStore = authStore
        self.apiClient = apiClient
        self.queue = queue
        self.sessionRepository = sessionRepository
        self.exportService = exportService
        self.pendingCount = (try? queue.count()) ?? 0
    }

    /// Enqueue a just-completed session for push. Must be called *after* the
    /// `WorkoutSession.status` row is durably `completed` — otherwise a crash
    /// between enqueue and write leaves a phantom queue row that points at
    /// an incomplete session.
    ///
    /// Best-effort kicks off a flush; the @Task wrapper means the caller
    /// doesn't block on the network.
    func enqueue(clientSessionId: String) {
        do {
            try queue.enqueue(clientSessionId: clientSessionId)
            pendingCount = (try? queue.count()) ?? pendingCount
            Logger.shared.info(
                .network,
                "outbox enqueue",
                metadata: ["clientSessionId": clientSessionId]
            )
        } catch {
            Logger.shared.error(.database, "outbox enqueue failed", error: error)
            return
        }
        Task { await flushIfAuthenticated() }
    }

    /// Drain the queue. Idempotent — silently returns if unauthenticated or a
    /// flush is in flight.
    func flushIfAuthenticated() async {
        guard authStore.isAuthenticated else { return }
        guard !isFlushing else { return }
        isFlushing = true
        lastError = nil
        defer { isFlushing = false }

        let items: [OutboxPendingItem]
        do {
            items = try queue.eligibleItems()
        } catch {
            Logger.shared.error(.database, "outbox queue read failed", error: error)
            return
        }

        var pushed = 0
        var retried = 0
        var failed = 0

        for item in items {
            let outcome = await pushOne(item)
            switch outcome {
            case .pushed: pushed += 1
            case .gaveUpClientError: failed += 1
            case .retryQueued: retried += 1
            case .authMissing:
                // Lost auth mid-flush — bail; we'll resume next foreground.
                break
            }
            if outcome == .authMissing { break }
        }

        lastFlushAt = Date()
        pendingCount = (try? queue.count()) ?? pendingCount

        Logger.shared.info(
            .network,
            "outbox flush complete",
            metadata: [
                "pushed": String(pushed),
                "retried": String(retried),
                "failed": String(failed),
                "queueSizeAfter": String(pendingCount),
            ]
        )
    }

    /// Called from `AuthenticationStore.signOut` to drop pending pushes —
    /// they belong to a different identity now.
    func wipeQueueOnSignOut() {
        do {
            try queue.clear()
            pendingCount = 0
        } catch {
            Logger.shared.error(.database, "outbox queue wipe failed", error: error)
        }
    }

    // MARK: - Private

    private enum PushOutcome {
        case pushed
        case retryQueued
        case gaveUpClientError
        case authMissing
    }

    private func pushOne(_ item: OutboxPendingItem) async -> PushOutcome {
        let clientSessionId = item.clientSessionId

        // Pull the durable session from the database. If it's missing the
        // user must have deleted it between completion and push — drop the
        // queue row.
        let session: WorkoutSession?
        do {
            session = try sessionRepository.getById(clientSessionId)
        } catch {
            Logger.shared.error(.database, "outbox session lookup failed", error: error)
            return .retryQueued
        }
        guard let session else {
            Logger.shared.warn(
                .network,
                "outbox: session no longer exists, dropping queue row",
                metadata: ["clientSessionId": clientSessionId]
            )
            try? queue.remove(clientSessionId: clientSessionId)
            return .gaveUpClientError
        }

        let exportPayload = exportService.buildSingleSessionPayload(session)
        let body: [String: Any] = [
            "client_session_id": clientSessionId,
            "source_device_id": Self.deviceId() ?? NSNull(),
            "export": exportPayload,
        ]

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            Logger.shared.error(.network, "outbox JSON serialize failed", error: error)
            try? queue.remove(clientSessionId: clientSessionId)
            return .gaveUpClientError
        }

        do {
            let response: OutboxPushResponse = try await authStore.withAuthorizedRequest { token in
                try await self.apiClient.sendData(
                    path: "/v1/workouts/outbox",
                    method: "POST",
                    bodyData: bodyData,
                    accessToken: token
                )
            }
            Logger.shared.info(
                .network,
                "outbox push success",
                metadata: [
                    "clientSessionId": clientSessionId,
                    "outboxId": response.outboxId,
                    "dedupHit": String(response.dedupHit),
                ]
            )
            try? queue.remove(clientSessionId: clientSessionId)
            return .pushed
        } catch APIError.unauthorized {
            // Treat 401 as auth-missing: tokens refresh in withAuthorizedRequest;
            // if we still get 401 here, the user effectively isn't signed in.
            lastError = "Authentication required"
            return .authMissing
        } catch let APIError.forbidden(msg) {
            // 403 — scope/quota. Surfaces to user via lastError; drop row.
            Logger.shared.error(
                .network,
                "outbox push 403 — dropping queue row",
                metadata: ["clientSessionId": clientSessionId, "message": msg ?? ""]
            )
            lastError = msg ?? "Forbidden"
            try? queue.remove(clientSessionId: clientSessionId)
            return .gaveUpClientError
        } catch let APIError.server(status, _) where status == 429 {
            scheduleRetry(item: item, error: "Rate limited (\(status))")
            return .retryQueued
        } catch let APIError.server(status, msg) where status >= 500 {
            scheduleRetry(item: item, error: "Server error (\(status)): \(msg ?? "")")
            return .retryQueued
        } catch let APIError.server(status, msg) {
            // Other 4xx — bad payload. Don't retry forever; drop the row and
            // log as an error so it surfaces in Sentry.
            Logger.shared.error(
                .network,
                "outbox push gave up on 4xx",
                metadata: [
                    "clientSessionId": clientSessionId,
                    "status": String(status),
                    "message": msg ?? "",
                ]
            )
            try? queue.remove(clientSessionId: clientSessionId)
            return .gaveUpClientError
        } catch let APIError.transport(error) {
            scheduleRetry(item: item, error: "Transport: \(error.localizedDescription)")
            return .retryQueued
        } catch {
            // Decoding errors etc. — treat as transient; the server's response
            // shape mismatching is more likely a deploy skew than a permanent
            // bad-payload condition on this device.
            scheduleRetry(item: item, error: error.localizedDescription)
            return .retryQueued
        }
    }

    private func scheduleRetry(item: OutboxPendingItem, error: String) {
        let backoff = Self.backoffSeconds(attempt: item.attemptCount)
        let nextAttempt = Date().addingTimeInterval(backoff)
        do {
            try queue.recordTransientFailure(
                clientSessionId: item.clientSessionId,
                nextAttemptAfter: nextAttempt,
                lastError: error
            )
            Logger.shared.warn(
                .network,
                "outbox push retry scheduled",
                metadata: [
                    "clientSessionId": item.clientSessionId,
                    "attempt": String(item.attemptCount + 1),
                    "nextAttemptAfter": ISO8601DateFormatter().string(from: nextAttempt),
                    "error": error,
                ]
            )
        } catch {
            Logger.shared.error(.database, "outbox retry bookkeeping failed", error: error)
        }
    }

    private static func backoffSeconds(attempt: Int) -> TimeInterval {
        // attempt is the *prior* attempt count; the row hasn't been bumped
        // yet. Cap matches the spec: 30s, 2m, 10m, 30m, 2h.
        switch attempt {
        case 0: return 30
        case 1: return 120
        case 2: return 600
        case 3: return 1800
        default: return 7200
        }
    }

    private static func deviceId() -> String? {
        return UIDevice.current.identifierForVendor?.uuidString
    }
}
