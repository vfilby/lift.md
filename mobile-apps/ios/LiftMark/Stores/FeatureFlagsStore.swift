import Foundation

/// `@Observable` registry of `FeatureFlag` values. Backed by `UserDefaults`,
/// per-key. See `spec/services/feature-flags.md`.
///
/// Read with `flags.isEnabled(.workoutInbox)`. Write with `flags.set(...)`.
/// Toggling triggers a recompute of every view that read the flag.
///
/// Also owns the one non-boolean developer setting, `engineOverride`
/// (`AIEngineOverride`), which lives alongside the flags because it is
/// removed with the `aiPlanEditing` flag.
@MainActor
@Observable
final class FeatureFlagsStore {
    private let defaults: UserDefaults
    private let launchArguments: Set<String>

    /// Mirrors UserDefaults so that mutations notify observers without
    /// having to plumb a publisher. Keyed by `FeatureFlag.rawValue`.
    private var values: [String: Bool] = [:]

    /// Developer override for the AI plan-editing engine. `auto` lets
    /// `PlanEditEngineSelector` pick. Persisted under
    /// `AIEngineOverride.defaultsKey`; never synced.
    var engineOverride: AIEngineOverride {
        didSet { defaults.set(engineOverride.rawValue, forKey: AIEngineOverride.defaultsKey) }
    }

    /// True when the app was launched with `--ai-engine-stub` (UI tests). The
    /// stub engine satisfies the AI editing tier gate regardless of auth.
    var isAIEngineStubActive: Bool {
        launchArguments.contains(StubPlanEditEngine.launchArgument)
    }

    init(defaults: UserDefaults = .standard, launchArguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        self.launchArguments = Set(launchArguments)
        self.engineOverride = Self.resolveInitialOverride(defaults: defaults, launchArguments: launchArguments)
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

    private static func resolveInitialOverride(defaults: UserDefaults, launchArguments: [String]) -> AIEngineOverride {
        if let fromArgs = AIEngineOverride.fromLaunchArguments(launchArguments) {
            return fromArgs
        }
        guard let raw = defaults.string(forKey: AIEngineOverride.defaultsKey),
              let stored = AIEngineOverride(rawValue: raw) else {
            return .auto
        }
        return stored
    }
}
