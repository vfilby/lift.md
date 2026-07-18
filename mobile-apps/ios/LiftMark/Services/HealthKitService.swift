import Foundation
import HealthKit

// MARK: - HealthKit Save Result

struct HealthKitSaveResult {
    let success: Bool
    let healthKitId: String?
    let error: String?
}

// MARK: - HealthKitService

enum HealthKitService {

    private static let healthStore = HKHealthStore()

    // MARK: - Availability

    /// Check if HealthKit is available on this device.
    static func isHealthKitAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // MARK: - Authorization

    /// Request write permission for workout data.
    static func requestAuthorization() async -> Bool {
        guard isHealthKitAvailable() else { return false }

        let workoutType = HKObjectType.workoutType()

        do {
            try await healthStore.requestAuthorization(toShare: [workoutType], read: [])
            return true
        } catch {
            Logger.shared.error(.app, "HealthKit authorization failed", error: error)
            return false
        }
    }

    /// Check current authorization status for writing workout data.
    static func isAuthorized() -> Bool {
        guard isHealthKitAvailable() else { return false }

        let workoutType = HKObjectType.workoutType()
        let status = healthStore.authorizationStatus(for: workoutType)
        return status == .sharingAuthorized
    }

    // MARK: - Save Workout

    /// Save a completed workout session to Apple Health.
    static func saveWorkout(_ session: WorkoutSession) async -> HealthKitSaveResult {
        guard isHealthKitAvailable() else {
            return HealthKitSaveResult(
                success: false, healthKitId: nil, error: "HealthKit is not available on this device")
        }

        do {
            let startDate: Date
            if let startTime = session.startTime {
                startDate = ISO8601DateFormatter().date(from: startTime) ?? Date()
            } else {
                startDate = ISO8601DateFormatter().date(from: session.date) ?? Date()
            }

            let endDate: Date
            if let endTime = session.endTime {
                endDate = ISO8601DateFormatter().date(from: endTime) ?? Date()
            } else {
                endDate = Date()
            }

            let totalVolume = calculateWorkoutVolume(session)

            var metadata: [String: Any] = [
                HKMetadataKeyExternalUUID: session.id
            ]

            if totalVolume > 0 {
                metadata["TotalVolumeLbs"] = totalVolume
            }

            let workout = HKWorkout(
                activityType: .traditionalStrengthTraining,
                start: startDate,
                end: endDate,
                duration: endDate.timeIntervalSince(startDate),
                totalEnergyBurned: nil,
                totalDistance: nil,
                metadata: metadata
            )

            try await healthStore.save(workout)

            return HealthKitSaveResult(success: true, healthKitId: workout.uuid.uuidString, error: nil)
        } catch {
            Logger.shared.error(.app, "Failed to save workout to HealthKit", error: error)
            return HealthKitSaveResult(success: false, healthKitId: nil, error: String(describing: error))
        }
    }

    // MARK: - Volume Calculation

    /// Calculate total workout volume as the sum of (weight x reps) for all completed sets.
    static func calculateWorkoutVolume(_ session: WorkoutSession) -> Double {
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
}
