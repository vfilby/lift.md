import Foundation

/// `@Observable` registry of `FeatureFlag` values. Backed by `UserDefaults`,
/// per-key. See `spec/services/feature-flags.md`.
///
/// Read with `flags.isEnabled(.workoutInbox)`. Write with `flags.set(...)`.
/// Toggling triggers a recompute of every view that read the flag.
@MainActor
@Observable
final class FeatureFlagsStore {
    private let defaults: UserDefaults
    private let launchArguments: Set<String>

    /// Mirrors UserDefaults so that mutations notify observers without
    /// having to plumb a publisher. Keyed by `FeatureFlag.rawValue`.
    private var values: [String: Bool] = [:]

    init(defaults: UserDefaults = .standard, launchArguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        self.launchArguments = Set(launchArguments)
        for flag in FeatureFlag.allCases {
            values[flag.rawValue] = resolveInitialValue(for: flag)
        }
    }

    func isEnabled(_ flag: FeatureFlag) -> Bool {
        values[flag.rawValue] ?? flag.defaultValue
    }

    func set(_ flag: FeatureFlag, _ enabled: Bool) {
        values[flag.rawValue] = enabled
        defaults.set(enabled, forKey: flag.defaultsKey)
    }

    // MARK: - Private

    private func resolveInitialValue(for flag: FeatureFlag) -> Bool {
        // Launch-argument override beats stored value (UI tests).
        if launchArguments.contains(flag.launchArgument) {
            return true
        }
        // Treat "key absent" as "use default" — a flag that has never
        // been toggled returns its declared default rather than `false`.
        guard defaults.object(forKey: flag.defaultsKey) != nil else {
            return flag.defaultValue
        }
        return defaults.bool(forKey: flag.defaultsKey)
    }
}
