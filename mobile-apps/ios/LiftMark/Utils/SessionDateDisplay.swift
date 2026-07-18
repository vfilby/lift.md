import Foundation

/// Display formatting for a completed workout session's date / time / duration header.
///
/// Pure functions so the fractional-seconds tolerance (via ``ISO8601``) and the
/// date-only fallback are unit-testable and shared between the History list card and
/// the History detail header. The detail header previously rendered the raw ISO `date`
/// string ("2026-06-02") whenever `startTime` was missing or unparseable; these helpers
/// always produce a human-readable date.
enum SessionDateDisplay {
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    /// Parses the `date` field, which is a calendar date ("yyyy-MM-dd") with no zone.
    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Full weekday/month/day/year line, e.g. "Tuesday, June 2, 2026".
    /// Prefers the parsed `startTime`; falls back to the `date` (yyyy-MM-dd) calendar
    /// date; only returns the raw `date` string if neither can be parsed.
    static func fullDateLine(startTime: String?, date: String) -> String {
        if let parsed = ISO8601.parse(startTime) {
            return fullDateFormatter.string(from: parsed)
        }
        if let dateOnly = dateOnlyFormatter.date(from: String(date.prefix(10))) {
            return fullDateFormatter.string(from: dateOnly)
        }
        return date
    }

    /// Short localized start time, e.g. "4:32 PM", or `nil` when `startTime` is missing
    /// or unparseable.
    static func shortTime(startTime: String?) -> String? {
        guard let parsed = ISO8601.parse(startTime) else { return nil }
        return shortTimeFormatter.string(from: parsed)
    }

    /// Human duration from a count of seconds, e.g. "51 min" or "1h 20m". `nil` when
    /// no duration is recorded.
    static func duration(seconds: Int?) -> String? {
        guard let seconds else { return nil }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) min"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
