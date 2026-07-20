import XCTest
import GRDB
@testable import LiftMark

/// Coverage for the "lmwf_text is the single source of truth" inbox rework
/// (PR 1 of GH #161; root-cause fix for the #145 superset-grouping bug).
///
/// The inbox no longer persists a server pre-parse — `lmwf_text` is parsed
/// on-device through the canonical `MarkdownParser` for both preview and
/// promotion. These tests prove:
///   1. Promoting the #145 arms superset keeps grouping intact (the parent
///      superset + both children with `parentExerciseId`) and stamps
///      `sourceMarkdown`.
///   2. `InboxItem`'s in-memory summary is derived from `lmwf_text`.
///   3. The repository round-trips against the slimmed v18 schema.
///   4. The poller stores only `lmwf_text` + metadata (ignores `workout`).
///   5. The v17→v18 migration drops the pre-parse columns.
@MainActor
final class InboxLMWFSourceOfTruthTests: XCTestCase {

    // The exact #145 fixture from the issue.
    private static let armsSupersetLMWF = """
    # Lift Day 1

    ## Superset: Arms

    ### Cable Tricep Pushdown (Seated)
    - 35 lbs x 12
    - 35 lbs x 12

    ### Dumbbell Curl
    - 15 lbs x 12
    - 15 lbs x 12
    """

    // MARK: - 1. Root-cause: arms-superset promotion

    /// Mirrors exactly what `InboxSectionView.promote()` does: parse the raw
    /// `lmwf_text`, stamp `sourceMarkdown`. Asserts the promoted plan retains
    /// the superset grouping that the deleted `InboxWorkoutMapper` bridge
    /// dropped (the real cause of #145).
    func testPromoteArmsSuperset_preservesGroupingAndSourceMarkdown() throws {
        let lmwfText = Self.armsSupersetLMWF

        // Promote via the canonical path (what the view now does).
        let result = MarkdownParser.parseWorkout(lmwfText)
        var plan = try XCTUnwrap(result.data, "fixture must parse: \(result.errors)")
        plan.sourceMarkdown = lmwfText

        // sourceMarkdown set → Edit / Reprocess / Export work on inbox plans.
        XCTAssertEqual(plan.sourceMarkdown, lmwfText)

        // There must be a "Superset: Arms" superset parent: groupType
        // .superset and no sets of its own.
        let parents = plan.exercises.filter { $0.groupType == .superset && $0.sets.isEmpty }
        XCTAssertEqual(parents.count, 1, "expected exactly one superset parent")
        let parent = try XCTUnwrap(parents.first)
        // The parser keeps the full superset header as the group name.
        XCTAssertEqual(parent.exerciseName, "Superset: Arms")
        XCTAssertEqual(parent.groupName, "Superset: Arms")

        // Both arm exercises are children of that parent.
        let tricep = try XCTUnwrap(
            plan.exercises.first { $0.exerciseName == "Cable Tricep Pushdown (Seated)" }
        )
        let curl = try XCTUnwrap(
            plan.exercises.first { $0.exerciseName == "Dumbbell Curl" }
        )

        XCTAssertEqual(tricep.parentExerciseId, parent.id,
                       "tricep must be grouped under the Arms superset")
        XCTAssertEqual(curl.parentExerciseId, parent.id,
                       "curl must be grouped under the Arms superset")

        // Each child carries its two working sets.
        XCTAssertEqual(tricep.sets.count, 2)
        XCTAssertEqual(curl.sets.count, 2)
        XCTAssertEqual(tricep.sets.first?.targetWeight, 35)
        XCTAssertEqual(curl.sets.first?.targetWeight, 15)
    }

    // MARK: - 2. InboxItem summary derivation

    func testInboxItemDerivesSummaryFromLmwfText() {
        let item = InboxItem(
            id: "01ABC",
            fetchedAt: Date(),
            createdAtServer: Date(),
            sourceTokenId: "session",
            lmwfText: Self.armsSupersetLMWF
        )

        XCTAssertEqual(item.summary.name, "Lift Day 1")
        // The summary uses the shared display count: the empty superset parent
        // is a structural header and is NOT counted, so 2 performed exercises
        // (the two children), 4 working sets. This is the same number the
        // promoted plan's detail header shows — the inbox/detail count mismatch
        // bug was the summary counting the parent via raw `exercises.count`.
        XCTAssertEqual(item.summary.exerciseCount, 2)
        XCTAssertEqual(item.summary.setCount, 4)
    }

