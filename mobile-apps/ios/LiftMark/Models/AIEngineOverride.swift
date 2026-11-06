import Foundation

/// Developer setting that forces one AI plan-editing engine regardless of
/// availability. Not a `FeatureFlag` (flags are booleans). Stored under
/// `feature_flag.aiEngineOverride`, read via `FeatureFlagsStore.engineOverride`,
/// and removed together with the `aiPlanEditing` flag. See
/// `spec/services/feature-flags.md` ("Developer setting: AI engine override").
enum AIEngineOverride: String, CaseIterable, Identifiable, Sendable {
    case auto
    case applePrivateCloud
    case appleOnDevice
    case liftMarkCloud

    var id: String { rawValue }

    static let defaultsKey = "feature_flag.aiEngineOverride"

    /// Launch-argument prefix used by UI tests: `--ai-engine-override=<rawValue>`.
    static let launchArgumentPrefix = "--ai-engine-override="

    /// Label for the Settings picker.
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .applePrivateCloud: return "Apple Private Cloud Compute"
        case .appleOnDevice: return "Apple on-device"
        case .liftMarkCloud: return "LiftMark cloud"
        }
    }

    /// The engine this override forces, or nil for `auto`.
    var engineKind: PlanEditEngineKind? {
        switch self {
        case .auto: return nil
        case .applePrivateCloud: return .applePrivateCloud
        case .appleOnDevice: return .appleOnDevice
        case .liftMarkCloud: return .liftMarkCloud
        }
    }

    /// Parse `--ai-engine-override=<rawValue>` from launch arguments.
    static func fromLaunchArguments(_ arguments: [String]) -> AIEngineOverride? {
        guard let argument = arguments.first(where: { $0.hasPrefix(launchArgumentPrefix) }) else { return nil }
        return AIEngineOverride(rawValue: String(argument.dropFirst(launchArgumentPrefix.count)))
    }
}
