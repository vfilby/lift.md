import Foundation

/// Service for generating compact workout history summaries for AI prompts.
/// Format is designed to be token-efficient while providing useful context.
struct WorkoutHistoryService {
    private let repository = SessionRepository()

    /// Generate a compact formatted summary of recent workouts plus PRs.
    func generateWorkoutHistoryContext(recentCount: Int = 5) throws -> String {
        let recentSessions = try repository.getRecentSessions(recentCount)
        let bestWeights = try repository.getExerciseBestWeightsNormalized()

        var parts: [String] = []

        if !recentSessions.isEmpty {
            parts.append("Recent workouts:")
            for session in recentSessions {
                parts.append(formatSessionCompact(session))
            }
        }

        // Best weights for exercises not in recent workouts
        var recentExerciseNames = Set<String>()
        for session in recentSessions {
            for exercise in session.exercises where !exercise.sets.isEmpty {
                recentExerciseNames.insert(ExerciseDictionary.getCanonicalName(exercise.exerciseName).lowercased())
            }
        }

        let additionalWeights = bestWeights.compactMap { (name, data) -> String? in
            guard !recentExerciseNames.contains(name.lowercased()) else { return nil }
            return "\(name): \(Int(data.weight))\(data.unit)x\(data.reps)"
        }

        if !additionalWeights.isEmpty {
            parts.append("")
            parts.append("Other exercise PRs: " + additionalWeights.joined(separator: ", "))
        }

        return parts.joined(separator: "\n")
    }

    /// Format a single workout session in compact format.
    /// Example: "2024-01-15 Push Day: Bench 185x8,205x5; Incline DB 60x10,70x8"
    func formatSessionCompact(_ session: WorkoutSession) -> String {
        let date = session.date.split(separator: "T").first.map(String.init) ?? session.date
        let exercises = session.exercises
            .filter { !$0.sets.isEmpty }
            .map { formatExerciseCompact($0) }
            .filter { !$0.isEmpty }

        return "\(date) \(session.name): \(exercises.joined(separator: "; "))"
    }

    /// Format a single exercise in compact format.
    /// Example: "Bench 185x8,205x5,225x3"
    func formatExerciseCompact(_ exercise: SessionExercise) -> String {
        let completedSets = exercise.sets.filter { $0.status == .completed }
        guard !completedSets.isEmpty else { return "" }

        let name = abbreviateExerciseName(exercise.exerciseName)
        let sets = completedSets.map { formatSetCompact($0) }.filter { !$0.isEmpty }
        guard !sets.isEmpty else { return "" }

        return "\(name) \(sets.joined(separator: ","))"
    }

    /// Format a single set in compact format.
    /// Example: "185x8" or "30s" or "bwx10"
    func formatSetCompact(_ set: SessionSet) -> String {
        let target = set.entries.first?.target
        let actual = set.entries.first?.actual
        let weight = actual?.weight?.value ?? target?.weight?.value
        let reps = actual?.reps ?? target?.reps
        let time = actual?.time ?? target?.time

        if let time, reps == nil {
            return DurationFormat.mmss(time)
        }

        if let reps {
            if let weight, weight > 0 {
                return "\(Int(weight))x\(reps)"
            }
            return "bwx\(reps)"
        }

        return ""
    }

    /// Abbreviate common exercise names to save tokens.
    /// Normalizes via canonical name first, then applies abbreviations.
    func abbreviateExerciseName(_ name: String) -> String {
        let canonical = ExerciseDictionary.getCanonicalName(name)
        let abbreviations: [String: String] = [
            "Bench Press": "Bench",
            "Incline Bench Press": "Inc Bench",
            "Incline Dumbbell Press": "Inc DB",
            "Dumbbell Bench Press": "DB Bench",
            "Overhead Press": "OHP",
            "Back Squat": "Squat",
            "Front Squat": "Fr Squat",
            "Deadlift": "DL",
            "Romanian Deadlift": "RDL",
            "Barbell Row": "Row",
            "Dumbbell Row": "DB Row",
            "Lat Pulldown": "Pulldown",
            "Pull-Up": "Pullups",
            "Chin-Up": "Chinups",
            "Bicep Curl": "Curls",
            "Dumbbell Curl": "DB Curls",
            "Tricep Pushdown": "Pushdowns",
            "Tricep Extension": "Tri Ext",
            "Leg Press": "Leg Press",
            "Leg Curl": "Leg Curl",
            "Leg Extension": "Leg Ext",
            "Calf Raise": "Calves",
            "Lateral Raise": "Lat Raise",
            "Face Pull": "Face Pull",
            "Cable Fly": "Flyes",
            "Dumbbell Fly": "DB Flyes",
            "Push-Up": "Pushups",
        ]

        return abbreviations[canonical] ?? canonical
    }

