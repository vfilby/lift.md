import Foundation
import GRDB

/// One row in the local `outbox_pending_queue` table — a completed session
/// awaiting push to `POST /v1/workouts/outbox`. See
/// `spec/services/workout-outbox.md`.
struct OutboxPendingItem: Equatable {
    let clientSessionId: String
    let enqueuedAt: Date
    let attemptCount: Int
    let nextAttemptAfter: Date?
    let lastError: String?
}

/// GRDB-backed retry queue for the workout outbox. Device-local; not synced
/// via CloudKit and excluded from `.db` backup exports.
struct OutboxPendingQueueRepository {
    private let dbManager: DatabaseManager

    init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    // MARK: - Read

    /// All currently-eligible items, oldest first. "Eligible" means
    /// `next_attempt_after` is null or in the past.
    func eligibleItems(now: Date = Date()) throws -> [OutboxPendingItem] {
        let dbQueue = try dbManager.database()
        let nowIso = Self.formatter().string(from: now)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT client_session_id, enqueued_at, attempt_count,
                       next_attempt_after, last_error
                FROM outbox_pending_queue
                WHERE next_attempt_after IS NULL OR next_attempt_after <= ?
                ORDER BY enqueued_at ASC
                """, arguments: [nowIso])
            return rows.compactMap(Self.assemble)
        }
    }

    func count() throws -> Int {
        let dbQueue = try dbManager.database()
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_pending_queue") ?? 0
        }
    }

    func contains(clientSessionId: String) throws -> Bool {
        let dbQueue = try dbManager.database()
        return try dbQueue.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_pending_queue WHERE client_session_id = ?",
                arguments: [clientSessionId]
            ) ?? 0) > 0
        }
    }

    // MARK: - Write

    /// Insert if not already present. Idempotent — re-enqueueing the same
    /// session is a no-op (preserves the original enqueued_at).
    func enqueue(clientSessionId: String, now: Date = Date()) throws {
        let dbQueue = try dbManager.database()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO outbox_pending_queue (
                    client_session_id, enqueued_at, attempt_count,
                    next_attempt_after, last_error
                ) VALUES (?, ?, 0, NULL, NULL)
                """, arguments: [
                    clientSessionId,
                    Self.formatter().string(from: now),
                ])
        }
    }

    /// Remove a row — called on successful push or on a non-retryable 4xx.
    func remove(clientSessionId: String) throws {
        let dbQueue = try dbManager.database()
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM outbox_pending_queue WHERE client_session_id = ?",
                arguments: [clientSessionId]
            )
        }
    }

    /// Mark a transient failure: bump `attempt_count`, push `next_attempt_after`
    /// out by the caller-computed backoff, record a short error message.
    func recordTransientFailure(
        clientSessionId: String,
        nextAttemptAfter: Date,
        lastError: String
    ) throws {
        let dbQueue = try dbManager.database()
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE outbox_pending_queue
                SET attempt_count = attempt_count + 1,
                    next_attempt_after = ?,
                    last_error = ?
                WHERE client_session_id = ?
                """, arguments: [
                    Self.formatter().string(from: nextAttemptAfter),
                    String(lastError.prefix(500)),
                    clientSessionId,
                ])
        }
    }

    /// Wipe the queue. Called on sign-out — server-side outbox is the durable
    /// record; pending-push state on this device is orphaned once the user
    /// signs out.
    func clear() throws {
        let dbQueue = try dbManager.database()
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox_pending_queue")
        }
    }

    // MARK: - Private

    // ISO8601DateFormatter isn't Sendable, so build per-call instances rather
    // than holding a static. Cost is negligible at our call volume; matches
    // the InboxItemRepository convention.
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static func assemble(_ row: Row) -> OutboxPendingItem? {
        guard
            let clientSessionId = row["client_session_id"] as? String,
            let enqueuedAtStr = row["enqueued_at"] as? String,
            let enqueuedAt = parseDate(enqueuedAtStr)
        else { return nil }

        let attemptCount = (row["attempt_count"] as? Int) ?? 0
        let nextAttemptAfter = (row["next_attempt_after"] as? String).flatMap(parseDate)
        let lastError = row["last_error"] as? String

        return OutboxPendingItem(
            clientSessionId: clientSessionId,
            enqueuedAt: enqueuedAt,
            attemptCount: attemptCount,
            nextAttemptAfter: nextAttemptAfter,
            lastError: lastError
        )
    }

    private static func parseDate(_ str: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: str) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: str)
    }
}
