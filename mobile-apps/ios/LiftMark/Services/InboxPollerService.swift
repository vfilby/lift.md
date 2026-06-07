import Foundation

// MARK: - Wire Types

/// Lightweight listing entry from `GET /v1/workouts`. Only the `inbox_id` is
/// needed here — the full payload comes from the detail call.
private struct InboxListItem: Decodable {
    let inboxId: String
}

private struct InboxListResponse: Decodable {
    let items: [InboxListItem]
    let nextCursor: String?
}

/// Detail payload from `GET /v1/workouts/:inbox_id`. We decode only
/// `lmwf_text` + metadata. The server still returns a structured `workout`
/// field for backward compatibility, but the client ignores it — `lmwf_text`
/// is the single source of truth (parsed on-device for preview + promote).
private struct InboxDetailResponse: Decodable {
    let inboxId: String
    let createdAt: Date
    let sourceTokenId: String?
    let lmwfText: String?
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
/// - On a complete listing, reconciles the local cache down to the server's
///   live set: any locally-cached row the server no longer lists is pruned
///   (it was imported/discarded elsewhere, or a delete/poll race stranded it).
///   Skipped when the listing is truncated (a partial page can't prove a row
///   is gone). This is what keeps an imported item from lingering in the inbox.
///
/// What it intentionally does NOT do:
/// - Auto-create `WorkoutPlan` rows. Items live in the local inbox table
///   until the user explicitly Discards, Adds to Plans, or Starts.
/// - `ack` items. The server row is the durable source of truth and stays
///   put until the user imports/discards it (which `DELETE`s it). Acking on
///   fetch is what stranded items after a local-cache wipe in GH #164.
/// - Re-fetch items already in the local table. Inbox rows are immutable
///   (a push mints a fresh `inbox_id`), so re-downloading their bodies every
///   poll is pure waste.
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
                    // No `status` filter — every live row is part of the inbox
                    // until the user imports/discards it. Filtering to
                    // `status=pending` is what hid acked items forever (#164).
                    path: "/v1/workouts",
                    method: "GET",
                    body: Optional<EmptyBody>.none,
                    accessToken: token
                ) as InboxListResponse
            }
        } catch {
            Logger.shared.error(.network, "inbox list failed", error: error)
            lastError = "Could not reach the lift.md server."
            return
        }

        var upserted = 0
        var skipped = 0
        var failures = 0

        for item in listResponse.items {
            // Already cached → skip the detail download. Inbox rows are
            // immutable (a push always mints a new inbox_id), so there's
            // nothing to refresh; only genuinely new items cost a round-trip.
            if (try? inboxRepository.exists(id: item.inboxId)) == true {
                skipped += 1
                continue
            }
            do {
                let didUpsert = try await fetchAndStore(inboxId: item.inboxId)
                if didUpsert {
                    upserted += 1
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

        // Reconcile deletions: drop local rows the server no longer lists.
        // The loop above is add-only; without this, a row imported/discarded
        // elsewhere — or stranded locally when a promote's delete lost a race
        // with an in-flight poll re-adding it — lingers in the inbox forever
        // even though it's gone server-side (the reported "imported AND still
        // in the inbox" bug). The server is the source of truth, so any local
        // id absent from the listing has been consumed and should be pruned.
        //
        // Only safe on a COMPLETE listing. A truncated page (nextCursor != nil)
        // doesn't reveal the full server set, so pruning then could delete live
        // rows we simply didn't see on this page — skip reconciliation that
        // cycle rather than risk it. (The poll fetches a single page; see spec.)
        var pruned = 0
        if listResponse.nextCursor == nil {
            let serverIds = Set(listResponse.items.map { $0.inboxId })
            let localIds = (try? inboxRepository.allIds()) ?? []
            for staleId in localIds where !serverIds.contains(staleId) {
                do {
                    try inboxRepository.delete(id: staleId)
                    pruned += 1
                } catch {
                    Logger.shared.warn(
                        .database,
                        "inbox prune failed for \(staleId): \(error)"
                    )
                }
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
                "pruned": String(pruned),
                "skipped": String(skipped),
                "failures": String(failures),
                "localCount": String(pendingCount),
            ]
        )

        if upserted > 0 || pruned > 0 {
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

        guard let lmwfText = detail.lmwfText, !lmwfText.isEmpty else {
            // No raw markdown means nothing we can preview or promote.
            // Server-side reaper will clean these up eventually; nothing
            // useful for us to do client-side.
            Logger.shared.warn(
                .network,
                "inbox item missing lmwf_text — skipped",
                metadata: ["inboxId": inboxId]
            )
            return false
        }

        let item = InboxItem(
            id: detail.inboxId,
            fetchedAt: Date(),
            createdAtServer: detail.createdAt,
            sourceTokenId: detail.sourceTokenId,
            lmwfText: lmwfText
        )
        try inboxRepository.upsert(item)
        return true
    }
}

