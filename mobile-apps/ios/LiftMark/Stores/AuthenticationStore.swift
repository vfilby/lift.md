import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Wire Types

private struct LoginRequest: Encodable {
    let email: String
    let password: String
    let deviceLabel: String
}

private struct LoginResponse: Decodable {
    let accessJwt: String
    let refreshToken: String
    let user: AuthenticatedUser
}

private struct RefreshRequest: Encodable {
    let refreshToken: String
}

private struct RefreshResponse: Decodable {
    let accessJwt: String
    let refreshToken: String
}

private struct LogoutRequest: Encodable {
    let refreshToken: String
}

private struct ResendVerificationRequest: Encodable {
    let email: String
}

// MARK: - JWT Helper

/// Decodes the payload of a JWT WITHOUT verifying the signature. We only
/// use the decoded payload to route locally (extract user_id, check exp
/// for the refresh-buffer heuristic). The server is the only thing that
/// trusts the access token; if a tampered token slipped past us, the
/// server's verifier would reject it on the next request.
enum JWTDecoder {
    struct Payload: Decodable {
        let sub: String
        let exp: TimeInterval
        let email: String?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case sub, exp, email
            case displayName = "display_name"
        }
    }

    static func decode(_ token: String) -> Payload? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        let payloadSegment = String(segments[1])
        guard let data = base64URLDecode(payloadSegment) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(Payload.self, from: data)
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var base64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = base64.count % 4
        if pad > 0 {
            base64.append(String(repeating: "=", count: 4 - pad))
        }
        return Data(base64Encoded: base64)
    }
}

// MARK: - AuthenticationStore

@MainActor
@Observable
final class AuthenticationStore {
    private let api: APIClientProtocol
    private let tokenStore: TokenStore

    /// Buffer applied to JWT `exp` checks. If the token expires within this
    /// window, we proactively refresh rather than racing the server clock.
    private let refreshBufferSeconds: TimeInterval = 30

    var currentUser: AuthenticatedUser?
    var lastError: AuthError?

    /// Set `true` when the refresh chain dies (refresh token rejected with
    /// 401 in `refreshIfNeeded`). Distinguishes a *silently expired* session
    /// from a *user-initiated* logout: the expired-session path drops the dead
    /// tokens but must NOT wipe device-local session state (outbox/inbox) the
    /// way `logout()` does, so completed-but-unsynced workouts survive until
    /// the user signs back in (GH #143). Reset on a successful `login(...)`.
    private(set) var sessionExpired: Bool = false

    var isAuthenticated: Bool { currentUser != nil }

    /// Invoked on a successful login so queued outbox pushes drain immediately
    /// rather than waiting for the next foreground transition. Wired up by
    /// `LiftMarkApp` to call `OutboxPusherService.flushIfAuthenticated()`.
    /// Left nil in tests that don't exercise the flush.
    var onAuthenticated: (() -> Void)?

    init(api: APIClientProtocol, tokenStore: TokenStore) {
        self.api = api
        self.tokenStore = tokenStore
        rehydrateFromKeychain()
    }

    // MARK: - Login / Logout

    @discardableResult
    func login(
        email: String,
        password: String,
        deviceLabel: String = AuthenticationStore.defaultDeviceLabel
    ) async throws -> AuthenticatedUser {
        let req = LoginRequest(email: email, password: password, deviceLabel: deviceLabel)
        do {
            let response: LoginResponse = try await api.send(
                path: "/v1/auth/password/login",
                method: "POST",
                body: req,
                accessToken: nil
            )
            tokenStore.saveAccessToken(response.accessJwt)
            tokenStore.saveRefreshToken(response.refreshToken)
            currentUser = response.user
            lastError = nil
            // A fresh session clears any prior "needs re-auth" state and drains
            // any completed-but-unsynced workouts queued under the old session.
            sessionExpired = false
            onAuthenticated?()
            return response.user
        } catch let error as APIError {
            let mapped = Self.mapLoginError(error)
            lastError = mapped
            throw mapped
        } catch {
            let mapped = AuthError.unknown(error.localizedDescription)
            lastError = mapped
            throw mapped
        }
    }

    func logout() async {
        let refresh = tokenStore.loadRefreshToken()
        let access = tokenStore.loadAccessToken()

        // Best-effort server-side revoke. Ignore failures: the user wants
        // out, and we'll clear local state regardless.
        if let refresh, let access {
            do {
                try await api.sendEmpty(
                    path: "/v1/auth/logout",
                    method: "POST",
                    body: LogoutRequest(refreshToken: refresh),
                    accessToken: access
                )
            } catch {
                Logger.shared.warn(.network, "Logout server call failed (ignored): \(error)")
            }
        }

        tokenStore.clear()
        currentUser = nil
        lastError = nil
        // A deliberate sign-out is a clean state, not a lapsed one.
        sessionExpired = false

        // Inbox is treated as session-scoped device state — wipe on
        // sign-out. The server is the source of truth; signing back in
        // repopulates from the next poll.
        do {
            try InboxItemRepository().clear()
            NotificationCenter.default.post(
                name: InboxPollerService.inboxDidChange,
                object: nil
            )
        } catch {
            Logger.shared.warn(.database, "Failed to wipe inbox on logout: \(error)")
        }

        // Outbox pending queue is also session-scoped device state — pushes
        // queued under the old identity aren't transferable.
        do {
            try OutboxPendingQueueRepository().clear()
        } catch {
            Logger.shared.warn(.database, "Failed to wipe outbox queue on logout: \(error)")
        }
    }

    // MARK: - Email verification

