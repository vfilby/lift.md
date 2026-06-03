import XCTest
@testable import LiftMark

final class WorkoutGenerationServiceTests: XCTestCase {

    // MARK: - buildWorkoutGenerationPrompt

    func testBuildPromptIncludesIntent() {
        let context = makeContext()
        let params = WorkoutGenerationParams(intent: "Upper body hypertrophy")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertTrue(prompt.contains("Upper body hypertrophy"))
    }

    func testBuildPromptIncludesWeightUnit() {
        let context = makeContext(weightUnit: .kg)
        let params = WorkoutGenerationParams(intent: "Push day")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertTrue(prompt.contains("kg"))
    }

    func testBuildPromptIncludesEquipment() {
        let context = makeContext(equipment: ["barbell", "dumbbells", "cables"])
        let params = WorkoutGenerationParams(intent: "Full body")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertTrue(prompt.contains("barbell, dumbbells, cables"))
    }

    func testBuildPromptDefaultsToFullGymWhenNoEquipment() {
        let context = makeContext(equipment: [])
        let params = WorkoutGenerationParams(intent: "Workout")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertTrue(prompt.contains("full commercial gym equipment"))
    }

    func testBuildPromptEquipmentOverride() {
        let context = makeContext(equipment: ["barbell", "dumbbells"])
        let params = WorkoutGenerationParams(intent: "Workout", equipmentOverride: ["kettlebell"])
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertTrue(prompt.contains("kettlebell"))
        XCTAssertFalse(prompt.contains("barbell"))
    }

