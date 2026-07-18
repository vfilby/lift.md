import XCTest
@testable import LiftMark

@MainActor
final class WorkoutPlanStoreTests: XCTestCase {

    private var store: WorkoutPlanStore!

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
        store = WorkoutPlanStore()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    func testLoadPlansInitiallyEmpty() {
        store.loadPlans()
        XCTAssertTrue(store.plans.isEmpty)
    }

    func testCreateAndLoadPlan() {
        let plan = WorkoutPlan(name: "Push Day")
        store.createPlan(plan)
        XCTAssertEqual(store.plans.count, 1)
        XCTAssertEqual(store.plans[0].name, "Push Day")
    }

    func testGetPlanById() {
        let plan = WorkoutPlan(name: "Pull Day")
        store.createPlan(plan)
        XCTAssertNotNil(store.getPlan(id: plan.id))
        XCTAssertNil(store.getPlan(id: "nonexistent"))
    }

    func testUpdatePlan() {
        var plan = WorkoutPlan(name: "Original")
        store.createPlan(plan)
        plan.name = "Updated"
        store.updatePlan(plan)
        XCTAssertEqual(store.plans[0].name, "Updated")
    }

    func testDeletePlan() {
        let plan = WorkoutPlan(name: "To Delete")
        store.createPlan(plan)
        XCTAssertEqual(store.plans.count, 1)
        store.deletePlan(id: plan.id)
        XCTAssertTrue(store.plans.isEmpty)
    }

