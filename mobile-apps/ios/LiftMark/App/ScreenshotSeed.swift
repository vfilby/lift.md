#if DEBUG
import Foundation
import GRDB

/// Seeds a deterministic dataset for App Store screenshot capture: four
/// LMWF plans (Push / Pull / Legs / Conditioning) plus six weeks of
/// completed sessions on a realistic split so home tiles, history list,
/// and exercise progress charts all show varied content with a believable
/// upward trend.
///
/// Triggered via `--seed-screenshots` (paired with `--reset-data`). The
/// markdown lives inline so the app needs no host-filesystem access; the
/// canonical Push Day copy is `test-fixtures/screenshot-routine.md`.
enum ScreenshotSeed {

    // MARK: - Public entry point

    static func seed() {
        let parsedPlans = planSources.compactMap { source -> (WorkoutPlan, PlanKey)? in
            let parsed = MarkdownParser.parseWorkout(source.markdown)
            guard parsed.success, var plan = parsed.data else {
                Logger.shared.error(.app, "ScreenshotSeed: failed to parse '\(source.key)'")
                return nil
            }
            plan.isFavorite = source.favorite
            return (plan, source.key)
        }

        let repository = WorkoutPlanRepository()
        do {
            for (plan, _) in parsedPlans {
                try repository.create(plan)
            }
            try seedHistory(plans: Dictionary(uniqueKeysWithValues: parsedPlans.map { ($1, $0) }))
        } catch {
            Logger.shared.error(.app, "ScreenshotSeed: \(error.localizedDescription)")
        }
    }

    // MARK: - Schedule

    // push/pull/legs/conditioning are the actively-run programs that fill the
    // history. fullBody/upper/arms/mobility round out the plan library so the
    // Plans screen looks lived-in — they're saved but not (yet) in the schedule,
    // so they carry no session history.
    private enum PlanKey: String { case push, pull, legs, conditioning, fullBody, upper, arms, mobility }

    /// 6-week PPL+conditioning split. Tuples are (daysAgo, plan). Entries are
    /// kept in chronological order — newest last — so progressive-overload
    /// math reads naturally (week 0 = oldest, week N = today).
    private static let schedule: [(daysAgo: Int, plan: PlanKey)] = [
        // Week 6 (oldest)
        (40, .push), (39, .pull), (37, .legs), (35, .conditioning),
        // Week 5
        (33, .push), (32, .pull), (30, .legs), (28, .conditioning),
        // Week 4
        (26, .push), (25, .pull), (23, .legs), (21, .conditioning),
        // Week 3
        (19, .push), (18, .pull), (16, .legs),
        // Week 2 — slight schedule drift; took Saturday off
        (12, .push), (11, .pull), (9, .legs), (7, .conditioning),
        // Week 1 (most recent — today is day 0, no session today). Newest
        // entry is Push Day so the trend-graph screenshot lands on a session
        // containing Barbell Bench Press without filtering by name.
        (5, .legs), (4, .pull), (2, .push)
    ]

    private static func seedHistory(plans: [PlanKey: WorkoutPlan]) throws {
        let dbQueue = try DatabaseManager.shared.database()
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // Reverse so we walk newest→oldest while writing — order doesn't matter
        // for correctness but keeps the SQL trace readable.
        for (index, entry) in schedule.enumerated() {
            guard let plan = plans[entry.plan] else { continue }
            guard let sessionDate = calendar.date(byAdding: .day, value: -entry.daysAgo, to: now),
                  let startDate = startTime(for: entry.plan, on: sessionDate, calendar: calendar),
                  let endDate = calendar.date(byAdding: .minute, value: durationMinutes(for: entry.plan), to: startDate)
            else { continue }

            // Progression index: 0 = oldest session, schedule.count-1 = newest.
            let progressionWeeks = (schedule.count - 1 - index) / 4 // ~weeks-back from latest
            try writeCompletedSession(
                plan: plan,
                date: dateFormatter.string(from: sessionDate),
                start: isoFormatter.string(from: startDate),
                end: isoFormatter.string(from: endDate),
                weeksFromLatest: progressionWeeks,
                in: dbQueue
            )
        }
    }

