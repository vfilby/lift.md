import Foundation

/// Lazily builds one engine per kind. Injected so tests can substitute fakes
/// and so the Apple engines are only constructed when actually selected.
struct PlanEditEngineFactories: Sendable {
    var stub: @Sendable () -> any PlanEditEngine
    var applePrivateCloud: @Sendable () -> any PlanEditEngine
    var appleOnDevice: @Sendable () -> any PlanEditEngine
    var liftMarkCloud: @Sendable () -> any PlanEditEngine

    func make(_ kind: PlanEditEngineKind) -> any PlanEditEngine {
        switch kind {
        case .stub: return stub()
        case .applePrivateCloud: return applePrivateCloud()
        case .appleOnDevice: return appleOnDevice()
        case .liftMarkCloud: return liftMarkCloud()
        }
    }

    /// Production wiring.
    @MainActor
    static func live(authStore: AuthenticationStore, apiClient: APIClientProtocol) -> PlanEditEngineFactories {
        let cloud = LiftMarkCloudEngine(authStore: authStore, apiClient: apiClient)
        return PlanEditEngineFactories(
            stub: { StubPlanEditEngine() },
            applePrivateCloud: { ApplePrivateCloudEngine() },
            appleOnDevice: { AppleOnDeviceEngine() },
            liftMarkCloud: { cloud }
        )
    }
}

/// Picks the engine for one Edit with AI sheet. See
/// `spec/services/ai-plan-editing.md` ("Engine selection"):
///
/// 1. `--ai-engine-stub` present → stub.
/// 2. Developer override set → that engine, even if unavailable.
/// 3. Otherwise the first of `applePrivateCloud` → `liftMarkCloud` whose
///    `availability()` is `.available`.
/// 4. None available → the last engine tried (`liftMarkCloud`) so the sheet
///    can show its reason.
///
/// `appleOnDevice` is never auto-selected in this phase.
struct PlanEditEngineSelector: Sendable {
    static let autoOrder: [PlanEditEngineKind] = [.applePrivateCloud, .liftMarkCloud]

    private let factories: PlanEditEngineFactories
    private let launchArguments: Set<String>

    init(
        factories: PlanEditEngineFactories,
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.factories = factories
        self.launchArguments = Set(launchArguments)
    }

    /// True when `--ai-engine-stub` is present. While the stub is active the
    /// tier gate is satisfied regardless of auth state.
    var isStubActive: Bool {
        launchArguments.contains(StubPlanEditEngine.launchArgument)
    }

    /// - Parameter isSignedIn: Informational; the auto order always ends on
    ///   `liftMarkCloud` so a signed-out user sees "Sign in to use LiftMark
    ///   cloud" rather than a generic failure.
    func select(override: AIEngineOverride, isSignedIn: Bool) async -> any PlanEditEngine {
        if isStubActive {
            return factories.make(.stub)
        }
        if let forced = override.engineKind {
            Logger.shared.info(.app, "ai engine forced by developer override", metadata: ["engine": forced.rawValue])
            return factories.make(forced)
        }

        var last: (any PlanEditEngine)?
        for kind in Self.autoOrder {
            let engine = factories.make(kind)
            last = engine
            if await engine.availability().isAvailable {
                return engine
            }
        }
        Logger.shared.info(
            .app,
            "no ai engine available",
            metadata: ["signedIn": String(isSignedIn)]
        )
        // `autoOrder` is non-empty, so `last` is always set here.
        return last ?? factories.make(.liftMarkCloud)
    }
}
