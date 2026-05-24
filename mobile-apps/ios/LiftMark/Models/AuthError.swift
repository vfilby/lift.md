import Foundation

enum AuthError: Error, Equatable {
    case invalidCredentials
    case emailNotVerified
    case network
    case unknown(String?)
}
