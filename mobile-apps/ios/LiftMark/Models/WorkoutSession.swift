import Foundation

// MARK: - WorkoutSession

struct WorkoutSession: Identifiable, Codable, Hashable {
    var id: String
    var workoutPlanId: String?
    var name: String
    var date: String // ISO date YYYY-MM-DD
    var startTime: String?
    var endTime: String?
    var duration: Int? // seconds
    var notes: String?
    var exercises: [SessionExercise]
    var status: SessionStatus

    init(
        id: String = UUID().uuidString,
        workoutPlanId: String? = nil,
        name: String,
        date: String,
        startTime: String? = nil,
        endTime: String? = nil,
        duration: Int? = nil,
        notes: String? = nil,
        exercises: [SessionExercise] = [],
        status: SessionStatus = .inProgress
    ) {
        self.id = id
        self.workoutPlanId = workoutPlanId
        self.name = name
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.notes = notes
        self.exercises = exercises
        self.status = status
    }
}

// MARK: - SessionExercise

struct SessionExercise: Identifiable, Codable, Hashable {
    var id: String
    var workoutSessionId: String
    var exerciseName: String
    var orderIndex: Int
    var notes: String?
    var equipmentType: String?
    var groupType: GroupType?
    var groupName: String?
    var parentExerciseId: String?
    var sets: [SessionSet]
    var status: ExerciseStatus

    init(
        id: String = UUID().uuidString,
        workoutSessionId: String,
        exerciseName: String,
        orderIndex: Int,
        notes: String? = nil,
        equipmentType: String? = nil,
        groupType: GroupType? = nil,
        groupName: String? = nil,
        parentExerciseId: String? = nil,
        sets: [SessionSet] = [],
        status: ExerciseStatus = .pending
    ) {
        self.id = id
        self.workoutSessionId = workoutSessionId
        self.exerciseName = exerciseName
        self.orderIndex = orderIndex
        self.notes = notes
        self.equipmentType = equipmentType
        self.groupType = groupType
        self.groupName = groupName
        self.parentExerciseId = parentExerciseId
        self.sets = sets
        self.status = status
    }
}

// MARK: - SessionSet

struct SessionSet: Identifiable, Codable, Hashable {
    var id: String
    var sessionExerciseId: String
    var orderIndex: Int
    var entries: [SetEntry]

    // Metadata
    var restSeconds: Int?
    var completedAt: String?
    var status: SetStatus
    var notes: String?
    var isDropset: Bool
    var isPerSide: Bool
    var isAmrap: Bool
    var side: String?

    // MARK: - Entries-native init

    init(
        id: String = UUID().uuidString,
        sessionExerciseId: String,
        orderIndex: Int,
        entries: [SetEntry] = [],
        restSeconds: Int? = nil,
        completedAt: String? = nil,
        status: SetStatus = .pending,
        notes: String? = nil,
        isDropset: Bool = false,
        isPerSide: Bool = false,
        isAmrap: Bool = false,
        side: String? = nil
    ) {
        self.id = id
        self.sessionExerciseId = sessionExerciseId
        self.orderIndex = orderIndex
        self.entries = entries
        self.restSeconds = restSeconds
        self.completedAt = completedAt
        self.status = status
        self.notes = notes
        self.isDropset = isDropset
        self.isPerSide = isPerSide
        self.isAmrap = isAmrap
        self.side = side
    }

    // MARK: - Backward-compatible init (builds entries from flat fields)

    init(
        id: String = UUID().uuidString,
        sessionExerciseId: String,
        orderIndex: Int,
        parentSetId: String? = nil,
        dropSequence: Int? = nil,
        targetWeight: Double? = nil,
        targetWeightUnit: WeightUnit? = nil,
        targetReps: Int? = nil,
        targetTime: Int? = nil,
        targetDistance: Double? = nil,
        targetDistanceUnit: DistanceUnit? = nil,
        targetRpe: Int? = nil,
        restSeconds: Int? = nil,
        actualWeight: Double? = nil,
        actualWeightUnit: WeightUnit? = nil,
        actualReps: Int? = nil,
        actualTime: Int? = nil,
        actualDistance: Double? = nil,
        actualDistanceUnit: DistanceUnit? = nil,
        actualRpe: Int? = nil,
        completedAt: String? = nil,
        status: SetStatus = .pending,
        notes: String? = nil,
        tempo: String? = nil,
        isDropset: Bool = false,
        isPerSide: Bool = false,
        isAmrap: Bool = false,
        side: String? = nil
    ) {
        self.id = id
        self.sessionExerciseId = sessionExerciseId
        self.orderIndex = orderIndex
        self.restSeconds = restSeconds
        self.completedAt = completedAt
        self.status = status
        self.notes = notes
        self.isDropset = isDropset
        self.isPerSide = isPerSide
        self.isAmrap = isAmrap
        self.side = side

        let target = EntryValues(
            weight: targetWeight.map { MeasuredWeight(value: $0, unit: targetWeightUnit ?? .lbs) },
            reps: targetReps,
            time: targetTime,
            distance: targetDistance.map { MeasuredDistance(value: $0, unit: targetDistanceUnit ?? .meters) },
            rpe: targetRpe
        )
        let actual = EntryValues(
            weight: actualWeight.map { MeasuredWeight(value: $0, unit: actualWeightUnit ?? .lbs) },
            reps: actualReps,
            time: actualTime,
            distance: actualDistance.map { MeasuredDistance(value: $0, unit: actualDistanceUnit ?? .meters) },
            rpe: actualRpe
        )
        let hasTarget = !target.isEmpty
        let hasActual = !actual.isEmpty

        if hasTarget || hasActual {
            self.entries = [SetEntry(
                groupIndex: 0,
                target: hasTarget ? target : nil,
                actual: hasActual ? actual : nil
            )]
        } else {
            self.entries = []
        }
    }

