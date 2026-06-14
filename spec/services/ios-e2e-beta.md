# iOS E2E against beta (Layer 3)

Status: spec for GH #137 Layer 3 — iOS UI tests that exercise the real
client↔server contract against the deployed **beta** backend.

## Why this exists

The 19 YAML UI scenarios under `e2e-spec/scenarios/` are **network-isolated by
design**: the app detects XCTest (`LiftMarkApp.isRunningTests`) and skips
session restore, inbox polling, outbox push, and CloudKit sync. Every fixture is
seeded locally. None of those scenarios touch auth, inbox, outbox, or sync, so
pointing them at a real backend changes nothing — there is no network call to
redirect.

Layer 3 is therefore a **new category of test**, not a URL flip: scenarios that
log in, push, and read against the live beta API and assert on the in-app UI
those calls drive. This document specifies the app hooks, the runner additions,
the scenarios, the test plan, and the CI workflow that make that possible.

Related: [validator-e2e.md](validator-e2e.md) (Layers 1 & 2 — backend
integration + Playwright smoke), [authentication.md](authentication.md),
[workout-inbox.md](workout-inbox.md), [workout-outbox.md](workout-outbox.md),
[feature-flags.md](feature-flags.md).

## App-side hooks

Two launch arguments, both test-only, gate the live-backend behaviour. Neither
changes any default (non-test) code path.

### `--live-backend`

`LiftMarkApp.isRunningTests` normally disables **all** network + sync startup
paths. `--live-backend` narrows that gate so the network paths under test run,
while **CloudKit sync stays off** (a beta UI run must not write to a tester's
iCloud).

| Startup path | default | tests (no flag) | tests + `--live-backend` |
| --- | --- | --- | --- |
| `CKSyncEngineManager.start()` | on | off | **off** (always off in tests) |
| `authStore.restoreSession()` | on | off | **on** |
| `inboxPoller.pollIfAuthenticated()` | on | off | **on** |
| `outboxPusher.flushIfAuthenticated()` | on | off | **on** |
| outbox enqueue on session-complete | on | off | **on** |

Mechanically: `networkPathsEnabled = !isRunningTests || isLiveBackend`. CloudKit
keeps using `!isRunningTests`; the four network paths switch to
`networkPathsEnabled`.

### `--api-base-url=<url>`

`APIClient` resolves its base URL in priority order: explicit `baseURL:`
constructor arg → **`--api-base-url=<url>` launch arg** → `LMWF_API_BASE_URL`
Info.plist → per-request `feature_flag.useBetaApi` (prod/beta default). The
launch arg is a hard override scoped to the test process; it does not touch the
production beta-mode toggle. The beta workflow passes
`--api-base-url=https://beta.getlift.md`.

Inbox polling additionally requires the `workoutInbox` feature flag, enabled per
run with the existing `--enable-flag=workoutInbox` plumbing
([feature-flags.md](feature-flags.md)).

### `--seed-session=<accessJWT>:<refreshToken>`

Writes a token pair straight to the Keychain at launch (after the `--reset-data`
wipe), so a scenario starts **already signed in** — combined with
`--live-backend`, `restoreSession()` rehydrates it. This lets the data-round-trip
scenarios (`beta-inbox`, `beta-outbox`) start signed in without re-driving the
login UI — that contract is covered once by `beta-login`, which taps the real
sheet a single time (the first-tap sheet-drop bug is fixed app-side, GH #279:
`LoginView` is presented from a stable host so it no longer needs a settle +
re-tap). The access JWT
is dot-delimited and the refresh token opaque — neither contains a colon — so the
first colon is the separator. `--reset-data` also clears the Keychain, so each
scenario starts from a known auth state.

