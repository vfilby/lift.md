import Foundation

/// Device-local representation of a workout pushed to this user from
/// outside the app (e.g., Claude Code via PAT). See
/// `spec/services/workout-inbox.md`.
///
/// Items live here until the user discards them or promotes them to a
/// `WorkoutPlan` via the Inbox section on the Plans screen.
///
/// `lmwfText` is the single source of truth — preview and promotion both
/// parse it through the canonical `MarkdownParser` path. No pre-parse is
/// persisted (the `workout_json` / `summary_*` columns were dropped in
/// schema v18). The list/preview `summary` is **derived in memory** by
/// parsing `lmwfText` when the item is loaded (see `Summary.derive`) — it is
/// never written back to the database.
struct InboxItem: Identifiable, Hashable {
    /// Server ULID. Stable across re-polls — upsert key.
    let id: String
    let fetchedAt: Date
    let createdAtServer: Date
    let sourceTokenId: String?
    /// Original markdown. Single source of truth for preview + promote.
    let lmwfText: String
    /// In-memory list/preview summary derived by parsing `lmwfText` at load
    /// time. Not persisted.
    let summary: Summary

    init(
        id: String,
        fetchedAt: Date,
        createdAtServer: Date,
        sourceTokenId: String?,
        lmwfText: String,
        summary: Summary? = nil
    ) {
        self.id = id
        self.fetchedAt = fetchedAt
        self.createdAtServer = createdAtServer
        self.sourceTokenId = sourceTokenId
        self.lmwfText = lmwfText
        self.summary = summary ?? Summary.derive(from: lmwfText)
    }

    /// Lightweight list/preview summary derived from `lmwfText`. Parsing is
    /// pure string work; we do it once at load time rather than on every
    /// SwiftUI render.
    struct Summary: Hashable {
        let name: String
        let exerciseCount: Int
        let setCount: Int

        /// Parse `lmwfText` via the canonical parser and fold it into a
        /// summary. Falls back to a generic name + zero counts if the
        /// markdown won't parse (server should never push unparseable text,
        /// but we degrade gracefully rather than dropping the row).
        static func derive(from lmwfText: String) -> Summary {
            let result = MarkdownParser.parseWorkout(lmwfText)
            guard let plan = result.data else {
                return Summary(name: "Workout", exerciseCount: 0, setCount: 0)
            }
            // Use the plan's shared display counts so the inbox row/preview
            // report the same numbers the promoted plan will (structural
            // section/superset headers excluded). See `WorkoutPlan`.
            return Summary(
                name: plan.name,
                exerciseCount: plan.displayExerciseCount,
                setCount: plan.plannedSetCount
            )
        }
    }
}
