import Foundation

// MARK: - MarkdownParser Set Parsing

extension MarkdownParser {

    /// Parse all sets for an exercise
    static func parseSets(
        _ context: ParseContext,
        exerciseHeaderLevel: Int,
        exerciseId: String
    ) -> [PlannedSet] {
        var sets: [PlannedSet] = []
        var orderIndex = 0

        while context.currentIndex < context.lines.count {
            let line = context.lines[context.currentIndex]

            // Stop at headers at or above exercise level
            if let level = line.headerLevel, level <= exerciseHeaderLevel {
                break
            }

            // Parse set (list item)
            if line.isList, let listContent = line.listContent {
                if let parsedSet = parseSetLine(listContent, context: context, lineNumber: line.lineNumber) {
                    sets.append(PlannedSet(
                        id: generateId(),
                        plannedExerciseId: exerciseId,
                        orderIndex: orderIndex,
                        targetWeight: parsedSet.weight,
                        targetWeightUnit: parsedSet.weightUnit,
                        targetReps: parsedSet.reps,
                        targetTime: parsedSet.time,
                        targetDistance: parsedSet.distance,
                        targetDistanceUnit: parsedSet.distanceUnit,
                        targetRpe: parsedSet.rpe.map { Int($0.rounded()) },
                        restSeconds: parsedSet.rest,
                        tempo: parsedSet.tempo,
                        isDropset: parsedSet.isDropset ?? false,
                        isPerSide: parsedSet.isPerSide ?? false,
                        isAmrap: parsedSet.isAmrap ?? false,
                        notes: parsedSet.notes
                    ))
                    orderIndex += 1
                }
                context.currentIndex += 1
            } else {
                context.currentIndex += 1
            }
        }

        return sets
    }

    /// Parse a single set line
    private static func parseSetLine(_ content: String, context: ParseContext, lineNumber: Int) -> ParsedSet? {
        // Split on @ to separate main content from modifiers
        let parts = content.components(separatedBy: "@")
        let mainPart = parts[0].trimmingCharacters(in: .whitespaces)
        let modifierParts = Array(parts.dropFirst())

        // Parse modifiers and extract trailing text
        let (modifiers, modifierTrailingText) = parseModifiersAndTrailingText(
            modifierParts, context: context, lineNumber: lineNumber
        )

        // Parse main set content
        guard let (setResult, mainTrailingText) = parseMainSetContent(
            mainPart, context: context, lineNumber: lineNumber
        ) else {
            return nil
        }

        // Combine trailing text
        let combined = [mainTrailingText, modifierTrailingText].compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        // Merge modifiers into set
        var result = setResult
        mergeModifiers(modifiers, into: &result, combined: combined)

        // Auto-detect per-side keywords in set-line trailing text for timed sets
        applyPerSideAutoDetection(to: &result, combined: combined)

        return result
    }

    /// Merge parsed modifier values and combined trailing text into the set
    private static func mergeModifiers(_ modifiers: ParsedSet, into result: inout ParsedSet, combined: String) {
        if let rpe = modifiers.rpe { result.rpe = rpe }
        if let rest = modifiers.rest { result.rest = rest }
        if let tempo = modifiers.tempo { result.tempo = tempo }
        if let isDropset = modifiers.isDropset { result.isDropset = isDropset }
        if let isPerSide = modifiers.isPerSide { result.isPerSide = isPerSide }
        if !combined.isEmpty { result.notes = combined }
    }

    /// Flag a timed set as per-side when its trailing text contains a per-side keyword
    private static func applyPerSideAutoDetection(to result: inout ParsedSet, combined: String) {
        guard result.time != nil && result.isPerSide != true else { return }
        let textToCheck = combined
        guard !textToCheck.isEmpty,
              perSideKeywords.contains(where: { textToCheck.range(of: $0, options: .caseInsensitive) != nil }) else {
            return
        }
        result.isPerSide = true
        // Strip the per-side keyword from notes since it's now conveyed by the flag
        var cleaned = textToCheck
        for keyword in perSideKeywords {
            if let range = cleaned.range(of: keyword, options: .caseInsensitive) {
                cleaned.replaceSubrange(range, with: "")
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        result.notes = cleaned.isEmpty ? nil : cleaned
    }

    /// Parse the main set content (before modifiers)
    private static func parseMainSetContent(
        _ content: String,
        context: ParseContext,
        lineNumber: Int
    ) -> (set: ParsedSet, trailingText: String?)? {
        let original = content.trimmingCharacters(in: .whitespaces)
        let trimmedLower = original.lowercased()

        // Reject standalone AMRAP
        if trimmedLower == "amrap" {
            context.errors.append(ParseError(
                line: lineNumber,
                message: "Standalone \"AMRAP\" is not valid. AMRAP must be used with a weight "
                    + "(e.g., \"135 x AMRAP\" or \"bw x AMRAP\")",
                code: "STANDALONE_AMRAP"
            ))
            return nil
        }

        // Try each pattern in priority order
        if let result = parseDistanceSet(original, context: context, lineNumber: lineNumber) {
            return result
        }
        if let result = parseWeightAndRepsSet(original, context: context, lineNumber: lineNumber) {
            return result
        }
        if let result = parseBodyweightSet(original, context: context, lineNumber: lineNumber) {
            return result
        }
        if let result = parseBareValueSet(original, content: content, context: context, lineNumber: lineNumber) {
            return result
        }

        // Failed to parse
        context.errors.append(ParseError(
            line: lineNumber,
            message: "Invalid set format: \"\(content)\". Expected format: "
                + "\"weight unit x reps\" or \"time\" or \"AMRAP\"",
            code: "INVALID_SET_FORMAT"
        ))
        return nil
    }
}
