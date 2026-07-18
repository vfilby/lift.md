import Foundation

// MARK: - Types

struct WorkoutHighlight: Identifiable {
    let id = UUID().uuidString
    let type: HighlightType
    let emoji: String
    let title: String
    let message: String
}

enum HighlightType {
    case pr
    case weightIncrease
    case volumeIncrease
    case streak
}

struct ExercisePR {
    let exerciseName: String
    let newWeight: Double
    let newReps: Int
    let oldWeight: Double?
    let oldReps: Int?
    let unit: String
}

struct VolumeComparison {
    let currentVolume: Double
    let previousVolume: Double
    let percentageIncrease: Double
}

// MARK: - Service

/// Service for calculating workout achievements and generating highlight messages.
struct WorkoutHighlightsService {
    private let repository = SessionRepository()

    /// Calculate all highlights for a completed workout session.
    func calculateWorkoutHighlights(_ session: WorkoutSession) throws -> [WorkoutHighlight] {
        var highlights: [WorkoutHighlight] = []

        let prs = try detectPersonalRecords(session)
        for pr in prs {
            highlights.append(createPRHighlight(pr))
        }

        if let volumeComparison = try calculateVolumeImprovement(session) {
            highlights.append(createVolumeHighlight(volumeComparison))
        }

        let streak = try calculateWorkoutStreak(session)
        if streak >= 2 {
            highlights.append(createStreakHighlight(streak))
        }

        let weightIncreases = try detectWeightIncreases(session)
        for increase in weightIncreases {
            highlights.append(createWeightIncreaseHighlight(increase))
        }

        return highlights
    }

    // MARK: - Detection

    /// Detect new personal records in the current session.
    private func detectPersonalRecords(_ session: WorkoutSession) throws -> [ExercisePR] {
        let bestWeights = try repository.getExerciseBestWeightsNormalized()
        var prs: [ExercisePR] = []

        let sessionMaxes = getSessionMaxWeights(session)

        for (exerciseName, sessionMax) in sessionMaxes {
            if let historicalBest = bestWeights[exerciseName] {
                if sessionMax.weight > historicalBest.weight {
                    prs.append(ExercisePR(
                        exerciseName: exerciseName,
                        newWeight: sessionMax.weight,
                        newReps: sessionMax.reps,
                        oldWeight: historicalBest.weight,
                        oldReps: historicalBest.reps,
                        unit: sessionMax.unit
                    ))
                }
            } else {
                prs.append(ExercisePR(
                    exerciseName: exerciseName,
                    newWeight: sessionMax.weight,
                    newReps: sessionMax.reps,
                    oldWeight: nil,
                    oldReps: nil,
                    unit: sessionMax.unit
                ))
            }
        }

        return prs
    }

    /// Detect weight increases compared to last session with same exercises.
    private func detectWeightIncreases(_ session: WorkoutSession) throws -> [ExercisePR] {
        var increases: [ExercisePR] = []
        let recentSessions = try repository.getRecentSessions(10)

        let currentExercises = session.exercises.filter { !$0.sets.isEmpty }

        for currentEx in currentExercises {
            guard let currentMax = getExerciseMaxWeight(currentEx) else { continue }

            if let lastSession = findLastSessionWithExercise(
                recentSessions,
                exerciseName: currentEx.exerciseName,
                excludeSessionId: session.id
            ) {
                if let lastEx = lastSession.exercises.first(
                    where: { ExerciseDictionary.isSameExercise($0.exerciseName, currentEx.exerciseName) }),
                   let lastMax = getExerciseMaxWeight(lastEx),
                   currentMax.weight > lastMax.weight {
                    increases.append(ExercisePR(
                        exerciseName: currentEx.exerciseName,
                        newWeight: currentMax.weight,
                        newReps: currentMax.reps,
                        oldWeight: lastMax.weight,
                        oldReps: lastMax.reps,
                        unit: currentMax.unit
                    ))
                }
            }
        }

        return increases
    }

    /// Calculate volume improvement compared to recent similar workouts.
    private func calculateVolumeImprovement(_ session: WorkoutSession) throws -> VolumeComparison? {
        let currentVolume = calculateSessionVolume(session)
        guard currentVolume > 0 else { return nil }

        let recentSessions = try repository.getRecentSessions(10)
        let similarSessions = recentSessions.filter {
            $0.id != session.id &&
            ($0.name.lowercased() == session.name.lowercased() ||
             $0.workoutPlanId == session.workoutPlanId)
        }

        guard let previousSession = similarSessions.first else { return nil }
        let previousVolume = calculateSessionVolume(previousSession)
        guard previousVolume > 0 else { return nil }

        let percentageIncrease = ((currentVolume - previousVolume) / previousVolume) * 100

        guard percentageIncrease > 5 else { return nil }

        return VolumeComparison(
            currentVolume: currentVolume,
            previousVolume: previousVolume,
            percentageIncrease: percentageIncrease
        )
    }

