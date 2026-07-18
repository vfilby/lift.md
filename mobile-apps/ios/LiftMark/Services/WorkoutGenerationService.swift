import Foundation

// MARK: - Types

struct AIPromptToggles: Equatable {
    var includeFormatPointer: Bool
    var includeRecentWorkouts: Bool
    var includeProgression: Bool
    var includeEquipment: Bool

    static let all = AIPromptToggles(
        includeFormatPointer: true,
        includeRecentWorkouts: true,
        includeProgression: true,
        includeEquipment: true
    )

    static let none = AIPromptToggles(
        includeFormatPointer: false,
        includeRecentWorkouts: false,
        includeProgression: false,
        includeEquipment: false
    )
}

struct WorkoutGenerationContext {
    var defaultWeightUnit: WeightUnit
    var customPromptAddition: String?
    var recentWorkouts: String
    var progression: String
    var availableEquipment: [String]
    var currentGym: String?
    var toggles: AIPromptToggles
}

struct WorkoutGenerationParams {
    var intent: String?
    var duration: WorkoutDuration?
    var difficulty: WorkoutDifficulty?
    var focusAreas: [String]?
    var equipmentOverride: [String]?
}

enum WorkoutDuration: String {
    case short   // ~30 min
    case medium  // ~60 min
    case long    // ~90 min
}

enum WorkoutDifficulty: String {
    case beginner
    case intermediate
    case advanced
}

struct WorkoutValidationResult {
    var valid: Bool
    var issues: [String]
    var warnings: [String]
}

// MARK: - WorkoutGenerationService

enum WorkoutGenerationService {

    static let lmwfSpecURL = "https://getlift.md/spec.md"

    // MARK: - Prompt Building

    /// Compose the AI prompt from independently-toggleable context blocks.
    /// Pure function — the `GeneratePromptView` uses this for both the live preview and
    /// the actual API call, so the user sees exactly what will be sent.
    static func buildWorkoutGenerationPrompt(
        context: WorkoutGenerationContext,
        params: WorkoutGenerationParams
    ) -> String {
        var sections: [String] = []

        sections.append(
            "You are a professional strength coach creating a personalized workout plan in lift.md format (LMWF)."
        )

        let userContext = buildUserContextSection(context: context, params: params)
        if !userContext.isEmpty {
            sections.append(userContext)
        }

        if context.toggles.includeFormatPointer {
            sections.append(formatPointerBlock(unit: context.defaultWeightUnit))
        }

        if let request = buildRequestSection(params: params, context: context) {
            sections.append(request)
        }

        sections.append("""
        # OUTPUT INSTRUCTIONS

        Output ONLY the workout in lift.md format. No preamble, no explanation, no surrounding prose \
        — the response will be parsed directly.
        """)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Block Composers

    private static func buildUserContextSection(
        context: WorkoutGenerationContext,
        params: WorkoutGenerationParams
    ) -> String {
        var blocks: [String] = []

        if context.toggles.includeRecentWorkouts,
           !context.recentWorkouts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append("""
            ## Recent Training History
            \(context.recentWorkouts)
            """)
        }

        if context.toggles.includeProgression,
           !context.progression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append("""
            ## Progression
            \(context.progression)
            """)
        }

        if context.toggles.includeEquipment {
            let equipment = params.equipmentOverride ?? context.availableEquipment
            let equipmentList = equipment.isEmpty ? "full commercial gym equipment" : equipment.joined(separator: ", ")
            let gymLine = context.currentGym.map { "Gym: \($0)\n" } ?? ""
            blocks.append("""
            ## Current Gym & Equipment
            \(gymLine)Available equipment: \(equipmentList)
            """)
        }

