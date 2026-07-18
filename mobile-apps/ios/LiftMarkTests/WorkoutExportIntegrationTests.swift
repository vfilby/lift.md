import XCTest
@testable import LiftMark

final class WorkoutExportIntegrationTests: XCTestCase {

    private var service: WorkoutExportService!
    private var sessionRepo: SessionRepository!
    private var planRepo: WorkoutPlanRepository!

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
        service = WorkoutExportService()
        sessionRepo = SessionRepository()
        planRepo = WorkoutPlanRepository()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    // MARK: - exportSingleSessionAsJson

    func testExportSingleSessionCreatesFile() throws {
        let session = try createCompletedSession(
            name: "Push Day",
            exercises: [("Bench Press", 225, 5)]
        )

        let url = try service.exportSingleSessionAsJson(session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["exportedAt"])
        XCTAssertNotNil(json["appVersion"])

        let sessionJson = try XCTUnwrap(json["session"] as? [String: Any])
        XCTAssertEqual(sessionJson["name"] as? String, "Push Day")
        XCTAssertEqual(sessionJson["status"] as? String, "completed")

        let exercises = try XCTUnwrap(sessionJson["exercises"] as? [[String: Any]])
        XCTAssertEqual(exercises.count, 1)
        XCTAssertEqual(exercises[0]["exerciseName"] as? String, "Bench Press")
    }

    func testExportSingleSessionStripsSetData() throws {
        let session = try createCompletedSession(
            name: "Test",
            exercises: [("Squat", 315, 3)]
        )

        let url = try service.exportSingleSessionAsJson(session)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessionJson = try XCTUnwrap(json["session"] as? [String: Any])
        let exercises = try XCTUnwrap(sessionJson["exercises"] as? [[String: Any]])
        let sets = try XCTUnwrap(exercises[0]["sets"] as? [[String: Any]])

        // Sets should have stripped data (no internal IDs)
        XCTAssertEqual(sets.count, 1)
        XCTAssertNotNil(sets[0]["targetWeight"])
        XCTAssertNotNil(sets[0]["status"])
        XCTAssertNil(sets[0]["id"]) // Internal ID stripped
        XCTAssertNil(sets[0]["sessionExerciseId"]) // FK stripped
    }

    func testExportSingleSessionIncludesOptionalFields() throws {
        let plan = makeDetailedBenchPlan()
        try planRepo.create(plan)
        let (session, _) = try sessionRepo.createFromPlan(plan)

        // Complete with actual values
        let setId = session.exercises[0].sets[0].id
        try sessionRepo.updateSessionSet(
            setId,
            actualWeight: 230,
            actualWeightUnit: .lbs,
            actualReps: 4,
            actualTime: nil,
            actualRpe: 9,
            status: .completed
        )
        try sessionRepo.complete(session.id)
        let completed = try sessionRepo.getById(session.id)!

        let url = try service.exportSingleSessionAsJson(completed)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessionJson = try XCTUnwrap(json["session"] as? [String: Any])

        XCTAssertNotNil(sessionJson["startTime"])
        XCTAssertNotNil(sessionJson["endTime"])
        XCTAssertNotNil(sessionJson["duration"])

        let exercises = try XCTUnwrap(sessionJson["exercises"] as? [[String: Any]])
        XCTAssertEqual(exercises[0]["notes"] as? String, "Heavy day")
        XCTAssertEqual(exercises[0]["equipmentType"] as? String, "barbell")

        let sets = try XCTUnwrap(exercises[0]["sets"] as? [[String: Any]])
        XCTAssertEqual(sets[0]["actualWeight"] as? Double, 230)
        XCTAssertEqual(sets[0]["actualReps"] as? Int, 4)
        XCTAssertEqual(sets[0]["actualRpe"] as? Int, 9)
        XCTAssertEqual(sets[0]["targetRpe"] as? Int, 8)
        XCTAssertEqual(sets[0]["restSeconds"] as? Int, 180)
        XCTAssertNil(sets[0]["tempo"]) // tempo is deprecated
    }

