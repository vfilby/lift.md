import Foundation

// MARK: - Parse Result Types

struct LMWFParseResult {
    let success: Bool
    let data: WorkoutPlan?
    let errors: [String]
    let warnings: [String]
    /// Source-line spans for each parsed exercise/group, keyed by the exercise's
    /// `orderIndex`. Lets a caller locate and replace an exercise's exact block
    /// within the original markdown (see `LMWFSourceEditor`) instead of
    /// regenerating the whole document and flattening header levels. Empty on
    /// parse failure and for callers that don't need it.
    var exerciseSpans: [Int: LMWFSourceSpan] = [:]
}

/// The source-line footprint of one exercise (or group) inside a markdown
/// document. Line numbers are 1-based and match `ParsedLine.lineNumber` (i.e.
/// the document with CRLF/CR normalized to LF, split on `\n`).
struct LMWFSourceSpan: Equatable {
    /// 1-based line of this block's header (the `#…` line).
    let startLine: Int
    /// 1-based line of the last content line of the block. Trailing blank lines
    /// that merely separate this block from the next are excluded, so a splice
    /// leaves the surrounding whitespace intact.
    let endLine: Int
    /// Number of `#` on this block's header.
    let headerLevel: Int
    /// For a section/superset parent: the header level of its child exercises.
    /// Supersets may nest children at any level below the parent, so this is the
    /// level actually found in the source rather than an assumed `parent + 1`.
    let childHeaderLevel: Int?
}

struct ParseError {
    let line: Int
    let message: String
    let code: String
}

struct ParseWarning {
    let line: Int
    let message: String
    let code: String
}

// MARK: - Internal Parse Types

struct ParsedLine {
    let lineNumber: Int
    let raw: String
    let trimmed: String
    var headerLevel: Int?
    var headerText: String?
    var isList: Bool = false
    var listContent: String?
    var isMetadata: Bool = false
    var metadataKey: String?
    var metadataValue: String?
}

class ParseContext {
    var lines: [ParsedLine]
    var currentIndex: Int = 0
    var workoutHeaderLevel: Int?
    var exerciseHeaderLevel: Int?
    var errors: [ParseError] = []
    var warnings: [ParseWarning] = []
    /// Source spans collected during parsing, keyed by exercise `orderIndex`.
    var spans: [Int: LMWFSourceSpan] = [:]

    init(lines: [ParsedLine]) {
        self.lines = lines
    }

    /// The last content line of a block spanning source-array indices
    /// `[startIndex, stopIndex)`, skipping trailing blank lines. `stopIndex` is
    /// the first line *after* the block (`currentIndex` once the block is fully
    /// consumed, or `lines.count` at EOF).
    func blockEndLine(startIndex: Int, stopIndex: Int) -> Int {
        var endIndex = min(stopIndex, lines.count) - 1
        while endIndex > startIndex && lines[endIndex].trimmed.isEmpty {
            endIndex -= 1
        }
        return lines[endIndex].lineNumber
    }
}

struct ParsedSet {
    var weight: Double?
    var weightUnit: WeightUnit?
    var reps: Int?
    var time: Int? // seconds
    var distance: Double?
    var distanceUnit: DistanceUnit?
    var isAmrap: Bool?
    var rpe: Double?
    var rest: Int? // seconds
    var tempo: String?
    var isDropset: Bool?
    var isPerSide: Bool?
    var notes: String?
}

struct WorkoutSection {
    let name: String
    let tags: [String]
    let defaultWeightUnit: WeightUnit?
    let notes: String?
}

// MARK: - MarkdownParser Helpers

extension MarkdownParser {

    // MARK: - Unit Normalization

