import Foundation

// MARK: - MarkdownParser Modifier Parsing

extension MarkdownParser {

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
                context.errors.append(ParseError(
                    line: lineNumber,
                    message: "RPE must be between 1-10, got: \(rpeStr)",
                    code: "INVALID_RPE"
                ))
            } else {
                let rounded = rpe.rounded()
                let clamped = max(1, min(10, rounded))
                if clamped != rpe {
                    context.warnings.append(ParseWarning(
                        line: lineNumber,
                        message: "RPE rounded to nearest integer (\(rpeStr) \u{2192} \(Int(clamped)))",
                        code: "RPE_ROUNDED"
                    ))
                }
                modifiers.rpe = clamped
                if let remaining = remaining, !remaining.isEmpty { trailingTextParts.append(remaining) }
                context.warnings.append(ParseWarning(
                    line: lineNumber,
                    message: "@rpe is deprecated \u{2014} use freeform notes instead",
                    code: "DEPRECATED_RPE"
                ))
            }
        } else {
            context.errors.append(ParseError(
                line: lineNumber,
                message: "Invalid RPE format: \(value)",
                code: "INVALID_RPE"
            ))
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
                    context.warnings.append(ParseWarning(
                        line: lineNumber,
                        message: "Very short rest period (\(rest)s). Double-check for typos.",
                        code: "SHORT_REST"
                    ))
                }
                if rest > 600 {
                    context.warnings.append(ParseWarning(
                        line: lineNumber,
                        message: "Very long rest period (\(rest)s). Double-check for typos.",
                        code: "LONG_REST"
                    ))
                }
                modifiers.rest = rest
                if let remaining = remaining, !remaining.isEmpty { trailingTextParts.append(remaining) }
            } else {
                context.errors.append(ParseError(
                    line: lineNumber,
                    message: "Invalid rest time format: \(restValue). Expected format: \"180s\" or \"3m\"",
                    code: "INVALID_REST"
                ))
            }
        } else {
            context.errors.append(ParseError(
                line: lineNumber,
                message: "Invalid rest time format: \(value). Expected format: \"180s\" or \"3m\"",
                code: "INVALID_REST"
            ))
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
            context.warnings.append(ParseWarning(
                line: lineNumber,
                message: "@tempo is deprecated \u{2014} use freeform notes instead",
                code: "DEPRECATED_TEMPO"
            ))
        } else {
            context.errors.append(ParseError(
                line: lineNumber,
                message: "Invalid tempo format: \(value). Expected format: \"X-X-X-X\" (e.g., \"3-0-1-0\")",
                code: "INVALID_TEMPO"
            ))
        }
    }

    /// Handle a flag-style modifier (dropset, perside, amrap). Returns true if the part was consumed.
    private static func parseFlagModifier(
        _ trimmed: String,
        into modifiers: inout ParsedSet,
        trailingTextParts: inout [String],
        context: ParseContext,
        lineNumber: Int
    ) -> Bool {
        let lowerTrimmed = trimmed.lowercased()
        if lowerTrimmed.hasPrefix("dropset") {
            modifiers.isDropset = true
            let trailing = String(trimmed.dropFirst("dropset".count)).trimmingCharacters(in: .whitespaces)
            if !trailing.isEmpty { trailingTextParts.append(trailing) }
            return true
        }
        if lowerTrimmed.hasPrefix("perside") {
            modifiers.isPerSide = true
            let trailing = String(trimmed.dropFirst("perside".count)).trimmingCharacters(in: .whitespaces)
            if !trailing.isEmpty { trailingTextParts.append(trailing) }
            return true
        }
        if lowerTrimmed.hasPrefix("amrap") {
            let trailing = String(trimmed.dropFirst("amrap".count)).trimmingCharacters(in: .whitespaces)
            if !trailing.isEmpty { trailingTextParts.append(trailing) }
            context.warnings.append(ParseWarning(
                line: lineNumber,
                message: "@amrap is not a modifier — express AMRAP via the rep value instead "
                    + "(e.g., \"135 x AMRAP\")",
                code: "DEPRECATED_AMRAP"
            ))
            return true
        }
        return false
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

            // Check flag modifiers
            if parseFlagModifier(trimmed, into: &modifiers, trailingTextParts: &trailingTextParts,
                                 context: context, lineNumber: lineNumber) {
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
            case "rpe": parseRpeModifier(value, into: &modifiers, trailingTextParts: &trailingTextParts,
                                         context: context, lineNumber: lineNumber)
            case "rest": parseRestModifier(value, into: &modifiers, trailingTextParts: &trailingTextParts,
                                           context: context, lineNumber: lineNumber)
            case "tempo": parseTempoModifier(value, into: &modifiers, trailingTextParts: &trailingTextParts,
                                             context: context, lineNumber: lineNumber)
            default:
                // Unknown modifier
                context.warnings.append(
                    ParseWarning(line: lineNumber, message: "Unknown modifier: @\(key)", code: "UNKNOWN_MODIFIER"))
                trailingTextParts.append(trimmed)
            }
        }

        return (modifiers, trailingTextParts.isEmpty ? nil : trailingTextParts.joined(separator: " "))
    }
}
