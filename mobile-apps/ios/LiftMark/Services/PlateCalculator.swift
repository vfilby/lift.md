import Foundation

/// Breakdown of plates needed per side for a barbell exercise.
struct PlateBreakdown {
    /// Total weight per side (excluding bar)
    let weightPerSide: Double
    /// Unit of measurement
    let unit: String // "lbs" or "kg"
    /// Plates needed per side, heaviest first
    let plates: [(weight: Double, count: Int)]
    /// Whether the target weight is exactly achievable with standard plates
    let isAchievable: Bool
    /// Remaining weight if not achievable
    let remainder: Double?
    /// Bar weight used in calculation
    let barWeight: Double
}

/// Pure functions for plate math calculations on barbell exercises.
enum PlateCalculator {

    // MARK: - Constants

    private static let standardPlatesLbs: [Double] = [45, 35, 25, 10, 5, 2.5]
    private static let standardPlatesKg: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]
    private static let standardBarWeightLbs: Double = 45
    private static let standardBarWeightKg: Double = 20

    private static let excludeKeywords = ["dumbbell", "kettlebell", "bodyweight", "cable", "machine"]
    private static let knownBarbellExercises = [
        "deadlift", "bench press", "overhead press", "strict press",
        "power clean", "hang clean", "clean and jerk", "snatch",
        "front squat", "back squat", "romanian deadlift", "rdl",
        "bent over row", "pendlay row"
    ]

    // MARK: - Public API

    /// Determines if an exercise uses a barbell and should show the plate calculator.
    ///
    /// Resolves shorthand to canonical names via `ExerciseDictionary` first
    /// (e.g. "Bench" → "Bench Press") so identity-keyed features don't depend
    /// on the user typing the canonical name verbatim. See GH #124.
    static func isBarbellExercise(exerciseName: String, equipmentType: String? = nil) -> Bool {
        // 1. Equipment type contains "barbell"
        if let equipmentType, equipmentType.localizedCaseInsensitiveContains("barbell") {
            return true
        }

        let canonicalName = ExerciseDictionary.getCanonicalName(exerciseName)
        let lowerName = canonicalName.lowercased()

        // 2. Name explicitly mentions barbell
        if lowerName.contains("barbell") {
            return true
        }

        // 3. Exclude other equipment types
        if excludeKeywords.contains(where: { lowerName.contains($0) }) {
            return false
        }

        // 4. Known barbell exercises
        return knownBarbellExercises.contains(where: { lowerName.contains($0) })
    }

    /// Calculates the optimal plate combination using a greedy algorithm.
    static func calculatePlates(totalWeight: Double, unit: String = "lbs", barWeight: Double? = nil) -> PlateBreakdown {
        let bar = barWeight ?? (unit == "lbs" ? standardBarWeightLbs : standardBarWeightKg)
        let weightForPlates = totalWeight - bar
        let weightPerSide = weightForPlates / 2.0

        // Can't have negative weight
        if weightPerSide < 0 {
            return PlateBreakdown(
                weightPerSide: 0,
                unit: unit,
                plates: [],
                isAchievable: false,
                remainder: weightPerSide,
                barWeight: bar
            )
        }

        let availablePlates = unit == "lbs" ? standardPlatesLbs : standardPlatesKg
        var plates: [(weight: Double, count: Int)] = []
        var remaining = weightPerSide

        for plateWeight in availablePlates {
            let count = Int(remaining / plateWeight)
            if count > 0 {
                plates.append((weight: plateWeight, count: count))
                remaining -= Double(count) * plateWeight
            }
        }

        let isAchievable = abs(remaining) < 0.01

        return PlateBreakdown(
            weightPerSide: weightPerSide,
            unit: unit,
            plates: plates,
            isAchievable: isAchievable,
            remainder: isAchievable ? nil : remaining,
            barWeight: bar
        )
    }

    /// Formats plate breakdown as a human-readable per-side string.
    /// Examples: "45lbs + 25lbs", "2x45lbs", "Bar only", "45lbs + 5lbs (+1.3lbs short)"
    static func formatPlateBreakdown(_ breakdown: PlateBreakdown) -> String {
        if breakdown.plates.isEmpty {
            return "Bar only"
        }

        let plateStrings = breakdown.plates.map { weight, count in
            count == 1 ? "\(formatNumber(weight))\(breakdown.unit)" : "\(count)\u{00D7}\(formatNumber(weight))\(breakdown.unit)"
        }

        let result = plateStrings.joined(separator: " + ")

        if let remainder = breakdown.remainder, abs(remainder) > 0.01 {
            return "\(result) (+\(String(format: "%.1f", remainder))\(breakdown.unit) short)"
        }

        return result
    }

    /// Formats complete plate setup including bar weight.
    /// Example: "45lb bar + 90lbs per side"
    static func formatCompletePlateSetup(_ breakdown: PlateBreakdown) -> String {
        if breakdown.plates.isEmpty {
            return "Bar only"
        }

        let unitSingular = breakdown.unit == "lbs" ? "lb" : "kg"
        return "\(formatNumber(breakdown.barWeight))\(unitSingular) bar + \(formatNumber(breakdown.weightPerSide))\(breakdown.unit) per side"
    }

    // MARK: - Private

    private static func formatNumber(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))" : String(format: "%.1f", value)
    }
}
