import Foundation

// MARK: - MarkdownParser Exercise Parsing

extension MarkdownParser {

    /// Parse all exercises in the workout
    static func parseExercises(_ context: ParseContext, workoutPlanId: String) -> [PlannedExercise] {
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
        let parsedSets = parseSets(context, exerciseHeaderLevel: headerLevel, exerciseId: exerciseId)

        // Auto-detect per-side keywords in exercise notes flag timed sets as isPerSide
        let sets = applyPerSideFromNotes(parsedSets, notes: notes)

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

    /// Flag timed sets as per-side when the exercise notes contain a per-side keyword
    private static func applyPerSideFromNotes(_ sets: [PlannedSet], notes: String?) -> [PlannedSet] {
        guard let notes = notes,
              perSideKeywords.contains(where: { notes.range(of: $0, options: .caseInsensitive) != nil }) else {
            return sets
        }
        return sets.map { set in
            guard set.targetTime != nil, !set.isPerSide else { return set }
            var modified = set
            modified.isPerSide = true
            return modified
        }
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

    /// Group attributes shared while parsing a superset/section's children
    private struct GroupParseInfo {
        let parentId: String
        let parentHeaderLevel: Int
        let childExerciseLevel: Int?
        let groupType: GroupType
        let groupName: String
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
        let childExerciseLevel = findChildExerciseLevel(
            context, startIndex: context.currentIndex, parentLevel: headerLine.headerLevel!
        )

        let group = GroupParseInfo(
            parentId: parentId,
            parentHeaderLevel: headerLine.headerLevel!,
            childExerciseLevel: childExerciseLevel,
            groupType: groupType,
            groupName: groupName
        )

        // Parse child exercises
        let childExercises = parseGroupChildren(
            context, workoutPlanId: workoutPlanId, orderIndex: orderIndex, group: group
        )

        context.spans[orderIndex] = LMWFSourceSpan(
            startLine: headerLine.lineNumber,
            endLine: context.blockEndLine(startIndex: blockStartIndex, stopIndex: context.currentIndex),
            headerLevel: headerLine.headerLevel!,
            childHeaderLevel: childExerciseLevel
        )

        return [parentExercise] + childExercises
    }

    /// Parse the child exercises of a group until its block ends
    private static func parseGroupChildren(
        _ context: ParseContext,
        workoutPlanId: String,
        orderIndex: Int,
        group: GroupParseInfo
    ) -> [PlannedExercise] {
        var childExercises: [PlannedExercise] = []
        var childOrderIndex = 0

        while context.currentIndex < context.lines.count {
            let line = context.lines[context.currentIndex]

            // Stop at same or higher level header
            if let level = line.headerLevel, level <= group.parentHeaderLevel {
                break
            }

            // Parse child exercise at the determined child level
            if let childLevel = group.childExerciseLevel, line.headerLevel == childLevel {
                let result = parseExerciseBlock(
                    context, workoutPlanId: workoutPlanId, orderIndex: orderIndex + childOrderIndex + 1
                )
                switch result {
                case .single(var exercise):
                    adoptSingleChild(&exercise, group: group)
                    childExercises.append(exercise)
                    childOrderIndex += 1
                case .group(var exercises):
                    adoptGroupChildren(&exercises, group: group)
                    childExercises.append(contentsOf: exercises)
                    childOrderIndex += exercises.count
                case .none:
                    break
                }
            } else {
                context.currentIndex += 1
            }
        }

        return childExercises
    }

    /// Attach a single child exercise to its parent group
    private static func adoptSingleChild(_ exercise: inout PlannedExercise, group: GroupParseInfo) {
        if exercise.parentExerciseId == nil {
            exercise.parentExerciseId = group.parentId
        }
        if exercise.groupType == nil {
            exercise.groupType = group.groupType
            exercise.groupName = group.groupName
        }
    }

    /// Attach a nested group's exercises to the outer parent group
    private static func adoptGroupChildren(_ exercises: inout [PlannedExercise], group: GroupParseInfo) {
        for i in 0..<exercises.count {
            if exercises[i].parentExerciseId == nil {
                exercises[i].parentExerciseId = group.parentId
            }
            if exercises[i].groupType != .superset || exercises[i].sets.isEmpty {
                if exercises[i].groupType == nil {
                    exercises[i].groupType = group.groupType
                    exercises[i].groupName = group.groupName
                }
            }
        }
    }

    /// Parse exercise metadata (@type, freeform notes)
    private static func parseExerciseMetadata(
        _ context: ParseContext,
        exerciseHeaderLevel: Int
    ) -> (equipmentType: String?, notes: String?) {
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
}
