import Foundation

// MARK: - MarkdownParser Document Structure

extension MarkdownParser {

    // MARK: - Workout Header Detection

    /// Find the workout header — first header that has child headers with sets
    static func findWorkoutHeader(_ context: ParseContext) -> ParsedLine? {
        for i in 0..<context.lines.count {
            let line = context.lines[i]
            if let headerLevel = line.headerLevel, line.headerText != nil {
                if hasChildExercises(context, headerIndex: i, headerLevel: headerLevel) {
                    context.workoutHeaderLevel = headerLevel
                    context.exerciseHeaderLevel = headerLevel + 1
                    context.currentIndex = i
                    return line
                }
            }
        }
        return nil
    }

    // MARK: - Stray Line Warnings

    /// Set-modifier keywords. These only take effect when appended to a set line.
    private static let setModifierKeywords: Set<String> = ["rest", "dropset", "perside", "rpe", "tempo", "amrap"]

    /// True for a non-set, non-header line that begins with a set modifier (e.g. `@rest: 180s`).
    static func isStandaloneModifier(_ line: ParsedLine) -> Bool {
        guard !line.isList, line.headerLevel == nil, line.trimmed.hasPrefix("@") else { return false }
        // Same key shape as the validator's `^@(\w+)` (ASCII word characters)
        let key = line.trimmed.dropFirst().prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        return setModifierKeywords.contains(key.lowercased())
    }

    private static func warningPreview(_ text: String) -> String {
        text.count > 80 ? "\(text.prefix(77))..." : text
    }

    /// Warn on every non-set line inside the workout block that begins with a set
    /// modifier and has no effect — e.g. `@rest: 180s` under the workout or a
    /// section/superset header, or after an exercise's first set (GH #425). An
    /// exercise-level `@rest:` default (consumed by parseExerciseMetadata) is exempt.
    static func warnStandaloneModifiers(_ context: ParseContext, workoutHeaderIndex: Int) {
        for line in context.lines.dropFirst(workoutHeaderIndex + 1) {
            if let level = line.headerLevel, let workoutLevel = context.workoutHeaderLevel, level <= workoutLevel {
                break
            }
            guard isStandaloneModifier(line), !context.exerciseRestDefaultLines.contains(line.lineNumber) else {
                continue
            }
            let text = warningPreview(line.trimmed)
            let restHint = line.metadataKey == "rest"
                ? " To set a default rest for every set of one exercise, put \"@rest:\" directly under "
                    + "that exercise's header, before its first set."
                : ""
            context.warnings.append(ParseWarning(
                line: line.lineNumber,
                message: "Modifier \"\(text)\" is on its own line and has no effect — modifiers only apply when "
                    + "appended to a set line (e.g., \"- 135 lbs x 5 \(text)\"). "
                    + "Add it to each set it should apply to." + restHint,
                code: "STANDALONE_MODIFIER"
            ))
        }
    }

    /// Warn on rest periods that look like typos (shared by set-level and exercise-level @rest).
    static func warnRestRange(_ rest: Int, context: ParseContext, lineNumber: Int) {
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
    }

    /// Warn on a non-empty, non-set line inside an exercise's set list (after its first
    /// set). Such text is skipped without being captured anywhere. Standalone modifiers are
    /// excluded — they already get STANDALONE_MODIFIER.
    static func warnIfIgnoredLine(_ context: ParseContext, line: ParsedLine) {
        guard !line.trimmed.isEmpty, !isStandaloneModifier(line) else { return }
        context.warnings.append(ParseWarning(
            line: line.lineNumber,
            message: "Line ignored: \"\(warningPreview(line.trimmed))\" is not a set and is not captured. "
                + "Put exercise notes between the exercise header and its first set, "
                + "or append per-set notes to the end of a set line.",
            code: "IGNORED_LINE"
        ))
    }

    /// Check if a header has child exercise headers (with sets)
    private static func hasChildExercises(_ context: ParseContext, headerIndex: Int, headerLevel: Int) -> Bool {
        let exerciseLevel = headerLevel + 1

        for i in (headerIndex + 1)..<context.lines.count {
            let line = context.lines[i]

            // Stop if we hit a header at same or higher level
            if let level = line.headerLevel, level <= headerLevel {
                break
            }

            // Check if this is an exercise header (one level below workout)
            if line.headerLevel == exerciseLevel {
                if hasSetsBelowHeader(context, headerIndex: i, headerLevel: exerciseLevel) {
                    return true
                }
            }
        }

        return false
    }

    /// Check if a header has sets below it (or nested headers with sets)
    static func hasSetsBelowHeader(_ context: ParseContext, headerIndex: Int, headerLevel: Int) -> Bool {
        for i in (headerIndex + 1)..<context.lines.count {
            let line = context.lines[i]

            // Stop if we hit a header at same or higher level
            if let level = line.headerLevel, level <= headerLevel {
                break
            }

            // Found a set
            if line.isList {
                return true
            }

            // Check nested headers (for supersets/sections)
            if let level = line.headerLevel, level > headerLevel {
                if hasSetsBelowHeader(context, headerIndex: i, headerLevel: level) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Workout Section Parsing

    static func parseWorkoutSection(_ context: ParseContext, headerLine: ParsedLine) -> WorkoutSection {
        let name = headerLine.headerText ?? ""
        var tags: [String] = []
        var defaultWeightUnit: WeightUnit?
        var noteLines: [String] = []

        // Move past header
        context.currentIndex += 1

        // Collect metadata and notes until we hit an exercise header
        while context.currentIndex < context.lines.count {
            let line = context.lines[context.currentIndex]

            // Stop at exercise header
            if line.headerLevel == context.exerciseHeaderLevel {
                break
            }

            // Stop at headers higher than workout level
            if let level = line.headerLevel, let workoutLevel = context.workoutHeaderLevel, level <= workoutLevel {
                break
            }

            // Parse metadata
            if line.isMetadata {
                if line.metadataKey == "tags" {
                    tags = parseTagsMetadata(line.metadataValue ?? "")
                } else if line.metadataKey == "units" {
                    if let unit = parseUnitsMetadata(
                        line.metadataValue ?? "", context: context, lineNumber: line.lineNumber
                    ) {
                        defaultWeightUnit = unit
                    }
                }
                // Ignore unknown metadata (forward compatible)
            } else if !line.trimmed.isEmpty {
                // Collect freeform notes (non-empty, non-metadata lines)
                noteLines.append(line.trimmed)
            }

            context.currentIndex += 1
        }

        return WorkoutSection(
            name: name,
            tags: tags,
            defaultWeightUnit: defaultWeightUnit,
            notes: noteLines.isEmpty ? nil : noteLines.joined(separator: "\n")
        )
    }

    /// Parse @tags metadata: "tag1, tag2, tag3" -> ["tag1", "tag2", "tag3"]
    private static func parseTagsMetadata(_ value: String) -> [String] {
        value.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parse @units metadata: "lbs" or "kg"
    private static func parseUnitsMetadata(_ value: String, context: ParseContext, lineNumber: Int) -> WeightUnit? {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "lbs", "lb":
            return .lbs
        case "kg", "kgs":
            return .kg
        default:
            context.errors.append(ParseError(
                line: lineNumber,
                message: "Invalid @units value \"\(value)\". Must be \"lbs\" or \"kg\"",
                code: "INVALID_UNITS"
            ))
            return nil
        }
    }
}