    /// Normalize distance unit to standard format
    static func normalizeDistanceUnit(_ unit: String) -> DistanceUnit {
        let normalized = unit.lowercased().trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "meters": return .meters
        case "km": return .km
        case "mile", "miles", "mi": return .miles
        case "foot", "feet", "ft": return .feet
        case "yard", "yards", "yd": return .yards
        default: return .meters
        }
    }

    /// Normalize weight unit to standard format
    static func normalizeWeightUnit(_ unit: String?) -> WeightUnit? {
        guard let unit = unit else { return nil }
        let normalized = unit.lowercased().trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "lb", "lbs": return .lbs
        case "kg", "kgs": return .kg
        case "bw": return nil // bodyweight — caller handles this
        default: return nil
        }
    }

    /// Normalize time value to seconds
    static func normalizeTimeToSeconds(_ value: Int, unit: String?) -> Int {
        guard let unit = unit else { return value }
        if unit.lowercased().hasPrefix("m") {
            return value * 60
        }
        return value
    }

    /// Parse rest time to seconds
    static func parseRestTime(_ value: String) -> Int? {
        guard let match = value.wholeMatch(of: restTimePattern),
              let num = Int(String(match.1)) else { return nil }

        let unit = match.2.map { String($0).lowercased() } ?? "s"
        if unit.hasPrefix("m") {
            return num * 60
        }
        return num
    }

    // MARK: - Set Pattern Helpers

    /// Try to parse a distance set (e.g., "200 meters", "0.5 km", "1 mile")
    static func parseDistanceSet(
        _ original: String,
        context: ParseContext,
        lineNumber: Int
    ) -> (set: ParsedSet, trailingText: String?)? {
        guard let match = original.wholeMatch(of: distancePattern) else { return nil }

        let valueStr = String(match.1)
        let unitStr = String(match.2)
        let trailing = nonEmpty(match.3)?.trimmingCharacters(in: .whitespaces)

        let value = Double(valueStr)!
        if value <= 0 {
            context.errors.append(ParseError(line: lineNumber, message: "Distance must be positive", code: "INVALID_DISTANCE"))
            return nil
        }

        let unit = normalizeDistanceUnit(unitStr)
        return (
            ParsedSet(distance: value, distanceUnit: unit),
            trailing?.isEmpty == true ? nil : trailing
        )
    }

    /// Try to parse a weight-and-reps set (e.g., "225 lbs x 5", "45 lbs x 60s")
    static func parseWeightAndRepsSet(
        _ original: String,
        context: ParseContext,
        lineNumber: Int
    ) -> (set: ParsedSet, trailingText: String?)? {
        guard let match = original.wholeMatch(of: setPattern1) else { return nil }

        let weightStr = String(match.1)
        let unitStr = match.2.map(String.init)
        let repsOrTimeStr = String(match.3).lowercased()
        let repsUnitStr = match.4.map(String.init)
        let trailing = nonEmpty(match.5)?.trimmingCharacters(in: .whitespaces)

        let weight = Double(weightStr)!
        let weightUnit = normalizeWeightUnit(unitStr)

        if weight < 0 {
            context.errors.append(ParseError(line: lineNumber, message: "Weight cannot be negative", code: "NEGATIVE_WEIGHT"))
            return nil
        }

        // Check if it's AMRAP
        if repsOrTimeStr == "amrap" {
            let isBW = unitStr?.lowercased() == "bw"
            return (
                ParsedSet(
                    weight: isBW ? nil : weight,
                    weightUnit: isBW ? nil : weightUnit,
                    isAmrap: true
                ),
                trailing?.isEmpty == true ? nil : trailing
            )
        }

        let value = Int(repsOrTimeStr)!
        if value <= 0 {
            context.errors.append(ParseError(line: lineNumber, message: "Reps/time must be positive", code: "INVALID_REPS_TIME"))
            return nil
        }

        let isTime = repsUnitStr.map { $0.lowercased().hasPrefix("s") || $0.lowercased().hasPrefix("m") } ?? false
        let isBW = unitStr?.lowercased() == "bw"

        if isTime {
            let seconds = normalizeTimeToSeconds(value, unit: repsUnitStr)
            return (
                ParsedSet(
                    weight: isBW ? nil : weight,
                    weightUnit: isBW ? nil : (weightUnit ?? nil),
                    time: seconds
                ),
                trailing?.isEmpty == true ? nil : trailing
            )
        } else {
            if value > 100 {
                context.warnings.append(ParseWarning(
                    line: lineNumber,
                    message: "Very high rep count (\(value)). Double-check for typos.",
                    code: "HIGH_REPS"
                ))
            }
            return (
                ParsedSet(
                    weight: isBW ? nil : weight,
                    weightUnit: isBW ? nil : (weightUnit ?? nil),
                    reps: value
                ),
                trailing?.isEmpty == true ? nil : trailing
            )
        }
    }

    /// Try to parse a bodyweight set (e.g., "x 10", "bw x 12", "bw for 60s")
    static func parseBodyweightSet(
        _ original: String,
        context: ParseContext,
        lineNumber: Int
    ) -> (set: ParsedSet, trailingText: String?)? {
        guard let match = original.wholeMatch(of: setPattern2) else { return nil }

        let repsOrTimeStr = String(match.2).lowercased()
        let repsUnitStr = match.3.map(String.init)
        let trailing = nonEmpty(match.4)?.trimmingCharacters(in: .whitespaces)

        if repsOrTimeStr == "amrap" {
            return (ParsedSet(isAmrap: true), trailing?.isEmpty == true ? nil : trailing)
        }

        let value = Int(repsOrTimeStr)!
        if value <= 0 {
            context.errors.append(ParseError(line: lineNumber, message: "Reps/time must be positive", code: "INVALID_REPS_TIME"))
            return nil
        }

        let isTime = repsUnitStr.map { $0.lowercased().hasPrefix("s") || $0.lowercased().hasPrefix("m") } ?? false

        if isTime {
            let seconds = normalizeTimeToSeconds(value, unit: repsUnitStr)
            return (ParsedSet(time: seconds), trailing?.isEmpty == true ? nil : trailing)
        } else {
            if value > 100 {
                context.warnings.append(ParseWarning(
                    line: lineNumber,
                    message: "Very high rep count (\(value)). Double-check for typos.",
                    code: "HIGH_REPS"
                ))
            }
            return (ParsedSet(reps: value), trailing?.isEmpty == true ? nil : trailing)
        }
    }

    /// Try to parse a bare value set (e.g., "10" = bodyweight reps, "60s" = time)
    static func parseBareValueSet(
        _ original: String,
        content: String,
        context: ParseContext,
        lineNumber: Int
    ) -> (set: ParsedSet, trailingText: String?)? {
        guard let match = original.wholeMatch(of: setPattern3) else { return nil }

        let valueStr = String(match.1)
        let unitStr = match.2.map(String.init)
        let trailing = nonEmpty(match.3)?.trimmingCharacters(in: .whitespaces)

        // Reject "135 lbs" or "100 kg" — weight unit without reps/time is incomplete
        if unitStr == nil, let trailing = trailing, !trailing.isEmpty {
            let trailingLower = trailing.lowercased()
            if trailingLower.hasPrefix("lb") || trailingLower.hasPrefix("kg") {
                context.errors.append(ParseError(
                    line: lineNumber,
                    message: "Incomplete set: \"\(content)\". Weight with unit requires reps (x 5) or time (x 60s)",
                    code: "INCOMPLETE_SET"
                ))
                return nil
            }
        }

        let value = Int(valueStr)!
        if value <= 0 {
            context.errors.append(ParseError(line: lineNumber, message: "Reps/time must be positive", code: "INVALID_REPS_TIME"))
            return nil
        }

        let isTime = unitStr.map { $0.lowercased().hasPrefix("s") || $0.lowercased().hasPrefix("m") } ?? false

        if isTime {
            let seconds = normalizeTimeToSeconds(value, unit: unitStr)
            return (ParsedSet(time: seconds), trailing?.isEmpty == true ? nil : trailing)
        } else {
            if value > 100 {
                context.warnings.append(ParseWarning(
                    line: lineNumber,
                    message: "Very high rep count (\(value)). Double-check for typos.",
                    code: "HIGH_REPS"
                ))
            }
            return (ParsedSet(reps: value), trailing?.isEmpty == true ? nil : trailing)
        }
    }

    // MARK: - Modifier Parsing Helpers

    /// Parse an @rpe modifier value
    static func parseRpeModifier(
        _ value: String,
        into modifiers: inout ParsedSet,
        trailingTextParts: inout [String],
        context: ParseContext,
        lineNumber: Int
    ) {
        if let rpeMatch = value.wholeMatch(of: rpePattern),
           let rpe = Double(String(rpeMatch.1)) {
            let rpeStr = String(rpeMatch.1)
            let remaining = nonEmpty(rpeMatch.2)?.trimmingCharacters(in: .whitespaces)
            if rpe < 1 || rpe > 10 {
                context.errors.append(ParseError(line: lineNumber, message: "RPE must be between 1-10, got: \(rpeStr)", code: "INVALID_RPE"))
            } else {
                let rounded = rpe.rounded()
                let clamped = max(1, min(10, rounded))
                if clamped != rpe {
                    context.warnings.append(ParseWarning(line: lineNumber, message: "RPE rounded to nearest integer (\(rpeStr) \u{2192} \(Int(clamped)))", code: "RPE_ROUNDED"))
                }
                modifiers.rpe = clamped
                if let remaining = remaining, !remaining.isEmpty { trailingTextParts.append(remaining) }
                context.warnings.append(ParseWarning(line: lineNumber, message: "@rpe is deprecated \u{2014} use freeform notes instead", code: "DEPRECATED_RPE"))
            }
        } else {
            context.errors.append(ParseError(line: lineNumber, message: "Invalid RPE format: \(value)", code: "INVALID_RPE"))
        }
    }

    /// Parse an @rest modifier value
    static func parseRestModifier(
        _ value: String,
        into modifiers: inout ParsedSet,
        trailingTextParts: inout [String],
        context: ParseContext,
        lineNumber: Int
    ) {
        if let restMatch = value.wholeMatch(of: restPattern) {
            let numStr = String(restMatch.1)
            let unitStr = restMatch.2.map(String.init)
            let remaining = nonEmpty(restMatch.3)?.trimmingCharacters(in: .whitespaces)
            let restValue = "\(numStr)\(unitStr ?? "")"
            if let rest = parseRestTime(restValue) {
                if rest < 10 {
                    context.warnings.append(ParseWarning(line: lineNumber, message: "Very short rest period (\(rest)s). Double-check for typos.", code: "SHORT_REST"))
                }
                if rest > 600 {
                    context.warnings.append(ParseWarning(line: lineNumber, message: "Very long rest period (\(rest)s). Double-check for typos.", code: "LONG_REST"))
                }
                modifiers.rest = rest
                if let remaining = remaining, !remaining.isEmpty { trailingTextParts.append(remaining) }
            } else {
                context.errors.append(ParseError(line: lineNumber, message: "Invalid rest time format: \(restValue). Expected format: \"180s\" or \"3m\"", code: "INVALID_REST"))
            }
        } else {
            context.errors.append(ParseError(line: lineNumber, message: "Invalid rest time format: \(value). Expected format: \"180s\" or \"3m\"", code: "INVALID_REST"))
        }
    }

    /// Parse an @tempo modifier value
    static func parseTempoModifier(
        _ value: String,
        into modifiers: inout ParsedSet,
        trailingTextParts: inout [String],
        context: ParseContext,
        lineNumber: Int
    ) {
        if let tempoMatch = value.wholeMatch(of: tempoPattern) {
            modifiers.tempo = String(tempoMatch.1)
            let remaining = nonEmpty(tempoMatch.2)?.trimmingCharacters(in: .whitespaces)
            if let remaining = remaining, !remaining.isEmpty { trailingTextParts.append(remaining) }
            context.warnings.append(ParseWarning(line: lineNumber, message: "@tempo is deprecated \u{2014} use freeform notes instead", code: "DEPRECATED_TEMPO"))
        } else {
            context.errors.append(ParseError(line: lineNumber, message: "Invalid tempo format: \(value). Expected format: \"X-X-X-X\" (e.g., \"3-0-1-0\")", code: "INVALID_TEMPO"))
        }
    }

    /// Parse modifiers and extract trailing text from @ parts
    static func parseModifiersAndTrailingText(
        _ parts: [String],
        context: ParseContext,
        lineNumber: Int
    ) -> (modifiers: ParsedSet, trailingText: String?) {
        var modifiers = ParsedSet()
        var trailingTextParts: [String] = []

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let lowerTrimmed = trimmed.lowercased()

            // Check flag modifiers
            if lowerTrimmed.hasPrefix("dropset") {
                modifiers.isDropset = true
                let trailing = String(trimmed.dropFirst("dropset".count)).trimmingCharacters(in: .whitespaces)
                if !trailing.isEmpty { trailingTextParts.append(trailing) }
                continue
            }
            if lowerTrimmed.hasPrefix("perside") {
                modifiers.isPerSide = true
                let trailing = String(trimmed.dropFirst("perside".count)).trimmingCharacters(in: .whitespaces)
                if !trailing.isEmpty { trailingTextParts.append(trailing) }
                continue
            }
            if lowerTrimmed.hasPrefix("amrap") {
                let trailing = String(trimmed.dropFirst("amrap".count)).trimmingCharacters(in: .whitespaces)
                if !trailing.isEmpty { trailingTextParts.append(trailing) }
                context.warnings.append(ParseWarning(
                    line: lineNumber,
                    message: "@amrap is not a modifier — express AMRAP via the rep value instead (e.g., \"135 x AMRAP\")",
                    code: "DEPRECATED_AMRAP"
                ))
                continue
            }

            // Try to parse as key: value modifier
            guard let match = trimmed.wholeMatch(of: modifierPattern) else {
                // Not a valid modifier, treat as trailing text
                trailingTextParts.append(trimmed)
                continue
            }

            let key = String(match.1).lowercased()
            let value = String(match.2).trimmingCharacters(in: .whitespaces)

            switch key {
            case "rpe":
                parseRpeModifier(value, into: &modifiers, trailingTextParts: &trailingTextParts, context: context, lineNumber: lineNumber)
            case "rest":
                parseRestModifier(value, into: &modifiers, trailingTextParts: &trailingTextParts, context: context, lineNumber: lineNumber)
            case "tempo":
                parseTempoModifier(value, into: &modifiers, trailingTextParts: &trailingTextParts, context: context, lineNumber: lineNumber)
            default:
                // Unknown modifier
                context.warnings.append(ParseWarning(line: lineNumber, message: "Unknown modifier: @\(key)", code: "UNKNOWN_MODIFIER"))
                trailingTextParts.append(trimmed)
            }
        }

        return (modifiers, trailingTextParts.isEmpty ? nil : trailingTextParts.joined(separator: " "))
    }
}
