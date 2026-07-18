import XCTest
@testable import LiftMark

final class MarkdownParserAdvancedTests: XCTestCase {

    // MARK: - Unit Lookahead (Issue 5: "Steady" bug)

    func testTrailingTextStartingWithSIsNotCapturedAsSeconds() {
        let markdown = """
        # Workout
        ## Rowing
        - 30 x 25 Steady pace
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let set = result.data?.exercises[0].sets[0]
        XCTAssertEqual(set?.targetWeight, 30)
        XCTAssertEqual(set?.targetReps, 25)
        XCTAssertNil(set?.targetTime, "Should not interpret 'S' from 'Steady' as seconds")
        XCTAssertEqual(set?.notes, "Steady pace")
    }

    func testExplicitSecondsUnitStillWorks() {
        let markdown = """
        # Workout
        ## Plank
        - 30 x 25s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let set = result.data?.exercises[0].sets[0]
        XCTAssertEqual(set?.targetWeight, 30)
        XCTAssertEqual(set?.targetTime, 25)
        XCTAssertNil(set?.targetReps, "25s should be time, not reps")
    }

    func testSecondsUnitFollowedBySpace() {
        let markdown = """
        # Workout
        ## Plank
        - 30 x 25 s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let set = result.data?.exercises[0].sets[0]
        XCTAssertEqual(set?.targetWeight, 30)
        XCTAssertEqual(set?.targetTime, 25)
    }

    // MARK: - Per-Side Auto-Detection from Exercise Notes

    func testPerSideNotesAutoFlagsTimedSets() {
        let markdown = """
        # Workout
        ## Side Plank
        per side
        - 60s
        - 45s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let sets = result.data?.exercises[0].sets
        XCTAssertEqual(sets?.count, 2)
        XCTAssertTrue(sets?[0].isPerSide ?? false)
        XCTAssertTrue(sets?[1].isPerSide ?? false)
    }

    func testPerSideNotesDoesNotFlagRepBasedSets() {
        let markdown = """
        # Workout
        ## Single Leg RDL
        per side
        - 50 lbs x 10
        - 60 lbs x 8
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let sets = result.data?.exercises[0].sets
        XCTAssertEqual(sets?.count, 2)
        XCTAssertFalse(sets?[0].isPerSide ?? true)
        XCTAssertFalse(sets?[1].isPerSide ?? true)
    }

    func testPerSideNotesCaseInsensitive() {
        let markdown = """
        # Workout
        ## Side Plank
        Per Side
        - 60s
        """
        let result = MarkdownParser.parseWorkout(markdown)
        XCTAssertTrue(result.data?.exercises[0].sets[0].isPerSide ?? false)

        let markdown2 = """
        # Workout
        ## Side Plank
        PER SIDE
        - 60s
        """
        let result2 = MarkdownParser.parseWorkout(markdown2)
        XCTAssertTrue(result2.data?.exercises[0].sets[0].isPerSide ?? false)
    }

    func testPerLegNotesAutoFlagsTimedSets() {
        let markdown = """
        # Workout
        ## Single Leg RDL Hold
        per leg
        - 30s
        - 25s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let sets = result.data?.exercises[0].sets
        XCTAssertTrue(sets?[0].isPerSide ?? false)
        XCTAssertTrue(sets?[1].isPerSide ?? false)
    }

    func testPerArmNotesAutoFlagsTimedSets() {
        let markdown = """
        # Workout
        ## Single Arm Hang
        per arm
        - 30s
        - 25s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let sets = result.data?.exercises[0].sets
        XCTAssertTrue(sets?[0].isPerSide ?? false)
        XCTAssertTrue(sets?[1].isPerSide ?? false)
    }

    func testEachSideNotesAutoFlagsTimedSets() {
        let markdown = """
        # Workout
        ## Side Plank
        each side
        - 60s
        - 45s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let sets = result.data?.exercises[0].sets
        XCTAssertTrue(sets?[0].isPerSide ?? false)
        XCTAssertTrue(sets?[1].isPerSide ?? false)
    }

