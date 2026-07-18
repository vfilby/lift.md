import XCTest
@testable import LiftMark

final class JsonImportServiceTests: XCTestCase {

    private var service: JsonImportService!
    private var sessionRepo: SessionRepository!
    private var planRepo: WorkoutPlanRepository!

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
        service = JsonImportService()
        sessionRepo = SessionRepository()
        planRepo = WorkoutPlanRepository()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    // MARK: - Valid Import

    func testImportValidUnifiedJson() throws {
        let url = try createTempJsonFile(content: validUnifiedJson)

        let result = try service.importUnifiedJson(from: url)

        XCTAssertEqual(result.plansImported, 1)
        XCTAssertEqual(result.sessionsImported, 1)
        XCTAssertEqual(result.gymsImported, 1)
        XCTAssertEqual(result.plansSkipped, 0)
        XCTAssertEqual(result.sessionsSkipped, 0)
        XCTAssertEqual(result.gymsSkipped, 0)

        // Verify data actually landed in the database
        let plans = try planRepo.getAll()
        let importedPlan = plans.first { $0.name == "Import Test Plan" }
        XCTAssertNotNil(importedPlan)
        XCTAssertEqual(importedPlan?.exercises.count, 1)
        XCTAssertEqual(importedPlan?.exercises[0].exerciseName, "Squat")
        XCTAssertEqual(importedPlan?.exercises[0].sets.count, 1)
        XCTAssertEqual(importedPlan?.exercises[0].sets[0].targetWeight, 225)
        XCTAssertEqual(importedPlan?.exercises[0].sets[0].targetReps, 5)

        let sessions = try sessionRepo.getCompleted()
        let importedSession = sessions.first { $0.name == "Import Test Session" }
        XCTAssertNotNil(importedSession)
        XCTAssertEqual(importedSession?.exercises.count, 1)
        XCTAssertEqual(importedSession?.exercises[0].exerciseName, "Squat")
        XCTAssertEqual(importedSession?.exercises[0].sets[0].actualWeight, 225)
    }

    // MARK: - Malformed JSON

    func testImportMalformedJsonThrowsInvalidFormat() throws {
        let url = try createTempJsonFile(content: "{ this is not valid json }")

        XCTAssertThrowsError(try service.importUnifiedJson(from: url)) { error in
            // Should throw a decoding error, not crash
            XCTAssertFalse(error is JsonImportError, "Malformed JSON should throw a serialization error")
        }
    }

    func testImportNonDictionaryJsonThrowsInvalidFormat() throws {
        let url = try createTempJsonFile(content: "[1, 2, 3]")

        XCTAssertThrowsError(try service.importUnifiedJson(from: url)) { error in
            if let importError = error as? JsonImportError {
                XCTAssertTrue(importError.errorDescription?.contains("not valid JSON") ?? false)
            }
        }
    }

    // MARK: - Missing Required Fields

    func testImportPlanWithMissingNameSkipsSilently() throws {
        let json = """
        {
            "formatVersion": "1.0",
            "plans": [
                {
                    "description": "No name field",
                    "exercises": []
                }
            ]
        }
        """
        let url = try createTempJsonFile(content: json)

        let result = try service.importUnifiedJson(from: url)

        // Plan without a name should be silently skipped (not imported, not counted as skipped)
        XCTAssertEqual(result.plansImported, 0)
        XCTAssertEqual(result.plansSkipped, 0)
    }

    func testImportSessionWithMissingNameSkipsSilently() throws {
        let json = """
        {
            "formatVersion": "1.0",
            "sessions": [
                {
                    "date": "2026-03-01",
                    "status": "completed"
                }
            ]
        }
        """
        let url = try createTempJsonFile(content: json)

        let result = try service.importUnifiedJson(from: url)

        XCTAssertEqual(result.sessionsImported, 0)
        XCTAssertEqual(result.sessionsSkipped, 0)
    }

    func testImportSessionWithMissingDateSkipsSilently() throws {
        let json = """
        {
            "formatVersion": "1.0",
            "sessions": [
                {
                    "name": "No Date Session",
                    "status": "completed"
                }
            ]
        }
        """
        let url = try createTempJsonFile(content: json)

        let result = try service.importUnifiedJson(from: url)

        XCTAssertEqual(result.sessionsImported, 0)
        XCTAssertEqual(result.sessionsSkipped, 0)
    }

    func testImportGymWithMissingNameSkipsSilently() throws {
        let json = """
        {
            "formatVersion": "1.0",
            "gyms": [
                {
                    "isDefault": false
                }
            ]
        }
        """
        let url = try createTempJsonFile(content: json)

        let result = try service.importUnifiedJson(from: url)

        XCTAssertEqual(result.gymsImported, 0)
        XCTAssertEqual(result.gymsSkipped, 0)
    }

    // MARK: - Duplicate Detection

