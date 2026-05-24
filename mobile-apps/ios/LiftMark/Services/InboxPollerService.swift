import Foundation

// MARK: - Wire Types

/// Lightweight listing entry from `GET /v1/workouts?status=pending`. Only the
/// `inbox_id` is needed here — the full payload comes from the detail call.
private struct InboxListItem: Decodable {
    let inboxId: String
}

private struct InboxListResponse: Decodable {
    let items: [InboxListItem]
    let nextCursor: String?
}

/// Detail payload from `GET /v1/workouts/:inbox_id`. `workout` is the full
/// parsed `WorkoutPlan` (we store it as-is for promotion later).
private struct InboxDetailResponse: Decodable {
    let inboxId: String
    let createdAt: Date
    let sourceTokenId: String?
    let lmwfText: String?
    let workout: InboxWorkout?
}

// MARK: - InboxPollerService

/// Foreground poller that drains the server-side workout inbox into the
/// device-local `workout_inbox` table. See `spec/services/workout-inbox.md`.
///
/// Lifecycle:
/// - Triggered on foreground transition and on the Settings "Sync now" tap.
/// - One in-flight poll at a time (`isPolling` gate).
/// - Per-item decode/store failures are logged and skipped; items stay
///   pending server-side and are retried on the next poll.
///
/// What it intentionally does NOT do:
/// - Auto-create `WorkoutPlan` rows. Items live in the local inbox table
///   until the user explicitly Discards, Adds to Plans, or Starts.
/// - Pagination follow-through (single page per run; server default is 50).
@MainActor
@Observable
final class InboxPollerService {
    let authStore: AuthenticationStore
    let apiClient: APIClientProtocol
    let inboxRepository: InboxItemRepository
    let featureFlags: FeatureFlagsStore

    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var isPolling: Bool = false
    private(set) var pendingCount: Int = 0

    init(
        authStore: AuthenticationStore,
        apiClient: APIClientProtocol,
        inboxRepository: InboxItemRepository = InboxItemRepository(),
        featureFlags: FeatureFlagsStore
    ) {
        self.authStore = authStore
        self.apiClient = apiClient
        self.inboxRepository = inboxRepository
        self.featureFlags = featureFlags
        // Initial count comes from whatever the device already has stored;
        // gets refreshed on each successful poll.
        self.pendingCount = (try? inboxRepository.count()) ?? 0
    }

    /// Idempotent. Silently returns if unauthenticated or a poll is in
    /// flight. Posts an `inboxDidChange` notification when the local table
    /// changes so UI can refresh.
    func pollIfAuthenticated() async {
        // Feature-flag gate is the single chokepoint for every poll entry
        // (foreground transition, manual Sync, pull-to-refresh). Hiding
        // the UI alone isn't enough — we want zero network calls when the
        // flag is off so beta logs stay clean during iteration.
        guard featureFlags.isEnabled(.workoutInbox) else { return }
        guard authStore.isAuthenticated else { return }
        guard !isPolling else { return }

        isPolling = true
        lastError = nil
        defer { isPolling = false }

        let listResponse: InboxListResponse
        do {
            listResponse = try await authStore.withAuthorizedRequest { token in
                try await self.apiClient.send(
                    path: "/v1/workouts?status=pending",
                    method: "GET",
                    body: Optional<EmptyBody>.none,
                    accessToken: token
                ) as InboxListResponse
            }
        } catch {
            Logger.shared.error(.network, "inbox list failed", error: error)
            lastError = "Could not reach the LiftMark server."
            return
        }

        var upserted = 0
        var acked = 0
        var failures = 0

        for item in listResponse.items {
            do {
                let didUpsert = try await fetchAndStore(inboxId: item.inboxId)
                if didUpsert {
                    upserted += 1
                    // Ack only after a successful local store. Ack failure
                    // is non-fatal — re-poll will see the same item, and
                    // the local upsert is a no-op (same inbox_id).
                    do {
                        try await ack(inboxId: item.inboxId)
                        acked += 1
                    } catch {
                        Logger.shared.warn(
                            .network,
                            "ack failed for \(item.inboxId) — will retry next poll"
                        )
                    }
                }
            } catch {
                failures += 1
                Logger.shared.error(
                    .network,
                    "inbox upsert failed for \(item.inboxId)",
                    error: error
                )
            }
        }

        lastSyncedAt = Date()
        pendingCount = (try? inboxRepository.count()) ?? pendingCount

        Logger.shared.info(
            .network,
            "inbox poll complete",
            metadata: [
                "fetched": String(listResponse.items.count),
                "upserted": String(upserted),
                "acked": String(acked),
                "failures": String(failures),
                "localCount": String(pendingCount),
            ]
        )

        if upserted > 0 {
            NotificationCenter.default.post(
                name: Self.inboxDidChange,
                object: nil
            )
        }
    }

    /// Reflect a local change (discard, promote) into the observable
    /// `pendingCount` and broadcast the notification so the UI updates.
    func refreshLocalState() {
        pendingCount = (try? inboxRepository.count()) ?? pendingCount
        NotificationCenter.default.post(name: Self.inboxDidChange, object: nil)
    }

    /// Notification posted whenever the local inbox table changes — used by
    /// the Plans screen to refresh its Inbox section without polling on a
    /// timer.
    static let inboxDidChange = Notification.Name("InboxPollerService.inboxDidChange")

    // MARK: - Private

    private func fetchAndStore(inboxId: String) async throws -> Bool {
        let detail = try await authStore.withAuthorizedRequest { token in
            try await self.apiClient.send(
                path: "/v1/workouts/\(inboxId)",
                method: "GET",
                body: Optional<EmptyBody>.none,
                accessToken: token
            ) as InboxDetailResponse
        }

        guard let inboxWorkout = detail.workout else {
            // Pre-full-payload rows. Server-side reaper will clean these
            // up eventually; nothing useful for us to do client-side.
            Logger.shared.warn(
                .network,
                "inbox item missing workout payload — skipped",
                metadata: ["inboxId": inboxId]
            )
            return false
        }

        let encoder = JSONEncoder()
        let workoutData = try encoder.encode(inboxWorkout)
        guard let workoutJSON = String(data: workoutData, encoding: .utf8) else {
            throw APIError.decoding(
                NSError(
                    domain: "InboxPollerService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to UTF-8 encode workout JSON"]
                )
            )
        }

        let totalSets = inboxWorkout.exercises.reduce(0) { $0 + $1.sets.count }

        let item = InboxItem(
            id: detail.inboxId,
            fetchedAt: Date(),
            createdAtServer: detail.createdAt,
            sourceTokenId: detail.sourceTokenId,
            lmwfText: detail.lmwfText ?? "",
            workoutJSON: workoutJSON,
            summaryName: inboxWorkout.name,
            summaryExerciseCount: inboxWorkout.exercises.count,
            summarySetCount: totalSets
        )
        try inboxRepository.upsert(item)
        return true
    }

    private func ack(inboxId: String) async throws {
        try await authStore.withAuthorizedRequest { token in
            try await self.apiClient.sendEmpty(
                path: "/v1/workouts/\(inboxId)/ack",
                method: "POST",
                body: Optional<EmptyBody>.none,
                accessToken: token
            )
        }
    }
}