    func testToggleFavorite() {
        let plan = WorkoutPlan(name: "Fav Test")
        store.createPlan(plan)
        XCTAssertFalse(store.plans[0].isFavorite)
        store.toggleFavorite(id: plan.id)
        XCTAssertTrue(store.plans[0].isFavorite)
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {

    private var store: SessionStore!
    private var planRepo: WorkoutPlanRepository!

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
        store = SessionStore()
        planRepo = WorkoutPlanRepository()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    func testLoadSessionsInitiallyEmpty() {
        store.loadSessions()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.activeSession)
    }

    func testStartSession() throws {
        let plan = WorkoutPlan(
            name: "Push Day",
            exercises: [PlannedExercise(workoutPlanId: "p", exerciseName: "Bench", orderIndex: 0, sets: [
                PlannedSet(plannedExerciseId: "e", orderIndex: 0, targetWeight: 225, targetWeightUnit: .lbs,
                           targetReps: 5)
            ])]
        )
        try planRepo.create(plan)

        let session = store.startSession(from: plan)
        XCTAssertNotNil(session)
        XCTAssertNotNil(store.activeSession)
        XCTAssertEqual(store.activeSession?.name, "Push Day")
    }

    func testCompleteSession() throws {
        let plan = WorkoutPlan(name: "Test")
        try planRepo.create(plan)
        _ = store.startSession(from: plan)
        XCTAssertNotNil(store.activeSession)

        store.completeSession()
        // activeSession stays non-nil after completeSession so navigation to summary screen works
        XCTAssertNotNil(store.activeSession)
        XCTAssertEqual(store.sessions.count, 1)

        store.clearActiveSession()
        XCTAssertNil(store.activeSession)
    }

    func testCancelSession() throws {
        let plan = WorkoutPlan(name: "Test")
        try planRepo.create(plan)
        _ = store.startSession(from: plan)

        store.cancelSession()
        XCTAssertNil(store.activeSession)
    }

    func testStartSessionCancelsStaleInProgressSessions() throws {
        let plan = WorkoutPlan(name: "Plan A")
        try planRepo.create(plan)

        // Start first session (simulates a paused/orphaned workout)
        let staleSession = store.startSession(from: plan)!

        // Start second session — should cancel the first
        let newSession = store.startSession(from: plan)
        XCTAssertNotNil(newSession)
        XCTAssertNotEqual(newSession?.id, staleSession.id)

        // Reload and verify only the new session is active
        store.loadSessions()
        XCTAssertEqual(store.activeSession?.id, newSession?.id)

        // Verify the stale session was canceled in the DB
        let repo = SessionRepository()
        let fetched = try repo.getById(staleSession.id)
        XCTAssertEqual(fetched?.status, .canceled)
    }

    func testDiscardedWorkoutDoesNotAppearOnReload() throws {
        let plan = WorkoutPlan(name: "Test")
        try planRepo.create(plan)
        _ = store.startSession(from: plan)

        store.cancelSession()
        XCTAssertNil(store.activeSession)

        // Simulate app restart
        store.loadSessions()
        XCTAssertNil(store.activeSession, "Canceled session must not appear as active after reload")
    }

    func testCompletedSessionsOrderedByMostRecentFirst() throws {
        // Create and complete two sessions to verify ordering.
        // Use a delay > 1 second to ensure different end_time values
        // (ISO8601DateFormatter has second-level precision).
        let plan1 = WorkoutPlan(name: "Older Workout")
        try planRepo.create(plan1)
        _ = store.startSession(from: plan1)
        store.completeSession()
        store.clearActiveSession()

        // Sleep > 1 second to guarantee different ISO8601 timestamps
        Thread.sleep(forTimeInterval: 1.1)

        let plan2 = WorkoutPlan(name: "Newer Workout")
        try planRepo.create(plan2)
        _ = store.startSession(from: plan2)
        store.completeSession()
        store.clearActiveSession()

        // Reload to get fresh data
        store.loadSessions()

        XCTAssertEqual(store.sessions.count, 2)
        // sessions.first should be the most recently completed (Newer Workout)
        XCTAssertEqual(store.sessions.first?.name, "Newer Workout",
                       "sessions.first must be the most recently completed session")
        XCTAssertEqual(store.sessions.last?.name, "Older Workout")
    }

    func testDeleteSession() throws {
        let plan = WorkoutPlan(name: "Test")
        try planRepo.create(plan)
        let session = store.startSession(from: plan)!
        store.completeSession()
        XCTAssertEqual(store.sessions.count, 1)

        store.deleteSession(id: session.id)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testCompleteSet() throws {
        let plan = WorkoutPlan(
            name: "Test",
            exercises: [PlannedExercise(workoutPlanId: "p", exerciseName: "Bench", orderIndex: 0, sets: [
                PlannedSet(plannedExerciseId: "e", orderIndex: 0, targetWeight: 225, targetWeightUnit: .lbs,
                           targetReps: 5)
            ])]
        )
        try planRepo.create(plan)
        let session = store.startSession(from: plan)!
        let setId = session.exercises[0].sets[0].id

        store.completeSet(setId: setId, actualWeight: 230, actualWeightUnit: .lbs, actualReps: 4, actualTime: nil,
                          actualRpe: 9)

        XCTAssertEqual(store.activeSession?.exercises[0].sets[0].status, .completed)
        XCTAssertEqual(store.activeSession?.exercises[0].sets[0].actualWeight, 230)
    }

    func testSkipSet() throws {
        let plan = WorkoutPlan(
            name: "Test",
            exercises: [PlannedExercise(workoutPlanId: "p", exerciseName: "Bench", orderIndex: 0, sets: [
                PlannedSet(plannedExerciseId: "e", orderIndex: 0, targetWeight: 225, targetWeightUnit: .lbs,
                           targetReps: 5)
            ])]
        )
        try planRepo.create(plan)
        let session = store.startSession(from: plan)!
        let setId = session.exercises[0].sets[0].id

        store.skipSet(setId: setId)
        XCTAssertEqual(store.activeSession?.exercises[0].sets[0].status, .skipped)
    }

    func testUpdateSetTarget() throws {
        let plan = WorkoutPlan(
            name: "Test",
            exercises: [PlannedExercise(workoutPlanId: "p", exerciseName: "Bench", orderIndex: 0, sets: [
                PlannedSet(plannedExerciseId: "e", orderIndex: 0, targetWeight: 225, targetWeightUnit: .lbs,
                           targetReps: 5)
            ])]
        )
        try planRepo.create(plan)
        let session = store.startSession(from: plan)!
        let setId = session.exercises[0].sets[0].id

        store.updateSetTarget(setId: setId, targetWeight: 235, targetReps: 3, targetTime: nil, restSeconds: nil)
        XCTAssertEqual(store.activeSession?.exercises[0].sets[0].targetWeight, 235)
        XCTAssertEqual(store.activeSession?.exercises[0].sets[0].targetReps, 3)
    }

    func testAddExercise() throws {
        let plan = WorkoutPlan(name: "Test")
        try planRepo.create(plan)
        _ = store.startSession(from: plan)

        store.addExercise(
            exerciseName: "Curls",
            sets: [SessionSetDraft(weight: 40, unit: .lbs, reps: 12, time: nil, rest: nil)]
        )

        XCTAssertEqual(store.activeSession?.exercises.count, 1)
        XCTAssertEqual(store.activeSession?.exercises[0].exerciseName, "Curls")
    }

    func testUpdateExercise() throws {
        let plan = WorkoutPlan(name: "Test")
        try planRepo.create(plan)
        _ = store.startSession(from: plan)
        store.addExercise(exerciseName: "Curls",
                          sets: [SessionSetDraft(weight: 40, unit: .lbs, reps: 12, time: nil, rest: nil)])
        let exId = store.activeSession!.exercises[0].id

        store.updateExercise(exerciseId: exId, name: "Hammer Curls", notes: "Slow", equipmentType: "dumbbell")
        XCTAssertEqual(store.activeSession?.exercises[0].exerciseName, "Hammer Curls")
    }
}

@MainActor
final class GymStoreTests: XCTestCase {

    private var store: GymStore!

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
        store = GymStore()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    func testLoadGymsStartsEmpty() {
        store.loadGyms()
        // No default gym is seeded — users create gyms as needed
        XCTAssertTrue(store.gyms.isEmpty)
    }

    func testCreateGym() {
        store.loadGyms()
        store.createGym(name: "Iron Paradise")
        XCTAssertEqual(store.gyms.count, 1)
        XCTAssertTrue(store.gyms.contains { $0.name == "Iron Paradise" })
    }

    func testDeleteGym() {
        store.loadGyms()
        store.createGym(name: "First Gym")
        store.createGym(name: "Temp Gym")
        let tempGym = store.gyms.first { $0.name == "Temp Gym" }!
        let countBefore = store.gyms.count

        store.deleteGym(id: tempGym.id)
        XCTAssertEqual(store.gyms.count, countBefore - 1)
    }

    func testDeleteGymPreventsLastGymDeletion() {
        store.loadGyms()
        store.createGym(name: "Only Gym")
        XCTAssertEqual(store.gyms.count, 1)
        let lastGym = store.gyms[0]
        store.deleteGym(id: lastGym.id)
        XCTAssertEqual(store.gyms.count, 1) // Should not delete last gym
    }

    func testSetDefault() {
        store.loadGyms()
        store.createGym(name: "First Gym")
        store.createGym(name: "New Gym")
        let newGym = store.gyms.first { $0.name == "New Gym" }!
        XCTAssertFalse(newGym.isDefault)

        store.setDefault(id: newGym.id)
        let updated = store.gyms.first { $0.name == "New Gym" }!
        XCTAssertTrue(updated.isDefault)
    }

    // MARK: - Issue #36: Deleted gyms reappearing / multiple defaults

    func testDeletedGymStaysDeletedAfterReload() {
        store.loadGyms()
        store.createGym(name: "Keep Gym")
        store.createGym(name: "Temp Gym")
        let tempGym = store.gyms.first { $0.name == "Temp Gym" }!

        store.deleteGym(id: tempGym.id)
        XCTAssertFalse(store.gyms.contains { $0.name == "Temp Gym" })

        // Simulate app restart by creating a new store and reloading
        let freshStore = GymStore()
        freshStore.loadGyms()
        XCTAssertFalse(freshStore.gyms.contains { $0.name == "Temp Gym" },
                       "Deleted gym should not reappear after reload")
    }

    func testDeletedGymIsSoftDeleted() throws {
        store.loadGyms()
        store.createGym(name: "Keep Gym")
        store.createGym(name: "Soft Delete Test")
        let gym = store.gyms.first { $0.name == "Soft Delete Test" }!

        store.deleteGym(id: gym.id)

        // Verify soft-delete: the row still exists in DB with deleted_at set
        let dbQueue = try DatabaseManager.shared.database()
        let row = try dbQueue.read { db in
            try GymRow.fetchOne(db, key: gym.id)
        }
        XCTAssertNotNil(row, "Soft-deleted gym row should still exist in DB")
        XCTAssertNotNil(row?.deletedAt, "Soft-deleted gym should have deleted_at set")
    }

    func testDeleteDefaultGymReassignsDefault() {
        store.loadGyms()
        store.createGym(name: "First Gym")
        store.createGym(name: "Second Gym")

        // Set up: first gym is default
        let defaultGym = store.gyms.first { $0.isDefault }!
        store.deleteGym(id: defaultGym.id)

        // Exactly one gym should be default
        let defaults = store.gyms.filter(\.isDefault)
        XCTAssertEqual(defaults.count, 1, "Exactly one gym should be default after deleting the default")
    }

    func testExactlyOneDefaultGymAtAllTimes() {
        store.loadGyms()
        store.createGym(name: "Gym A") // first gym becomes default
        store.createGym(name: "Gym B")
        store.createGym(name: "Gym C")

        let defaults = store.gyms.filter(\.isDefault)
        XCTAssertEqual(defaults.count, 1, "Should have exactly one default gym")
    }

    func testSetDefaultClearsOtherDefaults() {
        store.loadGyms()
        store.createGym(name: "Gym A") // first gym becomes default
        store.createGym(name: "Gym B")

        let gymA = store.gyms.first { $0.name == "Gym A" }!
        store.setDefault(id: gymA.id)

        let gymB = store.gyms.first { $0.name == "Gym B" }!
        store.setDefault(id: gymB.id)

        let defaults = store.gyms.filter(\.isDefault)
        XCTAssertEqual(defaults.count, 1, "Only one gym should be default")
        XCTAssertEqual(defaults.first?.id, gymB.id)
    }

    func testCreateFirstGymIsDefault() {
        // Start with empty DB — deleteDatabase already ran in setUp
        store.loadGyms()
        XCTAssertTrue(store.gyms.isEmpty, "Should start with no gyms")
        store.createGym(name: "First Gym")
        XCTAssertEqual(store.gyms.filter(\.isDefault).count, 1,
                       "First gym created should be the default")
    }
}

@MainActor
final class EquipmentStoreTests: XCTestCase {

    private var store: EquipmentStore!
    private var gymStore: GymStore!

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
        store = EquipmentStore()
        gymStore = GymStore()
        gymStore.loadGyms()
        gymStore.createGym(name: "Test Gym")
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    private var defaultGymId: String {
        gymStore.gyms.first { $0.isDefault }!.id
    }

    func testLoadEquipmentInitiallyEmpty() {
        store.loadEquipment(forGym: defaultGymId)
        // After deleteDatabase, equipment starts empty
        XCTAssertTrue(store.equipment.isEmpty)
    }

    func testAddEquipment() {
        store.loadEquipment(forGym: defaultGymId)
        let countBefore = store.equipment.count
        store.addEquipment(name: "Ab Roller", gymId: defaultGymId)
        XCTAssertEqual(store.equipment.count, countBefore + 1)
        XCTAssertTrue(store.equipment.contains { $0.name == "Ab Roller" })
    }

    func testRemoveEquipment() {
        store.loadEquipment(forGym: defaultGymId)
        store.addEquipment(name: "To Remove", gymId: defaultGymId)
        let item = store.equipment.first { $0.name == "To Remove" }!
        let countBefore = store.equipment.count

        store.removeEquipment(id: item.id, gymId: defaultGymId)
        XCTAssertEqual(store.equipment.count, countBefore - 1)
    }

    func testToggleAvailability() {
        store.loadEquipment(forGym: defaultGymId)
        store.addEquipment(name: "Toggle Test", gymId: defaultGymId)
        let item = store.equipment.first { $0.name == "Toggle Test" }!
        XCTAssertTrue(item.isAvailable)

        store.toggleAvailability(id: item.id, gymId: defaultGymId)
        let updated = store.equipment.first { $0.name == "Toggle Test" }!
        XCTAssertFalse(updated.isAvailable)
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {

    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
        store = SettingsStore()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    func testLoadSettingsReturnsSeededDefaults() {
        store.loadSettings()
        XCTAssertNotNil(store.settings)
        XCTAssertEqual(store.settings?.defaultWeightUnit, .lbs)
        XCTAssertEqual(store.settings?.theme, .auto)
    }

    func testUpdateSettings() {
        store.loadSettings()
        guard var settings = store.settings else {
            XCTFail("No settings loaded")
            return
        }
        settings.defaultWeightUnit = .kg
        settings.theme = .dark
        settings.keepScreenAwake = false

        store.updateSettings(settings)
        XCTAssertEqual(store.settings?.defaultWeightUnit, .kg)
        XCTAssertEqual(store.settings?.theme, .dark)
        XCTAssertFalse(store.settings?.keepScreenAwake ?? true)

        // Verify persistence
        let store2 = SettingsStore()
        store2.loadSettings()
        XCTAssertEqual(store2.settings?.defaultWeightUnit, .kg)
        XCTAssertEqual(store2.settings?.theme, .dark)
    }

    func testUpdateSettingsCustomPrompt() {
        store.loadSettings()
        guard var settings = store.settings else { return }
        settings.customPromptAddition = "I have a bad back"
        store.updateSettings(settings)
        XCTAssertEqual(store.settings?.customPromptAddition, "I have a bad back")

        let store2 = SettingsStore()
        store2.loadSettings()
        XCTAssertEqual(store2.settings?.customPromptAddition, "I have a bad back")
    }

    func testUpdateSettingsCustomPromptMultiLine() {
        store.loadSettings()
        guard var settings = store.settings else { return }
        let multiLine = "Line one\nLine two\nLine three"
        settings.customPromptAddition = multiLine
        store.updateSettings(settings)

        let store2 = SettingsStore()
        store2.loadSettings()
        XCTAssertEqual(store2.settings?.customPromptAddition, multiLine)
    }

    func testUpdateSettingsAIPromptToggles() {
        store.loadSettings()
        guard var settings = store.settings else { return }
        settings.aiPromptIncludeFormatPointer = false
        settings.aiPromptIncludeRecentWorkouts = false
        settings.aiPromptIncludeProgression = false
        settings.aiPromptIncludeEquipment = false
        store.updateSettings(settings)

        let store2 = SettingsStore()
        store2.loadSettings()
        XCTAssertEqual(store2.settings?.aiPromptIncludeFormatPointer, false)
        XCTAssertEqual(store2.settings?.aiPromptIncludeRecentWorkouts, false)
        XCTAssertEqual(store2.settings?.aiPromptIncludeProgression, false)
        XCTAssertEqual(store2.settings?.aiPromptIncludeEquipment, false)
    }

    func testUpdateSettingsHomeTiles() {
        store.loadSettings()
        guard var settings = store.settings else { return }
        settings.homeTiles = ["Bench Press", "Squat"]
        store.updateSettings(settings)
        XCTAssertEqual(store.settings?.homeTiles, ["Bench Press", "Squat"])

        // Verify persistence
        let store2 = SettingsStore()
        store2.loadSettings()
        XCTAssertEqual(store2.settings?.homeTiles, ["Bench Press", "Squat"])
    }
}
