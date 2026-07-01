import Foundation

// MARK: - MarkdownParser

enum MarkdownParser {

    // MARK: - Static Regex Patterns (Swift Regex literals, compile-time checked)

    // Line preprocessing patterns
    nonisolated(unsafe) private static let headerRegex = /^(#{1,6})\s+(.+)$/
    nonisolated(unsafe) private static let listRegex = /^-\s+(.+)$/
    nonisolated(unsafe) private static let metadataRegex = /^@(\w+):\s*(.+)$/

    // Set parsing patterns
    // Pattern 1: weight unit x reps/time (e.g., "225 lbs x 5", "45 lbs x 60s")
    nonisolated(unsafe) static let setPattern1 = /(?i)^(\d+(?:\.\d+)?)\s*(lbs?|kgs?|kg|bw)?\s*(?:x|for)\s*(\d+|amrap)\s*(reps?|s|sec|m|min)?(?=\s|$)\s*(.*)$/
    // Pattern 2: bodyweight x|for reps/time (e.g., "x 10", "bw x 12", "bw for 60s")
    nonisolated(unsafe) static let setPattern2 = /(?i)^(?:(bw|x)\s*)?(?:x|for)\s*(\d+|amrap)\s*(reps?|s|sec|m|min)?(?=\s|$)\s*(.*)$/
    // Pattern 3: single number (e.g., "10" = bodyweight reps, "60s" = time)
    nonisolated(unsafe) static let setPattern3 = /(?i)^(\d+)\s*(s|sec|m|min)?(?=\s|$)\s*(.*)$/
    // Pattern 4: distance (e.g., "200 meters", "0.5 km", "1 mile", "3.1 mi")
    nonisolated(unsafe) static let distancePattern = /(?i)^(\d+(?:\.\d+)?)\s*(meters|km|miles?|mi|feet|ft|yards?|yd)(?=\s|$)\s*(.*)$/

    // Modifier parsing patterns
    nonisolated(unsafe) static let modifierPattern = /^(\w+):\s*(.+)$/
    nonisolated(unsafe) static let rpePattern = /^(\d+(?:\.\d+)?)\s*(.*)$/
    nonisolated(unsafe) static let restPattern = /(?i)^(\d+)\s*(s|sec|m|min)?\s*(.*)$/
    nonisolated(unsafe) static let tempoPattern = /^(\d-\d-\d-\d)\s*(.*)$/
    nonisolated(unsafe) static let restTimePattern = /(?i)^(\d+)\s*(s|sec|m|min)?$/

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
        if let defaultUnit = section.defaultWeightUnit {
            for i in exercises.indices {
                for j in exercises[i].sets.indices {
                    if exercises[i].sets[j].targetWeight != nil && exercises[i].sets[j].targetWeightUnit == nil {
                        exercises[i].sets[j].targetWeightUnit = defaultUnit
                    }
                }
            }
        }

        if exercises.isEmpty {
            context.errors.append(ParseError(
                line: workoutHeaderLine.lineNumber,
                message: "Workout must contain at least one exercise",
                code: "NO_EXERCISES"
            ))
        }

        // Check for critical errors
        if !context.errors.isEmpty {
            return LMWFParseResult(
                success: false,
                data: nil,
                errors: context.errors.map { "Line \($0.line): \($0.message)" },
                warnings: context.warnings.map { "Line \($0.line): \($0.message)" }
            )
        }

        // Check for duplicate exercise names
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

        let now = ISO8601DateFormatter().string(from: Date())
        let workout = WorkoutPlan(
            id: workoutId,
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

        return LMWFParseResult(
            success: true,
            data: workout,
            errors: [],
            warnings: context.warnings.map { "Line \($0.line): \($0.message)" },
            exerciseSpans: context.spans
        )
    }

    // MARK: - ID Generation

    private static func generateId() -> String {
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

    // MARK: - Workout Header Detection

    /// Find the workout header — first header that has child headers with sets
    private static func findWorkoutHeader(_ context: ParseContext) -> ParsedLine? {
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
    private static func hasSetsBelowHeader(_ context: ParseContext, headerIndex: Int, headerLevel: Int) -> Bool {
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

    private static func parseWorkoutSection(_ context: ParseContext, headerLine: ParsedLine) -> WorkoutSection {
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
                    if let unit = parseUnitsMetadata(line.metadataValue ?? "", context: context, lineNumber: line.lineNumber) {
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

    // MARK: - Exercise Parsing

    /// Parse all exercises in the workout
    private static func parseExercises(_ context: ParseContext, workoutPlanId: String) -> [PlannedExercise] {
        var exercises: [PlannedExercise] = []
        var orderIndex = 0

        while context.currentIndex < context.lines.count {
            let line = context.lines[context.currentIndex]

            // Stop at headers at or above workout level
            if let level = line.headerLevel, let workoutLevel = context.workoutHeaderLevel, level <= workoutLevel {
                break
            }

            // Parse exercise at expected level
            if line.headerLevel == context.exerciseHeaderLevel {
                let result = parseExerciseBlock(context, workoutPlanId: workoutPlanId, orderIndex: orderIndex)
                switch result {
                case .single(let exercise):
                    exercises.append(exercise)
                    orderIndex += 1
                case .group(let groupExercises):
                    exercises.append(contentsOf: groupExercises)
                    orderIndex += groupExercises.count
                case .none:
                    break
                }
            } else {
                context.currentIndex += 1
            }
        }

        return exercises
    }

    private enum ExerciseBlockResult {
        case single(PlannedExercise)
        case group([PlannedExercise])
        case none
    }

    /// Parse a single exercise block (header, metadata, notes, sets)
    private static func parseExerciseBlock(
        _ context: ParseContext,
        workoutPlanId: String,
        orderIndex: Int
    ) -> ExerciseBlockResult {
        let blockStartIndex = context.currentIndex
        let headerLine = context.lines[context.currentIndex]
        guard let headerLevel = headerLine.headerLevel, let exerciseName = headerLine.headerText else {
            context.currentIndex += 1
            return .none
        }

        let exerciseId = generateId()

        // Check if this is a superset or section (has nested headers)
        let isSuperset = exerciseName.lowercased().contains("superset")
        let hasNested = checkForNestedHeaders(context, headerIndex: context.currentIndex, headerLevel: headerLevel)

        // If it has nested headers, it's either a superset or section
        if hasNested {
            let grouped = parseGroupedExercises(
                context,
                workoutPlanId: workoutPlanId,
                orderIndex: orderIndex,
                groupName: exerciseName,
                isSuperset: isSuperset
            )
            return .group(grouped)
        }

        // Regular exercise (no nested headers)
        context.currentIndex += 1

        // Parse metadata and notes
        let (equipmentType, notes) = parseExerciseMetadata(context, exerciseHeaderLevel: headerLevel)

        // Parse sets
        var sets = parseSets(context, exerciseHeaderLevel: headerLevel, exerciseId: exerciseId)

        // Auto-detect per-side keywords in exercise notes flag timed sets as isPerSide
        let perSideKeywords = ["per side", "per leg", "per arm", "each side", "each leg", "each arm", "each"]
        if let notes = notes, perSideKeywords.contains(where: { notes.range(of: $0, options: .caseInsensitive) != nil }) {
            sets = sets.map { set in
                guard set.targetTime != nil, !set.isPerSide else { return set }
                var modified = set
                modified.isPerSide = true
                return modified
            }
        }

        if sets.isEmpty {
            context.errors.append(ParseError(
                line: headerLine.lineNumber,
                message: "Exercise \"\(exerciseName)\" has no sets",
                code: "NO_SETS"
            ))
        }

        context.spans[orderIndex] = LMWFSourceSpan(
            startLine: headerLine.lineNumber,
            endLine: context.blockEndLine(startIndex: blockStartIndex, stopIndex: context.currentIndex),
            headerLevel: headerLevel,
            childHeaderLevel: nil
        )

        let exercise = PlannedExercise(
            id: exerciseId,
            workoutPlanId: workoutPlanId,
            exerciseName: exerciseName,
            orderIndex: orderIndex,
            notes: notes,
            equipmentType: equipmentType,
            sets: sets
        )
        return .single(exercise)
    }

    /// Check if there are nested headers below current header
    private static func checkForNestedHeaders(_ context: ParseContext, headerIndex: Int, headerLevel: Int) -> Bool {
        for i in (headerIndex + 1)..<context.lines.count {
            let line = context.lines[i]

            // Stop at same or higher level header
            if let level = line.headerLevel, level <= headerLevel {
                break
            }

            // Found nested header at any level below parent
            if let level = line.headerLevel, level > headerLevel {
                return true
            }
        }
        return false
    }

    /// Find the header level of child exercises within a group
    private static func findChildExerciseLevel(_ context: ParseContext, startIndex: Int, parentLevel: Int) -> Int? {
        for i in startIndex..<context.lines.count {
            let line = context.lines[i]

            // Stop at same or higher level header
            if let level = line.headerLevel, level <= parentLevel {
                break
            }

            // Check if this header has sets below it
            if let level = line.headerLevel, level > parentLevel {
                if hasSetsBelowHeader(context, headerIndex: i, headerLevel: level) {
                    return level
                }
            }
        }
        return nil
    }

    /// Parse grouped exercises (superset or section)
    private static func parseGroupedExercises(
        _ context: ParseContext,
        workoutPlanId: String,
        orderIndex: Int,
        groupName: String,
        isSuperset: Bool
    ) -> [PlannedExercise] {
        let blockStartIndex = context.currentIndex
        let headerLine = context.lines[context.currentIndex]
        let parentId = generateId()
        let groupType: GroupType = isSuperset ? .superset : .section

        // Create parent exercise (no sets, just a grouping container)
        let parentExercise = PlannedExercise(
            id: parentId,
            workoutPlanId: workoutPlanId,
            exerciseName: groupName,
            orderIndex: orderIndex,
            groupType: groupType,
            groupName: groupName,
            sets: []
        )

        context.currentIndex += 1

        // Find the first child header level that contains exercises (sets)
        let childExerciseLevel = findChildExerciseLevel(context, startIndex: context.currentIndex, parentLevel: headerLine.headerLevel!)

        // Parse child exercises
        var childExercises: [PlannedExercise] = []
        var childOrderIndex = 0

        while context.currentIndex < context.lines.count {
            let line = context.lines[context.currentIndex]

            // Stop at same or higher level header
            if let level = line.headerLevel, level <= headerLine.headerLevel! {
                break
            }

            // Parse child exercise at the determined child level
            if let childLevel = childExerciseLevel, line.headerLevel == childLevel {
                let result = parseExerciseBlock(context, workoutPlanId: workoutPlanId, orderIndex: orderIndex + childOrderIndex + 1)
                switch result {
                case .single(var exercise):
                    if exercise.parentExerciseId == nil {
                        exercise.parentExerciseId = parentId
                    }
                    if exercise.groupType == nil {
                        exercise.groupType = groupType
                        exercise.groupName = groupName
                    }
                    childExercises.append(exercise)
                    childOrderIndex += 1
                case .group(var exercises):
                    for i in 0..<exercises.count {
                        if exercises[i].parentExerciseId == nil {
                            exercises[i].parentExerciseId = parentId
                        }
                        if exercises[i].groupType != .superset || exercises[i].sets.isEmpty {
                            if exercises[i].groupType == nil {
                                exercises[i].groupType = groupType
                                exercises[i].groupName = groupName
                            }
                        }
                        childExercises.append(exercises[i])
                        childOrderIndex += 1
                    }
                case .none:
                    break
                }
            } else {
                context.currentIndex += 1
            }
        }

        context.spans[orderIndex] = LMWFSourceSpan(
            startLine: headerLine.lineNumber,
            endLine: context.blockEndLine(startIndex: blockStartIndex, stopIndex: context.currentIndex),
            headerLevel: headerLine.headerLevel!,
            childHeaderLevel: childExerciseLevel
        )

        return [parentExercise] + childExercises
    }

    /// Parse exercise metadata (@type, freeform notes)
    private static func parseExerciseMetadata(_ context: ParseContext, exerciseHeaderLevel: Int) -> (equipmentType: String?, notes: String?) {
        var equipmentType: String?
        var noteLines: [String] = []

        while context.currentIndex < context.lines.count {
            let line = context.lines[context.currentIndex]

            // Stop at headers at or above exercise level
            if let level = line.headerLevel, level <= exerciseHeaderLevel {
                break
            }

            // Stop at sets (list items)
            if line.isList {
                break
            }

            // Parse metadata
            if line.isMetadata {
                if line.metadataKey == "type" {
                    equipmentType = line.metadataValue
                }
                // Ignore unknown metadata (forward compatible)
                context.currentIndex += 1
            } else if !line.trimmed.isEmpty {
                noteLines.append(line.trimmed)
                context.currentIndex += 1
            } else {
                context.currentIndex += 1
            }
        }

        return (
            equipmentType: equipmentType,
            notes: noteLines.isEmpty ? nil : noteLines.joined(separator: "\n")
        )
    }

    // MARK: - Set Parsing

    /// Parse all sets for an exercise
    private static func parseSets(_ context: ParseContext, exerciseHeaderLevel: Int, exerciseId: String) -> [PlannedSet] {
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
        let (modifiers, modifierTrailingText) = parseModifiersAndTrailingText(modifierParts, context: context, lineNumber: lineNumber)

        // Parse main set content
        guard let (setResult, mainTrailingText) = parseMainSetContent(mainPart, context: context, lineNumber: lineNumber) else {
            return nil
        }

        // Combine trailing text
        let combined = [mainTrailingText, modifierTrailingText].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        // Merge modifiers into set
        var result = setResult
        if let rpe = modifiers.rpe { result.rpe = rpe }
        if let rest = modifiers.rest { result.rest = rest }
        if let tempo = modifiers.tempo { result.tempo = tempo }
        if let isDropset = modifiers.isDropset { result.isDropset = isDropset }
        if let isPerSide = modifiers.isPerSide { result.isPerSide = isPerSide }
        if !combined.isEmpty { result.notes = combined }

        // Auto-detect per-side keywords in set-line trailing text for timed sets
        if result.time != nil && result.isPerSide != true {
            let perSideKeywords = ["per side", "per leg", "per arm", "each side", "each leg", "each arm", "each"]
            let textToCheck = combined
            if !textToCheck.isEmpty, perSideKeywords.contains(where: { textToCheck.range(of: $0, options: .caseInsensitive) != nil }) {
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
        }

        return result
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
                message: "Standalone \"AMRAP\" is not valid. AMRAP must be used with a weight (e.g., \"135 x AMRAP\" or \"bw x AMRAP\")",
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
            message: "Invalid set format: \"\(content)\". Expected format: \"weight unit x reps\" or \"time\" or \"AMRAP\"",
            code: "INVALID_SET_FORMAT"
        ))
        return nil
    }

    // MARK: - Helpers

    /// Convert an optional Substring to String, returning nil for nil or empty values
    static func nonEmpty(_ sub: Substring?) -> String? {
        guard let sub = sub else { return nil }
        let str = String(sub)
        return str.isEmpty ? nil : str
    }
}