    func testBuildPromptShortDuration() {
        let params = WorkoutGenerationParams(intent: "Quick workout", duration: .short)
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: makeContext(), params: params)
        XCTAssertTrue(prompt.contains("~30 minutes"))
    }

    func testBuildPromptMediumDuration() {
        let params = WorkoutGenerationParams(intent: "Normal workout", duration: .medium)
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: makeContext(), params: params)
        XCTAssertTrue(prompt.contains("~60 minutes"))
    }

    func testBuildPromptLongDuration() {
        let params = WorkoutGenerationParams(intent: "Long session", duration: .long)
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: makeContext(), params: params)
        XCTAssertTrue(prompt.contains("~90 minutes"))
    }

    func testBuildPromptOmitsDurationWhenNotSpecified() {
        let params = WorkoutGenerationParams(intent: "Workout")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: makeContext(), params: params)
        XCTAssertFalse(prompt.contains("Target duration"))
    }

    func testBuildPromptIncludesDifficulty() {
        let params = WorkoutGenerationParams(intent: "Workout", difficulty: .advanced)
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: makeContext(), params: params)
        XCTAssertTrue(prompt.contains("advanced"))
    }

    func testBuildPromptIncludesFocusAreas() {
        let params = WorkoutGenerationParams(intent: "Workout", focusAreas: ["chest", "triceps"])
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: makeContext(), params: params)
        XCTAssertTrue(prompt.contains("chest, triceps"))
    }

    func testBuildPromptIncludesCustomNotes() {
        let context = makeContext(customPrompt: "I have a shoulder injury, avoid overhead movements")
        let params = WorkoutGenerationParams(intent: "Push day")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertTrue(prompt.contains("shoulder injury"))
    }

    func testBuildPromptOmitsCustomNotesWhenNil() {
        let context = makeContext(customPrompt: nil)
        let params = WorkoutGenerationParams(intent: "Push day")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertFalse(prompt.contains("Custom notes"))
    }

    func testBuildPromptOmitsCustomNotesWhenWhitespaceOnly() {
        let context = makeContext(customPrompt: "   \n\t  ")
        let params = WorkoutGenerationParams(intent: "Push day")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertFalse(prompt.contains("Custom notes"))
    }

    func testBuildPromptPreservesMultiLineCustomNotes() {
        let multiLine = "Line one\nLine two\nLine three"
        let context = makeContext(customPrompt: multiLine)
        let params = WorkoutGenerationParams(intent: "Push day")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertTrue(prompt.contains("Line one"))
        XCTAssertTrue(prompt.contains("Line two"))
        XCTAssertTrue(prompt.contains("Line three"))
    }

    func testBuildPromptIncludesGymName() {
        let context = makeContext(gym: "Iron Paradise")
        let params = WorkoutGenerationParams(intent: "Workout")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertTrue(prompt.contains("Iron Paradise"))
    }

    func testBuildPromptIncludesRecentWorkouts() {
        let context = makeContext(recentWorkouts: "2024-01-14 Push: Bench 225x5")
        let params = WorkoutGenerationParams(intent: "Pull day")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertTrue(prompt.contains("Bench 225x5"))
    }

    func testBuildPromptContainsLMWFFormatPointerWhenToggled() {
        let params = WorkoutGenerationParams(intent: "Workout")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: makeContext(), params: params)
        XCTAssertTrue(prompt.contains("# lift.md FORMAT"))
        XCTAssertTrue(prompt.contains(WorkoutGenerationService.lmwfSpecURL))
        XCTAssertTrue(prompt.contains("@rest:"))
    }

    // MARK: - Toggle behavior

    func testBuildPromptOmitsFormatPointerWhenDisabled() {
        var toggles = AIPromptToggles.all
        toggles.includeFormatPointer = false
        let context = makeContext(toggles: toggles)
        let params = WorkoutGenerationParams(intent: "Workout")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertFalse(prompt.contains("# lift.md FORMAT"))
        XCTAssertFalse(prompt.contains(WorkoutGenerationService.lmwfSpecURL))
    }

    func testBuildPromptOmitsRecentWorkoutsWhenDisabled() {
        var toggles = AIPromptToggles.all
        toggles.includeRecentWorkouts = false
        let context = makeContext(recentWorkouts: "2024-01-14 Push: Bench 225x5", toggles: toggles)
        let params = WorkoutGenerationParams(intent: "Pull day")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertFalse(prompt.contains("Bench 225x5"))
        XCTAssertFalse(prompt.contains("Recent Training History"))
    }

    func testBuildPromptOmitsEquipmentWhenDisabled() {
        var toggles = AIPromptToggles.all
        toggles.includeEquipment = false
        let context = makeContext(equipment: ["barbell", "dumbbells"], toggles: toggles)
        let params = WorkoutGenerationParams(intent: "Workout")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertFalse(prompt.contains("barbell"))
        XCTAssertFalse(prompt.contains("Current Gym & Equipment"))
    }

    func testBuildPromptIncludesProgressionWhenToggled() {
        let context = makeContext(progression: "- Bench: 185x5→195x5")
        let params = WorkoutGenerationParams(intent: "Push day")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertTrue(prompt.contains("## Progression"))
        XCTAssertTrue(prompt.contains("185x5→195x5"))
    }

    func testBuildPromptOmitsProgressionWhenDisabled() {
        var toggles = AIPromptToggles.all
        toggles.includeProgression = false
        let context = makeContext(progression: "- Bench: 185x5→195x5", toggles: toggles)
        let params = WorkoutGenerationParams(intent: "Push day")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertFalse(prompt.contains("185x5→195x5"))
        XCTAssertFalse(prompt.contains("## Progression"))
    }

    func testBuildPromptOmitsRequestSectionWithoutIntent() {
        let params = WorkoutGenerationParams(intent: nil)
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: makeContext(), params: params)
        XCTAssertFalse(prompt.contains("# WORKOUT REQUEST"))
        XCTAssertFalse(prompt.contains("# REQUIREMENTS"))
    }

    func testBuildPromptAllTogglesOffIsMinimal() {
        let context = makeContext(
            recentWorkouts: "history",
            progression: "progression",
            equipment: ["barbell"],
            gym: "Home",
            toggles: .none
        )
        let params = WorkoutGenerationParams(intent: "Workout")
        let prompt = WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
        XCTAssertFalse(prompt.contains("# lift.md FORMAT"))
        XCTAssertFalse(prompt.contains("Recent Training History"))
        XCTAssertFalse(prompt.contains("## Progression"))
        XCTAssertFalse(prompt.contains("Current Gym & Equipment"))
        // Intent still reaches the prompt, and preferences block always present.
        XCTAssertTrue(prompt.contains("Workout"))
        XCTAssertTrue(prompt.contains("## Preferences"))
    }

    // MARK: - validateGeneratedWorkout

    func testValidateValidWorkout() {
        let workout = makeWorkoutPlan(
            name: "Push Day",
            exercises: [
                makePlannedExercise(name: "Bench Press", sets: [
                    makePlannedSet(weight: 225, reps: 5)
                ])
            ]
        )
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertTrue(result.valid)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testValidateEmptyNameIsInvalid() {
        let workout = makeWorkoutPlan(name: "  ", exercises: [
            makePlannedExercise(name: "Bench", sets: [makePlannedSet(reps: 10)])
        ])
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.issues.contains { $0.contains("name is required") })
    }

    func testValidateNoExercisesIsInvalid() {
        let workout = makeWorkoutPlan(name: "Empty Workout", exercises: [])
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.issues.contains { $0.contains("at least one exercise") })
    }

    func testValidateEmptyExerciseNameIsInvalid() {
        let workout = makeWorkoutPlan(name: "Workout", exercises: [
            makePlannedExercise(name: "  ", sets: [makePlannedSet(reps: 10)])
        ])
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.issues.contains { $0.contains("missing a name") })
    }

    func testValidateSetWithNoDataIsInvalid() {
        let workout = makeWorkoutPlan(name: "Workout", exercises: [
            makePlannedExercise(name: "Bench", sets: [makePlannedSet()])
        ])
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.issues.contains { $0.contains("must specify weight, reps, or time") })
    }

    func testValidateRPEOutOfRangeIsInvalid() {
        let workout = makeWorkoutPlan(name: "Workout", exercises: [
            makePlannedExercise(name: "Bench", sets: [makePlannedSet(reps: 5, rpe: 15)])
        ])
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.issues.contains { $0.contains("RPE must be between 1 and 10") })
    }

    func testValidateRPEZeroIsInvalid() {
        let workout = makeWorkoutPlan(name: "Workout", exercises: [
            makePlannedExercise(name: "Bench", sets: [makePlannedSet(reps: 5, rpe: 0)])
        ])
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertFalse(result.valid)
    }

    func testValidateTimeBasedSetIsValid() {
        let workout = makeWorkoutPlan(name: "Core", exercises: [
            makePlannedExercise(name: "Plank", sets: [makePlannedSet(time: 60)])
        ])
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertTrue(result.valid)
    }

    func testValidateBodyweightRepsIsValid() {
        let workout = makeWorkoutPlan(name: "BW", exercises: [
            makePlannedExercise(name: "Push-ups", sets: [makePlannedSet(reps: 20)])
        ])
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertTrue(result.valid)
    }

    func testValidateExerciseWithNoSetsWarns() {
        let workout = makeWorkoutPlan(name: "Workout", exercises: [
            makePlannedExercise(name: "Warmup", sets: []),
            makePlannedExercise(name: "Bench", sets: [makePlannedSet(weight: 225, reps: 5)])
        ])
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertTrue(result.valid)  // Warnings don't make it invalid
        XCTAssertTrue(result.warnings.contains { $0.contains("no sets") })
    }

    func testValidateLowVolumeWarns() {
        let workout = makeWorkoutPlan(name: "Workout", exercises: [
            makePlannedExercise(name: "Bench", sets: [
                makePlannedSet(weight: 225, reps: 5),
                makePlannedSet(weight: 225, reps: 5)
            ])
        ])
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertTrue(result.valid)
        XCTAssertTrue(result.warnings.contains { $0.contains("Low total volume") })
    }

    func testValidateHighVolumeWarns() {
        var exercises: [PlannedExercise] = []
        for i in 0..<10 {
            var sets: [PlannedSet] = []
            for _ in 0..<5 {
                sets.append(makePlannedSet(weight: 100, reps: 10))
            }
            exercises.append(makePlannedExercise(name: "Ex \(i)", sets: sets))
        }
        let workout = makeWorkoutPlan(name: "Marathon", exercises: exercises)
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertTrue(result.valid)
        XCTAssertTrue(result.warnings.contains { $0.contains("Very high volume") })
    }

    func testValidateWeightWithUnitIsClean() {
        // With SetMeasurement, weight always has a unit (defaults to .lbs)
        // so the "without unit" warning can no longer trigger through normal code paths
        let workout = makeWorkoutPlan(name: "Workout", exercises: [
            makePlannedExercise(name: "Bench", sets: [
                PlannedSet(
                    plannedExerciseId: "ex-1",
                    orderIndex: 0,
                    targetWeight: 225,
                    targetReps: 5
                )
            ])
        ])
        let result = WorkoutGenerationService.validateGeneratedWorkout(workout)
        XCTAssertTrue(result.valid)
        XCTAssertFalse(result.warnings.contains { $0.contains("without unit") })
    }

    // MARK: - parseAIWorkoutResponse

    func testParseValidAIResponse() throws {
        let markdown = """
        # Push Day
        @units: lbs

        ## Bench Press
        - 225 x 5
        - 225 x 5
        """
        let workout = try WorkoutGenerationService.parseAIWorkoutResponse(markdown: markdown, defaultWeightUnit: .lbs)
        XCTAssertEqual(workout.name, "Push Day")
        XCTAssertEqual(workout.exercises.count, 1)
        XCTAssertEqual(workout.exercises[0].exerciseName, "Bench Press")
    }

    func testParseAIResponsePreservesSourceMarkdown() throws {
        let markdown = """
        # Test
        ## Ex
        - 100 x 5
        """
        let workout = try WorkoutGenerationService.parseAIWorkoutResponse(markdown: markdown, defaultWeightUnit: .lbs)
        XCTAssertEqual(workout.sourceMarkdown, markdown)
    }

    func testParseAIResponseUsesDefaultUnitWhenNoneSpecified() throws {
        let markdown = """
        # Test
        ## Ex
        - 100 x 5
        """
        let workout = try WorkoutGenerationService.parseAIWorkoutResponse(markdown: markdown, defaultWeightUnit: .kg)
        XCTAssertEqual(workout.defaultWeightUnit, .kg)
    }

    func testParseInvalidAIResponseThrows() {
        let markdown = "This is not a valid workout"
        XCTAssertThrowsError(
            try WorkoutGenerationService.parseAIWorkoutResponse(markdown: markdown, defaultWeightUnit: .lbs)
        ) { error in
            XCTAssertTrue(error is WorkoutGenerationError)
        }
    }

    func testParseEmptyMarkdownThrows() {
        XCTAssertThrowsError(
            try WorkoutGenerationService.parseAIWorkoutResponse(markdown: "", defaultWeightUnit: .lbs)
        )
    }

    // MARK: - Helpers

    private func makeContext(
        weightUnit: WeightUnit = .lbs,
        customPrompt: String? = nil,
        recentWorkouts: String = "No recent workouts",
        progression: String = "",
        equipment: [String] = ["barbell", "dumbbells"],
        gym: String? = nil,
        toggles: AIPromptToggles = .all
    ) -> WorkoutGenerationContext {
        WorkoutGenerationContext(
            defaultWeightUnit: weightUnit,
            customPromptAddition: customPrompt,
            recentWorkouts: recentWorkouts,
            progression: progression,
            availableEquipment: equipment,
            currentGym: gym,
            toggles: toggles
        )
    }

    private func makeWorkoutPlan(
        name: String,
        exercises: [PlannedExercise]
    ) -> WorkoutPlan {
        WorkoutPlan(
            name: name,
            exercises: exercises
        )
    }

    private func makePlannedExercise(
        name: String,
        sets: [PlannedSet] = []
    ) -> PlannedExercise {
        PlannedExercise(
            workoutPlanId: "plan-1",
            exerciseName: name,
            orderIndex: 0,
            sets: sets
        )
    }

    private func makePlannedSet(
        weight: Double? = nil,
        reps: Int? = nil,
        time: Int? = nil,
        rpe: Int? = nil
    ) -> PlannedSet {
        PlannedSet(
            plannedExerciseId: "ex-1",
            orderIndex: 0,
            targetWeight: weight,
            targetWeightUnit: weight != nil ? .lbs : nil,
            targetReps: reps,
            targetTime: time,
            targetRpe: rpe
        )
    }
}