    /// Asks the server to (re)send the verification email for `email`. The
    /// server returns 204 regardless of whether the address exists
    /// (anti-enumeration), so a success here doesn't imply the account is
    /// real — just that the request was accepted. Maps transport / 5xx
    /// failures to `AuthError` so the UI can surface them; client-side
    /// validation errors (400) are surfaced as `.unknown(message)`.
    func resendVerificationEmail(for email: String) async throws {
        do {
            try await api.sendEmpty(
                path: "/v1/auth/password/resend-verification",
                method: "POST",
                body: ResendVerificationRequest(email: email),
                accessToken: nil
            )
        } catch let error as APIError {
            switch error {
            case .transport:
                throw AuthError.network
            case .server(_, let message):
                throw AuthError.unknown(message)
            case .conflict(let message):
                throw AuthError.unknown(message)
            case .unauthorized, .forbidden, .notFound, .decoding:
                throw AuthError.unknown(nil)
            }
        }
    }

    // MARK: - Refresh

    /// Returns a fresh access token, refreshing via the server if the
    /// stored one is missing or close to expiry. Throws if there is no
    /// refresh token, or the refresh call fails.
    @discardableResult
    func refreshIfNeeded() async throws -> String {
        if let access = tokenStore.loadAccessToken(),
           let payload = JWTDecoder.decode(access),
           payload.exp > Date().timeIntervalSince1970 + refreshBufferSeconds {
            return access
        }

        guard let refresh = tokenStore.loadRefreshToken() else {
            throw AuthError.unknown("No refresh token")
        }

        do {
            let response: RefreshResponse = try await api.send(
                path: "/v1/auth/refresh",
                method: "POST",
                body: RefreshRequest(refreshToken: refresh),
                accessToken: nil
            )
            tokenStore.saveAccessToken(response.accessJwt)
            tokenStore.saveRefreshToken(response.refreshToken)
            return response.accessJwt
        } catch let error as APIError {
            if case .unauthorized = error {
                // Refresh chain is dead — the access/refresh pair is useless, so
                // drop the dead tokens and the in-memory user. CRITICAL: this is
                // an *expired session*, NOT a user-initiated logout. We must NOT
                // call `logout()` (which wipes the outbox/inbox), or completed-
                // but-unsynced workouts would be silently lost (GH #143). Surface
                // `sessionExpired` so the UI can prompt re-auth and the queued
                // pushes survive to drain after the next successful login.
                markSessionExpired()
                Logger.shared.warn(
                    .network,
                    "auth refresh failed (401) — session expired, prompting re-auth; outbox preserved"
                )
            }
            throw error
        }
    }

    /// Convenience for callers that make authenticated API calls. Wraps a
    /// block with `refreshIfNeeded` and retries once on 401 (the access
    /// token may have been revoked server-side between our last refresh
    /// and this call).
    func withAuthorizedRequest<T>(_ block: (String) async throws -> T) async throws -> T {
        let token = try await refreshIfNeeded()
        do {
            return try await block(token)
        } catch APIError.unauthorized {
            // Force-refresh by re-using the refresh token. If we still
            // have one, refreshIfNeeded will hit /v1/auth/refresh because
            // we don't have a known-good access token here — but the local
            // exp check would pass on our just-minted token. Bypass by
            // calling the refresh endpoint directly via the same path.
            guard let refresh = tokenStore.loadRefreshToken() else {
                markSessionExpired()
                throw APIError.unauthorized
            }
            do {
                let response: RefreshResponse = try await api.send(
                    path: "/v1/auth/refresh",
                    method: "POST",
                    body: RefreshRequest(refreshToken: refresh),
                    accessToken: nil
                )
                tokenStore.saveAccessToken(response.accessJwt)
                tokenStore.saveRefreshToken(response.refreshToken)
                return try await block(response.accessJwt)
            } catch APIError.unauthorized {
                // Refresh chain is dead even on the forced retry. Same handling
                // as `refreshIfNeeded`: expired session, not a logout. Preserve
                // device-local queues (GH #143).
                markSessionExpired()
                throw APIError.unauthorized
            }
        }
    }

    /// Drop the dead session tokens and flag re-auth needed WITHOUT wiping the
    /// outbox/inbox (that is `logout()`'s job, for deliberate sign-out only).
    private func markSessionExpired() {
        tokenStore.clear()
        currentUser = nil
        sessionExpired = true
    }

    // MARK: - Private

    private func rehydrateFromKeychain() {
        guard let access = tokenStore.loadAccessToken(),
              let payload = JWTDecoder.decode(access) else {
            return
        }

        // Best-effort user reconstitution from JWT claims. The login flow
        // populates `currentUser` with the full server-returned object;
        // here we only know what the JWT carries (likely just `sub`), so
        // downstream UI that needs `email`/`displayName` should fetch them
        // when the inbox poller / /v1/me lands.
        currentUser = AuthenticatedUser(
            userId: payload.sub,
            email: payload.email ?? "",
            displayName: payload.displayName ?? "",
            tier: .free,
            trialEndsAt: nil
        )

        if payload.exp <= Date().timeIntervalSince1970 + refreshBufferSeconds {
            Task { [weak self] in
                _ = try? await self?.refreshIfNeeded()
            }
        }
    }

    private static func mapLoginError(_ error: APIError) -> AuthError {
        switch error {
        case .unauthorized:
            return .invalidCredentials
        case .forbidden:
            return .emailNotVerified
        case .transport:
            return .network
        case .server(_, let message):
            return .unknown(message)
        case .conflict(let message):
            return .unknown(message)
        case .notFound:
            return .unknown(nil)
        case .decoding:
            return .unknown(nil)
        }
    }

    static var defaultDeviceLabel: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "Unknown device"
        #endif
    }
}
