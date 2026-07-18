import Foundation

// MARK: - MarkdownParser

// The parser is split across focused files:
// - MarkdownParser.swift            — regex patterns, public API, result assembly
// - MarkdownParser+Structure.swift  — workout header detection, workout section parsing
// - MarkdownParser+Exercises.swift  — exercise blocks, groups (supersets/sections)
// - MarkdownParser+Sets.swift       — set lines and main set content
// - MarkdownParser+Modifiers.swift  — @modifier parsing
// - MarkdownParserHelpers.swift     — unit normalization, set pattern helpers
// - MarkdownParserTypes.swift       — parse result / internal parse types

enum MarkdownParser {

    // MARK: - Static Regex Patterns (Swift Regex literals, compile-time checked)

    // Line preprocessing patterns
    nonisolated(unsafe) private static let headerRegex = /^(#{1,6})\s+(.+)$/
    nonisolated(unsafe) private static let listRegex = /^-\s+(.+)$/
    nonisolated(unsafe) private static let metadataRegex = /^@(\w+):\s*(.+)$/

    // Set parsing patterns
    // Pattern 1: weight unit x reps/time (e.g., "225 lbs x 5", "45 lbs x 60s")
    nonisolated(unsafe) static let setPattern1 =
        /(?i)^(\d+(?:\.\d+)?)\s*(lbs?|kgs?|kg|bw)?\s*(?:x|for)\s*(\d+|amrap)\s*(reps?|s|sec|m|min)?(?=\s|$)\s*(.*)$/
    // Pattern 2: bodyweight x|for reps/time (e.g., "x 10", "bw x 12", "bw for 60s")
    nonisolated(unsafe) static let setPattern2 =
        /(?i)^(?:(bw|x)\s*)?(?:x|for)\s*(\d+|amrap)\s*(reps?|s|sec|m|min)?(?=\s|$)\s*(.*)$/
    // Pattern 3: single number (e.g., "10" = bodyweight reps, "60s" = time)
    nonisolated(unsafe) static let setPattern3 = /(?i)^(\d+)\s*(s|sec|m|min)?(?=\s|$)\s*(.*)$/
    // Pattern 4: distance (e.g., "200 meters", "0.5 km", "1 mile", "3.1 mi")
    nonisolated(unsafe) static let distancePattern =
        /(?i)^(\d+(?:\.\d+)?)\s*(meters|km|miles?|mi|feet|ft|yards?|yd)(?=\s|$)\s*(.*)$/

    // Modifier parsing patterns
    nonisolated(unsafe) static let modifierPattern = /^(\w+):\s*(.+)$/
    nonisolated(unsafe) static let rpePattern = /^(\d+(?:\.\d+)?)\s*(.*)$/
    nonisolated(unsafe) static let restPattern = /(?i)^(\d+)\s*(s|sec|m|min)?\s*(.*)$/
    nonisolated(unsafe) static let tempoPattern = /^(\d-\d-\d-\d)\s*(.*)$/
    nonisolated(unsafe) static let restTimePattern = /(?i)^(\d+)\s*(s|sec|m|min)?$/

    // Keywords that flag timed sets as per-side when found in notes or trailing text
    static let perSideKeywords = ["per side", "per leg", "per arm", "each side", "each leg", "each arm", "each"]

    // MARK: - Public API

    /// Parse markdown text into a WorkoutPlan
    static func parseWorkout(_ markdown: String) -> LMWFParseResult {
        let context = ParseContext(lines: preprocessLines(markdown))
        let workoutId = generateId()

        // Find workout header
        guard let workoutHeaderLine = findWorkoutHeader(context) else {
            return LMWFParseResult(
                success: false,
                data: nil,
                errors: ["No workout header found. Must have a header (# Workout Name) with exercises below it."],
                warnings: []
            )
        }

        // Parse workout metadata and notes
        let section = parseWorkoutSection(context, headerLine: workoutHeaderLine)

        // Parse exercises
        var exercises = parseExercises(context, workoutPlanId: workoutId)

        // Apply default weight unit to sets that have a weight but no explicit unit
        applyDefaultWeightUnit(section.defaultWeightUnit, to: &exercises)

        if exercises.isEmpty {
            context.errors.append(ParseError(
                line: workoutHeaderLine.lineNumber,
                message: "Workout must contain at least one exercise",
                code: "NO_EXERCISES"
            ))
        }

        // Check for critical errors
        if !context.errors.isEmpty {
            return failureResult(context)
        }

        // Check for duplicate exercise names
        warnOnDuplicateExerciseNames(exercises, context: context)

        let workout = buildWorkoutPlan(id: workoutId, section: section, markdown: markdown, exercises: exercises)

        return LMWFParseResult(
            success: true,
            data: workout,
            errors: [],
            warnings: context.warnings.map { "Line \($0.line): \($0.message)" },
            exerciseSpans: context.spans
        )
    }

    // MARK: - Result Assembly

    /// Apply default weight unit to sets that have a weight but no explicit unit
    private static func applyDefaultWeightUnit(_ defaultUnit: WeightUnit?, to exercises: inout [PlannedExercise]) {
        guard let defaultUnit = defaultUnit else { return }
        for i in exercises.indices {
            for j in exercises[i].sets.indices {
                if exercises[i].sets[j].targetWeight != nil && exercises[i].sets[j].targetWeightUnit == nil {
                    exercises[i].sets[j].targetWeightUnit = defaultUnit
                }
            }
        }
    }

    /// Warn on duplicate exercise names (case-insensitive)
    private static func warnOnDuplicateExerciseNames(_ exercises: [PlannedExercise], context: ParseContext) {
        var seenExerciseNames: [String: Int] = [:]
        for exercise in exercises {
            let lowerName = exercise.exerciseName.lowercased()
            if let firstLine = seenExerciseNames[lowerName] {
                _ = firstLine // first occurrence tracked for reference
                context.warnings.append(ParseWarning(
                    line: 0,
                    message: "Duplicate exercise name: '\(exercise.exerciseName)'. Consider merging or renaming.",
                    code: "DUPLICATE_EXERCISE_NAME"
                ))
            } else {
                seenExerciseNames[lowerName] = 0
            }
        }
    }

    /// Build a failure result from the context's accumulated errors and warnings
    private static func failureResult(_ context: ParseContext) -> LMWFParseResult {
        LMWFParseResult(
            success: false,
            data: nil,
            errors: context.errors.map { "Line \($0.line): \($0.message)" },
            warnings: context.warnings.map { "Line \($0.line): \($0.message)" }
        )
    }

    /// Assemble the final WorkoutPlan from parsed pieces
    private static func buildWorkoutPlan(
        id: String,
        section: WorkoutSection,
        markdown: String,
        exercises: [PlannedExercise]
    ) -> WorkoutPlan {
        let now = ISO8601DateFormatter().string(from: Date())
        return WorkoutPlan(
            id: id,
            name: section.name,
            description: section.notes,
            tags: section.tags,
            defaultWeightUnit: section.defaultWeightUnit,
            sourceMarkdown: markdown,
            createdAt: now,
            updatedAt: now,
            isFavorite: false,
            exercises: exercises
        )
    }

    // MARK: - ID Generation

    static func generateId() -> String {
        UUID().uuidString.lowercased()
    }

    // MARK: - Line Preprocessing

    private static func preprocessLines(_ markdown: String) -> [ParsedLine] {
        // Normalize line endings (CRLF -> LF, CR -> LF)
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.components(separatedBy: "\n")

        return rawLines.enumerated().map { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let lineNumber = index + 1

            // Parse header (# Header Text)
            if let match = trimmed.wholeMatch(of: Self.headerRegex) {
                return ParsedLine(
                    lineNumber: lineNumber,
                    raw: raw,
                    trimmed: trimmed,
                    headerLevel: match.1.count,
                    headerText: String(match.2).trimmingCharacters(in: .whitespaces)
                )
            }

            // Parse list item (- Content)
            if let match = trimmed.wholeMatch(of: Self.listRegex) {
                return ParsedLine(
                    lineNumber: lineNumber,
                    raw: raw,
                    trimmed: trimmed,
                    isList: true,
                    listContent: String(match.1).trimmingCharacters(in: .whitespaces)
                )
            }

            // Parse metadata (@key: value)
            if let match = trimmed.wholeMatch(of: Self.metadataRegex) {
                return ParsedLine(
                    lineNumber: lineNumber,
                    raw: raw,
                    trimmed: trimmed,
                    isMetadata: true,
                    metadataKey: String(match.1).lowercased(),
                    metadataValue: String(match.2).trimmingCharacters(in: .whitespaces)
                )
            }

            // Regular text
            return ParsedLine(
                lineNumber: lineNumber,
                raw: raw,
                trimmed: trimmed
            )
        }
    }

    // MARK: - Helpers

    /// Convert an optional Substring to String, returning nil for nil or empty values
    static func nonEmpty(_ sub: Substring?) -> String? {
        guard let sub = sub else { return nil }
        let str = String(sub)
        return str.isEmpty ? nil : str
    }
}
