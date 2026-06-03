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

    /// True while launch-time session restoration is in flight. The root view
    /// shows a neutral loading state (rather than flashing the login screen)
    /// until this clears, and launch-time authed work is gated on `isReady`.
    /// See `spec/services/authentication.md` (Launch rehydration contract).
    private(set) var isRestoring: Bool = false

    /// Inverse of `isRestoring`: restoration has settled and `currentUser` /
    /// `sessionExpired` reflect the durable session state.
    var isReady: Bool { !isRestoring }

    /// Single-flight handle for the refresh round-trip. Because the validator
    /// *rotates* refresh tokens, two concurrent refreshes would race — the
    /// second presents an already-consumed token and gets 401, falsely
    /// expiring the session. Both the launch restoration and on-demand
    /// `refreshIfNeeded()` funnel through this so at most one refresh is ever
    /// in flight against a given stored refresh token.
    private var inFlightRefresh: Task<String, Error>?

    /// Single-flight handle for the launch restoration. Idempotent: repeated
    /// or concurrent `restoreSession()` calls await the same work.
    private var restoreTask: Task<Void, Never>?

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

    // MARK: - Launch restoration

    /// Awaits launch-time session restoration. Idempotent and single-flight:
    /// the work is kicked off synchronously in `init` (so it's already running
    /// by the time the first view appears), and callers `await` the same task.
    ///
    /// The contract (see `spec/services/authentication.md`): the store never
    /// concludes "logged out" off an expired *access* token alone. If a refresh
    /// token exists and the access token is stale, it performs an **awaited**
    /// refresh first. Only a missing refresh token or a 401-rejected refresh
    /// forces re-login; a transient network failure leaves the user
    /// authenticated-but-offline.
    func restoreSession() async {
        await restoreTask?.value
    }

    // MARK: - Login / Logout

    @discardableResult
    func login(
        email: String,
        password: String,
        deviceLabel: String = AuthenticationStore.defaultDeviceLabel
    ) async throws -> AuthenticatedUser {
        // A fresh credential supersedes any launch restoration still in flight.
        // Cancel it so a late refresh can't clobber the new tokens or flip
        // sessionExpired after we've signed in.
        restoreTask?.cancel()
        restoreTask = nil
        isRestoring = false

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
        // Deliberate sign-out supersedes any in-flight launch restoration.
        restoreTask?.cancel()
        restoreTask = nil
        isRestoring = false

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
            case .edgeBlocked:
                // Blocked at the edge (CloudFront/WAF) — treat as a network
                // failure so the UI can offer a retry.
                throw AuthError.network
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

        // Access token missing or stale → refresh. The local exp check above
        // already short-circuited the fresh-token case.
        return try await forceRefresh()
    }

    /// Performs `/v1/auth/refresh`, coalescing concurrent callers onto a single
    /// round-trip. The refresh token rotates server-side, so a second caller
    /// presenting the same stored token would get a 401 and falsely expire the
    /// session — hence the single-flight `inFlightRefresh` handle. Skips the
    /// local `exp` check, so `withAuthorizedRequest` can force a refresh after a
    /// server-side 401 even though its just-minted token still looks valid.
    @discardableResult
    private func forceRefresh() async throws -> String {
        if let inFlight = inFlightRefresh {
            return try await inFlight.value
        }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw AuthError.unknown("Store deallocated") }
            return try await self.performRefresh()
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    /// The actual `/v1/auth/refresh` round-trip. Always funneled through
    /// `inFlightRefresh` so it can't run concurrently with itself.
    private func performRefresh() async throws -> String {
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
            // A successful refresh proves the session is alive: clear any stale
            // expired flag so the UI leaves the re-auth state.
            sessionExpired = false
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
            // Transient/5xx: leave the session intact. The caller (launch
            // restore or withAuthorizedRequest) decides whether to retry; we
            // never clear tokens here for a non-401 failure.
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
            // The access token was revoked server-side between our refresh and
            // this call. Force a fresh refresh (the local exp check would pass
            // on our just-minted token, so bypass it) and retry the block once.
            // `forceRefresh` coalesces through the same single-flight handle as
            // `refreshIfNeeded`, so it can't double-spend the rotating refresh
            // token against a concurrent caller. A 401 here means the refresh
            // chain is dead → expired session (not a logout): `forceRefresh`
            // already called `markSessionExpired`, preserving device queues
            // (GH #143).
            guard tokenStore.loadRefreshToken() != nil else {
                markSessionExpired()
                throw APIError.unauthorized
            }
            let fresh = try await forceRefresh()
            return try await block(fresh)
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

    /// Synchronous half of launch restoration, run from `init`. Reconstitutes
    /// the in-memory user from the (possibly expired) access-token claims so the
    /// UI doesn't flash logged-out, and — when a refresh is needed — sets
    /// `isRestoring` and kicks off the *awaited* refresh as a single-flight
    /// `restoreTask`. The async resolution lives in `performRestore()`.
    private func rehydrateFromKeychain() {
        let access = tokenStore.loadAccessToken()
        let payload = access.flatMap(JWTDecoder.decode)
        let hasRefreshToken = tokenStore.loadRefreshToken() != nil

        // No access token at all. If we also have no refresh token, we're
        // genuinely logged out and restoration is already complete. If only the
        // access token is missing (e.g. a partial/legacy keychain state) but a
        // refresh token survives, attempt to restore from it rather than
        // forcing re-login.
        guard let payload else {
            if hasRefreshToken {
                beginRestore()
            }
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

        // Access token still fresh → nothing to await; we're done.
        guard payload.exp <= Date().timeIntervalSince1970 + refreshBufferSeconds else {
            return
        }

        // Access token is stale. We must NOT conclude anything about auth state
        // until an awaited refresh resolves. Without a refresh token there's
        // nothing to await — the stale access token is all we have, so stay
        // authenticated-but-offline rather than forcing re-login.
        if hasRefreshToken {
            beginRestore()
        }
    }

    /// Enter the restoring state and start the single-flight restore task.
    private func beginRestore() {
        isRestoring = true
        restoreTask = Task { [weak self] in
            await self?.performRestore()
        }
    }

    /// Awaited launch refresh. Outcomes (see spec):
    /// - success → authenticated with fresh tokens (handled in `refreshIfNeeded`)
    /// - 401 → `markSessionExpired()` already ran in `refreshIfNeeded`; logged out
    /// - transient (network/5xx) → leave the session intact (offline); the
    ///   reconstituted-from-claims user stays signed in and we retry later.
    private func performRestore() async {
        defer { isRestoring = false }
        do {
            _ = try await refreshIfNeeded()
        } catch {
            // Swallow: refreshIfNeeded has already applied the only state
            // change that matters here (markSessionExpired on 401). A transient
            // failure is intentionally a no-op — we stay authenticated-offline.
            Logger.shared.warn(.network, "Launch session restore did not complete: \(error)")
        }
    }

    private static func mapLoginError(_ error: APIError) -> AuthError {
        switch error {
        case .unauthorized:
            return .invalidCredentials
        case .forbidden:
            return .emailNotVerified
        case .transport, .edgeBlocked:
            // .edgeBlocked is an edge/WAF block that never reached the API —
            // surface it as a network failure so the user can retry.
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