        var prefs = ["- Weight unit: \(context.defaultWeightUnit.rawValue)"]
        if let custom = context.customPromptAddition?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            prefs.append("- Custom notes: \(custom)")
        }
        blocks.append("""
        ## Preferences
        \(prefs.joined(separator: "\n"))
        """)

        return "# USER CONTEXT\n\n" + blocks.joined(separator: "\n\n")
    }

    private static func formatPointerBlock(unit: WeightUnit) -> String {
        """
        # lift.md FORMAT

        Output valid lift.md format (LMWF) markdown — full spec at \(lmwfSpecURL)

        Minimal shape:
        ```
        # Workout Name
        @tags: tag1, tag2
        @units: \(unit.rawValue)

        ## Exercise Name
        - 135 x 5 @rest: 120s
        - 185 x 5
        ```

        Use nested headers (`###` under a `## Superset:` parent) for supersets/circuits.
        Functional modifiers: `@rest: 120s`, `@dropset`, `@perside` \
        (primarily for timed per-side sets, e.g. `30s @perside`).
        For AMRAP, use the rep value (`- 135 x AMRAP` or `- bw x AMRAP`) — there is no `@amrap` modifier.
        """
    }

    private static func buildRequestSection(
        params: WorkoutGenerationParams,
        context: WorkoutGenerationContext
    ) -> String? {
        let intent = params.intent?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intent, !intent.isEmpty else { return nil }

        var lines = ["Generate a workout for: \(intent)"]

        if let duration = params.duration {
            let guidance: String
            switch duration {
            case .short: guidance = "~30 minutes (4–5 exercises, 12–15 working sets)"
            case .medium: guidance = "~60 minutes (6–8 exercises, 18–24 working sets)"
            case .long: guidance = "~90 minutes (8–10 exercises, 25–30 working sets)"
            }
            lines.append("Target duration: \(guidance)")
        }
        if let difficulty = params.difficulty {
            lines.append("Target difficulty: \(difficulty.rawValue)")
        }
        if let focus = params.focusAreas, !focus.isEmpty {
            lines.append("Focus areas: \(focus.joined(separator: ", "))")
        }

        var requirements: [String] = ["1. Match the stated intent."]
        if context.toggles.includeProgression || context.toggles.includeRecentWorkouts {
            requirements.append(
                "2. Base weights and exercise selection on the recent training history / progression above."
            )
        }
        if context.toggles.includeEquipment {
            requirements.append("\(requirements.count + 1). Only use equipment from the available list above.")
        }
        if context.toggles.includeRecentWorkouts {
            requirements.append(
                "\(requirements.count + 1). Consider recency and volume of similar movements for recovery."
            )
        }

        return """
        # WORKOUT REQUEST

        \(lines.joined(separator: "\n"))

        # REQUIREMENTS

        \(requirements.joined(separator: "\n"))
        """
    }

    // MARK: - AI Response Parsing

    /// Parse the AI's markdown response into a WorkoutPlan using the LMWF parser.
    static func parseAIWorkoutResponse(markdown: String, defaultWeightUnit: WeightUnit) throws -> WorkoutPlan {
        let result = MarkdownParser.parseWorkout(markdown)

        guard result.success, var workout = result.data else {
            let errorMessages = result.errors.joined(separator: "; ")
            throw WorkoutGenerationError.parseFailed(errorMessages.isEmpty ? "Unknown parse error" : errorMessages)
        }

        guard !workout.name.isEmpty, !workout.exercises.isEmpty else {
            throw WorkoutGenerationError.parseFailed("Invalid workout: missing name or exercises")
        }

        if workout.defaultWeightUnit == nil {
            workout.defaultWeightUnit = defaultWeightUnit
        }

        workout.sourceMarkdown = markdown

        return workout
    }

    // MARK: - Validation

    /// Validate that a generated workout meets quality standards.
    static func validateGeneratedWorkout(_ workout: WorkoutPlan) -> WorkoutValidationResult {
        var issues: [String] = []
        var warnings: [String] = []

        // Required fields
        if workout.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("Workout name is required")
        }

        if workout.exercises.isEmpty {
            issues.append("Workout must have at least one exercise")
        }

        // Exercise validation
        for (idx, exercise) in workout.exercises.enumerated() {
            if exercise.exerciseName.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("Exercise \(idx + 1) is missing a name")
            }

            if exercise.sets.isEmpty {
                warnings.append("Exercise \"\(exercise.exerciseName)\" has no sets")
            }

            // Set validation
            for (setIdx, set) in exercise.sets.enumerated() {
                let target = set.entries.first?.target
                let hasWeight = target?.weight?.value != nil
                let hasReps = target?.reps != nil
                let hasTime = target?.time != nil

                if !hasWeight && !hasReps && !hasTime {
                    issues.append(
                        "Exercise \"\(exercise.exerciseName)\", set \(setIdx + 1): must specify weight, reps, or time"
                    )
                }

                if hasWeight && target?.weight?.unit == nil {
                    warnings.append(
                        "Exercise \"\(exercise.exerciseName)\", set \(setIdx + 1): weight specified without unit"
                    )
                }

                if let rpe = target?.rpe, rpe < 1 || rpe > 10 {
                    issues.append(
                        "Exercise \"\(exercise.exerciseName)\", set \(setIdx + 1): RPE must be between 1 and 10"
                    )
                }
            }
        }

        // Quality warnings
        let totalWorkingSets = workout.exercises.reduce(0) { $0 + $1.sets.count }
        if totalWorkingSets < 8 {
            warnings.append("Low total volume: only \(totalWorkingSets) working sets")
        }
        if totalWorkingSets > 40 {
            warnings.append("Very high volume: \(totalWorkingSets) working sets may be too much")
        }

        return WorkoutValidationResult(
            valid: issues.isEmpty,
            issues: issues,
            warnings: warnings
        )
    }
}

// MARK: - Errors

enum WorkoutGenerationError: LocalizedError {
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .parseFailed(let reason):
            return "Failed to parse AI workout response: \(reason)"
        }
    }
}
