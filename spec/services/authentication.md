# Authentication Service Specification

## Purpose

Owns the user's authenticated session on iOS: login, logout, token storage,
and — critically — **launch-time session restoration**. The dominant UX
requirement is that a signed-in user stays signed in across app restarts,
updates, and long idle periods. Re-entering a password is only ever required
when the long-lived refresh token is genuinely expired or revoked.

Implemented by `AuthenticationStore` (`Stores/AuthenticationStore.swift`) over
`TokenStore` (`Services/TokenStore.swift`) and `APIClientProtocol`.

## Token lifecycle

| Token | Source | TTL | Purpose |
|-------|--------|-----|---------|
| Access JWT | `/v1/auth/password/login`, `/v1/auth/refresh` | **1 hour** (validator signs `'1h'`) | Bearer for every authed API call |
| Refresh token | same | **1 year** absolute (validator `REFRESH_LIFETIME_MS`) | Opaque, rotating; mints new access (and refresh) tokens |

The access token is intentionally short-lived. Because of this, **an expired
access token is the normal state on most app launches** and MUST NOT be treated
as "logged out." The refresh token is the durable proof of session and is the
only thing that decides whether the user is still signed in.

### Refresh-token rotation

`/v1/auth/refresh` rotates: every successful refresh returns a **new** refresh
token and invalidates the one presented. A consequence is that **two concurrent
refresh calls using the same stored refresh token will race** — the first
succeeds and rotates; the second presents a now-consumed token and gets `401`.
The launch path MUST therefore perform refresh as a **single-flight** operation;
it must never let a background refresh race the first authed API call.

## Keychain storage

Tokens are persisted by `TokenStore` in the iOS Keychain
(`kSecClassGenericPassword`, service `app.liftmark.auth`).

| Property | Value |
|----------|-------|
| Access token account | `access_token` |
| Refresh token account | `refresh_token` |
| Accessibility | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |

`AfterFirstUnlockThisDeviceOnly` is **required and must not be weakened**:

- *This-device-only* — tokens never migrate to a backup or another device, so
  signing in on one device cannot leak a session to another.
- *After-first-unlock* — tokens survive app updates and restarts. They are only
  briefly unavailable in the window between a device reboot and the first
  unlock; a launch in that window is treated as a *transient* read failure
  (see below), never as a logout.

## Launch rehydration contract

On construction, `AuthenticationStore` restores in-memory session state from the
Keychain. The contract:

1. **No tokens in Keychain** → logged out. Restoration is complete immediately.
2. **Access token present and not within the refresh buffer of expiry**
   (`exp > now + 30s`) → authenticated immediately from the JWT claims; no
   network call.
3. **Access token expired (or within buffer) and a refresh token is present** →
   the store enters a *restoring* state and performs an **awaited** refresh
   before concluding anything about auth state:
   - Refresh **succeeds** → authenticated with the freshly-minted tokens.
   - Refresh rejected with **401** (refresh token expired/revoked) → and only
     then → logged out, with `sessionExpired = true` (device-local
     outbox/inbox preserved; see GH #143).
   - Refresh fails for a **transient** reason (network down, Keychain not yet
     readable, 5xx) → the user stays **authenticated-but-offline**. The session
     is NOT cleared and re-login is NOT required. The user is reconstituted from
     the (expired) access-token claims, and the next authed request (or the next
     launch / foreground) retries the refresh.
4. The store never decides "logged out" off the back of an expired *access*
   token alone. Only a missing refresh token (case 1) or a 401-rejected refresh
   (case 3) forces re-login.

### Readiness signal

`AuthenticationStore` exposes `isRestoring` (and the derived `isReady`) so the
UI and background services can wait for restoration to finish:

- While `isRestoring == true`, the root view shows a brief neutral loading state
  rather than flashing the login screen or the authenticated UI.
- Launch-time authed work (inbox poll, outbox flush) is gated on `isReady` so it
  does not fire a premature request against an expired token and trip a spurious
  `401` / refresh race.

`restoreSession()` is idempotent and single-flight: concurrent or repeated calls
await the same in-flight restoration rather than issuing a second refresh.

## Runtime refresh (`withAuthorizedRequest`)

Independent of launch, authed callers wrap requests in `withAuthorizedRequest`,
which calls `refreshIfNeeded()` first and retries once on a `401`. `401` on the
forced retry → `sessionExpired`. This path is unchanged by the launch contract;
both share the single-flight refresh so a launch restoration and a first authed
call cannot double-spend the refresh token.

## Logout vs. session expiry

- **`logout()`** — deliberate user sign-out. Best-effort server revoke, clears
  tokens, and wipes session-scoped device state (inbox + outbox queues).
- **Session expiry** (`markSessionExpired()`) — refresh chain rejected with
  `401`. Clears the dead tokens and the in-memory user, sets
  `sessionExpired = true`, but **preserves** the outbox/inbox so completed-but-
  unsynced workouts survive until the user signs back in (GH #143).

A transient network failure is **neither** of these — it leaves the session
intact.

## Error mapping (login)

| API result | `AuthError` |
|------------|-------------|
| 401 | `.invalidCredentials` |
| 403 | `.emailNotVerified` |
| transport | `.network` |
| 5xx / conflict | `.unknown(message)` |