    func testImportSameDataTwiceSkipsDuplicates() throws {
        let url = try createTempJsonFile(content: validUnifiedJson)

        let result1 = try service.importUnifiedJson(from: url)
        XCTAssertEqual(result1.plansImported, 1)
        XCTAssertEqual(result1.sessionsImported, 1)
        XCTAssertEqual(result1.gymsImported, 1)

        // Import again
        let result2 = try service.importUnifiedJson(from: url)
        XCTAssertEqual(result2.plansImported, 0)
        XCTAssertEqual(result2.plansSkipped, 1)
        XCTAssertEqual(result2.sessionsImported, 0)
        XCTAssertEqual(result2.sessionsSkipped, 1)
        XCTAssertEqual(result2.gymsImported, 0)
        XCTAssertEqual(result2.gymsSkipped, 1)

        // Database should still have only one of each
        let plans = try planRepo.getAll()
        XCTAssertEqual(plans.filter { $0.name == "Import Test Plan" }.count, 1)
    }

    func testDuplicatePlanDetectedByName() throws {
        let json1 = """
        {
            "formatVersion": "1.0",
            "plans": [{ "name": "Same Name", "exercises": [] }]
        }
        """
        let json2 = """
        {
            "formatVersion": "1.0",
            "plans": [{ "name": "Same Name", "description": "Different description", "exercises": [] }]
        }
        """
        let url1 = try createTempJsonFile(content: json1)
        let url2 = try createTempJsonFile(content: json2)

        let result1 = try service.importUnifiedJson(from: url1)
        XCTAssertEqual(result1.plansImported, 1)

        let result2 = try service.importUnifiedJson(from: url2)
        XCTAssertEqual(result2.plansImported, 0)
        XCTAssertEqual(result2.plansSkipped, 1)
    }

    func testDuplicateSessionDetectedByNameAndDate() throws {
        let json1 = """
        {
            "formatVersion": "1.0",
            "sessions": [{ "name": "Leg Day", "date": "2026-03-01", "status": "completed" }]
        }
        """
        // Same name, different date should be imported as new
        let json2 = """
        {
            "formatVersion": "1.0",
            "sessions": [{ "name": "Leg Day", "date": "2026-03-02", "status": "completed" }]
        }
        """
        let url1 = try createTempJsonFile(content: json1)
        let url2 = try createTempJsonFile(content: json2)

        let result1 = try service.importUnifiedJson(from: url1)
        XCTAssertEqual(result1.sessionsImported, 1)

        let result2 = try service.importUnifiedJson(from: url2)
        XCTAssertEqual(result2.sessionsImported, 1, "Same name but different date should import as new session")
        XCTAssertEqual(result2.sessionsSkipped, 0)
    }

    // MARK: - Empty Collections

    func testImportEmptyPlansArray() throws {
        let json = """
        {
            "formatVersion": "1.0",
            "plans": [],
            "sessions": [],
            "gyms": []
        }
        """
        let url = try createTempJsonFile(content: json)

        let result = try service.importUnifiedJson(from: url)

        XCTAssertEqual(result.plansImported, 0)
        XCTAssertEqual(result.plansSkipped, 0)
        XCTAssertEqual(result.sessionsImported, 0)
        XCTAssertEqual(result.sessionsSkipped, 0)
        XCTAssertEqual(result.gymsImported, 0)
        XCTAssertEqual(result.gymsSkipped, 0)
        XCTAssertEqual(result.summary, "No data to import.")
    }

    func testImportJsonWithNoCollectionKeys() throws {
        let json = """
        {
            "formatVersion": "1.0",
            "exportedAt": "2026-03-01T00:00:00Z"
        }
        """
        let url = try createTempJsonFile(content: json)

        let result = try service.importUnifiedJson(from: url)

        XCTAssertEqual(result.plansImported, 0)
        XCTAssertEqual(result.sessionsImported, 0)
        XCTAssertEqual(result.gymsImported, 0)
        XCTAssertEqual(result.summary, "No data to import.")
    }

    // MARK: - Schema Version Compatibility

    func testImportWithVersion1_0Succeeds() throws {
        let json = """
        {
            "formatVersion": "1.0",
            "plans": [{ "name": "Versioned Plan", "exercises": [] }]
        }
        """
        let url = try createTempJsonFile(content: json)

        let result = try service.importUnifiedJson(from: url)
        XCTAssertEqual(result.plansImported, 1)
    }

    func testImportWithUnsupportedVersionThrows() throws {
        let json = """
        {
            "formatVersion": "2.0",
            "plans": [{ "name": "Future Plan", "exercises": [] }]
        }
        """
        let url = try createTempJsonFile(content: json)

        XCTAssertThrowsError(try service.importUnifiedJson(from: url)) { error in
            guard let importError = error as? JsonImportError else {
                XCTFail("Expected JsonImportError, got \(type(of: error))")
                return
            }
            XCTAssertTrue(importError.errorDescription?.contains("2.0") ?? false)
        }
    }

    func testImportWithNoVersionSucceeds() throws {
        // Missing formatVersion should be accepted (backwards compatibility)
        let json = """
        {
            "plans": [{ "name": "No Version Plan", "exercises": [] }]
        }
        """
        let url = try createTempJsonFile(content: json)

        let result = try service.importUnifiedJson(from: url)
        XCTAssertEqual(result.plansImported, 1)
    }

