import Foundation

struct AuthenticatedUser: Codable, Hashable {
    let userId: String
    let email: String
    let displayName: String
    let tier: Tier
    let trialEndsAt: Date?

    enum Tier: String, Codable {
        case pro
        case trial
        case free
    }
}
