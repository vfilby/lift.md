import XCTest
@testable import LiftMark

final class ActiveWorkoutViewModelTests: XCTestCase {

    // MARK: - Progress: completedSets

    func testCompletedSetsCountsOnlyCompleted() {
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(status: .completed),
                makeSet(status: .pending),
                makeSet(status: .skipped),
                makeSet(status: .completed)
            ])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.completedSets(in: session), 2)
    }

    func testCompletedSetsAcrossMultipleExercises() {
        let session = makeSession(exercises: [
            makeExercise(sets: [makeSet(status: .completed), makeSet(status: .completed)]),
            makeExercise(sets: [makeSet(status: .completed), makeSet(status: .pending)])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.completedSets(in: session), 3)
    }

    func testCompletedSetsReturnsZeroForNilSession() {
        XCTAssertEqual(ActiveWorkoutViewModel.completedSets(in: nil), 0)
    }

    func testCompletedSetsReturnsZeroForEmptyExercises() {
        let session = makeSession(exercises: [])
        XCTAssertEqual(ActiveWorkoutViewModel.completedSets(in: session), 0)
    }

    // MARK: - Progress: skippedSets

    func testSkippedSetsCountsOnlySkipped() {
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(status: .completed),
                makeSet(status: .skipped),
                makeSet(status: .pending),
                makeSet(status: .skipped)
            ])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.skippedSets(in: session), 2)
    }

    func testSkippedSetsAcrossMultipleExercises() {
        let session = makeSession(exercises: [
            makeExercise(sets: [makeSet(status: .skipped), makeSet(status: .skipped)]),
            makeExercise(sets: [makeSet(status: .completed), makeSet(status: .skipped)])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.skippedSets(in: session), 3)
    }

    func testSkippedSetsReturnsZeroForNilSession() {
        XCTAssertEqual(ActiveWorkoutViewModel.skippedSets(in: nil), 0)
    }

    func testSkippedSetsReturnsZeroWhenNoSkippedSets() {
        let session = makeSession(exercises: [
            makeExercise(sets: [makeSet(status: .completed), makeSet(status: .pending)])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.skippedSets(in: session), 0)
    }

    // MARK: - Progress: totalSets

    func testTotalSetsCountsAllSets() {
        let session = makeSession(exercises: [
            makeExercise(sets: [makeSet(status: .completed), makeSet(status: .pending)]),
            makeExercise(sets: [makeSet(status: .skipped)])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.totalSets(in: session), 3)
    }

    func testTotalSetsReturnsZeroForNilSession() {
        XCTAssertEqual(ActiveWorkoutViewModel.totalSets(in: nil), 0)
    }

    // MARK: - Progress: progress percentage

    func testProgressReturnsZeroForNilSession() {
        XCTAssertEqual(ActiveWorkoutViewModel.progress(in: nil), 0)
    }

    func testProgressReturnsZeroForEmptySession() {
        let session = makeSession(exercises: [])
        XCTAssertEqual(ActiveWorkoutViewModel.progress(in: session), 0)
    }

    func testProgressReturnsCorrectFraction() {
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(status: .completed),
                makeSet(status: .completed),
                makeSet(status: .pending),
                makeSet(status: .pending)
            ])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.progress(in: session), 0.5, accuracy: 0.001)
    }

    func testProgressReturnsOneWhenAllCompleted() {
        let session = makeSession(exercises: [
            makeExercise(sets: [makeSet(status: .completed), makeSet(status: .completed)])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.progress(in: session), 1.0, accuracy: 0.001)
    }

    func testProgressReturnsZeroWhenNoneCompleted() {
        let session = makeSession(exercises: [
            makeExercise(sets: [makeSet(status: .pending), makeSet(status: .pending)])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.progress(in: session), 0.0, accuracy: 0.001)
    }

    func testProgressSkippedSetsAreNotCounted() {
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(status: .completed),
                makeSet(status: .skipped),
                makeSet(status: .pending)
            ])
        ])
        // 1 completed / 3 total
        XCTAssertEqual(ActiveWorkoutViewModel.progress(in: session), 1.0 / 3.0, accuracy: 0.001)
    }

    // MARK: - Progress: pendingSets

    func testPendingSetsCountsOnlyPending() {
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(status: .completed),
                makeSet(status: .pending),
                makeSet(status: .skipped),
                makeSet(status: .pending)
            ])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.pendingSets(in: session), 2)
    }

    func testPendingSetsExcludesSkippedSets() {
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(status: .completed),
                makeSet(status: .skipped),
                makeSet(status: .skipped)
            ])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.pendingSets(in: session), 0)
    }

    func testPendingSetsReturnsZeroForNilSession() {
        XCTAssertEqual(ActiveWorkoutViewModel.pendingSets(in: nil), 0)
    }

    func testPendingSetsAcrossMultipleExercises() {
        let session = makeSession(exercises: [
            makeExercise(sets: [makeSet(status: .pending), makeSet(status: .completed)]),
            makeExercise(sets: [makeSet(status: .skipped), makeSet(status: .pending)])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.pendingSets(in: session), 2)
    }

    func testPendingSetsReturnsZeroWhenAllCompleted() {
        let session = makeSession(exercises: [
            makeExercise(sets: [makeSet(status: .completed), makeSet(status: .completed)])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.pendingSets(in: session), 0)
    }

    // MARK: - Skip-Heavy Detection

    func testIsSkipHeavyReturnsFalseForNilSession() {
        XCTAssertFalse(ActiveWorkoutViewModel.isSkipHeavy(in: nil))
    }

    func testIsSkipHeavyReturnsFalseForEmptySession() {
        let session = makeSession(exercises: [])
        XCTAssertFalse(ActiveWorkoutViewModel.isSkipHeavy(in: session))
    }

    func testIsSkipHeavyReturnsTrueWhenLessThanHalfCompleted() {
        // 1 completed out of 4 total -> 1 < 4/2=2 -> true
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(status: .completed),
                makeSet(status: .skipped),
                makeSet(status: .skipped),
                makeSet(status: .skipped)
            ])
        ])
        XCTAssertTrue(ActiveWorkoutViewModel.isSkipHeavy(in: session))
    }

    func testIsSkipHeavyReturnsFalseWhenMajorityCompleted() {
        // 3 completed out of 4 total -> 3 < 2 is false
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(status: .completed),
                makeSet(status: .completed),
                makeSet(status: .completed),
                makeSet(status: .skipped)
            ])
        ])
        XCTAssertFalse(ActiveWorkoutViewModel.isSkipHeavy(in: session))
    }

    func testIsSkipHeavyBoundaryExactlyHalf() {
        // 2 completed out of 4 total -> 2 < 4/2=2 -> false (not strictly less)
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(status: .completed),
                makeSet(status: .completed),
                makeSet(status: .skipped),
                makeSet(status: .skipped)
            ])
        ])
        XCTAssertFalse(ActiveWorkoutViewModel.isSkipHeavy(in: session))
    }

    func testIsSkipHeavyWithOddTotal() {
        // 1 completed out of 3 total -> 1 < 3/2=1 (int division) -> false
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(status: .completed),
                makeSet(status: .skipped),
                makeSet(status: .skipped)
            ])
        ])
        // 3/2 == 1 in integer division, 1 < 1 is false
        XCTAssertFalse(ActiveWorkoutViewModel.isSkipHeavy(in: session))
    }

    func testIsSkipHeavyZeroCompleted() {
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(status: .skipped),
                makeSet(status: .skipped),
                makeSet(status: .skipped),
                makeSet(status: .skipped)
            ])
        ])
        XCTAssertTrue(ActiveWorkoutViewModel.isSkipHeavy(in: session))
    }

    // MARK: - Active Exercise Detection

    func testActiveExerciseNameReturnsFirstWithPendingSet() {
        let session = makeSession(exercises: [
            makeExercise(name: "Bench Press", sets: [makeSet(status: .completed)]),
            makeExercise(name: "Squat", sets: [makeSet(status: .pending)]),
            makeExercise(name: "Deadlift", sets: [makeSet(status: .pending)])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.activeExerciseName(in: session), "Squat")
    }

    func testActiveExerciseNameReturnsNilWhenAllCompleted() {
        let session = makeSession(exercises: [
            makeExercise(name: "Bench Press", sets: [makeSet(status: .completed)])
        ])
        XCTAssertNil(ActiveWorkoutViewModel.activeExerciseName(in: session))
    }

    func testActiveExerciseNameReturnsNilForNilSession() {
        XCTAssertNil(ActiveWorkoutViewModel.activeExerciseName(in: nil))
    }

    func testActiveExerciseNameSkipsExercisesWithNoSets() {
        let session = makeSession(exercises: [
            makeExercise(name: "Empty", sets: []),
            makeExercise(name: "Has Pending", sets: [makeSet(status: .pending)])
        ])
        XCTAssertEqual(ActiveWorkoutViewModel.activeExerciseName(in: session), "Has Pending")
    }

    // MARK: - Display Items: Regular Exercises

    func testBuildDisplayItemsSingleExercises() {
        let exercises = [
            makeExercise(id: "e1", name: "Bench Press", orderIndex: 0, sets: [makeSet()]),
            makeExercise(id: "e2", name: "Squat", orderIndex: 1, sets: [makeSet()])
        ]
        let items = ActiveWorkoutViewModel.buildDisplayItems(from: exercises)
        XCTAssertEqual(items.count, 2)

        if case .single(let ex, let idx, let num) = items[0] {
            XCTAssertEqual(ex.exerciseName, "Bench Press")
            XCTAssertEqual(idx, 0)
            XCTAssertEqual(num, 1)
        } else {
            XCTFail("Expected .single for first item")
        }

        if case .single(let ex, let idx, let num) = items[1] {
            XCTAssertEqual(ex.exerciseName, "Squat")
            XCTAssertEqual(idx, 1)
            XCTAssertEqual(num, 2)
        } else {
            XCTFail("Expected .single for second item")
        }
    }

    func testBuildDisplayItemsEmptyExercises() {
        let items = ActiveWorkoutViewModel.buildDisplayItems(from: [])
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - Display Items: Superset

    func testBuildDisplayItemsSuperset() {
        let parentId = "parent1"
        let parent = makeExercise(id: parentId, name: "Superset", groupType: .superset, sets: [])
        let child1 = makeExercise(id: "c1", name: "Bench Press", orderIndex: 1, parentExerciseId: parentId, sets: [makeSet()])
        let child2 = makeExercise(id: "c2", name: "Row", orderIndex: 2, parentExerciseId: parentId, sets: [makeSet()])

        let items = ActiveWorkoutViewModel.buildDisplayItems(from: [parent, child1, child2])
        XCTAssertEqual(items.count, 1)

        if case .superset(let p, let children) = items[0] {
            XCTAssertEqual(p.id, parentId)
            XCTAssertEqual(children.count, 2)
            XCTAssertEqual(children[0].exercise.exerciseName, "Bench Press")
            XCTAssertEqual(children[0].displayNumber, 1)
            XCTAssertEqual(children[1].exercise.exerciseName, "Row")
            XCTAssertEqual(children[1].displayNumber, 2)
        } else {
            XCTFail("Expected .superset item")
        }
    }

    func testBuildDisplayItemsSingleMemberSupersetRendersStandalone() {
        // A superset block that contains only one exercise is not a real
        // superset (nothing to alternate with). It should render as a plain
        // standalone exercise, matching the plan view — not as a 1-member
        // superset group.
        let parentId = "parent1"
        let parent = makeExercise(id: parentId, name: "Superset", groupType: .superset, sets: [])
        let onlyChild = makeExercise(id: "c1", name: "Cable Tricep Pushdown", orderIndex: 1, parentExerciseId: parentId, sets: [makeSet()])

        let items = ActiveWorkoutViewModel.buildDisplayItems(from: [parent, onlyChild])
        XCTAssertEqual(items.count, 1)

        if case .single(let ex, _, let num) = items[0] {
            XCTAssertEqual(ex.exerciseName, "Cable Tricep Pushdown")
            XCTAssertEqual(num, 1)
        } else {
            XCTFail("Expected .single for a single-member superset, got \(items[0])")
        }
    }

    func testSupersetGroupingPredicate() {
        XCTAssertFalse(SupersetGrouping.isRealSuperset(childCount: 0))
        XCTAssertFalse(SupersetGrouping.isRealSuperset(childCount: 1))
        XCTAssertTrue(SupersetGrouping.isRealSuperset(childCount: 2))
        XCTAssertTrue(SupersetGrouping.isRealSuperset(childCount: 5))
    }

    // MARK: - Display Items: Section Divider

    func testBuildDisplayItemsSection() {
        let sectionId = "section1"
        let section = makeExercise(id: sectionId, name: "Warm Up", groupType: .section, groupName: "Warm Up", sets: [])
        let child1 = makeExercise(id: "c1", name: "Jumping Jacks", orderIndex: 1, parentExerciseId: sectionId, sets: [makeSet()])
        let child2 = makeExercise(id: "c2", name: "Arm Circles", orderIndex: 2, parentExerciseId: sectionId, sets: [makeSet()])

        let items = ActiveWorkoutViewModel.buildDisplayItems(from: [section, child1, child2])
        XCTAssertEqual(items.count, 3) // section header + 2 children

        if case .section(let name) = items[0] {
            XCTAssertEqual(name, "Warm Up")
        } else {
            XCTFail("Expected .section item")
        }

        if case .single(let ex, _, let num) = items[1] {
            XCTAssertEqual(ex.exerciseName, "Jumping Jacks")
            XCTAssertEqual(num, 1)
        } else {
            XCTFail("Expected .single for section child 1")
        }

        if case .single(let ex, _, let num) = items[2] {
            XCTAssertEqual(ex.exerciseName, "Arm Circles")
            XCTAssertEqual(num, 2)
        } else {
            XCTFail("Expected .single for section child 2")
        }
    }

    func testBuildDisplayItemsSectionUsesExerciseNameWhenGroupNameNil() {
        let sectionId = "section1"
        let section = makeExercise(id: sectionId, name: "Warm Up", groupType: .section, groupName: nil, sets: [])
        let child = makeExercise(id: "c1", name: "Jog", orderIndex: 1, parentExerciseId: sectionId, sets: [makeSet()])

        let items = ActiveWorkoutViewModel.buildDisplayItems(from: [section, child])
        if case .section(let name) = items[0] {
            XCTAssertEqual(name, "Warm Up")
        } else {
            XCTFail("Expected .section item")
        }
    }

    func testBuildDisplayItemsSectionSkipsEmptyName() {
        let sectionId = "section1"
        let section = makeExercise(id: sectionId, name: "", groupType: .section, groupName: "", sets: [])
        let child = makeExercise(id: "c1", name: "Jog", orderIndex: 1, parentExerciseId: sectionId, sets: [makeSet()])

        let items = ActiveWorkoutViewModel.buildDisplayItems(from: [section, child])
        // Empty section name is not emitted, only the child
        XCTAssertEqual(items.count, 1)
        if case .single(let ex, _, _) = items[0] {
            XCTAssertEqual(ex.exerciseName, "Jog")
        } else {
            XCTFail("Expected .single for child")
        }
    }

    // MARK: - Display Items: Mixed Structure

    func testBuildDisplayItemsMixedStructure() {
        let supersetId = "ss1"
        let sectionId = "sec1"

        let exercises = [
            makeExercise(id: "e1", name: "Warm Up Jog", orderIndex: 0, sets: [makeSet()]),
            makeExercise(id: supersetId, name: "Superset A", orderIndex: 1, groupType: .superset, sets: []),
            makeExercise(id: "c1", name: "Bench Press", orderIndex: 2, parentExerciseId: supersetId, sets: [makeSet()]),
            makeExercise(id: "c2", name: "Row", orderIndex: 3, parentExerciseId: supersetId, sets: [makeSet()]),
            makeExercise(id: sectionId, name: "Cooldown", orderIndex: 4, groupType: .section, groupName: "Cooldown", sets: []),
            makeExercise(id: "sc1", name: "Stretch", orderIndex: 5, parentExerciseId: sectionId, sets: [makeSet()])
        ]

        let items = ActiveWorkoutViewModel.buildDisplayItems(from: exercises)
        // single (Warm Up Jog) + superset + section header + single (Stretch)
        XCTAssertEqual(items.count, 4)

        if case .single(let ex, _, let num) = items[0] {
            XCTAssertEqual(ex.exerciseName, "Warm Up Jog")
            XCTAssertEqual(num, 1)
        } else {
            XCTFail("Expected .single for first")
        }

        if case .superset(_, let children) = items[1] {
            XCTAssertEqual(children.count, 2)
            XCTAssertEqual(children[0].displayNumber, 2)
            XCTAssertEqual(children[1].displayNumber, 3)
        } else {
            XCTFail("Expected .superset")
        }

        if case .section(let name) = items[2] {
            XCTAssertEqual(name, "Cooldown")
        } else {
            XCTFail("Expected .section")
        }

        if case .single(let ex, _, let num) = items[3] {
            XCTAssertEqual(ex.exerciseName, "Stretch")
            XCTAssertEqual(num, 4)
        } else {
            XCTFail("Expected .single for Stretch")
        }
    }

    // MARK: - Display Items: Display Number Tracking

    func testBuildDisplayItemsDisplayNumbersIncrementCorrectly() {
        let ssId = "ss1"
        let exercises = [
            makeExercise(id: "e1", name: "Ex1", orderIndex: 0, sets: [makeSet()]),
            makeExercise(id: ssId, name: "SS", orderIndex: 1, groupType: .superset, sets: []),
            makeExercise(id: "c1", name: "Ex2", orderIndex: 2, parentExerciseId: ssId, sets: [makeSet()]),
            makeExercise(id: "c2", name: "Ex3", orderIndex: 3, parentExerciseId: ssId, sets: [makeSet()]),
            makeExercise(id: "e4", name: "Ex4", orderIndex: 4, sets: [makeSet()])
        ]

        let items = ActiveWorkoutViewModel.buildDisplayItems(from: exercises)
        // single(1) + superset(children 2,3) + single(4)
        XCTAssertEqual(items.count, 3)

        if case .single(_, _, let num) = items[0] { XCTAssertEqual(num, 1) }
        if case .superset(_, let children) = items[1] {
            XCTAssertEqual(children[0].displayNumber, 2)
            XCTAssertEqual(children[1].displayNumber, 3)
        }
        if case .single(_, _, let num) = items[2] { XCTAssertEqual(num, 4) }
    }

    // MARK: - Display Items: Orphan Children Skipped

    func testBuildDisplayItemsOrphanChildrenAreSkipped() {
        // A child referencing a nonexistent parent should be skipped
        let exercises = [
            makeExercise(id: "orphan", name: "Orphan", orderIndex: 0, parentExerciseId: "nonexistent", sets: [makeSet()]),
            makeExercise(id: "e1", name: "Normal", orderIndex: 1, sets: [makeSet()])
        ]

        let items = ActiveWorkoutViewModel.buildDisplayItems(from: exercises)
        XCTAssertEqual(items.count, 1)
        if case .single(let ex, _, _) = items[0] {
            XCTAssertEqual(ex.exerciseName, "Normal")
        } else {
            XCTFail("Expected .single for Normal exercise")
        }
    }

    // MARK: - Collapse Logic: isExerciseCollapsed

    func testCollapseExplicitlyExpandedOverridesAutoCollapse() {
        let exercise = makeExercise(id: "e1", sets: [makeSet(status: .completed)])
        let result = ActiveWorkoutViewModel.isExerciseCollapsed(
            exercise,
            expandedExercises: ["e1"],
            collapsedExercises: [],
            lastInteractedExerciseId: nil,
            allExercises: [exercise]
        )
        XCTAssertFalse(result)
    }

    func testCollapseExplicitlyCollapsedOverridesDefault() {
        let exercise = makeExercise(id: "e1", sets: [makeSet(status: .pending)])
        let result = ActiveWorkoutViewModel.isExerciseCollapsed(
            exercise,
            expandedExercises: [],
            collapsedExercises: ["e1"],
            lastInteractedExerciseId: nil,
            allExercises: [exercise]
        )
        XCTAssertTrue(result)
    }

    func testCollapseAutoCollapsesWhenAllSetsCompleted() {
        let exercise = makeExercise(id: "e1", sets: [
            makeSet(status: .completed),
            makeSet(status: .completed)
        ])
        let other = makeExercise(id: "e2", sets: [makeSet(status: .pending)])
        let result = ActiveWorkoutViewModel.isExerciseCollapsed(
            exercise,
            expandedExercises: [],
            collapsedExercises: [],
            lastInteractedExerciseId: nil,
            allExercises: [exercise, other]
        )
        XCTAssertTrue(result)
    }

    func testCollapseAutoCollapsesWhenAllSetsSkipped() {
        let exercise = makeExercise(id: "e1", sets: [
            makeSet(status: .skipped),
            makeSet(status: .skipped)
        ])
        let other = makeExercise(id: "e2", sets: [makeSet(status: .pending)])
        let result = ActiveWorkoutViewModel.isExerciseCollapsed(
            exercise,
            expandedExercises: [],
            collapsedExercises: [],
            lastInteractedExerciseId: nil,
            allExercises: [exercise, other]
        )
        XCTAssertTrue(result)
    }

    func testCollapseCurrentExerciseStaysExpanded() {
        let exercise = makeExercise(id: "e1", sets: [makeSet(status: .pending)])
        let result = ActiveWorkoutViewModel.isExerciseCollapsed(
            exercise,
            expandedExercises: [],
            collapsedExercises: [],
            lastInteractedExerciseId: nil,
            allExercises: [exercise]
        )
        XCTAssertFalse(result, "First exercise with pending sets should be expanded")
    }

    func testCollapseNonCurrentPendingExerciseIsCollapsed() {
        let ex1 = makeExercise(id: "e1", sets: [makeSet(status: .pending)])
        let ex2 = makeExercise(id: "e2", sets: [makeSet(status: .pending)])
        let result = ActiveWorkoutViewModel.isExerciseCollapsed(
            ex2,
            expandedExercises: [],
            collapsedExercises: [],
            lastInteractedExerciseId: nil,
            allExercises: [ex1, ex2]
        )
        XCTAssertTrue(result, "Non-current exercise should be collapsed")
    }

    func testCollapseLastInteractedExerciseStaysExpanded() {
        let ex1 = makeExercise(id: "e1", sets: [makeSet(status: .pending)])
        let ex2 = makeExercise(id: "e2", sets: [makeSet(status: .pending)])
        let result = ActiveWorkoutViewModel.isExerciseCollapsed(
            ex2,
            expandedExercises: [],
            collapsedExercises: [],
            lastInteractedExerciseId: "e2",
            allExercises: [ex1, ex2]
        )
        XCTAssertFalse(result, "Last interacted exercise with pending sets should stay expanded")
    }

    func testCollapseLastInteractedButFullyDoneCollapses() {
        let ex1 = makeExercise(id: "e1", sets: [makeSet(status: .pending)])
        let ex2 = makeExercise(id: "e2", sets: [makeSet(status: .completed)])
        let result = ActiveWorkoutViewModel.isExerciseCollapsed(
            ex2,
            expandedExercises: [],
            collapsedExercises: [],
            lastInteractedExerciseId: "e2",
            allExercises: [ex1, ex2]
        )
        // All done -> auto-collapse takes priority before lastInteracted check
        XCTAssertTrue(result)
    }

    // MARK: - Collapse Logic: isSupersetCollapsed

    func testSupersetCollapseExplicitlyExpanded() {
        let parent = makeExercise(id: "ss1", groupType: .superset, sets: [])
        let child = (exercise: makeExercise(id: "c1", sets: [makeSet(status: .completed)]), exerciseIndex: 1, displayNumber: 1)
        let result = ActiveWorkoutViewModel.isSupersetCollapsed(
            parent, children: [child],
            expandedExercises: ["ss1"],
            collapsedExercises: [],
            lastInteractedExerciseId: nil,
            allExercises: [parent, child.exercise]
        )
        XCTAssertFalse(result)
    }

    func testSupersetCollapseExplicitlyCollapsed() {
        let parent = makeExercise(id: "ss1", groupType: .superset, sets: [])
        let child = (exercise: makeExercise(id: "c1", sets: [makeSet(status: .pending)]), exerciseIndex: 1, displayNumber: 1)
        let result = ActiveWorkoutViewModel.isSupersetCollapsed(
            parent, children: [child],
            expandedExercises: [],
            collapsedExercises: ["ss1"],
            lastInteractedExerciseId: nil,
            allExercises: [parent, child.exercise]
        )
        XCTAssertTrue(result)
    }

    func testSupersetAutoCollapsesWhenAllChildrenDone() {
        let parent = makeExercise(id: "ss1", groupType: .superset, sets: [])
        let child1 = (exercise: makeExercise(id: "c1", sets: [makeSet(status: .completed)]), exerciseIndex: 1, displayNumber: 1)
        let child2 = (exercise: makeExercise(id: "c2", sets: [makeSet(status: .skipped)]), exerciseIndex: 2, displayNumber: 2)
        let other = makeExercise(id: "e3", sets: [makeSet(status: .pending)])
        let result = ActiveWorkoutViewModel.isSupersetCollapsed(
            parent, children: [child1, child2],
            expandedExercises: [],
            collapsedExercises: [],
            lastInteractedExerciseId: nil,
            allExercises: [parent, child1.exercise, child2.exercise, other]
        )
        XCTAssertTrue(result)
    }

    func testSupersetStaysExpandedWhenChildIsCurrent() {
        let parent = makeExercise(id: "ss1", groupType: .superset, sets: [])
        let child1 = (exercise: makeExercise(id: "c1", sets: [makeSet(status: .pending)]), exerciseIndex: 1, displayNumber: 1)
        let child2 = (exercise: makeExercise(id: "c2", sets: [makeSet(status: .pending)]), exerciseIndex: 2, displayNumber: 2)
        let result = ActiveWorkoutViewModel.isSupersetCollapsed(
            parent, children: [child1, child2],
            expandedExercises: [],
            collapsedExercises: [],
            lastInteractedExerciseId: nil,
            allExercises: [parent, child1.exercise, child2.exercise]
        )
        // c1 is the first pending exercise globally, so superset should be expanded
        XCTAssertFalse(result)
    }

    func testSupersetStaysExpandedWhenChildIsLastInteracted() {
        let parent = makeExercise(id: "ss1", groupType: .superset, sets: [])
        let otherEx = makeExercise(id: "e0", sets: [makeSet(status: .pending)])
        let child1 = (exercise: makeExercise(id: "c1", sets: [makeSet(status: .pending)]), exerciseIndex: 2, displayNumber: 2)
        let result = ActiveWorkoutViewModel.isSupersetCollapsed(
            parent, children: [child1],
            expandedExercises: [],
            collapsedExercises: [],
            lastInteractedExerciseId: "c1",
            allExercises: [otherEx, parent, child1.exercise]
        )
        XCTAssertFalse(result)
    }

    func testSupersetCollapsesWhenNotCurrentAndNoInteraction() {
        let parent = makeExercise(id: "ss1", groupType: .superset, sets: [])
        let currentEx = makeExercise(id: "e0", sets: [makeSet(status: .pending)])
        let child1 = (exercise: makeExercise(id: "c1", sets: [makeSet(status: .pending)]), exerciseIndex: 2, displayNumber: 2)
        let result = ActiveWorkoutViewModel.isSupersetCollapsed(
            parent, children: [child1],
            expandedExercises: [],
            collapsedExercises: [],
            lastInteractedExerciseId: nil,
            allExercises: [currentEx, parent, child1.exercise]
        )
        XCTAssertTrue(result, "Superset not containing current exercise should collapse")
    }

    // MARK: - Helpers

    private func makeSession(
        id: String = "session1",
        exercises: [SessionExercise] = []
    ) -> WorkoutSession {
        WorkoutSession(
            id: id,
            name: "Test Workout",
            date: "2024-01-15",
            exercises: exercises,
            status: .inProgress
        )
    }

    private func makeExercise(
        id: String = UUID().uuidString,
        name: String = "Exercise",
        orderIndex: Int = 0,
        groupType: GroupType? = nil,
        groupName: String? = nil,
        parentExerciseId: String? = nil,
        sets: [SessionSet] = []
    ) -> SessionExercise {
        SessionExercise(
            id: id,
            workoutSessionId: "session1",
            exerciseName: name,
            orderIndex: orderIndex,
            groupType: groupType,
            groupName: groupName,
            parentExerciseId: parentExerciseId,
            sets: sets,
            status: .pending
        )
    }

    private func makeSet(status: SetStatus = .pending) -> SessionSet {
        SessionSet(
            sessionExerciseId: "e1",
            orderIndex: 0,
            status: status
        )
    }

    // MARK: - parseExerciseFromMarkdown

    func testParseExerciseFromMarkdownAcceptsStandaloneExerciseBlock() {
        let md = """
        ## Bicep Curl
        - 25 x 12
        - 25 x 10
        """
        let parsed = ActiveWorkoutViewModel.parseExerciseFromMarkdown(md)
        XCTAssertNotNil(parsed, "Standalone exercise block (no workout header) should parse")
        XCTAssertEqual(parsed?.name, "Bicep Curl")
        XCTAssertEqual(parsed?.sets.count, 2)
        XCTAssertEqual(parsed?.sets.first?.reps, 12)
        XCTAssertEqual(parsed?.sets.first?.weight, 25)
    }

    func testParseExerciseFromMarkdownAcceptsFullWorkoutMarkdown() {
        let md = """
        # Quick Add
        ## Bench Press
        - 135 x 5
        """
        let parsed = ActiveWorkoutViewModel.parseExerciseFromMarkdown(md)
        XCTAssertEqual(parsed?.name, "Bench Press")
        XCTAssertEqual(parsed?.sets.count, 1)
        XCTAssertEqual(parsed?.sets.first?.reps, 5)
    }

    func testParseExerciseFromMarkdownReturnsNilForEmpty() {
        XCTAssertNil(ActiveWorkoutViewModel.parseExerciseFromMarkdown(""))
        XCTAssertNil(ActiveWorkoutViewModel.parseExerciseFromMarkdown("   \n  "))
    }

    func testParseExerciseFromMarkdownReturnsNilForNoExercise() {
        // Just text, no `##` exercise header — parser should produce no exercise.
        XCTAssertNil(ActiveWorkoutViewModel.parseExerciseFromMarkdown("just some notes"))
    }

    func testParseExerciseFromMarkdownCarriesRestSeconds() {
        let md = """
        ## Bench Press
        - 135 x 5 @rest: 120s
        - 135 x 5 @rest: 180s
        """
        let parsed = ActiveWorkoutViewModel.parseExerciseFromMarkdown(md)
        XCTAssertEqual(parsed?.sets.count, 2)
        XCTAssertEqual(parsed?.sets[0].rest, 120)
        XCTAssertEqual(parsed?.sets[1].rest, 180)
    }

    // MARK: - Rest Timer Scoping (#123)
    //
    // When a user completes sets out of order, multiple exercises hold pending
    // sets simultaneously. The rest timer must only render on the card whose
    // set actually triggered it. These tests guard that scoping.

    private func makeSetWithId(_ id: String, status: SetStatus = .pending) -> SessionSet {
        SessionSet(id: id, sessionExerciseId: "e1", orderIndex: 0, status: status)
    }

    func testOwnsRestTimerReturnsFalseWhenTimerNil() {
        let exercise = makeExercise(sets: [makeSetWithId("s1", status: .completed)])
        XCTAssertFalse(ActiveWorkoutViewModel.ownsRestTimer(
            exercises: [exercise], restTimer: nil))
    }

    func testOwnsRestTimerTrueWhenExerciseContainsTriggeringSet() {
        let exercise = makeExercise(sets: [
            makeSetWithId("s1", status: .completed),
            makeSetWithId("s2", status: .pending)
        ])
        let timer = RestTimerState(seconds: 60, triggeringSetId: "s1")
        XCTAssertTrue(ActiveWorkoutViewModel.ownsRestTimer(
            exercises: [exercise], restTimer: timer))
    }

    func testOwnsRestTimerFalseWhenTriggeringSetBelongsToAnotherExercise() {
        // Exercise A has a pending set (in-progress) but DID NOT trigger the
        // timer. Exercise B owns the timer. A's card must not render the
        // timer just because it is "active". This is the #123 regression.
        let exerciseA = makeExercise(
            id: "ex-a",
            sets: [
                makeSetWithId("a1", status: .completed),
                makeSetWithId("a2", status: .pending)
            ])
        let timerOwnedByExerciseB = RestTimerState(seconds: 60, triggeringSetId: "b1")
        XCTAssertFalse(ActiveWorkoutViewModel.ownsRestTimer(
            exercises: [exerciseA], restTimer: timerOwnedByExerciseB))
    }

    func testOwnsRestTimerHandlesSupersetChildren() {
        // Superset cards pass the full list of children's exercises.
        let childA = makeExercise(id: "child-a", sets: [makeSetWithId("a1", status: .pending)])
        let childB = makeExercise(id: "child-b", sets: [makeSetWithId("b1", status: .completed)])
        let timer = RestTimerState(seconds: 90, triggeringSetId: "b1")
        XCTAssertTrue(ActiveWorkoutViewModel.ownsRestTimer(
            exercises: [childA, childB], restTimer: timer))
    }

    func testOwnsRestTimerOnlyOneCardOwnsAcrossOutOfOrderCompletion() {
        // Simulates the bug repro: two exercises, both with at least one
        // completed set and one pending set. Exactly one card may own the
        // timer.
        let cableTriExtension = makeExercise(
            id: "cable-tri",
            sets: [
                makeSetWithId("cable-s1", status: .completed),
                makeSetWithId("cable-s2", status: .pending)
            ])
        let dbCurls = makeExercise(
            id: "db-curls",
            sets: [
                makeSetWithId("db-s1", status: .completed),
                makeSetWithId("db-s2", status: .pending)
            ])
        // The user just completed cable-s1 — that's the triggering set.
        let timer = RestTimerState(seconds: 55, triggeringSetId: "cable-s1")

        let cableOwns = ActiveWorkoutViewModel.ownsRestTimer(
            exercises: [cableTriExtension], restTimer: timer)
        let curlsOwns = ActiveWorkoutViewModel.ownsRestTimer(
            exercises: [dbCurls], restTimer: timer)

        XCTAssertTrue(cableOwns)
        XCTAssertFalse(curlsOwns, "DB Curls card must not echo the timer started by Cable Tri Extension (#123)")
    }
}