    // MARK: - validateJsonFile

    func testValidateJsonFileReturnsTrueForValidFile() throws {
        let url = try createTempJsonFile(content: validUnifiedJson)
        XCTAssertTrue(service.validateJsonFile(at: url))
    }

    func testValidateJsonFileReturnsFalseForMalformedJson() throws {
        let url = try createTempJsonFile(content: "not json at all")
        XCTAssertFalse(service.validateJsonFile(at: url))
    }

    func testValidateJsonFileReturnsFalseForJsonWithoutRequiredKeys() throws {
        let url = try createTempJsonFile(content: """
        { "formatVersion": "1.0", "exportedAt": "2026-03-01" }
        """)
        XCTAssertFalse(service.validateJsonFile(at: url))
    }

    func testValidateJsonFileReturnsTrueForSingleSessionFormat() throws {
        let url = try createTempJsonFile(content: """
        { "session": { "name": "Test", "date": "2026-03-01" } }
        """)
        XCTAssertTrue(service.validateJsonFile(at: url))
    }

    // MARK: - Single Session Format

    func testImportSingleSessionFormat() throws {
        let json = """
        {
            "formatVersion": "1.0",
            "session": {
                "name": "Single Session",
                "date": "2026-03-15",
                "status": "completed",
                "exercises": [
                    {
                        "exerciseName": "Deadlift",
                        "orderIndex": 0,
                        "sets": [
                            {
                                "orderIndex": 0,
                                "targetWeight": 315,
                                "targetWeightUnit": "lbs",
                                "targetReps": 3,
                                "actualWeight": 315,
                                "actualWeightUnit": "lbs",
                                "actualReps": 3,
                                "status": "completed"
                            }
                        ]
                    }
                ]
            }
        }
        """
        let url = try createTempJsonFile(content: json)

        let result = try service.importUnifiedJson(from: url)

        XCTAssertEqual(result.sessionsImported, 1)
        let sessions = try sessionRepo.getCompleted()
        let importedSession = sessions.first { $0.name == "Single Session" }
        XCTAssertNotNil(importedSession)
        XCTAssertEqual(importedSession?.exercises[0].exerciseName, "Deadlift")
    }

    // MARK: - ImportResult Summary

    func testImportResultSummaryFormatsCorrectly() {
        var result = JsonImportService.ImportResult()
        result.plansImported = 2
        result.sessionsImported = 3
        result.gymsSkipped = 1

        XCTAssertTrue(result.summary.contains("2 plans imported"))
        XCTAssertTrue(result.summary.contains("3 sessions imported"))
        XCTAssertTrue(result.summary.contains("1 gyms skipped (duplicates)"))
        XCTAssertFalse(result.summary.contains("plans skipped"))
    }

    func testImportResultSummaryWhenEmpty() {
        let result = JsonImportService.ImportResult()
        XCTAssertEqual(result.summary, "No data to import.")
    }

    // MARK: - Helpers

    private func createTempJsonFile(content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_import_\(UUID().uuidString).json"
        let fileURL = tempDir.appendingPathComponent(fileName)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        return fileURL
    }

    /// Spec-compliant unified-export JSON fixture (one plan, one session, one gym).
    private let validUnifiedJson = """
        {
            "formatVersion": "1.0",
            "exportedAt": "2026-03-01T00:00:00Z",
            "appVersion": "1.0.0",
            "plans": [
                {
                    "name": "Import Test Plan",
                    "tags": ["test"],
                    "defaultWeightUnit": "lbs",
                    "isFavorite": false,
                    "exercises": [
                        {
                            "exerciseName": "Squat",
                            "orderIndex": 0,
                            "equipmentType": "barbell",
                            "sets": [
                                {
                                    "orderIndex": 0,
                                    "targetWeight": 225,
                                    "targetWeightUnit": "lbs",
                                    "targetReps": 5,
                                    "restSeconds": 180,
                                    "isDropset": false,
                                    "isPerSide": false,
                                    "isAmrap": false
                                }
                            ]
                        }
                    ]
                }
            ],
            "sessions": [
                {
                    "name": "Import Test Session",
                    "date": "2026-03-01",
                    "startTime": "2026-03-01T10:00:00Z",
                    "endTime": "2026-03-01T11:00:00Z",
                    "duration": 3600,
                    "status": "completed",
                    "exercises": [
                        {
                            "exerciseName": "Squat",
                            "orderIndex": 0,
                            "equipmentType": "barbell",
                            "sets": [
                                {
                                    "orderIndex": 0,
                                    "targetWeight": 225,
                                    "targetWeightUnit": "lbs",
                                    "targetReps": 5,
                                    "actualWeight": 225,
                                    "actualWeightUnit": "lbs",
                                    "actualReps": 5,
                                    "status": "completed",
                                    "isDropset": false,
                                    "isPerSide": false
                                }
                            ]
                        }
                    ]
                }
            ],
            "gyms": [
                {
                    "name": "Test Gym",
                    "isDefault": false
                }
            ]
        }
        """
}