    // MARK: - exportSessionsAsJson

    func testExportAllSessionsThrowsWhenNoCompleted() {
        XCTAssertThrowsError(try service.exportSessionsAsJson()) { error in
            XCTAssertTrue(error is ExportError)
        }
    }

    func testExportAllSessionsCreatesFile() throws {
        _ = try createCompletedSession(name: "Session 1", exercises: [("Bench", 225, 5)])
        _ = try createCompletedSession(name: "Session 2", exercises: [("Squat", 315, 3)])

        let url = try service.exportSessionsAsJson()
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 2)
    }

    // MARK: - Unified Export

    func testUnifiedExportCreatesValidJson() throws {
        // Create a plan
        let plan = makeIntegrationTestPlan()
        try planRepo.create(plan)

        // Create a completed session
        _ = try createCompletedSession(name: "Export Test Session", exercises: [("Squat", 225, 5)])

        // Export unified JSON
        let url = try service.exportUnifiedJson()
        defer { try? FileManager.default.removeItem(at: url) }

        // Parse and validate structure
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Top-level fields
        XCTAssertEqual(json["formatVersion"] as? String, "1.0")
        XCTAssertNotNil(json["exportedAt"])
        XCTAssertNotNil(json["appVersion"])

        // Plans
        let plans = try XCTUnwrap(json["plans"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(plans.count, 1)
        let exportedPlan = plans.first { ($0["name"] as? String) == "Integration Test Plan" }
        XCTAssertNotNil(exportedPlan)
        XCTAssertEqual(exportedPlan?["defaultWeightUnit"] as? String, "lbs")
        let planTags = exportedPlan?["tags"] as? [String]
        XCTAssertTrue(planTags?.contains("test") ?? false)
        XCTAssertNotNil(exportedPlan?["sourceMarkdown"])

        // Plan exercises
        let planExercises = exportedPlan?["exercises"] as? [[String: Any]]
        XCTAssertEqual(planExercises?.count, 1)
        XCTAssertEqual(planExercises?[0]["exerciseName"] as? String, "Bench Press")

        // Plan sets — no internal IDs
        let planSets = planExercises?[0]["sets"] as? [[String: Any]]
        XCTAssertEqual(planSets?.count, 1)
        XCTAssertNil(planSets?[0]["id"])
        XCTAssertNil(planSets?[0]["plannedExerciseId"])
        XCTAssertEqual(planSets?[0]["targetWeight"] as? Double, 135)

        // Sessions
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(sessions.count, 1)

        // Gyms
        let gyms = json["gyms"] as? [[String: Any]]
        XCTAssertNotNil(gyms)

        // Settings
        let settings = json["settings"] as? [String: Any]
        XCTAssertNotNil(settings)
        // API key must NOT be in settings
        XCTAssertNil(settings?["anthropicApiKey"])
        XCTAssertNil(settings?["apiKey"])
    }

    func testUnifiedExportValidatesAgainstSchema() throws {
        // Create test data
        _ = try createCompletedSession(name: "Schema Validation Session", exercises: [("Deadlift", 315, 3)])

        // Export
        let url = try service.exportUnifiedJson()
        defer { try? FileManager.default.removeItem(at: url) }

        // Validate against JSON schema using Python tool
        let schemaPath = findProjectRoot()?
            .appendingPathComponent("spec/data/schemas/liftmark-export-unified.schema.json")
        guard let schemaPath, FileManager.default.fileExists(atPath: schemaPath.path) else {
            // Skip if we can't find the schema (CI environment)
            return
        }

        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Inline validation of required fields and types
        XCTAssertEqual(json["formatVersion"] as? String, "1.0")
        XCTAssertNotNil(json["exportedAt"] as? String)
        XCTAssertNotNil(json["appVersion"] as? String)

        // Validate sessions array structure
        assertSessionsMatchSchema(json)

        // Validate plans array structure
        assertPlansMatchSchema(json)
    }

    private func assertSessionsMatchSchema(
        _ json: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) {
        if let sessions = json["sessions"] as? [[String: Any]] {
            for session in sessions {
                XCTAssertNotNil(session["name"] as? String, file: file, line: line)
                XCTAssertNotNil(session["date"] as? String, file: file, line: line)
                XCTAssertNotNil(session["status"] as? String, file: file, line: line)
                if let exercises = session["exercises"] as? [[String: Any]] {
                    for exercise in exercises {
                        XCTAssertNotNil(exercise["exerciseName"] as? String, file: file, line: line)
                        XCTAssertNotNil(exercise["orderIndex"], file: file, line: line)
                        XCTAssertNotNil(exercise["status"] as? String, file: file, line: line)
                        assertSessionSetsMatchSchema(exercise, file: file, line: line)
                    }
                }
            }
        }
    }

    private func assertSessionSetsMatchSchema(
        _ exercise: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) {
        if let sets = exercise["sets"] as? [[String: Any]] {
            for set in sets {
                XCTAssertNotNil(set["orderIndex"], file: file, line: line)
                XCTAssertNotNil(set["status"] as? String, file: file, line: line)
                // Verify booleans are actual booleans, not ints
                if let isDropset = set["isDropset"] {
                    XCTAssertTrue(isDropset is Bool,
                                  "isDropset should be Bool, got \(type(of: isDropset))",
                                  file: file, line: line)
                }
                if let isPerSide = set["isPerSide"] {
                    XCTAssertTrue(isPerSide is Bool,
                                  "isPerSide should be Bool, got \(type(of: isPerSide))",
                                  file: file, line: line)
                }
            }
        }
    }

    private func assertPlansMatchSchema(
        _ json: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) {
        if let plans = json["plans"] as? [[String: Any]] {
            for plan in plans {
                XCTAssertNotNil(plan["name"] as? String, file: file, line: line)
                if let exercises = plan["exercises"] as? [[String: Any]] {
                    for exercise in exercises {
                        XCTAssertNotNil(exercise["exerciseName"] as? String, file: file, line: line)
                        XCTAssertNotNil(exercise["orderIndex"], file: file, line: line)
                        if let sets = exercise["sets"] as? [[String: Any]] {
                            for set in sets {
                                XCTAssertNotNil(set["orderIndex"], file: file, line: line)
                                if let isDropset = set["isDropset"] {
                                    XCTAssertTrue(isDropset is Bool, "Plan set isDropset should be Bool",
                                                  file: file, line: line)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Import from Spec Fixture

    func testImportSpecFixtureAndVerifyData() throws {
        let importService = JsonImportService()

        // Find the spec-compliant fixture
        guard let fixtureURL = findProjectRoot()?.appendingPathComponent("test-fixtures/unified-export-sample.json"),
              FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail("Could not find test-fixtures/unified-export-sample.json")
            return
        }

        // Validate the fixture is recognized
        XCTAssertTrue(importService.validateJsonFile(at: fixtureURL))

        // Import
        let result = try importService.importUnifiedJson(from: fixtureURL)

        // Verify plans were imported
        XCTAssertEqual(result.plansImported, 2, "Should import 2 plans")
        XCTAssertEqual(result.plansSkipped, 0)

        // Verify sessions were imported
        XCTAssertEqual(result.sessionsImported, 1, "Should import 1 session")
        XCTAssertEqual(result.sessionsSkipped, 0)

        // Verify gyms were imported
        XCTAssertEqual(result.gymsImported, 1, "Should import 1 gym")
        XCTAssertEqual(result.gymsSkipped, 0)

        // Verify imported plan data is in the database
        let plans = try planRepo.getAll()
        let importedPlan = plans.first { $0.name == "Test Push Day" }
        XCTAssertNotNil(importedPlan, "Test Push Day plan should exist")
        XCTAssertEqual(importedPlan?.exercises.count, 2)
        XCTAssertEqual(importedPlan?.exercises[0].exerciseName, "Bench Press")
        XCTAssertEqual(importedPlan?.exercises[0].sets.count, 3)
        XCTAssertEqual(importedPlan?.exercises[0].sets[0].targetWeight, 135)
        XCTAssertEqual(importedPlan?.exercises[0].sets[0].targetWeightUnit, .lbs)
        XCTAssertEqual(importedPlan?.exercises[0].sets[0].targetReps, 10)
        XCTAssertNil(importedPlan?.exercises[0].sets[2].tempo) // tempo is deprecated

        // Verify imported session data
        let sessions = try sessionRepo.getCompleted()
        let importedSession = sessions.first { $0.name == "Test Push Day" }
        XCTAssertNotNil(importedSession, "Test Push Day session should exist")
        XCTAssertEqual(importedSession?.exercises.count, 2)
        XCTAssertEqual(importedSession?.exercises[0].exerciseName, "Bench Press")
        XCTAssertEqual(importedSession?.exercises[0].sets.count, 3)
        XCTAssertEqual(importedSession?.exercises[0].sets[0].actualWeight, 135)
        XCTAssertEqual(importedSession?.exercises[0].sets[0].actualReps, 10)
        XCTAssertEqual(importedSession?.exercises[0].sets[1].actualRpe, 7)

        // Verify the second session exercise
        XCTAssertEqual(importedSession?.exercises[1].exerciseName, "Overhead Press")
        XCTAssertEqual(importedSession?.exercises[1].sets[1].notes, "Missed last rep")
    }

    func testImportDuplicateSkipsExisting() throws {
        let importService = JsonImportService()

        guard let fixtureURL = findProjectRoot()?.appendingPathComponent("test-fixtures/unified-export-sample.json"),
              FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail("Could not find test-fixtures/unified-export-sample.json")
            return
        }

        // Import once
        let result1 = try importService.importUnifiedJson(from: fixtureURL)
        XCTAssertEqual(result1.plansImported, 2)
        XCTAssertEqual(result1.sessionsImported, 1)

        // Import again — should skip duplicates
        let result2 = try importService.importUnifiedJson(from: fixtureURL)
        XCTAssertEqual(result2.plansImported, 0)
        XCTAssertEqual(result2.plansSkipped, 2)
        XCTAssertEqual(result2.sessionsImported, 0)
        XCTAssertEqual(result2.sessionsSkipped, 1)
        XCTAssertEqual(result2.gymsSkipped, 1)
    }

    // MARK: - Round-Trip Test

    func testExportThenImportRoundTrip() throws {
        let importService = JsonImportService()

        // Create original data
        let plan = WorkoutPlan(
            name: "Round Trip Plan",
            tags: ["roundtrip"],
            defaultWeightUnit: .lbs,
            exercises: [PlannedExercise(
                workoutPlanId: "p",
                exerciseName: "Curl",
                orderIndex: 0,
                sets: [PlannedSet(
                    plannedExerciseId: "e",
                    orderIndex: 0,
                    targetWeight: 30,
                    targetWeightUnit: .lbs,
                    targetReps: 12
                )]
            )]
        )
        try planRepo.create(plan)
        _ = try createCompletedSession(name: "Round Trip Session", exercises: [("Curl", 30, 12)])

        // Export
        let exportURL = try service.exportUnifiedJson()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        // Reset database
        DatabaseManager.shared.deleteDatabase()
        sessionRepo = SessionRepository()
        planRepo = WorkoutPlanRepository()

        // Verify empty
        XCTAssertEqual(try planRepo.getAll().count, 0)
        XCTAssertEqual(try sessionRepo.getCompleted().count, 0)

        // Import
        let result = try importService.importUnifiedJson(from: exportURL)
        XCTAssertGreaterThanOrEqual(result.plansImported, 1)
        XCTAssertGreaterThanOrEqual(result.sessionsImported, 1)

        // Verify round-tripped data
        let plans = try planRepo.getAll()
        let roundTrippedPlan = plans.first { $0.name == "Round Trip Plan" }
        XCTAssertNotNil(roundTrippedPlan)
        XCTAssertEqual(roundTrippedPlan?.exercises[0].exerciseName, "Curl")
        XCTAssertEqual(roundTrippedPlan?.exercises[0].sets[0].targetWeight, 30)

        let sessions = try sessionRepo.getCompleted()
        let roundTrippedSession = sessions.first { $0.name == "Round Trip Session" }
        XCTAssertNotNil(roundTrippedSession)
        XCTAssertEqual(roundTrippedSession?.exercises[0].exerciseName, "Curl")
    }

    // MARK: - Helpers

    /// Plan exercising the optional fields (notes, equipment, RPE, rest, tempo).
    private func makeDetailedBenchPlan() -> WorkoutPlan {
        WorkoutPlan(
            name: "Detailed",
            exercises: [PlannedExercise(
                workoutPlanId: "p",
                exerciseName: "Bench",
                orderIndex: 0,
                notes: "Heavy day",
                equipmentType: "barbell",
                sets: [PlannedSet(
                    plannedExerciseId: "e",
                    orderIndex: 0,
                    targetWeight: 225,
                    targetWeightUnit: .lbs,
                    targetReps: 5,
                    targetRpe: 8,
                    restSeconds: 180,
                    tempo: "3-1-1-0"
                )]
            )]
        )
    }

    /// Plan with tags, source markdown, and one bench set for unified-export tests.
    private func makeIntegrationTestPlan() -> WorkoutPlan {
        WorkoutPlan(
            name: "Integration Test Plan",
            tags: ["test", "push"],
            defaultWeightUnit: .lbs,
            sourceMarkdown: "# Integration Test Plan\n## Bench Press\n- 135 x 10",
            exercises: [PlannedExercise(
                workoutPlanId: "p",
                exerciseName: "Bench Press",
                orderIndex: 0,
                equipmentType: "barbell",
                sets: [PlannedSet(
                    plannedExerciseId: "e",
                    orderIndex: 0,
                    targetWeight: 135,
                    targetWeightUnit: .lbs,
                    targetReps: 10,
                    restSeconds: 90
                )]
            )]
        )
    }

    private func findProjectRoot() -> URL? {
        // Try to find the project root by walking up from the source file location
        // The source file is at mobile-apps/ios/LiftMarkTests/WorkoutExportIntegrationTests.swift
        // Project root is 3 levels up from mobile-apps/ios/
        let sourceFile = URL(fileURLWithPath: #filePath)
        var dir = sourceFile.deletingLastPathComponent() // LiftMarkTests/
        dir = dir.deletingLastPathComponent() // ios/
        dir = dir.deletingLastPathComponent() // mobile-apps/
        dir = dir.deletingLastPathComponent() // project root

        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("spec").path) {
            return dir
        }

        // Fallback: walk up from test bundle
        dir = Bundle(for: type(of: self)).bundleURL
        for _ in 0..<15 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("spec").path) {
                return dir
            }
        }
        return nil
    }

    private func createCompletedSession(name: String, exercises: [(String, Double, Int)]) throws -> WorkoutSession {
        var plannedExercises: [PlannedExercise] = []
        for (i, ex) in exercises.enumerated() {
            plannedExercises.append(PlannedExercise(
                workoutPlanId: "plan",
                exerciseName: ex.0,
                orderIndex: i,
                sets: [PlannedSet(
                    plannedExerciseId: "ex",
                    orderIndex: 0,
                    targetWeight: ex.1,
                    targetWeightUnit: .lbs,
                    targetReps: ex.2
                )]
            ))
        }
        let plan = WorkoutPlan(name: name, exercises: plannedExercises)
        try planRepo.create(plan)
        let (session, _) = try sessionRepo.createFromPlan(plan)

        for exercise in session.exercises {
            for set in exercise.sets {
                try sessionRepo.updateSessionSet(
                    set.id,
                    actualWeight: set.targetWeight,
                    actualWeightUnit: .lbs,
                    actualReps: set.targetReps,
                    actualTime: nil,
                    actualRpe: nil,
                    status: .completed
                )
            }
        }
        try sessionRepo.complete(session.id)
        return try sessionRepo.getById(session.id)!
    }
}
