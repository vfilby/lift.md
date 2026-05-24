import XCTest
@testable import LiftMark

/// Coverage for `InboxWorkoutMapper.toWorkoutPlan` — the translation seam
/// between the validator's parser output and the app's WorkoutPlan model.
/// The test fixtures mirror the JSON shape emitted by the server's parser
/// (`validator/src/parser/types.ts`), so a server-side rename will surface
/// here via Decodable failures.
final class InboxWorkoutMapperTests: XCTestCase {

    // MARK: - Decoding fidelity

    func testDecodesValidatorParserShape() throws {
        let json = """
        {
          "name": "Push Day",
          "description": null,
          "tags": ["strength", "upper"],
          "defaultWeightUnit": "lbs",
          "exercises": [
            {
              "exerciseName": "Bench Press",
              "orderIndex": 0,
              "notes": null,
              "equipmentType": null,
              "groupType": null,
              "groupName": null,
              "parentExerciseId": null,
              "sets": [
                {
                  "orderIndex": 0,
                  "targetWeight": 135,
                  "targetWeightUnit": null,
                  "targetReps": 5,
                  "targetTime": null,
                  "targetDistance": null,
                  "targetDistanceUnit": null,
                  "targetRpe": null,
                  "restSeconds": null,
                  "tempo": null,
                  "isDropset": false,
                  "isPerSide": false,
                  "isAmrap": false,
                  "notes": null
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let inbox = try JSONDecoder().decode(InboxWorkout.self, from: json)
        XCTAssertEqual(inbox.name, "Push Day")
        XCTAssertEqual(inbox.defaultWeightUnit, "lbs")
        XCTAssertEqual(inbox.tags, ["strength", "upper"])
        XCTAssertEqual(inbox.exercises.count, 1)
        XCTAssertEqual(inbox.exercises[0].sets.first?.targetWeight, 135)
    }

    // MARK: - Mapping

    func testMapsCoreFieldsAndGeneratesFreshIds() {
        let inbox = InboxWorkout(
            name: "Leg Day",
            description: "Heavy session",
            tags: ["lower"],
            defaultWeightUnit: "kg",
            exercises: [
                InboxExercise(
                    exerciseName: "Back Squat",
                    orderIndex: 0,
                    notes: "Belt on working sets",
                    equipmentType: "barbell",
                    groupType: nil,
                    groupName: nil,
                    parentExerciseId: nil,
                    sets: [
                        InboxSet(
                            orderIndex: 0, targetWeight: 100, targetWeightUnit: nil,
                            targetReps: 5, targetTime: nil, targetDistance: nil,
                            targetDistanceUnit: nil, targetRpe: 8, restSeconds: 180,
                            tempo: nil, isDropset: false, isPerSide: false,
                            isAmrap: false, notes: nil
                        )
                    ]
                )
            ]
        )

        let plan = InboxWorkoutMapper.toWorkoutPlan(inbox)
        XCTAssertEqual(plan.name, "Leg Day")
        XCTAssertEqual(plan.description, "Heavy session")
        XCTAssertEqual(plan.tags, ["lower"])
        XCTAssertEqual(plan.defaultWeightUnit, .kg)
        XCTAssertNil(plan.sourceMarkdown)
        XCTAssertFalse(plan.isFavorite)

        // Plan + exercise + set IDs are all freshly minted UUIDs. The
        // server's exercise ID is parser-local and must not leak through.
        XCTAssertNotNil(UUID(uuidString: plan.id))
        XCTAssertEqual(plan.exercises.count, 1)
        let ex = plan.exercises[0]
        XCTAssertEqual(ex.exerciseName, "Back Squat")
        XCTAssertEqual(ex.equipmentType, "barbell")
        XCTAssertEqual(ex.notes, "Belt on working sets")
        XCTAssertEqual(ex.workoutPlanId, plan.id)
        XCTAssertNotNil(UUID(uuidString: ex.id))

        XCTAssertEqual(ex.sets.count, 1)
        let set = ex.sets[0]
        XCTAssertEqual(set.targetWeight, 100)
        // Falls back to defaultWeightUnit when the set didn't carry one.
        XCTAssertEqual(set.targetWeightUnit, .kg)
        XCTAssertEqual(set.targetReps, 5)
        XCTAssertEqual(set.targetRpe, 8)
        XCTAssertEqual(set.restSeconds, 180)
        XCTAssertEqual(set.plannedExerciseId, ex.id)
    }

    func testPreservesModifiersAndOrderIndices() {
        let inbox = InboxWorkout(
            name: "Set Test", description: nil, tags: nil, defaultWeightUnit: "lbs",
            exercises: [
                InboxExercise(
                    exerciseName: "DB Row", orderIndex: 2, notes: nil,
                    equipmentType: nil, groupType: nil, groupName: nil,
                    parentExerciseId: nil,
                    sets: [
                        InboxSet(
                            orderIndex: 0, targetWeight: 50, targetWeightUnit: "lbs",
                            targetReps: 10, targetTime: nil, targetDistance: nil,
                            targetDistanceUnit: nil, targetRpe: nil, restSeconds: nil,
                            tempo: nil, isDropset: true, isPerSide: true,
                            isAmrap: false, notes: "warmup"
                        ),
                        InboxSet(
                            orderIndex: 1, targetWeight: 60, targetWeightUnit: "lbs",
                            targetReps: nil, targetTime: nil, targetDistance: nil,
                            targetDistanceUnit: nil, targetRpe: nil, restSeconds: nil,
                            tempo: nil, isDropset: false, isPerSide: false,
                            isAmrap: true, notes: nil
                        )
                    ]
                )
            ]
        )

        let plan = InboxWorkoutMapper.toWorkoutPlan(inbox)
        let ex = plan.exercises[0]
        XCTAssertEqual(ex.orderIndex, 2)
        XCTAssertEqual(ex.sets[0].orderIndex, 0)
        XCTAssertTrue(ex.sets[0].isDropset)
        XCTAssertTrue(ex.sets[0].isPerSide)
        XCTAssertFalse(ex.sets[0].isAmrap)
        XCTAssertEqual(ex.sets[0].notes, "warmup")

        XCTAssertEqual(ex.sets[1].orderIndex, 1)
        XCTAssertTrue(ex.sets[1].isAmrap)
        XCTAssertFalse(ex.sets[1].isDropset)
    }

    func testGroupTypeAndParentIdHandling() {
        let inbox = InboxWorkout(
            name: "Superset", description: nil, tags: nil, defaultWeightUnit: "lbs",
            exercises: [
                InboxExercise(
                    exerciseName: "Bench", orderIndex: 0, notes: nil,
                    equipmentType: nil,
                    groupType: "superset",
                    groupName: "Push A",
                    // Server's parser-local ID — must be dropped on import
                    // because it doesn't match any locally-generated ID.
                    parentExerciseId: "server-uuid-1234",
                    sets: []
                )
            ]
        )

        let plan = InboxWorkoutMapper.toWorkoutPlan(inbox)
        let ex = plan.exercises[0]
        XCTAssertEqual(ex.groupType, .superset)
        XCTAssertEqual(ex.groupName, "Push A")
        XCTAssertNil(ex.parentExerciseId, "Server's parser-local parent id must not leak through.")
    }

    func testUnknownDefaultWeightUnitDropsToNil() {
        let inbox = InboxWorkout(
            name: "Bad Unit", description: nil, tags: nil,
            defaultWeightUnit: "stones",
            exercises: []
        )
        let plan = InboxWorkoutMapper.toWorkoutPlan(inbox)
        XCTAssertNil(plan.defaultWeightUnit)
    }

    func testEmptyTagsAndDescriptionTolerated() {
        let inbox = InboxWorkout(
            name: "Bare", description: nil, tags: nil, defaultWeightUnit: nil,
            exercises: []
        )
        let plan = InboxWorkoutMapper.toWorkoutPlan(inbox)
        XCTAssertEqual(plan.tags, [])
        XCTAssertNil(plan.description)
        XCTAssertEqual(plan.exercises, [])
    }
}