    /// Slightly different start times by plan so the history list isn't
    /// uniform — push/pull are morning, legs is afternoon, conditioning is
    /// evening. Adds visual variety to the timestamps.
    private static func startTime(for plan: PlanKey, on date: Date, calendar: Calendar) -> Date? {
        switch plan {
        case .push: return calendar.date(bySettingHour: 7, minute: 15, second: 0, of: date)
        case .pull: return calendar.date(bySettingHour: 7, minute: 30, second: 0, of: date)
        case .legs: return calendar.date(bySettingHour: 17, minute: 0, second: 0, of: date)
        case .conditioning: return calendar.date(bySettingHour: 18, minute: 30, second: 0, of: date)
        // Library-only plans (no scheduled sessions); values are placeholders.
        case .fullBody, .upper, .arms, .mobility:
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: date)
        }
    }

    private static func durationMinutes(for plan: PlanKey) -> Int {
        switch plan {
        case .push: return 52
        case .pull: return 48
        case .legs: return 58
        case .conditioning: return 32
        // Library-only plans (no scheduled sessions); values are placeholders.
        case .fullBody, .upper, .arms, .mobility: return 45
        }
    }

    // MARK: - Session writes

    private static func writeCompletedSession(
        plan: WorkoutPlan,
        date: String,
        start: String,
        end: String,
        weeksFromLatest: Int,
        in dbQueue: DatabaseQueue
    ) throws {
        try dbQueue.write { db in
            let sessionId = IDGenerator.generate()
            let duration = Int(ISO8601DateFormatter().date(from: end)!
                .timeIntervalSince(ISO8601DateFormatter().date(from: start)!))

            try WorkoutSessionRow(
                id: sessionId,
                workoutTemplateId: plan.id,
                name: plan.name,
                date: date,
                startTime: start,
                endTime: end,
                duration: duration,
                notes: nil,
                status: SessionStatus.completed.rawValue,
                updatedAt: end
            ).insert(db)

            // Map plan exercise IDs → session exercise IDs so parent links survive.
            var planToSession: [String: String] = [:]
            for exercise in plan.exercises {
                planToSession[exercise.id] = IDGenerator.generate()
            }

            for exercise in plan.exercises {
                guard let sessionExerciseId = planToSession[exercise.id] else { continue }
                let parentId = exercise.parentExerciseId.flatMap { planToSession[$0] }
                try SessionExerciseRow(
                    id: sessionExerciseId,
                    workoutSessionId: sessionId,
                    exerciseName: exercise.exerciseName,
                    orderIndex: exercise.orderIndex,
                    notes: exercise.notes,
                    equipmentType: exercise.equipmentType,
                    groupType: exercise.groupType?.rawValue,
                    groupName: exercise.groupName,
                    parentExerciseId: parentId,
                    status: ExerciseStatus.completed.rawValue,
                    updatedAt: end
                ).insert(db)

                try insertCompletedSets(
                    for: exercise,
                    sessionExerciseId: sessionExerciseId,
                    weeksFromLatest: weeksFromLatest,
                    completedAt: end,
                    in: db
                )
            }
        }
    }

    private static func insertCompletedSets(
        for exercise: PlannedExercise,
        sessionExerciseId: String,
        weeksFromLatest: Int,
        completedAt: String,
        in db: Database
    ) throws {
        for (index, set) in exercise.sets.enumerated() {
            let setId = IDGenerator.generate()
            try SessionSetRow(
                id: setId,
                sessionExerciseId: sessionExerciseId,
                orderIndex: index,
                restSeconds: set.restSeconds,
                completedAt: completedAt,
                status: SetStatus.completed.rawValue,
                notes: nil,
                isDropset: set.isDropset ? 1 : 0,
                isPerSide: set.isPerSide ? 1 : 0,
                isAmrap: set.isAmrap ? 1 : 0,
                side: nil,
                updatedAt: completedAt
            ).insert(db)

            for entry in set.entries {
                if let target = entry.target {
                    for row in target.toMeasurementRows(
                        setId: setId, parentType: "session", role: "target",
                        groupIndex: entry.groupIndex, now: completedAt
                    ) {
                        try row.insert(db)
                    }
                }
                let actual = actualValues(
                    forExercise: exercise.exerciseName,
                    target: entry.target,
                    weeksFromLatest: weeksFromLatest
                )
                for row in actual.toMeasurementRows(
                    setId: setId, parentType: "session", role: "actual",
                    groupIndex: entry.groupIndex, now: completedAt
                ) {
                    try row.insert(db)
                }
            }
        }
    }

    /// Build "actual" values that match the planned target plus a small,
    /// exercise-specific weight regression so older sessions lifted slightly
    /// less. The latest session matches the plan exactly; each prior week
    /// removes a per-exercise increment from the working weights.
    private static func actualValues(
        forExercise name: String,
        target: EntryValues?,
        weeksFromLatest: Int
    ) -> EntryValues {
        guard let target = target else { return EntryValues() }
        var actual = target
        let bump = -Double(weeksFromLatest) * weeklyIncrement(forExercise: name)
        if let weight = actual.weight, bump != 0 {
            let progressed = max(weight.value + bump, weight.value * 0.6)
            actual.weight = MeasuredWeight(value: progressed.rounded(), unit: weight.unit)
        }
        return actual
    }

    /// Per-exercise per-week progression. Compound lifts get bigger jumps,
    /// accessories smaller, isolation work effectively flat. Anything not
    /// listed here progresses at 0 (timed/bodyweight/stretches).
    private static func weeklyIncrement(forExercise name: String) -> Double {
        switch name {
        case "Barbell Bench Press": return 5
        case "Overhead Press": return 2.5
        case "Barbell Row": return 5
        case "Conventional Deadlift": return 10
        case "Barbell Back Squat": return 10
        case "Romanian Deadlift": return 5
        case "Leg Press": return 15
        case "Incline Dumbbell Press": return 2.5
        case "Lat Pulldown": return 5
        case "Cable Tricep Pushdown": return 2.5
        case "Dumbbell Bicep Curl": return 2.5
        case "Bulgarian Split Squat": return 2.5
        default: return 0
        }
    }

    // MARK: - Plan sources

    private struct PlanSource {
        let key: PlanKey
        let markdown: String
        let favorite: Bool
    }

    private static let planSources: [PlanSource] = [
        PlanSource(key: .push, markdown: pushDayMarkdown, favorite: true),
        PlanSource(key: .pull, markdown: pullDayMarkdown, favorite: false),
        PlanSource(key: .legs, markdown: legDayMarkdown, favorite: false),
        PlanSource(key: .conditioning, markdown: conditioningMarkdown, favorite: false),
        // Library-only plans — fill out the Plans screen, no session history.
        PlanSource(key: .fullBody, markdown: fullBodyMarkdown, favorite: false),
        PlanSource(key: .upper, markdown: upperBodyMarkdown, favorite: false),
        PlanSource(key: .arms, markdown: armDayMarkdown, favorite: false),
        PlanSource(key: .mobility, markdown: mobilityMarkdown, favorite: false)
    ]

    /// Source: test-fixtures/screenshot-routine.md. Showcase plan — the
    /// workout-detail screenshot opens this one. No warmup section so the
    /// screenshots land directly on the working sets and the superset.
    private static let pushDayMarkdown = """
    # Push Day — Upper Strength

    @tags: push, upper, strength
    @units: lbs

    ## Main

    ### Barbell Bench Press
    Heavy compound — film a working set if form feels off
    - 135 x 8 @rest: 90s
    - 155 x 6 @rest: 120s
    - 185 x 5 @rest: 150s
    - 195 x 5 @rest: 150s
    - 195 x 5 @rest: 150s

    ### Overhead Press
    Strict press, full lockout overhead
    - 75 x 8 @rest: 90s
    - 95 x 6 @rest: 120s
    - 105 x 5 @rest: 120s

    ### Superset: Chest & Shoulders
    #### Incline Dumbbell Press
    Set the bench around 30°. Press up and slightly in, controlled tempo down.
    - 50 x 10
    - 55 x 10
    - 60 x 8
    #### Lateral Raises
    Slight bend in the elbows. Lead with the elbows, raise to shoulder height — no swinging.
    - 15 x 15
    - 15 x 15
    - 20 x 12

    ### Cable Tricep Pushdown
    Drop set to finish — strip the stack, then max reps
    - 60 x 12 @dropset
    - 40 x AMRAP

    ### Push-ups
    Finisher — go to failure on the last set
    - x 15
    - x 12
    - bw x AMRAP

    ## Cool Down

    ### Plank
    Core finisher
    - 60s @rest: 45s
    - 45s

    ### Doorway Chest Stretch
    Open up the pecs
    - 30s @perside

    ### Cross-Body Shoulder Stretch
    Each side, gentle pull
    - 30s @perside
    """

    private static let pullDayMarkdown = """
    # Pull Day — Back & Biceps

    @tags: pull, back, biceps
    @units: lbs

    ## Warmup

    ### Cat-Cow
    Spinal mobility, move with breath
    - x 10

    ### Band Pull-Aparts
    - x 15
    - x 15

    ### Scapular Pull-Ups
    Just the shrug — no elbow bend
    - x 8

    ## Main

    ### Conventional Deadlift
    Working triples — keep core braced and bar close
    - 135 x 5 @rest: 120s
    - 185 x 3 @rest: 150s
    - 225 x 3 @rest: 180s
    - 275 x 3 @rest: 180s
    - 275 x 3 @rest: 180s

    ### Barbell Row
    Pendlay-style, full reset between reps
    - 95 x 8 @rest: 90s
    - 115 x 6 @rest: 120s
    - 135 x 6 @rest: 120s
    - 135 x 6 @rest: 120s

    ### Lat Pulldown
    Squeeze the lats, no momentum
    - 100 x 10 @rest: 90s
    - 120 x 8 @rest: 90s
    - 130 x 6 @rest: 90s

    ### Dumbbell Bicep Curl
    Strict, slow eccentric
    - 25 x 10 @rest: 60s
    - 30 x 8 @rest: 60s
    - 30 x 8 @rest: 60s

    ### Face Pulls
    Pull to forehead, externally rotate
    - 30 x 15
    - 35 x 12
    - 35 x 12

    ## Cool Down

    ### Child's Pose
    - 60s

    ### Lat Stretch
    - 30s @perside
    """

    private static let legDayMarkdown = """
    # Leg Day — Lower Power

    @tags: legs, lower, strength
    @units: lbs

    ## Warmup

    ### 90/90 Hip Switches
    - x 10

    ### Bodyweight Squat
    - x 12

    ### Glute Bridge
    - x 12

    ## Main

    ### Barbell Back Squat
    Heavy compound — drive through heels, brace hard
    - 135 x 8 @rest: 90s
    - 185 x 5 @rest: 150s
    - 225 x 5 @rest: 180s
    - 245 x 3 @rest: 180s
    - 245 x 3 @rest: 180s

    ### Romanian Deadlift
    Hip hinge, feel the hamstrings
    - 135 x 8 @rest: 90s
    - 155 x 8 @rest: 90s
    - 175 x 6 @rest: 120s

    ### Bulgarian Split Squat
    Each leg, slow tempo
    - 30 x 10 @perside @rest: 90s
    - 35 x 8 @perside @rest: 90s
    - 35 x 8 @perside @rest: 90s

    ### Leg Press
    Full ROM, no lockout
    - 270 x 12 @rest: 90s
    - 360 x 10 @rest: 120s
    - 405 x 8 @rest: 120s

    ### Standing Calf Raise
    Pause at the top
    - 90 x 15
    - 110 x 12
    - 110 x 12

    ## Cool Down

    ### Pigeon Pose
    - 45s @perside

    ### Quad Stretch
    - 30s @perside

    ### Hamstring Stretch
    - 30s @perside
    """

    private static let conditioningMarkdown = """
    # Conditioning & Core

    @tags: conditioning, core, cardio
    @units: lbs

    ## Warmup

    ### Jumping Jacks
    - 60s

    ### High Knees
    - 30s

    ## Circuit

    ### Kettlebell Swing
    Hip-driven, not a squat
    - 35 x 20 @rest: 45s
    - 35 x 20 @rest: 45s
    - 35 x 20 @rest: 45s

    ### Goblet Squat
    Elbows inside knees at the bottom
    - 35 x 15 @rest: 45s
    - 35 x 15 @rest: 45s

    ### Mountain Climbers
    - 45s @rest: 30s
    - 45s @rest: 30s
    - 45s

    ### Russian Twist
    - x 30 @rest: 30s
    - x 30 @rest: 30s

    ## Core

    ### Superset: Plank & Dead Bug
    #### Plank
    Beat last week's 65s — aim for 70s if it feels solid.
    - 60s @rest: 20s
    - 60s @rest: 20s
    - 45s

    #### Dead Bug
    Slow and controlled, lower back pressed into floor.
    - x 10 @perside
    - x 10 @perside
    - x 10 @perside

    ### Hollow Hold
    - 30s @rest: 30s
    - 30s

    ### Bird Dog
    Each side, slow and controlled
    - x 12 @perside

    ## Cool Down

    ### Cat-Cow
    - x 10

    ### Cobra Stretch
    - 30s
    """

    // MARK: - Library-only plans (no scheduled history)

    private static let fullBodyMarkdown = """
    # Full Body — 5×5 Strength

    @tags: full-body, strength, beginner
    @units: lbs

    ## Main

    ### Back Squat
    Five across — same weight all sets once warm
    - 185 x 5 @rest: 180s
    - 185 x 5 @rest: 180s
    - 185 x 5 @rest: 180s
    - 185 x 5 @rest: 180s
    - 185 x 5 @rest: 180s

    ### Bench Press
    Pause briefly on the chest each rep
    - 155 x 5 @rest: 180s
    - 155 x 5 @rest: 180s
    - 155 x 5 @rest: 180s
    - 155 x 5 @rest: 180s
    - 155 x 5 @rest: 180s

    ### Barbell Row
    Flat back, pull to the lower ribs
    - 135 x 5 @rest: 120s
    - 135 x 5 @rest: 120s
    - 135 x 5 @rest: 120s
    - 135 x 5 @rest: 120s
    - 135 x 5 @rest: 120s
    """

    private static let upperBodyMarkdown = """
    # Upper Body — Hypertrophy

    @tags: upper, hypertrophy
    @units: lbs

    ## Main

    ### Incline Dumbbell Press
    Controlled tempo, stretch at the bottom
    - 50 x 12 @rest: 90s
    - 55 x 10 @rest: 90s
    - 60 x 8 @rest: 90s

    ### Seated Cable Row
    Squeeze and hold a beat at the back
    - 120 x 12 @rest: 75s
    - 135 x 10 @rest: 75s
    - 150 x 8 @rest: 75s

    ### Dumbbell Shoulder Press
    Press to lockout, no leg drive
    - 35 x 12 @rest: 75s
    - 40 x 10 @rest: 75s

    ### Lat Pulldown
    Drive the elbows down and back
    - 110 x 12 @rest: 75s
    - 120 x 10 @rest: 75s
    """

    private static let armDayMarkdown = """
    # Arm Day — Biceps & Triceps

    @tags: arms, biceps, triceps
    @units: lbs

    ## Main

    ### Barbell Curl
    Strict — no swinging at the hips
    - 60 x 12 @rest: 60s
    - 70 x 10 @rest: 60s
    - 70 x 10 @rest: 60s

    ### Close-Grip Bench Press
    Elbows tucked, full lockout
    - 115 x 10 @rest: 90s
    - 125 x 8 @rest: 90s

    ### Hammer Curl
    Neutral grip, control the lowering
    - 30 x 12 @rest: 60s
    - 30 x 12 @rest: 60s

    ### Overhead Cable Extension
    Keep the elbows high and still
    - 50 x 15 @rest: 60s
    - 60 x 12 @rest: 60s
    """

    private static let mobilityMarkdown = """
    # Mobility & Core

    @tags: mobility, core, recovery
    @units: lbs

    ## Main

    ### Plank
    Brace hard, breathe steady
    - 60s @rest: 45s
    - 60s @rest: 45s
    - 45s

    ### Dead Bug
    Slow and controlled, opposite arm and leg
    - x 12 @perside
    - x 12 @perside

    ### Bird Dog
    Reach long, pause at full extension
    - x 10 @perside
    - x 10 @perside

    ### Couch Stretch
    Open the hip flexors
    - 45s @perside

    ### Cat-Cow
    Move with the breath
    - x 10
    """
}
#endif
