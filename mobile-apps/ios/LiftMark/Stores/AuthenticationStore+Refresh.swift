import Foundation

// MARK: - Wire Types

private struct RefreshRequest: Encodable {
    let refreshToken: String
}

private struct RefreshResponse: Decodable {
    let accessJwt: String
    let refreshToken: String
}

// MARK: - Token Refresh

/// Token-refresh machinery, split from `AuthenticationStore.swift` for file
/// size: the single-flight `/v1/auth/refresh` round-trip, the authorized-
/// request wrapper with its refresh-on-401 retry, and the expired-session
/// state transition. See `spec/services/authentication.md`.
extension AuthenticationStore {
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
        let token = try await forceRefresh()
        // If the refresh succeeded but we have no in-memory user (e.g. a
        // runtime refresh after the session was cleared, with no persisted
        // profile to fall back on), repopulate from /v1/me. Awaited and
        // guarded on `currentUser == nil` so it's deterministic and fires at
        // most once; fetchMe re-enters `refreshIfNeeded` but the token is now
        // fresh, so it short-circuits above and never re-refreshes.
        if currentUser == nil {
            await fetchMe()
        }
        return token
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
            // Persist the rotated pair atomically (refresh-before-access)
            // BEFORE returning, so a relaunch or a kill mid-refresh always
            // reads the new refresh token and never re-presents the consumed
            // one. See spec (Refresh-token rotation / client hardening).
            tokenStore.saveTokens(access: response.accessJwt, refresh: response.refreshToken)
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
    /// The persisted profile is intentionally KEPT so the re-auth UI can still
    /// show who was signed in while prompting for the password.
    private func markSessionExpired() {
        tokenStore.clear()
        currentUser = nil
        sessionExpired = true
    }

    #if DEBUG
    /// Test-only seam: force the lapsed-session state (as if a refresh 401'd)
    /// so UI tests can exercise the auth-sync banner without driving a real
    /// network round-trip. Mirrors the `--seed-*` launch-arg pattern used by
    /// the migrator-bridge UI tests. Never compiled into release builds.
    func seedSessionExpiredForTesting() {
        sessionExpired = true
    }
    #endif
}
