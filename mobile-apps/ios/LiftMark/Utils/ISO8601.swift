import Foundation

/// Tolerant ISO8601 timestamp parsing.
///
/// The app writes timestamps with a bare `ISO8601DateFormatter()` (whole seconds, e.g.
/// "2026-06-02T16:32:00Z"), but any value that round-trips through CloudKit
/// (`CKRecordMapper.dateToISO` serializes with `.withFractionalSeconds`) or the API
/// comes back WITH fractional seconds (e.g. "2026-06-02T16:32:00.000Z").
///
/// A bare `ISO8601DateFormatter().date(from:)` returns `nil` on a fractional-second
/// string. That silently dropped synced workout start times in the UI — the receiving
/// device showed "Day · duration" with no time, and the detail header fell back to the
/// raw `date` string. Always parse session/plan timestamps through this helper so both
/// the whole-second (locally written) and fractional-second (synced) forms are accepted.
enum ISO8601 {
    // ISO8601DateFormatter is thread-safe for parsing; nonisolated(unsafe) silences the
    // Swift 6 global-state check (matches the convention used elsewhere in the app).
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse an ISO8601 timestamp, accepting both fractional- and whole-second forms.
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}