    /// Check if there's any workout history available.
    func hasWorkoutHistory() throws -> Bool {
        let sessions = try repository.getRecentSessions(1)
        return !sessions.isEmpty
    }

    /// Generate a trajectory block for the top `topN` exercises by recent frequency.
    /// Compounds are preferred; if fewer than `topN` compounds appear in the window,
    /// pad with the most-frequent remaining exercises regardless of category.
    /// Pulls from the last `windowSize` sessions to rank and build trajectories.
    /// Emits plain weight×reps trajectories with no coach-style hints — the LLM decides
    /// the next step.
    func generateProgressionContext(topN: Int = 5, windowSize: Int = 30) throws -> String {
        let sessions = try repository.getRecentSessions(windowSize)
        return formatProgression(sessions: sessions, topN: topN)
    }

    /// Pure formatter — takes sessions (most-recent first) and returns the progression block.
    /// Exposed for unit tests.
    func formatProgression(sessions: [WorkoutSession], topN: Int = 5) -> String {
        guard !sessions.isEmpty else { return "" }

        let (trajectoriesByName, frequency) = collectTrajectories(from: sessions)
        guard !frequency.isEmpty else { return "" }

        let selected = selectTopExercises(frequency: frequency, topN: topN)
        guard !selected.isEmpty else { return "" }

        var lines = ["Recent progression (top \(selected.count) by frequency):"]
        for name in selected {
            let trajectory = trajectoriesByName[name] ?? []
            // Take up to 3 most-recent, reverse to oldest→newest.
            let recent = trajectory.prefix(3).reversed().joined(separator: "→")
            guard !recent.isEmpty else { continue }
            lines.append("- \(abbreviateExerciseName(name)): \(recent)")
        }
        return lines.joined(separator: "\n")
    }

    /// Walk the sessions (most-recent first) and collect, per canonical exercise name,
    /// the top completed-set summary of each appearance plus an appearance count.
    private func collectTrajectories(
        from sessions: [WorkoutSession]
    ) -> (trajectories: [String: [String]], frequency: [String: Int]) {
        // Canonical name → ordered list of completed set summaries (most recent first).
        var trajectoriesByName: [String: [String]] = [:]
        var frequency: [String: Int] = [:]

        for session in sessions {
            for exercise in session.exercises where !exercise.sets.isEmpty {
                let canonical = ExerciseDictionary.getCanonicalName(exercise.exerciseName)
                let completedSets = exercise.sets.filter { $0.status == .completed }
                guard !completedSets.isEmpty else { continue }

                frequency[canonical, default: 0] += 1
                let setStrings = completedSets.map { formatSetCompact($0) }.filter { !$0.isEmpty }
                guard let topSet = setStrings.first else { continue }
                trajectoriesByName[canonical, default: []].append(topSet)
            }
        }

        return (trajectoriesByName, frequency)
    }

    /// Pick up to `topN` exercise names, preferring compounds by frequency and
    /// padding with the most-frequent remaining exercises when needed.
    private func selectTopExercises(frequency: [String: Int], topN: Int) -> [String] {
        let compounds = frequency.keys.filter { name in
            ExerciseDictionary.getDefinition(name)?.category == "compound"
        }
        let nonCompounds = frequency.keys.filter { name in
            ExerciseDictionary.getDefinition(name)?.category != "compound"
        }

        let sortByFreq: (String, String) -> Bool = { lhs, rhs in
            let lhsFreq = frequency[lhs] ?? 0
            let rhsFreq = frequency[rhs] ?? 0
            if lhsFreq != rhsFreq { return lhsFreq > rhsFreq }
            return lhs < rhs
        }

        var selected = Array(compounds.sorted(by: sortByFreq).prefix(topN))
        if selected.count < topN {
            let pad = nonCompounds.sorted(by: sortByFreq).prefix(topN - selected.count)
            selected.append(contentsOf: pad)
        }
        return selected
    }
}
