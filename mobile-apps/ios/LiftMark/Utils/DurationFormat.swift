import Foundation

/// Canonical user-facing duration formatting.
///
/// Every surface that shows a set or rest duration renders it as `M:SS`
/// ("0:45", "1:15") so times read the same everywhere — input fields, set
/// rows, cards, history, and the Live Activity — matching the exercise and
/// rest timers. LMWF source text (e.g. `- 30s @rest: 60s`) is format syntax,
/// not display, and keeps the spec's `Ns` notation.
/// See spec/screens/active-workout.md → "Duration Display Consistency".
enum DurationFormat {
    /// Format a second count as `M:SS`. Negative values clamp to "0:00".
    static func mmss(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    /// Parse user-typed duration input: `m:ss` ("1:15") or raw seconds
    /// ("75"). Returns nil for malformed or negative input, including
    /// seconds >= 60 after the colon.
    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":")
            guard parts.count == 2,
                  let minutes = Int(parts[0]),
                  let secs = Int(parts[1]),
                  minutes >= 0, secs >= 0, secs < 60 else { return nil }
            return minutes * 60 + secs
        }
        guard let seconds = Int(trimmed), seconds >= 0 else { return nil }
        return seconds
    }
}