    /// Calculate workout streak (consecutive days with workouts).
    private func calculateWorkoutStreak(_ session: WorkoutSession) throws -> Int {
        let recentSessions = try repository.getRecentSessions(30)

        let sortedSessions = recentSessions
            .filter { $0.id != session.id }
            .sorted { $0.date > $1.date }

        var streak = 1
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        guard var lastDate = dateFormatter.date(from: String(session.date.prefix(10))) else {
            return streak
        }

        for s in sortedSessions {
            guard let currentDate = dateFormatter.date(from: String(s.date.prefix(10))) else { continue }

            let daysDiff = Calendar.current.dateComponents([.day], from: currentDate, to: lastDate).day ?? 0

            if daysDiff == 0 {
                continue
            } else if daysDiff == 1 {
                streak += 1
                lastDate = currentDate
            } else {
                break
            }
        }

        return streak
    }

    // MARK: - Helpers

    func getSessionMaxWeights(_ session: WorkoutSession) -> [String: (weight: Double, reps: Int, unit: String)] {
        var maxes: [String: (weight: Double, reps: Int, unit: String)] = [:]

        for exercise in session.exercises where !exercise.sets.isEmpty {
            if let max = getExerciseMaxWeight(exercise) {
                let canonical = ExerciseDictionary.getCanonicalName(exercise.exerciseName)
                if let existing = maxes[canonical] {
                    if max.weight > existing.weight {
                        maxes[canonical] = max
                    }
                } else {
                    maxes[canonical] = max
                }
            }
        }

        return maxes
    }

    func getExerciseMaxWeight(_ exercise: SessionExercise) -> (weight: Double, reps: Int, unit: String)? {
        var maxWeight: Double = 0
        var maxSet: SessionSet?

        for set in exercise.sets {
            let actual = set.entries.first?.actual
            if set.status == .completed, let weight = actual?.weight?.value, weight > maxWeight {
                maxWeight = weight
                maxSet = set
            }
        }

        guard let maxSet, maxWeight > 0 else { return nil }
        let actual = maxSet.entries.first?.actual
        return (maxWeight, actual?.reps ?? 0, actual?.weight?.unit.rawValue ?? "lbs")
    }

    func calculateSessionVolume(_ session: WorkoutSession) -> Double {
        var totalVolume: Double = 0
        for exercise in session.exercises {
            for set in exercise.sets {
                let actual = set.entries.first?.actual
                if set.status == .completed,
                   let weight = actual?.weight?.value,
                   let reps = actual?.reps {
                    totalVolume += weight * Double(reps)
                }
            }
        }
        return totalVolume
    }

    func findLastSessionWithExercise(
        _ sessions: [WorkoutSession],
        exerciseName: String,
        excludeSessionId: String
    ) -> WorkoutSession? {
        sessions.first { session in
            session.id != excludeSessionId &&
            session.exercises.contains {
                ExerciseDictionary.isSameExercise($0.exerciseName, exerciseName) && !$0.sets.isEmpty
            }
        }
    }

    // MARK: - Highlight Creation

    func createPRHighlight(_ pr: ExercisePR) -> WorkoutHighlight {
        if let oldWeight = pr.oldWeight {
            return WorkoutHighlight(
                type: .pr,
                emoji: "🎉",
                title: "New PR!",
                message: "\(pr.exerciseName): \(Int(pr.newWeight))\(pr.unit) (previous: \(Int(oldWeight))\(pr.unit))"
            )
        } else {
            return WorkoutHighlight(
                type: .pr,
                emoji: "🎉",
                title: "First PR!",
                message: "\(pr.exerciseName): \(Int(pr.newWeight))\(pr.unit)"
            )
        }
    }

    func createWeightIncreaseHighlight(_ increase: ExercisePR) -> WorkoutHighlight {
        WorkoutHighlight(
            type: .weightIncrease,
            emoji: "💪",
            title: "Weight Increase!",
            message: "\(increase.exerciseName): \(Int(increase.newWeight))\(increase.unit) "
                + "(up from \(Int(increase.oldWeight ?? 0))\(increase.unit))"
        )
    }

    func createVolumeHighlight(_ comparison: VolumeComparison) -> WorkoutHighlight {
        WorkoutHighlight(
            type: .volumeIncrease,
            emoji: "📈",
            title: "Volume Increase!",
            message: "\(Int(comparison.percentageIncrease))% more volume vs last time"
        )
    }

    func createStreakHighlight(_ streak: Int) -> WorkoutHighlight {
        let weekCount = streak / 7
        let message: String
        if weekCount > 0 {
            message = "\(weekCount)-week streak!"
        } else {
            message = "\(streak)-day streak!"
        }
        return WorkoutHighlight(
            type: .streak,
            emoji: "🔥",
            title: "Consistency!",
            message: message
        )
    }
}