    func testEachLegNotesAutoFlagsTimedSets() {
        let markdown = """
        # Workout
        ## Single Leg Balance
        each leg
        - 30s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.data?.exercises[0].sets[0].isPerSide ?? false)
    }

    func testEachArmNotesAutoFlagsTimedSets() {
        let markdown = """
        # Workout
        ## Farmer Hold
        each arm
        - 30s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.data?.exercises[0].sets[0].isPerSide ?? false)
    }

    func testEachKeywordNotesAutoFlagsTimedSets() {
        let markdown = """
        # Workout
        ## Side Plank
        Hold each for full duration
        - 60s
        - 45s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let sets = result.data?.exercises[0].sets
        XCTAssertTrue(sets?[0].isPerSide ?? false)
        XCTAssertTrue(sets?[1].isPerSide ?? false)
    }

    func testPerLegNotesDoesNotFlagRepBasedSets() {
        let markdown = """
        # Workout
        ## Single Leg RDL
        per leg
        - 50 lbs x 10
        - 60 lbs x 8
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let sets = result.data?.exercises[0].sets
        XCTAssertFalse(sets?[0].isPerSide ?? true)
        XCTAssertFalse(sets?[1].isPerSide ?? true)
    }

    func testEachArmNotesDoesNotFlagRepBasedSets() {
        let markdown = """
        # Workout
        ## Single Arm Curl
        each arm
        - 25 lbs x 10
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.data?.exercises[0].sets[0].isPerSide ?? true)
    }

    func testExplicitPerSideModifierStillWorks() {
        let markdown = """
        # Workout
        ## Stretches
        - 30s @perside
        - 45s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.data?.exercises[0].sets[0].isPerSide ?? false)
        XCTAssertFalse(result.data?.exercises[0].sets[1].isPerSide ?? true)
    }

    // MARK: - Per-Side Auto-Detection from Set Line Text

    func testPerLegInSetLineAutoFlagsTimedSet() {
        let markdown = """
        # Workout
        ## Standing Quad Stretch
        Pull heel to glutes
        - 60s per leg
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let set = result.data?.exercises[0].sets[0]
        XCTAssertEqual(set?.targetTime, 60)
        XCTAssertTrue(set?.isPerSide ?? false, "Should detect 'per leg' in set line text")
        // "per leg" should be stripped from notes
        XCTAssertNil(set?.notes, "Per-side keyword should be stripped from set notes")
    }

    func testPerSideInSetLineAutoFlagsTimedSet() {
        let markdown = """
        # Workout
        ## Pigeon Pose
        - 90s per side
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let set = result.data?.exercises[0].sets[0]
        XCTAssertEqual(set?.targetTime, 90)
        XCTAssertTrue(set?.isPerSide ?? false, "Should detect 'per side' in set line text")
        XCTAssertNil(set?.notes, "Per-side keyword should be stripped from set notes")
    }

    func testEachSideInSetLineAutoFlagsTimedSet() {
        let markdown = """
        # Workout
        ## Stretch
        - 45s each side
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.data?.exercises[0].sets[0].isPerSide ?? false)
    }

    func testPerLegInSetLineDoesNotFlagRepBasedSet() {
        let markdown = """
        # Workout
        ## Lunges
        - 25 per leg
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let set = result.data?.exercises[0].sets[0]
        XCTAssertEqual(set?.targetReps, 25)
        XCTAssertFalse(set?.isPerSide ?? true, "Should not flag rep-based set from set line keyword")
    }

    func testPerSideSetLineCaseInsensitive() {
        let markdown = """
        # Workout
        ## Stretch
        - 60s Per Leg
        """
        let result = MarkdownParser.parseWorkout(markdown)
        XCTAssertTrue(result.data?.exercises[0].sets[0].isPerSide ?? false)
    }

    func testPerSideSetLineWithSectionHeaders() {
        // Reproduces the user's workout structure with ## sections and ### exercises
        let markdown = """
        # Post-Snowboarding Stretch
        @tags: stretching

        ## Lower Body

        ### Standing Quad Stretch
        Pull heel to glutes
        - 60s per leg

        ### Pigeon Pose
        - 90s per side

        ### Wide-Leg Forward Fold
        - 90s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let exercises = result.data?.exercises ?? []
        // Find exercises with sets (not section headers)
        let exercisesWithSets = exercises.filter { !$0.sets.isEmpty }
        XCTAssertEqual(exercisesWithSets.count, 3)

        // Standing Quad Stretch: 60s per leg → isPerSide
        XCTAssertTrue(exercisesWithSets[0].sets[0].isPerSide, "Standing Quad Stretch should be per-side")
        XCTAssertEqual(exercisesWithSets[0].sets[0].targetTime, 60)

        // Pigeon Pose: 90s per side → isPerSide
        XCTAssertTrue(exercisesWithSets[1].sets[0].isPerSide, "Pigeon Pose should be per-side")
        XCTAssertEqual(exercisesWithSets[1].sets[0].targetTime, 90)

        // Wide-Leg Forward Fold: 90s → NOT per-side
        XCTAssertFalse(exercisesWithSets[2].sets[0].isPerSide, "Wide-Leg Forward Fold should not be per-side")
    }

    func testSingleNumberWithTrailingTextNotSeconds() {
        let markdown = """
        # Workout
        ## Exercise
        - 25 Slow and controlled
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let set = result.data?.exercises[0].sets[0]
        XCTAssertEqual(set?.targetReps, 25)
        XCTAssertNil(set?.targetTime, "Should not interpret 'S' from 'Slow' as seconds")
        XCTAssertEqual(set?.notes, "Slow and controlled")
    }

    // MARK: - Unicode Exercise Names

    func testParsesChineseCharacterExerciseName() {
        let markdown = """
        # Workout
        ## \u{5367}\u{63A8} (Bench Press)
        - 100 x 5
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].exerciseName, "\u{5367}\u{63A8} (Bench Press)")
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetWeight, 100)
    }

    func testParsesAccentedLetterExerciseName() {
        let markdown = """
        # Entra\u{00EE}nement
        ## D\u{00E9}velopp\u{00E9} Couch\u{00E9}
        - 60 kg x 8
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.name, "Entra\u{00EE}nement")
        XCTAssertEqual(result.data?.exercises[0].exerciseName, "D\u{00E9}velopp\u{00E9} Couch\u{00E9}")
    }

    func testParsesEmojiExerciseName() {
        let markdown = """
        # Workout
        ## \u{1F4AA} Bicep Curls
        - 25 x 10
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].exerciseName, "\u{1F4AA} Bicep Curls")
    }

    // MARK: - Mixed Units (Explicit vs Default)

    func testMixedExplicitAndDefaultUnits() {
        let markdown = """
        # Workout
        @units: lbs

        ## Bench Press
        - 225 x 5
        - 100 kg x 5
        ## Squats
        - 315 x 3
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        // First set uses default lbs
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetWeight, 225)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetWeightUnit, .lbs)
        // Second set uses explicit kg
        XCTAssertEqual(result.data?.exercises[0].sets[1].targetWeight, 100)
        XCTAssertEqual(result.data?.exercises[0].sets[1].targetWeightUnit, .kg)
        // Third exercise uses default lbs
        XCTAssertEqual(result.data?.exercises[1].sets[0].targetWeight, 315)
        XCTAssertEqual(result.data?.exercises[1].sets[0].targetWeightUnit, .lbs)
    }

    // MARK: - Extreme Values

    func testVeryHighRepCount() {
        let markdown = """
        # Workout
        ## Jump Rope
        - 999
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetReps, 999)
        // Should produce a warning for high rep count
        XCTAssertGreaterThan(result.warnings.count, 0)
    }

    func testVeryLargeWeight() {
        let markdown = """
        # Workout
        ## Leg Press
        - 9999.5 x 3
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetWeight, 9999.5)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetReps, 3)
    }

    func testVeryLongExerciseName() {
        let longName = "Single Arm Dumbbell Overhead Press With Rotation And Pause At The Top"
            + " For Maximum Time Under Tension"
        let markdown = """
        # Workout
        ## \(longName)
        - 25 x 8
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].exerciseName, longName)
    }

    // MARK: - Whitespace Variations

    func testExtraSpacesInSetLine() {
        let markdown = """
        # Workout
        ## Bench Press
        -   225   x   5
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetWeight, 225)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetReps, 5)
    }

    func testTabsInWorkoutLines() {
        let markdown = "# Workout\n\t## Bench Press\n\t- 100 x 5"
        let result = MarkdownParser.parseWorkout(markdown)

        // Tabs before ## may prevent header detection depending on trimming
        // This documents current behavior
        if result.success {
            XCTAssertEqual(result.data?.exercises[0].sets[0].targetWeight, 100)
        } else {
            XCTAssertFalse(result.errors.isEmpty, "Should produce errors if tabs break parsing")
        }
    }

    func testTrailingWhitespaceInSetLine() {
        let markdown = "# Workout\n## Press\n- 100 x 5   \n- 200 x 3   "
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets.count, 2)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetWeight, 100)
        XCTAssertEqual(result.data?.exercises[0].sets[1].targetWeight, 200)
    }

    // MARK: - Empty Sections

    func testEmptySectionFollowedByExercises() {
        let markdown = """
        # Workout

        ## Warmup

        ## Main Work
        ### Bench Press
        - 225 x 5
        """
        let result = MarkdownParser.parseWorkout(markdown)

        // The parser should handle an empty section (Warmup has no exercises)
        // and still parse the following section correctly
        if result.success {
            let exercisesWithSets = result.data?.exercises.filter { !$0.sets.isEmpty } ?? []
            XCTAssertGreaterThan(exercisesWithSets.count, 0, "Should have at least one exercise with sets")
        } else {
            // Document if it fails — this is a finding
            XCTAssertFalse(result.errors.isEmpty)
        }
    }

    // MARK: - Single-Exercise Workout (Minimal Valid)

    func testMinimalSingleExerciseOneSet() {
        let markdown = """
        # Workout
        ## Squats
        - 135 x 5
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.name, "Workout")
        XCTAssertEqual(result.data?.exercises.count, 1)
        XCTAssertEqual(result.data?.exercises[0].exerciseName, "Squats")
        XCTAssertEqual(result.data?.exercises[0].sets.count, 1)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetWeight, 135)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetReps, 5)
    }

    // MARK: - All Bodyweight Exercises

    func testAllBodyweightWorkout() {
        let markdown = """
        # Bodyweight Circuit
        ## Push-ups
        - bw x 20
        - bw x 15
        ## Pull-ups
        - bw x 10
        - bw x 8
        ## Dips
        - bw x 12
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises.count, 3)
        // All sets should have nil weight
        for exercise in result.data?.exercises ?? [] {
            for set in exercise.sets {
                XCTAssertNil(set.targetWeight, "\(exercise.exerciseName) should have nil targetWeight for bodyweight")
                XCTAssertNotNil(set.targetReps)
            }
        }
    }

    // MARK: - All Time-Based Exercises

    func testAllTimeBasedWorkout() {
        let markdown = """
        # Stretching Routine
        ## Plank
        - 60s
        - 45s
        ## Wall Sit
        - 2m
        ## Side Plank
        - 30s @perside
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises.count, 3)

        // Plank sets
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetTime, 60)
        XCTAssertEqual(result.data?.exercises[0].sets[1].targetTime, 45)
        // Wall Sit
        XCTAssertEqual(result.data?.exercises[1].sets[0].targetTime, 120)
        // Side Plank
        XCTAssertEqual(result.data?.exercises[2].sets[0].targetTime, 30)
        XCTAssertTrue(result.data?.exercises[2].sets[0].isPerSide ?? false)

        // All sets should have nil weight and nil reps
        for exercise in result.data?.exercises ?? [] {
            for set in exercise.sets {
                XCTAssertNil(set.targetWeight)
                XCTAssertNil(set.targetReps)
                XCTAssertNotNil(set.targetTime)
            }
        }
    }

    // MARK: - Multiple Modifiers on One Set (Flag + Key-Value)

    func testDropsetWithRPEModifiers() {
        let markdown = """
        # Workout
        ## Curls
        - 30 x 10 @dropset @rpe: 8
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let set = result.data?.exercises[0].sets[0]
        XCTAssertTrue(set?.isDropset ?? false)
        XCTAssertEqual(set?.targetRpe, 8)
    }

    func testPerSideWithRestModifiers() {
        let markdown = """
        # Workout
        ## Side Plank
        - 60s @perside @rest: 30s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let set = result.data?.exercises[0].sets[0]
        XCTAssertTrue(set?.isPerSide ?? false)
        XCTAssertEqual(set?.restSeconds, 30)
        XCTAssertEqual(set?.targetTime, 60)
    }

    func testDropsetWithRPEAndRestModifiers() {
        let markdown = """
        # Workout
        ## Curls
        - 30 x 10 @dropset @rpe: 9 @rest: 60s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        let set = result.data?.exercises[0].sets[0]
        XCTAssertTrue(set?.isDropset ?? false)
        XCTAssertEqual(set?.targetRpe, 9)
        XCTAssertEqual(set?.restSeconds, 60)
    }

    // MARK: - Notes with Special Characters

    func testNotesWithMarkdownLikeContent() {
        let markdown = """
        # Workout
        ## Bench Press

        Use **strict** form. Keep *elbows* tucked.

        - 225 x 5
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        // Notes should preserve markdown-like content as-is
        XCTAssertTrue(result.data?.exercises[0].notes?.contains("**strict**") ?? false)
        XCTAssertTrue(result.data?.exercises[0].notes?.contains("*elbows*") ?? false)
    }

    func testNotesWithUrlLikeContent() {
        let markdown = """
        # Workout
        ## Bench Press

        See https://example.com/form-guide for reference.

        - 225 x 5
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.data?.exercises[0].notes?.contains("https://example.com/form-guide") ?? false)
    }

    func testSetNotesWithSpecialCharactersAndSymbols() {
        let markdown = """
        # Workout
        ## Squats
        - 225 x 5 @rpe: 8 Form check: knees > toes? YES! (100%)
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetRpe, 8)
        XCTAssertTrue(result.data?.exercises[0].sets[0].notes?.contains("Form check") ?? false)
        XCTAssertTrue(result.data?.exercises[0].sets[0].notes?.contains("(100%)") ?? false)
    }

    // MARK: - Per-Side Expansion for Rep-Based Sets

    func testPerSideModifierOnRepBasedSets() {
        let markdown = """
        # Workout
        ## Lunges
        - 12 @perside
        - 10 @perside
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?.exercises[0].sets.count, 2)
        XCTAssertTrue(result.data?.exercises[0].sets[0].isPerSide ?? false)
        XCTAssertTrue(result.data?.exercises[0].sets[1].isPerSide ?? false)
        XCTAssertEqual(result.data?.exercises[0].sets[0].targetReps, 12)
        XCTAssertNil(result.data?.exercises[0].sets[0].targetTime)
    }

    func testPerSideAutoDetectFromNotesOnlyAppliesToTimedSets() {
        // Auto-detect from exercise notes only flags timed sets, not rep-based
        let markdown = """
        # Workout
        ## Single Leg RDL
        each leg
        - 50 lbs x 12
        - 60s
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.data?.exercises[0].sets[0].isPerSide ?? true,
                       "Rep-based sets should NOT get isPerSide from exercise notes auto-detect")
        XCTAssertTrue(result.data?.exercises[0].sets[1].isPerSide ?? false,
                       "Timed sets should get isPerSide from exercise notes auto-detect")
    }

    // MARK: - Duplicate Exercise Name Warning

    func testDuplicateExerciseNameWarning() {
        let markdown = """
        # Workout
        ## Bench Press
        - 135 x 10
        ## Squats
        - 225 x 5
        ## Bench Press
        - 185 x 8
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("Duplicate exercise name") }),
                       "Should warn about duplicate exercise name 'Bench Press'")
    }

    func testDuplicateExerciseNameCaseInsensitive() {
        let markdown = """
        # Workout
        ## Bench Press
        - 135 x 10
        ## bench press
        - 185 x 8
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("Duplicate exercise name") }),
                       "Duplicate detection should be case-insensitive")
    }

    func testNoDuplicateWarningForUniqueExercises() {
        let markdown = """
        # Workout
        ## Bench Press
        - 135 x 10
        ## Squats
        - 225 x 5
        """
        let result = MarkdownParser.parseWorkout(markdown)

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.warnings.contains(where: { $0.contains("Duplicate exercise name") }),
                        "Should not warn when all exercise names are unique")
    }

}
