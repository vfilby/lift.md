import Foundation
import GRDB

/// GRDB-backed store for `InboxItem` rows. See `spec/services/workout-inbox.md`.
///
/// Upserts are keyed on `inbox_id` (server ULID) so re-polling the same
/// server-side item is a no-op. The table is device-local — it is not
/// synced via CloudKit and is excluded from `.db` backup exports.
struct InboxItemRepository {
    private let dbManager: DatabaseManager

    init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    // MARK: - Read

    /// Newest-first, by server `created_at`.
    func list() throws -> [InboxItem] {
        let dbQueue = try dbManager.database()
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT inbox_id, fetched_at, created_at_server, source_token_id,
                       lmwf_text
                FROM workout_inbox
                ORDER BY created_at_server DESC
                """)
            return rows.compactMap(Self.assemble)
        }
    }

    func count() throws -> Int {
        let dbQueue = try dbManager.database()
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout_inbox") ?? 0
        }
    }

    func get(id: String) throws -> InboxItem? {
        let dbQueue = try dbManager.database()
        return try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT inbox_id, fetched_at, created_at_server, source_token_id,
                       lmwf_text
                FROM workout_inbox
                WHERE inbox_id = ?
                """, arguments: [id])
            return row.flatMap(Self.assemble)
        }
    }

    // MARK: - Write

    /// INSERT OR REPLACE by `inbox_id`. Caller supplies a freshly-built item
    /// — `fetched_at` is set to "now" if the caller passes the current Date,
    /// but the repository does not overwrite it on re-upsert beyond what the
    /// caller specifies (the poller passes the original first-fetch time on
    /// re-poll only if it has it cached; usually it just sets a fresh now).
    func upsert(_ item: InboxItem) throws {
        let dbQueue = try dbManager.database()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO workout_inbox (
                    inbox_id, fetched_at, created_at_server, source_token_id,
                    lmwf_text
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(inbox_id) DO UPDATE SET
                    created_at_server = excluded.created_at_server,
                    source_token_id   = excluded.source_token_id,
                    lmwf_text         = excluded.lmwf_text
                """, arguments: [
                    item.id,
                    Self.makeFormatter(fractional: true).string(from: item.fetchedAt),
                    Self.makeFormatter(fractional: true).string(from: item.createdAtServer),
                    item.sourceTokenId,
                    item.lmwfText,
                ])
        }
    }

    func delete(id: String) throws {
        let dbQueue = try dbManager.database()
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM workout_inbox WHERE inbox_id = ?",
                arguments: [id]
            )
        }
    }

    /// Wipe the entire inbox. Called on sign-out — server is the source of
    /// truth, signing back in will repopulate from the next poll.
    func clear() throws {
        let dbQueue = try dbManager.database()
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM workout_inbox")
        }
    }

    // MARK: - Private

    // ISO8601DateFormatter isn't Sendable, so we build per-call instances
    // rather than holding a static. Cost is negligible at our call volume.
    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return f
    }

    static func parseDate(_ s: String) -> Date {
        makeFormatter(fractional: true).date(from: s)
            ?? makeFormatter(fractional: false).date(from: s)
            ?? Date()
    }

    // Parsing `lmwf_text` into the in-memory summary happens here, once per
    // load (not on every SwiftUI render). `InboxItem.init` derives the
    // summary from `lmwfText` when none is supplied.
    private static func assemble(_ row: Row) -> InboxItem? {
        guard
            let id: String = row["inbox_id"],
            let fetchedAt: String = row["fetched_at"],
            let createdAtServer: String = row["created_at_server"],
            let lmwfText: String = row["lmwf_text"]
        else { return nil }

        return InboxItem(
            id: id,
            fetchedAt: parseDate(fetchedAt),
            createdAtServer: parseDate(createdAtServer),
            sourceTokenId: row["source_token_id"],
            lmwfText: lmwfText
        )
    }
}
