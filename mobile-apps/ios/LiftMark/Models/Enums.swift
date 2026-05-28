import Foundation

// MARK: - Weight Unit

enum WeightUnit: String, Codable, Hashable, CaseIterable {
    case lbs
    case kg
}

// MARK: - Distance Unit

enum DistanceUnit: String, Codable, Hashable, CaseIterable {
    case meters
    case km
    case miles
    case feet
    case yards
}

// MARK: - Set Status (SessionSet lifecycle)

enum SetStatus: String, Codable, Hashable, CaseIterable {
    case pending
    case completed
    case skipped
    case failed
}

// MARK: - Exercise Status (SessionExercise lifecycle)

enum ExerciseStatus: String, Codable, Hashable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed
    case skipped
}

// MARK: - Session Status (WorkoutSession lifecycle)

enum SessionStatus: String, Codable, Hashable, CaseIterable {
    case inProgress = "in_progress"
    case completed
    case canceled
}

// MARK: - Group Type

enum GroupType: String, Codable, Hashable, CaseIterable {
    case superset
    case section
}

/// Shared rules for grouping exercises into supersets.
///
/// A superset only means something when it has two or more members to
/// alternate between. A "single-member superset" (a superset block that
/// happens to contain exactly one exercise — almost always an authoring
/// mistake) is not a real superset: there is nothing to alternate with.
/// Both the plan (pre-start) view and the active (in-progress) view use
/// this predicate so they render single-member supersets identically — as
/// a standalone exercise with no SUPERSET badge or grouped card.
enum SupersetGrouping {
    /// Minimum number of child exercises required for a superset to be
    /// rendered as a grouped superset.
    static let minimumMembers = 2

    /// True when a collection of superset children is large enough to be
    /// treated as a real (grouped) superset.
    static func isRealSuperset(childCount: Int) -> Bool {
        childCount >= minimumMembers
    }
}

// MARK: - Theme

enum AppTheme: String, Codable, Hashable, CaseIterable {
    case light
    case dark
    case auto
}

// MARK: - API Key Status

enum ApiKeyStatus: String, Codable, Hashable, CaseIterable {
    case verified
    case invalid
    case notSet = "not_set"
}

// MARK: - Chart Metric Type

enum ChartMetricType: String, Codable, Hashable, CaseIterable {
    case maxWeight
    case totalVolume
    case reps
    case time
}

// MARK: - Trend

enum Trend: String, Codable, Hashable, CaseIterable {
    case improving
    case stable
    case declining
}