    // MARK: - Backward-compatible computed properties

    // Deprecated fields (always nil)
    var parentSetId: String? { nil }
    var dropSequence: Int? { nil }
    var tempo: String? { nil }

    // Target accessors
    var targetWeight: Double? {
        get { entries.first?.target?.weight?.value }
        set {
            ensureTarget()
            if let nv = newValue {
                let unit = entries[0].target?.weight?.unit ?? .lbs
                entries[0].target?.weight = MeasuredWeight(value: nv, unit: unit)
            } else {
                entries[0].target?.weight = nil
            }
        }
    }

    var targetWeightUnit: WeightUnit? {
        get { entries.first?.target?.weight?.unit }
        set {
            guard var weight = entries.first?.target?.weight else { return }
            weight.unit = newValue ?? .lbs
            entries[0].target?.weight = weight
        }
    }

    var targetReps: Int? {
        get { entries.first?.target?.reps }
        set { ensureTarget(); entries[0].target?.reps = newValue }
    }

    var targetTime: Int? {
        get { entries.first?.target?.time }
        set { ensureTarget(); entries[0].target?.time = newValue }
    }

    var targetDistance: Double? {
        get { entries.first?.target?.distance?.value }
        set {
            ensureTarget()
            if let nv = newValue {
                let unit = entries[0].target?.distance?.unit ?? .meters
                entries[0].target?.distance = MeasuredDistance(value: nv, unit: unit)
            } else {
                entries[0].target?.distance = nil
            }
        }
    }

    var targetDistanceUnit: DistanceUnit? {
        get { entries.first?.target?.distance?.unit }
        set {
            guard var distance = entries.first?.target?.distance else { return }
            distance.unit = newValue ?? .meters
            entries[0].target?.distance = distance
        }
    }

    var targetRpe: Int? {
        get { entries.first?.target?.rpe }
        set { ensureTarget(); entries[0].target?.rpe = newValue }
    }

    // Actual accessors
    var actualWeight: Double? {
        get { entries.first?.actual?.weight?.value }
        set {
            ensureActual()
            if let nv = newValue {
                let unit = entries[0].actual?.weight?.unit ?? .lbs
                entries[0].actual?.weight = MeasuredWeight(value: nv, unit: unit)
            } else {
                entries[0].actual?.weight = nil
            }
        }
    }

    var actualWeightUnit: WeightUnit? {
        get { entries.first?.actual?.weight?.unit }
        set {
            guard var weight = entries.first?.actual?.weight else { return }
            weight.unit = newValue ?? .lbs
            entries[0].actual?.weight = weight
        }
    }

    var actualReps: Int? {
        get { entries.first?.actual?.reps }
        set { ensureActual(); entries[0].actual?.reps = newValue }
    }

    var actualTime: Int? {
        get { entries.first?.actual?.time }
        set { ensureActual(); entries[0].actual?.time = newValue }
    }

    var actualDistance: Double? {
        get { entries.first?.actual?.distance?.value }
        set {
            ensureActual()
            if let nv = newValue {
                let unit = entries[0].actual?.distance?.unit ?? .meters
                entries[0].actual?.distance = MeasuredDistance(value: nv, unit: unit)
            } else {
                entries[0].actual?.distance = nil
            }
        }
    }

    var actualDistanceUnit: DistanceUnit? {
        get { entries.first?.actual?.distance?.unit }
        set {
            guard var distance = entries.first?.actual?.distance else { return }
            distance.unit = newValue ?? .meters
            entries[0].actual?.distance = distance
        }
    }

    var actualRpe: Int? {
        get { entries.first?.actual?.rpe }
        set { ensureActual(); entries[0].actual?.rpe = newValue }
    }

    // MARK: - Private helpers

    private mutating func ensureTarget() {
        if entries.isEmpty {
            entries = [SetEntry(groupIndex: 0, target: EntryValues(), actual: nil)]
        }
        if entries[0].target == nil {
            entries[0].target = EntryValues()
        }
    }

    private mutating func ensureActual() {
        if entries.isEmpty {
            entries = [SetEntry(groupIndex: 0, target: nil, actual: EntryValues())]
        }
        if entries[0].actual == nil {
            entries[0].actual = EntryValues()
        }
    }
}

// MARK: - Exercise History Types

struct ExerciseHistoryPoint: Codable, Hashable {
    var date: String
    var startTime: String?
    var workoutName: String
    var maxWeight: Double
    var avgReps: Double
    var totalVolume: Double
    var setsCount: Int
    var avgTime: Double
    var maxTime: Double
    var unit: WeightUnit
}

struct ExerciseProgressMetrics: Codable, Hashable {
    var exerciseName: String
    var totalSessions: Int
    var totalVolume: Double
    var maxWeight: Double
    var maxWeightUnit: WeightUnit
    var avgWeightPerSession: Double
    var avgRepsPerSet: Double
    var firstSessionDate: String
    var lastSessionDate: String
    var trend: Trend
}
