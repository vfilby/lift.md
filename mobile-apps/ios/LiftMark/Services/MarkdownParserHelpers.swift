import Foundation

// Parse result / internal parse types live in MarkdownParserTypes.swift.
// Modifier parsing helpers live in MarkdownParser+Modifiers.swift.

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
            context.errors.append(ParseError(
                line: lineNumber,
                message: "Distance must be positive",
                code: "INVALID_DISTANCE"
            ))
            return nil
        }

        let unit = normalizeDistanceUnit(unitStr)
        return (
            ParsedSet(distance: value, distanceUnit: unit),
            trailing?.isEmpty == true ? nil : trailing
        )
    }

    /// Parse a positive reps-or-time value into reps or seconds, emitting
    /// INVALID_REPS_TIME / HIGH_REPS diagnostics as needed. Exactly one of the
    /// returned tuple's members is non-nil.
    static func parseRepsOrTimeValue(
        _ repsOrTimeStr: String,
        unit: String?,
        context: ParseContext,
        lineNumber: Int
    ) -> (reps: Int?, time: Int?)? {
        let value = Int(repsOrTimeStr)!
        if value <= 0 {
            context.errors.append(ParseError(
                line: lineNumber,
                message: "Reps/time must be positive",
                code: "INVALID_REPS_TIME"
            ))
            return nil
        }

        let isTime = unit.map { $0.lowercased().hasPrefix("s") || $0.lowercased().hasPrefix("m") } ?? false
        if isTime {
            return (reps: nil, time: normalizeTimeToSeconds(value, unit: unit))
        }

        if value > 100 {
            context.warnings.append(ParseWarning(
                line: lineNumber,
                message: "Very high rep count (\(value)). Double-check for typos.",
                code: "HIGH_REPS"
            ))
        }
        return (reps: value, time: nil)
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
            context.errors.append(ParseError(
                line: lineNumber,
                message: "Weight cannot be negative",
                code: "NEGATIVE_WEIGHT"
            ))
            return nil
        }

        let isBW = unitStr?.lowercased() == "bw"

        // Check if it's AMRAP
        if repsOrTimeStr == "amrap" {
            return (
                ParsedSet(
                    weight: isBW ? nil : weight,
                    weightUnit: isBW ? nil : weightUnit,
                    isAmrap: true
                ),
                trailing?.isEmpty == true ? nil : trailing
            )
        }

        guard let repsTime = parseRepsOrTimeValue(
            repsOrTimeStr, unit: repsUnitStr, context: context, lineNumber: lineNumber
        ) else { return nil }

        return (
            ParsedSet(
                weight: isBW ? nil : weight,
                weightUnit: isBW ? nil : weightUnit,
                reps: repsTime.reps,
                time: repsTime.time
            ),
            trailing?.isEmpty == true ? nil : trailing
        )
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

        guard let repsTime = parseRepsOrTimeValue(
            repsOrTimeStr, unit: repsUnitStr, context: context, lineNumber: lineNumber
        ) else { return nil }

        return (
            ParsedSet(reps: repsTime.reps, time: repsTime.time),
            trailing?.isEmpty == true ? nil : trailing
        )
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

        guard let repsTime = parseRepsOrTimeValue(
            valueStr, unit: unitStr, context: context, lineNumber: lineNumber
        ) else { return nil }

        return (
            ParsedSet(reps: repsTime.reps, time: repsTime.time),
            trailing?.isEmpty == true ? nil : trailing
        )
    }
}
