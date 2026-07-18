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

    #if DEBUG
    /// Test-only seam: seed `count` stranded outbox rows and refresh
    /// `pendingCount` WITHOUT kicking a flush, so UI tests can render the
    /// auth-sync banner from a known queue depth. Clears existing rows first for
    /// determinism. Never compiled into release builds.
    func seedPendingForTesting(count: Int) {
        try? queue.clear()
        for i in 0..<count {
            try? queue.enqueue(clientSessionId: "uitest-outbox-seed-\(i)")
        }
        pendingCount = (try? queue.count()) ?? count
    }
    #endif

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
            CrashReporter.shared.captureError(
                error,
                category: .database,
                metadata: [
                    "tag": "outbox_enqueue_failed",
                    "clientSessionId": clientSessionId,
                ]
            )
            return
        }
        Task { await flushIfAuthenticated() }
    }

    /// Drain the queue. Idempotent — silently returns if a flush is in flight.
    ///
    /// If the device isn't authenticated but there ARE queued completions, the
    /// queue is preserved and the failure is surfaced loudly (device log +
    /// Sentry + observable `lastError`) so a silently-unsynced completed
    /// workout can't go unnoticed (GH #143).
    ///
    /// - Parameter force: when `true` (a manual "Sync now"), process ALL queued
    ///   items regardless of their `next_attempt_after` backoff timer. The
    ///   automatic flush (foreground, enqueue, reachability) leaves `force` at
    ///   its default `false` and only touches items eligible *now*.
    func flushIfAuthenticated(force: Bool = false) async {
        guard authStore.isAuthenticated else {
            reportAuthFailure(reason: "not_authenticated")
            return
        }
        guard !isFlushing else { return }
        isFlushing = true
        lastError = nil
        defer { isFlushing = false }

        let items: [OutboxPendingItem]
        do {
            items = force ? try queue.allItems() : try queue.eligibleItems()
        } catch {
            Logger.shared.error(.database, "outbox queue read failed", error: error)
            CrashReporter.shared.captureError(
                error,
                category: .database,
                metadata: ["tag": "outbox_queue_read_failed"]
            )
            return
        }

        var pushed = 0
        var retried = 0
        var failed = 0
        var hitAuthFailure = false

        for item in items {
            let outcome = await pushOne(item)
            switch outcome {
            case .pushed: pushed += 1
            case .gaveUpClientError: failed += 1
            case .retryQueued: retried += 1
            case .authMissing:
                // Lost auth mid-flush — the queue row is preserved (we never
                // delete on auth failure). Bail; we'll resume after re-auth.
                hitAuthFailure = true
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

        // Report once per flush cycle (not per item) to avoid Sentry spam.
        if hitAuthFailure {
            reportAuthFailure(reason: "push_401")
        }
    }

    /// Loud, recoverable handling of an auth failure that leaves completed
    /// workouts stranded in the queue. The rows are NEVER deleted here — the
    /// caller guarantees the queue is untouched. Emits one device-log error
    /// per flush cycle, and reflects the unsynced state in the observable
    /// `lastError` / `pendingCount` so the app-level auth-sync banner can
    /// render. The Sentry capture is throttled to once per build per device
    /// (repeats drop to breadcrumbs) — a persistently signed-out device
    /// re-hits this on every foreground flush, and per-cycle captures put
    /// 700+ identical events on one issue (Sentry LIFTMARK-IOS-P).
    /// See `spec/services/workout-outbox.md`.
    private func reportAuthFailure(reason: String) {
        let stranded = (try? queue.count()) ?? pendingCount
        pendingCount = stranded
        // Nothing queued → nothing was lost → stay quiet (e.g. a routine
        // foreground flush while signed out with an empty queue).
        guard stranded > 0 else { return }

        lastError = "Sign in to sync \(stranded) completed workout\(stranded == 1 ? "" : "s")"

        Logger.shared.error(
            .sync,
            "outbox flush blocked: authentication required",
            metadata: [
                "pendingCount": String(stranded),
                "reason": reason,
            ]
        )

        let err = NSError(
            domain: "LiftMark.Outbox",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Outbox auth failure: \(stranded) completed workout(s) cannot sync"]
        )
        CrashReporter.shared.captureErrorOncePerBuild(
            key: "outbox-auth-failure",
            error: err,
            breadcrumb: "outbox.authFailure.repeat",
            category: .sync,
            metadata: [
                "tag": "outbox_auth_failure",
                "partialFailureCount": String(stranded),
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
        } catch {
            return classifyPushFailure(error, item: item)
        }
    }

    /// Map a thrown push error to a `PushOutcome`. Split out of `pushOne` so each
    /// method stays focused (and within the function-length lint limit).
    private func classifyPushFailure(_ error: Error, item: OutboxPendingItem) -> PushOutcome {
        let clientSessionId = item.clientSessionId
        guard let apiError = error as? APIError else {
            // Decoding errors etc. — transient; a response-shape mismatch is more
            // likely deploy skew than a permanent bad payload on this device.
            scheduleRetry(item: item, error: error.localizedDescription)
            return .retryQueued
        }
        switch apiError {
        case .unauthorized:
            // Tokens refresh in withAuthorizedRequest; a 401 here means the user
            // effectively isn't signed in.
            lastError = "Authentication required"
            return .authMissing
        case let .edgeBlocked(status):
            // Edge/WAF block (HTML 403, e.g. SizeRestrictions_BODY) — never
            // reached our API. Transient infra, NOT a permanent client error: a
            // large body blocked at the edge must never be silently dropped.
            scheduleRetry(item: item, error: "Edge blocked (\(status))")
            captureOutboxFailure(
                tag: "outbox_edge_blocked", status: status, clientSessionId: clientSessionId,
                message: "Outbox push blocked at edge (\(status)); preserving queue row"
            )
            return .retryQueued
        case let .forbidden(msg):
            // A real API 403 IS terminal: surface via lastError + drop. Capture
            // so the drop is observable (Problem D).
            Logger.shared.error(
                .network,
                "outbox push 403 — dropping queue row",
                metadata: ["clientSessionId": clientSessionId, "message": msg ?? ""]
            )
            lastError = msg ?? "Forbidden"
            captureOutboxFailure(
                tag: "outbox_push_403", status: 403, clientSessionId: clientSessionId,
                message: "Outbox push 403 — dropping queue row: \(msg ?? "")"
            )
            try? queue.remove(clientSessionId: clientSessionId)
            return .gaveUpClientError
        case let .server(status, _) where status == 429:
            scheduleRetry(item: item, error: "Rate limited (\(status))")
            return .retryQueued
        case let .server(status, msg) where status >= 500:
            scheduleRetry(item: item, error: "Server error (\(status)): \(msg ?? "")")
            return .retryQueued
        case let .server(status, msg):
            // Other 4xx — bad payload. Drop the row + capture (Problem D).
            Logger.shared.error(
                .network,
                "outbox push gave up on 4xx",
                metadata: ["clientSessionId": clientSessionId, "status": String(status), "message": msg ?? ""]
            )
            captureOutboxFailure(
                tag: "outbox_push_4xx", status: status, clientSessionId: clientSessionId,
                message: "Outbox push gave up on 4xx (\(status)): \(msg ?? "")"
            )
            try? queue.remove(clientSessionId: clientSessionId)
            return .gaveUpClientError
        case let .transport(err):
            scheduleRetry(item: item, error: "Transport: \(err.localizedDescription)")
            return .retryQueued
        case .notFound, .conflict, .decoding:
            // Unexpected for this endpoint — treat as transient rather than
            // silently dropping a completed workout.
            scheduleRetry(item: item, error: "Unexpected: \(apiError)")
            return .retryQueued
        }
    }

    /// Emit one Sentry capture for an outbox push failure. The tag/status/
    /// clientSessionId keys are on the CrashReporter sync metadata allowlist.
    private func captureOutboxFailure(tag: String, status: Int, clientSessionId: String, message: String) {
        let err = NSError(
            domain: "LiftMark.Outbox",
            code: status,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        CrashReporter.shared.captureError(
            err,
            category: .network,
            metadata: ["tag": tag, "status": String(status), "clientSessionId": clientSessionId]
        )
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
