import Foundation

// MARK: - WorkoutPlan

struct WorkoutPlan: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var description: String?
    var tags: [String]
    var defaultWeightUnit: WeightUnit?
    var sourceMarkdown: String?
    var createdAt: String
    var updatedAt: String
    var isFavorite: Bool
    var exercises: [PlannedExercise]

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String? = nil,
        tags: [String] = [],
        defaultWeightUnit: WeightUnit? = nil,
        sourceMarkdown: String? = nil,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        updatedAt: String = ISO8601DateFormatter().string(from: Date()),
        isFavorite: Bool = false,
        exercises: [PlannedExercise] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.tags = tags
        self.defaultWeightUnit = defaultWeightUnit
        self.sourceMarkdown = sourceMarkdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isFavorite = isFavorite
        self.exercises = exercises
    }
}

// MARK: - Display counts
//
// One source of truth for the "how many exercises / sets" a plan shows.
// Plan cards, the detail header, the inbox row + preview, and the import
// confirmation all read these so the same plan never reports two different
// numbers (the GH inbox bug: an inbox card said "16 exercises" while the
// promoted plan said "14" because each counted structural rows differently).
extension WorkoutPlan {
    /// Number of exercises the user actually performs. Excludes structural
    /// rows (empty section headers and empty superset parents), matching how
    /// they render: no number, no standalone card. This is the count shown
    /// everywhere a plan's exercise tally appears.
    var displayExerciseCount: Int {
        exercises.lazy.filter { !$0.isStructuralHeader }.count
    }

    /// Total planned sets across all exercises.
    var plannedSetCount: Int {
        exercises.reduce(0) { $0 + $1.sets.count }
    }
}

// MARK: - PlannedExercise

struct PlannedExercise: Identifiable, Codable, Hashable {
    var id: String
    var workoutPlanId: String
    var exerciseName: String
    var orderIndex: Int
    var notes: String?
    var equipmentType: String?
    var groupType: GroupType?
    var groupName: String?
    var parentExerciseId: String?
    var sets: [PlannedSet]

    init(
        id: String = UUID().uuidString,
        workoutPlanId: String,
        exerciseName: String,
        orderIndex: Int,
        notes: String? = nil,
        equipmentType: String? = nil,
        groupType: GroupType? = nil,
        groupName: String? = nil,
        parentExerciseId: String? = nil,
        sets: [PlannedSet] = []
    ) {
        self.id = id
        self.workoutPlanId = workoutPlanId
        self.exerciseName = exerciseName
        self.orderIndex = orderIndex
        self.notes = notes
        self.equipmentType = equipmentType
        self.groupType = groupType
        self.groupName = groupName
        self.parentExerciseId = parentExerciseId
        self.sets = sets
    }

    /// True for scaffolding rows that carry no sets of their own: empty
    /// section headers and empty superset parents. These are excluded from
    /// the user-facing exercise count and from exercise numbering — they are
    /// structure, not exercises the user performs. The single predicate every
    /// count/numbering site shares so they can't drift apart.
    var isStructuralHeader: Bool {
        sets.isEmpty && (groupType == .section || groupType == .superset)
    }
}

// MARK: - PlannedSet

struct PlannedSet: Identifiable, Codable, Hashable {
    var id: String
    var plannedExerciseId: String
    var orderIndex: Int
    var entries: [SetEntry]
    var restSeconds: Int?
    var isDropset: Bool
    var isPerSide: Bool
    var isAmrap: Bool
    var notes: String?

    // MARK: - Entries-native init

    init(
        id: String = UUID().uuidString,
        plannedExerciseId: String,
        orderIndex: Int,
        entries: [SetEntry] = [],
        restSeconds: Int? = nil,
        isDropset: Bool = false,
        isPerSide: Bool = false,
        isAmrap: Bool = false,
        notes: String? = nil
    ) {
        self.id = id
        self.plannedExerciseId = plannedExerciseId
        self.orderIndex = orderIndex
        self.entries = entries
        self.restSeconds = restSeconds
        self.isDropset = isDropset
        self.isPerSide = isPerSide
        self.isAmrap = isAmrap
        self.notes = notes
    }

    // MARK: - Backward-compatible init (builds entries from flat fields)

    init(
        id: String = UUID().uuidString,
        plannedExerciseId: String,
        orderIndex: Int,
        targetWeight: Double? = nil,
        targetWeightUnit: WeightUnit? = nil,
        targetReps: Int? = nil,
        targetTime: Int? = nil,
        targetDistance: Double? = nil,
        targetDistanceUnit: DistanceUnit? = nil,
        targetRpe: Int? = nil,
        restSeconds: Int? = nil,
        tempo: String? = nil,
        isDropset: Bool = false,
        isPerSide: Bool = false,
        isAmrap: Bool = false,
        notes: String? = nil
    ) {
        self.id = id
        self.plannedExerciseId = plannedExerciseId
        self.orderIndex = orderIndex
        self.restSeconds = restSeconds
        self.isDropset = isDropset
        self.isPerSide = isPerSide
        self.isAmrap = isAmrap
        self.notes = notes

        let target = EntryValues(
            weight: targetWeight.map { MeasuredWeight(value: $0, unit: targetWeightUnit ?? .lbs) },
            reps: targetReps,
            time: targetTime,
            distance: targetDistance.map { MeasuredDistance(value: $0, unit: targetDistanceUnit ?? .meters) },
            rpe: targetRpe
        )

        if !target.isEmpty {
            self.entries = [SetEntry(groupIndex: 0, target: target, actual: nil)]
        } else {
            self.entries = []
        }
    }

    // MARK: - Backward-compatible computed properties

    var tempo: String? { nil }

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

    // MARK: - Private helpers

    private mutating func ensureTarget() {
        if entries.isEmpty {
            entries = [SetEntry(groupIndex: 0, target: EntryValues(), actual: nil)]
        }
        if entries[0].target == nil {
            entries[0].target = EntryValues()
        }
    }
}
