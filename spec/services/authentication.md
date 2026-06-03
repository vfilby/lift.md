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

### Idempotent-rotation grace (benign-retry resilience)

Strict rotation treats *any* presentation of an already-rotated refresh token as
theft and revokes the entire token family (forcing a full re-login). In practice
this also nukes the session on **benign retries**: a lost response, a concurrent
double-spend, or the app being killed mid-refresh (e.g. during an OS update)
re-presents a just-rotated token within ~1 s, and the user is logged out for no
security reason. Confirmed in production.

The validator therefore applies a bounded **rotation grace** before treating a
re-presented, already-rotated token as reuse. When the presented row has BOTH
`revoked_at` and `replaced_by`, the server treats it as a **benign retry** —
re-issuing a fresh token pair instead of nuking the family — *iff ALL* of:

1. the successor row (`replaced_by`) still exists, AND
2. the successor is the **live tip**: it has no `replaced_by` and no
   `revoked_at` (i.e. the legitimate client never actually used it), AND
3. the re-presentation is within the grace window of the rotation:
   `now − revoked_at ≤ REFRESH_GRACE_MS` (default **60 000 ms**).

On a benign retry the server **rotates the successor** (minting a new
access JWT + refresh token exactly like the normal success path, `authn_age`
= `rotated`), sets the refresh cookie, audits `refresh_token_grace_reissue`,
and returns `200`. If that rotation loses a concurrent race
(`RotationConflictError`) it returns the same `401` "retry with the new token"
as the normal rotation-conflict path — it does **not** nuke.

If **any** condition fails — successor missing, successor already advanced or
revoked, or the re-presentation is outside the grace window — the server keeps
the strict behavior: revoke the whole family, audit
`refresh_token_reuse_detected`, return `401`. This preserves theft protection
for genuine old-token replays (an attacker replaying a stale token minutes/days
later, or after the legit client has moved past the successor).

The grace window is intentionally short (sub-minute). Client hardening persists
the new token synchronously, so a legitimate relaunch reads the *new* token and
never re-presents the old one; the grace only catches the sub-minute
lost-response / kill-during-refresh race. `REFRESH_GRACE_MS` may be overridden
via the `REFRESH_GRACE_MS` env var (read per-request) for testing.

## `GET /v1/me`

Returns the authenticated caller's own profile. Accepts **either** a session
JWT **or** a PAT (resource-endpoint convention — same combined auth middleware
the workout outbox/tokens resource routes use); no scope is required beyond
authentication.

**PII is shaped by auth modality (least privilege).** A PAT is a credential a
user may hand to a third-party agent (Claude Code, ChatGPT, scripts), so a
PAT-authenticated `/v1/me` must **not** expose the account email/name. The
non-PII subset (`tier`, `trial_ends_at`) is still returned so an agent can gate
on plan state.

Session JWT (the user inspecting their own account) — `200` JSON, **full**
profile:

```json
{
  "user_id": "…",
  "tier": "trial",
  "trial_ends_at": "…",
  "primary_email": "…",
  "display_name": "…"
}
```

PAT — `200` JSON, **non-PII subset** (no `primary_email`, no `display_name`):

```json
{
  "user_id": "…",
  "tier": "trial",
  "trial_ends_at": "…"
}
```

`401` if unauthenticated. `404` `{ "error": "User not found" }` if the
authenticated `user_id` has no user row (e.g. a deleted account whose token is
still cryptographically valid).

### Client use of `/v1/me`

The JWT carries only `sub` (and sometimes `email`/`display_name`); it does NOT
carry `tier` or `trial_ends_at`. Reconstituting `currentUser` from claims alone
therefore cannot know the real plan — historically the client hardcoded
`tier: .free`, so a *trial* user relaunching saw "Free plan / please sign in".
`/v1/me` is the authoritative source for the profile fields the JWT lacks.

`AuthenticationStore.fetchMe()` calls `GET /v1/me` through
`withAuthorizedRequest` (so it shares the single-flight refresh and the
refresh-on-401 retry), decodes the response into `AuthenticatedUser`, sets
`currentUser`, and persists it (see *Persisted profile* below). It is invoked:

- after a **successful launch restore** (`performRestore`), to replace the
  claims-reconstituted user with the real server profile; and
- after a **successful runtime refresh** when `currentUser` is missing or was
  reconstituted from claims (so a long-idle relaunch that refreshes still
  shows the real tier/email).

`fetchMe()` is **best-effort**: a transient `/v1/me` failure (network, 5xx,
edge block) is swallowed and logged. It never signs the user out and never
clears the persisted profile — the user keeps whatever profile was already
restored (persisted or claims-derived) and the next launch/refresh retries.

## Keychain storage

Tokens are persisted by `TokenStore` in the iOS Keychain
(`kSecClassGenericPassword`, service `app.liftmark.auth`).

| Property | Value |
|----------|-------|
| Access token account | `access_token` |
| Refresh token account | `refresh_token` |
| Accessibility | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |

### Persisted profile

The Keychain holds only the tokens. The last-known **profile**
(`email`, `display_name`, `tier`, `trial_ends_at`, plus `user_id`) is persisted
separately by `ProfileStore` in `UserDefaults` (key
`auth.lastKnownProfile`). The profile is non-secret display data — it is
not a credential — so it does not need Keychain protection, and storing it in
`UserDefaults` lets launch rehydration read it synchronously without a Keychain
round-trip.

- **On successful login** the full server-returned `AuthenticatedUser` is
  persisted verbatim.
- **On launch rehydration** `currentUser` is restored from the persisted
  profile *verbatim* (real tier, real email) when one exists. Only when no
  profile is persisted does the store fall back to reconstituting a partial
  user from the JWT claims (with `tier: .free` as the unknown-plan default).
  The hardcoded `.free` is thus a last-resort fallback, never applied over a
  known persisted tier.
- **On `logout()`** the persisted profile is cleared (deliberate sign-out is a
  clean slate).
- **On `markSessionExpired()`** the persisted profile is **kept**, so the
  re-auth UI can still show who was signed in while prompting for the password.

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
   (`exp > now + 30s`) → authenticated immediately from the persisted profile
   (or, absent one, the JWT claims); no network call.
3. **Access token expired (or within buffer) and a refresh token is present** →
   the store enters a *restoring* state and performs an **awaited** refresh
   before concluding anything about auth state:
   - Refresh **succeeds** → authenticated with the freshly-minted tokens.
     The rotated access + refresh tokens are persisted **atomically before the
     refresh call returns** (`TokenStore.saveTokens(access:refresh:)`), so a
     relaunch (or a kill mid-refresh) always reads the *new* refresh token and
     never re-presents the consumed one. After the refresh resolves, the store
     calls `fetchMe()` (best-effort) to replace the claims-reconstituted user
     with the real server profile.
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