    func testInboxItemSummaryDegradesGracefullyOnUnparseable() {
        let item = InboxItem(
            id: "bad",
            fetchedAt: Date(),
            createdAtServer: Date(),
            sourceTokenId: nil,
            lmwfText: "not a workout at all"
        )
        // No header → parser returns no data; summary falls back rather than
        // crashing or dropping the row.
        XCTAssertEqual(item.summary.exerciseCount, 0)
        XCTAssertEqual(item.summary.setCount, 0)
    }

    // MARK: - 3. Repository round-trip on the slimmed schema

    func testRepositoryRoundTripStoresOnlyLmwfTextAndMetadata() throws {
        DatabaseManager.shared.deleteDatabase()
        defer { DatabaseManager.shared.deleteDatabase() }
        let repo = InboxItemRepository()

        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let item = InboxItem(
            id: "01ROUNDTRIP",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_500),
            createdAtServer: created,
            sourceTokenId: "tok-123",
            lmwfText: Self.armsSupersetLMWF
        )
        try repo.upsert(item)

        let loaded = try XCTUnwrap(try repo.get(id: "01ROUNDTRIP"))
        XCTAssertEqual(loaded.id, "01ROUNDTRIP")
        XCTAssertEqual(loaded.sourceTokenId, "tok-123")
        XCTAssertEqual(loaded.lmwfText, Self.armsSupersetLMWF)
        // Summary is re-derived from lmwf_text on load (not persisted).
        XCTAssertEqual(loaded.summary.name, "Lift Day 1")
        // Display count excludes the empty superset parent (see summary test).
        XCTAssertEqual(loaded.summary.exerciseCount, 2)

