import Foundation

/// Persists the last-known `AuthenticatedUser` profile (email, display name,
/// tier, trial end) so launch rehydration can restore the *real* plan and
/// identity instead of a `tier: .free` placeholder reconstituted from JWT
/// claims (which carry no tier). See `spec/services/authentication.md`
/// (Persisted profile).
///
/// This is non-secret display data, not a credential, so it lives in
/// `UserDefaults` rather than the Keychain — that also lets rehydration read it
/// synchronously without a Keychain round-trip.
final class ProfileStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "auth.lastKnownProfile") {
        self.defaults = defaults
        self.key = key
    }

    /// Persist the full profile verbatim, overwriting any prior value.
    func save(_ user: AuthenticatedUser) {
        do {
            let data = try JSONEncoder().encode(user)
            defaults.set(data, forKey: key)
        } catch {
            Logger.shared.warn(.network, "ProfileStore save failed: \(error)")
        }
    }

    /// Load the last-known profile, or nil if none persisted / decode fails.
    func load() -> AuthenticatedUser? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(AuthenticatedUser.self, from: data)
        } catch {
            Logger.shared.warn(.network, "ProfileStore load failed: \(error)")
            return nil
        }
    }

    /// Drop the persisted profile (deliberate sign-out).
    func clear() {
        defaults.removeObject(forKey: key)
    }
}