> **Ordering invariant (GH #277):** the `--reset-data` reset — DB +
> UserDefaults + Keychain — runs at the very top of `LiftMarkApp.init`, **before
> `AuthenticationStore` is constructed**. That store's init synchronously
> rehydrates `currentUser` from the Keychain access token, so a Keychain clear
> placed *after* construction would leave a prior scenario's seeded session live
> in memory (the device renders signed-in despite an empty Keychain). This is
> exactly the BetaE2E `testBetaInbox` → `testBetaLogin` sequence — login launches
> `--reset-data` right after the seeded inbox scenario, and its first assertion
> (`account-sign-in` is present) is the regression guard for this ordering.

## Runner: environment-variable interpolation

Credentials are minted fresh per CI run (see below), so they cannot be baked into
static YAML. `ActionAdapter` therefore interpolates `${VAR}` tokens in
`replaceText` / `typeText` values from the test process environment
(`ProcessInfo.processInfo.environment`). An unset variable interpolates to the
empty string. A literal `${...}` is not expected in normal fixtures, so the
substitution is unconditional and runner-wide.

Example: `replaceText target: login-email, value: "${LMWF_E2E_EMAIL}"`.

## Scenarios

New scenarios live alongside the existing ones in `e2e-spec/scenarios/` and run
**only** under the `BetaE2E` test plan. They are excluded from `Smoke` and
`Full` (which have no backend and no `LMWF_E2E_*` credentials): `Full` lists the
three `testBeta*` methods in its `skippedTests`, so the nightly Full UI suite
never drives them. (Before that exclusion existed they ran credential-less in the
nightly and failed on `login-email` / empty `--seed-session` every run — GH #272.)

| Scenario | Auth | Exercises | Assertion surface |
| --- | --- | --- | --- |
| `beta-login` | real login UI | login → token persist → logout/revoke | `account-identity`, `account-sign-out`, `account-sign-in` (in-app) |
| `beta-inbox` | `--seed-session` | launch-time poll surfaces an API-pushed workout | `inbox-section` + the pushed workout name (in-app) |
| `beta-outbox` | `--seed-session` | complete workout → relaunch flush → outbox push | server-side `GET /v1/workouts/outbox` asserts in the workflow |

`beta-login` drives the **real** Settings → Sign in sheet. It launches with
`--reset-data`, which wipes the DB + UserDefaults + Keychain tokens, so it starts
from a clean *signed-out* state independent of test order (a seeded session from
another scenario can't bleed in). A single tap on `account-sign-in` presents
`LoginView` reliably — the first-tap sheet-drop instability is fixed app-side
(GH #279: the sheet is hosted from a stable parent, `SettingsView`), so the
scenario needs no settle delay or re-tap workaround. `beta-inbox` / `beta-outbox`
start signed in via `--seed-session` so they test the inbox/outbox contract
without re-driving the login UI:

- `beta-inbox` launches with `--enable-flag=workoutInbox`; `--live-backend`
  polls the inbox at launch, and the pushed "Beta Inbox Probe" must surface in
  the Workouts-tab inbox section.
- `beta-outbox` deliberately omits `workoutInbox` (the outbox is
  flag-independent, and the flag would render the home inbox card — the account's
  inbox holds the probe — pushing `button-import-workout` below the fold). It
  imports + completes a workout (the proven `workout-flow` steps), then
  **relaunches** to fire `flushIfAuthenticated` (the completed session + queue
  persist across the non-`--reset-data` relaunch). The server-side round-trip is
  asserted by a workflow step querying the outbox, because the app has no in-app
  outbox list view.

All rely on the runner's `waitFor*` polling for async settling (CloudFront/Lambda
latency).

## CI workflow — `[iOS] E2E (beta)`

`.github/workflows/swift-e2e-beta.yml`. Manual `workflow_dispatch` + weekly cron.
Reuses the beta account's existing `lmwf-beta-e2e-test-secret` and the
`/v1/__test__/*` backdoor (beta-only; the route returns 404 when `LMWF_ENV=prod`,
so it can never run against prod). No new secret, no persistent account.

Per run:

1. **Seed** — `POST /v1/__test__/seed-user` with a fresh random email + known
   password → returns `session_jwt`. For `beta-inbox`, also
   `POST /v1/workouts` with that token to plant a workout in the user's inbox.
2. **Warm** — pre-warm `$LMWF_E2E_BASE_URL/version` (mirrors validator
   `e2e-beta`) to dodge Lambda cold-start timeouts.
3. **Run** — `xcodebuild test -testPlan BetaE2E`, passing the seeded email,
   password, and base URL as env vars (the test plan forwards them to the app as
   launch-arg/`replaceText` interpolation values).
4. **Verify outbox** — `GET /v1/workouts/outbox` with the seeded token; assert
   the completed session landed.
5. **Teardown** — `POST /v1/__test__/delete-user-by-email` removes the run's
   rows (no TTL accumulation).

### Flake tolerance

Beta sits behind CloudFront/WAF, which intermittently 403s (the validator
`e2e-beta` job hit this). The app already has `edgeBlocked` retry semantics; the
test plan additionally sets a generous `UITEST_TIMEOUT_SCALE` so `waitFor*`
polling absorbs edge latency rather than failing fast.

### Host dependency (GH #248)

The workflow targets `https://beta.getlift.md`. That host goes live with the
beta DNS cutover ([password-manager.md](password-manager.md) / GH #248); until
then the workflow is red-on-run by design. The host is a workflow input/env var
(`LMWF_E2E_BASE_URL`, default `https://beta.getlift.md`) so it is a one-line flip
if the cutover slips.

## Tests / verification

- Swift compiles with the new hooks (`make build`).
- `BetaE2E.xctestplan` selects only the three beta scenarios; `Smoke` / `Full`
  are unchanged (no backend dependency leaks into the PR gate or nightly).
- The launch-arg gates are unit-asserted where practical; the scenarios
  themselves are the integration tests for this spec and run green once
  `beta.getlift.md` is live.