        // The slimmed table has no pre-parse columns.
        let db = try DatabaseManager.shared.database()
        let columns: [String] = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(workout_inbox)").map { $0["name"] }
        }
        XCTAssertEqual(
            Set(columns),
            ["inbox_id", "fetched_at", "created_at_server", "source_token_id", "lmwf_text"]
        )

        try repo.delete(id: "01ROUNDTRIP")
        XCTAssertEqual(try repo.count(), 0)
    }

    // MARK: - 4. Poller stores only lmwf_text (ignores `workout`)

    func testPollerStoresOnlyLmwfTextIgnoringServerWorkout() async throws {
        DatabaseManager.shared.deleteDatabase()
        defer { DatabaseManager.shared.deleteDatabase() }

        let tokenStore = TokenStore(service: "app.liftmark.inbox.tests.\(UUID().uuidString)")
        tokenStore.clear()
        defer { tokenStore.clear() }
        tokenStore.saveAccessToken(Self.makeJWT(expSecondsFromNow: 3600))
        tokenStore.saveRefreshToken("refresh-junk")

        let mock = RoutingMockAPIClient()
        // Listing: one pending item.
        mock.listResponse = ["items": [["inbox_id": "01POLL"]], "next_cursor": NSNull()]
        // Detail: lmwf_text present + a bogus structured `workout` that must
        // be ignored entirely (it has a wrong name so if it leaked into the
        // stored summary the assertion would catch it).
        mock.detailResponse = [
            "inbox_id": "01POLL",
            "created_at": "2026-05-01T12:00:00Z",
            "source_token_id": "session",
            "lmwf_text": Self.armsSupersetLMWF,
            "workout": ["name": "WRONG NAME FROM SERVER", "exercises": []],
        ]

        let auth = AuthenticationStore(api: mock, tokenStore: tokenStore)
        let flags = FeatureFlagsStore(defaults: makeTransientDefaults())
        flags.set(.workoutInbox, true)
        let repo = InboxItemRepository()
        let poller = InboxPollerService(
            authStore: auth,
            apiClient: mock,
            inboxRepository: repo,
            featureFlags: flags
        )

        await poller.pollIfAuthenticated()

        let stored = try repo.list()
        XCTAssertEqual(stored.count, 1)
        let item = try XCTUnwrap(stored.first)
        XCTAssertEqual(item.lmwfText, Self.armsSupersetLMWF)
        // Summary derived from lmwf_text — NOT the server's bogus workout name.
        XCTAssertEqual(item.summary.name, "Lift Day 1")
        XCTAssertNotEqual(item.summary.name, "WRONG NAME FROM SERVER")
    }

    // MARK: - 6. Durability: no ack, recover after a local-cache wipe (#164)

    /// The poll must NOT call `/ack`. Acking on fetch transitioned the row to
    /// `ingested` server-side, and the poller listed only `status=pending` —
    /// so once a device's local cache was wiped (logout / reinstall / the v18
    /// table drop) the item was stranded forever. Regression guard for #164.
    func testPollerDoesNotAck() async throws {
        DatabaseManager.shared.deleteDatabase()
        defer { DatabaseManager.shared.deleteDatabase() }

        let mock = RoutingMockAPIClient()
        mock.listResponse = ["items": [["inbox_id": "01POLL"]], "next_cursor": NSNull()]
        mock.detailResponse = Self.detailPayload(inboxId: "01POLL")

        let ctx = try makeAuthedPoller(mock: mock)
        defer { ctx.tokenStore.clear() }

        await ctx.poller.pollIfAuthenticated()

        XCTAssertEqual(try ctx.repo.count(), 1)
        XCTAssertFalse(
            mock.sentPaths.contains { $0.contains("/ack") },
            "poller must never ack — that's what stranded items in #164. Sent: \(mock.sentPaths)"
        )
    }

    /// The list call carries no `status` filter, so the server returns every
    /// live row (including ones a prior build had acked into `ingested`).
    func testPollerListsWithoutStatusFilter() async throws {
        DatabaseManager.shared.deleteDatabase()
        defer { DatabaseManager.shared.deleteDatabase() }

        let mock = RoutingMockAPIClient()
        mock.listResponse = ["items": [], "next_cursor": NSNull()]

        let ctx = try makeAuthedPoller(mock: mock)
        defer { ctx.tokenStore.clear() }

        await ctx.poller.pollIfAuthenticated()

        XCTAssertTrue(
            mock.sentPaths.contains("/v1/workouts"),
            "expected an unfiltered list call; sent: \(mock.sentPaths)"
        )
        XCTAssertFalse(
            mock.sentPaths.contains { $0.contains("status=pending") },
            "list must not filter by status — that hid acked items in #164"
        )
    }

    /// A wiped local cache (logout / reinstall / migration drop) must self-heal:
    /// the next poll re-fetches the still-present server rows. This is the
    /// user-facing recovery path for #164.
    func testPollerRepopulatesAfterLocalWipe() async throws {
        DatabaseManager.shared.deleteDatabase()
        defer { DatabaseManager.shared.deleteDatabase() }

        let mock = RoutingMockAPIClient()
        mock.listResponse = ["items": [["inbox_id": "01POLL"]], "next_cursor": NSNull()]
        mock.detailResponse = Self.detailPayload(inboxId: "01POLL")

        let ctx = try makeAuthedPoller(mock: mock)
        defer { ctx.tokenStore.clear() }

        await ctx.poller.pollIfAuthenticated()
        XCTAssertEqual(try ctx.repo.count(), 1)

        // Simulate logout-wipe / reinstall: the local table is gone but the
        // server still holds the row (we never acked/deleted it).
        try ctx.repo.clear()
        XCTAssertEqual(try ctx.repo.count(), 0)

        await ctx.poller.pollIfAuthenticated()
        XCTAssertEqual(try ctx.repo.count(), 1, "item must come back after a wipe")
        XCTAssertEqual(try ctx.repo.list().first?.summary.name, "Lift Day 1")
    }

    /// Items already cached locally are not re-downloaded — the poll re-lists
    /// the whole inbox cheaply but only fetches detail for genuinely new items.
    func testPollerSkipsAlreadyCachedItems() async throws {
        DatabaseManager.shared.deleteDatabase()
        defer { DatabaseManager.shared.deleteDatabase() }

        let mock = RoutingMockAPIClient()
        mock.listResponse = ["items": [["inbox_id": "01POLL"]], "next_cursor": NSNull()]
        mock.detailResponse = Self.detailPayload(inboxId: "01POLL")

        let ctx = try makeAuthedPoller(mock: mock)
        defer { ctx.tokenStore.clear() }

        await ctx.poller.pollIfAuthenticated()
        await ctx.poller.pollIfAuthenticated()

        let detailFetches = mock.sentPaths.filter { $0 == "/v1/workouts/01POLL" }.count
        XCTAssertEqual(detailFetches, 1, "cached item must not be re-fetched on the second poll")
        XCTAssertEqual(try ctx.repo.count(), 1)
    }

    // MARK: - 7. Deletion reconciliation (imported/discarded item must leave the inbox)

    /// The reported bug: an item promoted/discarded server-side lingers in the
    /// local inbox because the add-only poll never pruned it. After this fix the
    /// next complete poll drops any local row the server no longer lists.
    func testPollerPrunesLocalRowsAbsentFromServerListing() async throws {
        DatabaseManager.shared.deleteDatabase()
        defer { DatabaseManager.shared.deleteDatabase() }

        let mock = RoutingMockAPIClient()
        // First poll: server has the item; it lands locally.
        mock.listResponse = ["items": [["inbox_id": "01POLL"]], "next_cursor": NSNull()]
        mock.detailResponse = Self.detailPayload(inboxId: "01POLL")

        let ctx = try makeAuthedPoller(mock: mock)
        defer { ctx.tokenStore.clear() }

        await ctx.poller.pollIfAuthenticated()
        XCTAssertEqual(try ctx.repo.count(), 1)

        // The item is consumed server-side (imported/discarded elsewhere, or a
        // delete that this device's local cache didn't reflect): the listing no
        // longer includes it. The next complete poll must prune the stale row.
        mock.listResponse = ["items": [], "next_cursor": NSNull()]
        await ctx.poller.pollIfAuthenticated()

        XCTAssertEqual(try ctx.repo.count(), 0, "stale local row must be pruned once the server stops listing it")
    }

    /// Reconciliation must NOT run on a truncated listing — a partial page can't
    /// prove a row is gone, so pruning then could delete live items we simply
    /// didn't see. A non-nil `next_cursor` means "more pages exist".
    func testPollerDoesNotPruneOnTruncatedListing() async throws {
        DatabaseManager.shared.deleteDatabase()
        defer { DatabaseManager.shared.deleteDatabase() }

        let mock = RoutingMockAPIClient()
        mock.listResponse = ["items": [["inbox_id": "01POLL"]], "next_cursor": NSNull()]
        mock.detailResponse = Self.detailPayload(inboxId: "01POLL")

        let ctx = try makeAuthedPoller(mock: mock)
        defer { ctx.tokenStore.clear() }

        await ctx.poller.pollIfAuthenticated()
        XCTAssertEqual(try ctx.repo.count(), 1)

        // Item absent from THIS page, but the listing is truncated (more pages).
        // The cached row must survive — we can't conclude it was deleted.
        mock.listResponse = ["items": [], "next_cursor": "cursor-more-pages"]
        await ctx.poller.pollIfAuthenticated()

        XCTAssertEqual(try ctx.repo.count(), 1, "must not prune when the listing is incomplete")
    }

    /// The repository exposes every cached id so the poller can diff the local
    /// set against the server listing.
    func testRepositoryAllIdsReturnsEveryCachedRow() throws {
        DatabaseManager.shared.deleteDatabase()
        defer { DatabaseManager.shared.deleteDatabase() }
        let repo = InboxItemRepository()

        for id in ["01A", "01B", "01C"] {
            try repo.upsert(InboxItem(
                id: id,
                fetchedAt: Date(),
                createdAtServer: Date(),
                sourceTokenId: "session",
                lmwfText: Self.armsSupersetLMWF
            ))
        }

        XCTAssertEqual(Set(try repo.allIds()), ["01A", "01B", "01C"])
    }

    // MARK: - 5. v17 -> v18 migration drops the pre-parse columns

    func testV18MigrationDropsPreParseColumns() throws {
        // Build a v17-shaped workout_inbox (with pre-parse columns) and run
        // the live migrator up to v18.
        let loaded = try DatabaseSeedLoader.load(ddl: """
            CREATE TABLE workout_inbox (
                inbox_id              TEXT PRIMARY KEY NOT NULL,
                fetched_at            TEXT NOT NULL,
                created_at_server     TEXT NOT NULL,
                source_token_id       TEXT,
                lmwf_text             TEXT NOT NULL,
                workout_json          TEXT NOT NULL,
                summary_name          TEXT NOT NULL,
                summary_exercise_count INTEGER NOT NULL DEFAULT 0,
                summary_set_count     INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE schema_version (version INTEGER NOT NULL DEFAULT 0);
            INSERT INTO schema_version (version) VALUES (17);
            """)
        defer { DatabaseSeedLoader.cleanup(loaded) }
        let queue = try DatabaseSeedLoader.openQueue(at: loaded.path)

        // schema_version=17 stamps v1..v17 as applied; the migrator then runs only v18.
        try DatabaseSeedLoader.migrate(queue, upTo: "v18_workout_inbox_drop_preparse")

        let columns: [String] = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(workout_inbox)").map { $0["name"] }
        }
        XCTAssertEqual(
            Set(columns),
            ["inbox_id", "fetched_at", "created_at_server", "source_token_id", "lmwf_text"],
            "v18 must drop workout_json + summary_* columns"
        )
    }

    // MARK: - Helpers

    private struct PollerContext {
        let poller: InboxPollerService
        let repo: InboxItemRepository
        let tokenStore: TokenStore
    }

    /// Wires an authenticated `InboxPollerService` over the supplied mock with
    /// the workout-inbox flag on and a live (default) repository.
    private func makeAuthedPoller(mock: RoutingMockAPIClient) throws -> PollerContext {
        let tokenStore = TokenStore(service: "app.liftmark.inbox.tests.\(UUID().uuidString)")
        tokenStore.clear()
        tokenStore.saveAccessToken(Self.makeJWT(expSecondsFromNow: 3600))
        tokenStore.saveRefreshToken("refresh-junk")

        let auth = AuthenticationStore(api: mock, tokenStore: tokenStore)
        let flags = FeatureFlagsStore(defaults: makeTransientDefaults())
        flags.set(.workoutInbox, true)
        let repo = InboxItemRepository()
        let poller = InboxPollerService(
            authStore: auth,
            apiClient: mock,
            inboxRepository: repo,
            featureFlags: flags
        )
        return PollerContext(poller: poller, repo: repo, tokenStore: tokenStore)
    }

    /// A minimal valid detail payload for the arms-superset fixture.
    private static func detailPayload(inboxId: String) -> [String: Any] {
        [
            "inbox_id": inboxId,
            "created_at": "2026-05-01T12:00:00Z",
            "source_token_id": "session",
            "lmwf_text": armsSupersetLMWF,
        ]
    }

    private func makeTransientDefaults() -> UserDefaults {
        let suite = "inbox.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func makeJWT(expSecondsFromNow: TimeInterval, sub: String = "user-test") -> String {
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "sub": sub,
            "exp": Date().timeIntervalSince1970 + expSecondsFromNow,
        ]
        func b64(_ obj: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "" }
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(header)).\(b64(payload)).signature-junk"
    }
}

// MARK: - Routing mock

/// Path-aware mock: the poller makes a listing call then a detail call (two
/// different response types), so the single-shot shared mock won't do. Routes
/// by path substring and decodes through the real snake_case machinery.
private final class RoutingMockAPIClient: APIClientProtocol, @unchecked Sendable {
    var listResponse: [String: Any] = [:]
    var detailResponse: [String: Any] = [:]
    private(set) var sentPaths: [String] = []

    func send<Req: Encodable, Res: Decodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws -> Res {
        sentPaths.append(path)
        let dict: [String: Any]
        // The list call is the bare collection path; anything with an
        // inbox_id segment after it is a detail fetch.
        if path == "/v1/workouts" || path.hasPrefix("/v1/workouts?") {
            dict = listResponse
        } else {
            dict = detailResponse
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Res.self, from: data)
    }

    func sendEmpty<Req: Encodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws {
        sentPaths.append(path)
    }

    func sendData<Res: Decodable>(
        path: String,
        method: String,
        bodyData: Data,
        accessToken: String?
    ) async throws -> Res {
        throw APIError.server(status: 500, message: "Mock: sendData not implemented")
    }
}
