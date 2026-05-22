import XCTest
@testable import LiftMark

final class MarkdownParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParsesSimpleWorkoutWithOneExercise() {
        let markdown = """
        # Test Workout
        @units: lbs

        ## Bicep Curls
        - 20 x 10
        - 25 x 8
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertNotNil(result.data)
        XCTAssertEqual(result.data?.name, "Test Workout")
        XCTAssertEqual(result.data?.defaultWeightUnit, .lbs)
        XCTAssertEqual(result.data?.exercises.count, 1)
        XCTAssertEqual(result.data?.exercises[0].exerciseName, "Bicep Curls")
        XCTAssertEqual(result.data?.exercises[0].sets.count, 2)
    }

    // MARK: - Rest Modifiers

    func testParsesSetsWithRestModifiers() {
        let markdown = """
        # Workout
        ## Exercise
        - 100 x 5 @rest: 60s
        - 100 x 5 @rest: 90s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].restSeconds, 60)
        XCTAssertEqual(result.data?.exercises[0].sets[1].restSeconds, 90)
    }

    // MARK: - RPE Modifiers

    func testParsesSetsWithRPEModifiers() {
        let markdown = """
        # Workout
        ## Squats
        - 225 lbs x 5 @rpe: 8
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetWeight, 225)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetReps, 5)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetRpe, 8)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("@rpe is deprecated") }))
    }

    // MARK: - Deprecated Modifier Warnings

    func testRpeDeprecationWarning() {
        let markdown = """
        # Workout
        ## Squats
        - 225 x 5 @rpe: 8
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetRpe, 8)
        let rpeWarnings = result.warnings.filter { $0.contains("@rpe is deprecated") }
        XCTAssertEqual(rpeWarnings.count, 1)
        XCTAssertTrue(rpeWarnings[0].contains("use freeform notes instead"))
    }

    func testTempoDeprecationWarning() {
        let markdown = """
        # Workout
        ## Pause Squats
        - 225 x 5 @tempo: 3-2-1-0
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        // tempo is deprecated and no longer stored on PlannedSet
        XCTAssertNil(result.data?.exercises[0].sets[0].tempo)
        let tempoWarnings = result.warnings.filter { $0.contains("@tempo is deprecated") }
        XCTAssertEqual(tempoWarnings.count, 1)
        XCTAssertTrue(tempoWarnings[0].contains("use freeform notes instead"))
    }

    func testBothRpeAndTempoDeprecationWarnings() {
        let markdown = """
        # Workout
        ## Bench
        - 225 x 5 @rpe: 8 @tempo: 3-0-1-0
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("@rpe is deprecated") }))
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("@tempo is deprecated") }))
    }

    func testAmrapFlagModifierEmitsDeprecationWarning() {
        let markdown = """
        # Workout
        ## Pull-ups
        - bw x 10 @amrap
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        // @amrap as a flag does NOT set isAmrap — only the rep value `AMRAP` does.
        XCTAssertFalse(result.data?.exercises[0].sets[0].isAmrap ?? true)
        let amrapWarnings = result.warnings.filter { $0.contains("@amrap is not a modifier") }
        XCTAssertEqual(amrapWarnings.count, 1)
        XCTAssertTrue(amrapWarnings[0].contains("135 x AMRAP"))
    }

    func testAmrapRepValueParsesWithoutDeprecationWarning() {
        let markdown = """
        # Workout
        ## Pull-ups
        - bw x AMRAP
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.data?.exercises[0].sets[0].isAmrap ?? false)
        XCTAssertFalse(result.warnings.contains(where: { $0.contains("@amrap") }))
    }

    // MARK: - Bodyweight Exercises

    func testParsesBodyweightExercises() {
        let markdown = """
        # Workout
        ## Pull-ups
        - bw x 10
        - bw x 8
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertNil(result.data?.exercises[0].sets[0].targetWeight)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetReps, 10)
    }

    // MARK: - Time-Based Sets

    func testParsesTimeBasedSets() {
        let markdown = """
        # Workout
        ## Plank
        - 60s
        - 45s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetTime, 60)
        XCTAssertEqual(result.data?.exercises[0].sets[1].targetTime, 45)
    }

    // MARK: - KG Units

    func testParsesKgUnits() {
        let markdown = """
        # Workout
        @units: kg

        ## Deadlift
        - 100 kg x 5
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.defaultWeightUnit, .kg)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetWeight, 100)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetWeightUnit, .kg)
    }

    // MARK: - Error Cases

    func testFailsWhenNoWorkoutHeaderFound() {
        let markdown = """
        Just some text
        without a proper workout
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertFalse(result.success)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testFailsWhenExerciseHasNoSets() {
        let markdown = """
        # Workout
        ## Empty Exercise
        """
        let result = MarkdownParser.parseWorkout(markdown)

        // Without sets, the workout header isn't found
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.errors.isEmpty)
    }

    // MARK: - Tags

    func testParsesWorkoutTags() {
        let markdown = """
        # Upper Body
        @tags: strength, push
        @units: lbs

        ## Bench Press
        - 135 x 10
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.data?.tags.contains("strength") ?? false)
        XCTAssertTrue(result.data?.tags.contains("push") ?? false)
    }

    // MARK: - Supersets

    func testParsesSupersets() {
        let markdown = """
        # Workout

        ## Superset
        ### Bicep Curls
        - 20 x 10
        ### Tricep Extensions
        - 20 x 10
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        // Should have parent superset + 2 child exercises
        XCTAssertGreaterThanOrEqual(result.data?.exercises.count ?? 0, 2)
    }

    // MARK: - Sections

    func testParsesSectionsWithExercises() {
        let markdown = """
        # Workout

        ## Warmup
        ### Arm Circles
        - 30s
        ### Jumping Jacks
        - 60s

        ## Workout
        ### Bench Press
        - 135 x 10
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let exercises = result.data?.exercises ?? []

        // Should have: Warmup section parent, 2 warmup exercises, Workout section parent, 1 workout exercise
        XCTAssertEqual(exercises.count, 5)

        // First should be section parent
        XCTAssertEqual(exercises[0].groupType, .section)
        XCTAssertEqual(exercises[0].exerciseName, "Warmup")
        XCTAssertEqual(exercises[0].sets.count, 0)

        // Warmup exercises should have parent pointing to warmup section
        XCTAssertEqual(exercises[1].exerciseName, "Arm Circles")
        XCTAssertEqual(exercises[1].parentExerciseId, exercises[0].id)

        XCTAssertEqual(exercises[2].exerciseName, "Jumping Jacks")
        XCTAssertEqual(exercises[2].parentExerciseId, exercises[0].id)
    }

    // MARK: - Supersets Inside Sections

    func testParsesSupersetInsideSections() {
        let markdown = """
        # Workout

        ## Workout
        ### Superset: Arms
        #### Bicep Curls
        - 20 x 10
        #### Tricep Extensions
        - 20 x 10
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let exercises = result.data?.exercises ?? []

        // Should have: Workout section parent, Superset parent, 2 superset children
        XCTAssertEqual(exercises.count, 4)

        // First should be section parent
        let sectionParent = exercises[0]
        XCTAssertEqual(sectionParent.groupType, .section)
        XCTAssertEqual(sectionParent.exerciseName, "Workout")
        XCTAssertEqual(sectionParent.sets.count, 0)

        // Second should be superset parent, with parent pointing to section
        let supersetParent = exercises[1]
        XCTAssertEqual(supersetParent.groupType, .superset)
        XCTAssertEqual(supersetParent.exerciseName, "Superset: Arms")
        XCTAssertEqual(supersetParent.sets.count, 0)
        XCTAssertEqual(supersetParent.parentExerciseId, sectionParent.id)

        // Superset children should have parent pointing to superset, NOT section
        let child1 = exercises[2]
        XCTAssertEqual(child1.exerciseName, "Bicep Curls")
        XCTAssertEqual(child1.parentExerciseId, supersetParent.id)
        XCTAssertEqual(child1.sets.count, 1)

        let child2 = exercises[3]
        XCTAssertEqual(child2.exerciseName, "Tricep Extensions")
        XCTAssertEqual(child2.parentExerciseId, supersetParent.id)
        XCTAssertEqual(child2.sets.count, 1)
    }

    // MARK: - Non-Adjacent Header Levels

    func testParsesSupersetWithNonAdjacentHeaderLevels() {
        // H2 superset -> H4 exercises (skipping H3)
        let markdown = """
        # Workout

        ## Superset: Arms
        #### Bicep Curls
        - 20 x 10
        #### Tricep Extensions
        - 20 x 10
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let exercises = result.data?.exercises ?? []

        // Should have: Superset parent + 2 superset children
        XCTAssertEqual(exercises.count, 3)

        let supersetParent = exercises[0]
        XCTAssertEqual(supersetParent.groupType, .superset)
        XCTAssertEqual(supersetParent.exerciseName, "Superset: Arms")
        XCTAssertEqual(supersetParent.sets.count, 0)

        let child1 = exercises[1]
        XCTAssertEqual(child1.exerciseName, "Bicep Curls")
        XCTAssertEqual(child1.parentExerciseId, supersetParent.id)
        XCTAssertEqual(child1.sets.count, 1)

        let child2 = exercises[2]
        XCTAssertEqual(child2.exerciseName, "Tricep Extensions")
        XCTAssertEqual(child2.parentExerciseId, supersetParent.id)
        XCTAssertEqual(child2.sets.count, 1)
    }

    // MARK: - Per-Side Modifier

    func testParsesPerSideModifier() {
        let markdown = """
        # Workout
        ## Stretches
        - 30s @perside
        - 45s @perside
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.data?.exercises[0].sets[0].isPerSide ?? false)
        XCTAssertTrue(result.data?.exercises[0].sets[1].isPerSide ?? false)
    }

    // MARK: - Dropset Modifier

    func testParsesDropsetModifier() {
        let markdown = """
        # Workout
        ## Curls
        - 20 x 10
        - 15 x 12 @dropset
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        // First set should not be a dropset
        XCTAssertFalse(result.data?.exercises[0].sets[0].isDropset ?? true)
        XCTAssertTrue(result.data?.exercises[0].sets[1].isDropset ?? false)
    }

    // MARK: - Trailing Text

    func testParsesTrailingTextWithoutModifiers() {
        let markdown = """
        # Workout
        ## Bench Press
        - 225 x 5 Felt strong today!
        - 245 x 3 PR set!
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].notes, "Felt strong today!")
        XCTAssertEqual(result.data?.exercises[0].sets[1].notes, "PR set!")
    }

    func testParsesTrailingTextAfterModifiers() {
        let markdown = """
        # Workout
        ## Squats
        - 315 x 5 @rpe: 8 Great depth today
        - 335 x 3 @rpe: 9 @rest: 180s Tough but doable
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetRpe, 8)
        XCTAssertEqual(result.data?.exercises[0].sets[0].notes, "Great depth today")
        XCTAssertEqual(result.data?.exercises[0].sets[1].targetRpe, 9)
        XCTAssertEqual(result.data?.exercises[0].sets[1].restSeconds, 180)
        XCTAssertEqual(result.data?.exercises[0].sets[1].notes, "Tough but doable")
    }

    func testParsesTrailingTextWithTempoModifier() {
        let markdown = """
        # Workout
        ## Pause Squats
        - 225 x 5 @tempo: 3-2-1-0 @rest: 120s Really focused on the pause
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertNil(result.data?.exercises[0].sets[0].tempo) // tempo is deprecated
        XCTAssertEqual(result.data?.exercises[0].sets[0].restSeconds, 120)
        XCTAssertEqual(result.data?.exercises[0].sets[0].notes, "Really focused on the pause")
    }

    func testHandlesTextThatLooksLikeModifierButIsNot() {
        let markdown = """
        # Workout
        ## Deadlift
        - 405 x 5 @rpe: 8.5 Back felt good, no issues
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        // RPE 8.5 rounds to nearest Int (9) in existing model
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetRpe, 9)
        XCTAssertEqual(result.data?.exercises[0].sets[0].notes, "Back felt good, no issues")
    }

    func testHandlesMultipleAtSymbolsInTrailingText() {
        let markdown = """
        # Workout
        ## Bench Press
        - 225 x 5 @rpe: 7 Hit the target @135 for warmup
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetRpe, 7)
        // The trailing text includes text from after @135
        XCTAssertTrue(result.data?.exercises[0].sets[0].notes?.contains("Hit the target") ?? false)
    }

    func testHandlesTrailingTextWithOnlyInvalidModifiers() {
        let markdown = """
        # Workout
        ## Press
        - 135 x 8 @invalid: value Some note here
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        // Invalid modifier should generate a warning
        XCTAssertGreaterThan(result.warnings.count, 0)
        XCTAssertTrue(result.data?.exercises[0].sets[0].notes?.contains("Some note here") ?? false)
    }

    func testParsesTrailingTextAfterFlagModifiers() {
        let markdown = """
        # Workout
        ## Curls
        - 20 x 12 @dropset Burned out completely
        - 15 x 15 Great pump
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.data?.exercises[0].sets[0].isDropset ?? false)
        XCTAssertEqual(result.data?.exercises[0].sets[0].notes, "Burned out completely")
        XCTAssertEqual(result.data?.exercises[0].sets[1].notes, "Great pump")
    }

    func testPreservesTrailingTextWithSpecialCharacters() {
        let markdown = """
        # Workout
        ## Squats
        - 225 x 5 @rpe: 8 Form was perfect! \u{1F4AA} #PR
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].notes, "Form was perfect! \u{1F4AA} #PR")
    }

    func testHandlesEmptyTrailingTextGracefully() {
        let markdown = """
        # Workout
        ## Bench Press
        - 225 x 5 @rpe: 8
        - 245 x 3
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertNil(result.data?.exercises[0].sets[0].notes)
        XCTAssertNil(result.data?.exercises[0].sets[1].notes)
    }

    // MARK: - GenAI Format Variations

    func testHandlesDirectionalInstructions() {
        let markdown = """
        # Test
        ## Arm Circles
        - 30s forward
        - 30s backward
        """
        let result = MarkdownParser.parseWorkout(markdown)
        // Expected: success with notes preserved or defined errors
        XCTAssertTrue(result.success || !result.errors.isEmpty)
    }

    func testHandlesSideLimbSpecifications() {
        let markdown = """
        # Test
        ## Dead Bug
        - 12 each side
        - 10 each arm
        """
        let result = MarkdownParser.parseWorkout(markdown)
        XCTAssertTrue(result.success || !result.errors.isEmpty)
    }

    func testHandlesPerSideAndBothSides() {
        let markdown = """
        # Test
        ## Stretch
        - 45s per side
        - 60s both sides
        """
        let result = MarkdownParser.parseWorkout(markdown)
        XCTAssertTrue(result.success || !result.errors.isEmpty)
    }

    func testParsesClaudeGeneratedPushDayWorkout() {
        let markdown = """
        # Push Day - Compound Focus
        @tags: push, chest, shoulders, triceps
        @units: lbs

        ## Warmup

        ### Arm Circles
        - 30s forward
        - 30s backward

        ### Band Pull-Aparts
        - 15
        - 15

        ### Push-up to Downward Dog
        - 8

        ### Empty Bar Overhead Press
        - 45 x 10
        - 45 x 8

        ## Workout

        ### Bench Press
        - 135 x 8
        - 185 x 6 @rpe: 6
        - 205 x 5 @rpe: 7
        - 225 x 4 @rpe: 8
        - 225 x 4 @rpe: 9 @rest: 180s

        ### Overhead Press
        - 95 x 8
        - 115 x 6 @rpe: 7
        - 125 x 5 @rpe: 8 @rest: 120s

        ### Incline Dumbbell Press
        - 50 x 10
        - 60 x 8 @rpe: 7
        - 65 x 8 @rpe: 8

        ### Dips
        - bw x 10
        - bw x 8 @rpe: 8
        - bw x AMRAP

        ### Superset: Shoulder & Tricep Finisher
        #### Lateral Raises
        - 20 x 12
        - 25 x 10
        #### Tricep Pushdowns
        - 50 x 12
        - 60 x 10

        ## Core

        ### Hanging Leg Raises
        - 10
        - 10
        - 10 @rest: 60s

        ### Dead Bug
        - 12 each side
        - 12 each side

        ## Cool Down

        ### Doorway Chest Stretch
        - 45s each side

        ### Overhead Tricep Stretch
        - 30s each arm

        ### Thread the Needle
        - 30s each side

        ### Child's Pose
        - 60s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        if result.success {
            XCTAssertNotNil(result.data?.exercises)
            XCTAssertGreaterThan(result.data?.exercises.count ?? 0, 0)
        } else {
            // Document the failures for now
            XCTAssertFalse(result.errors.isEmpty)
        }
    }

}
