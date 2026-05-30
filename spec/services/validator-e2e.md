# Validator E2E Test Suite

## Three-layer testing strategy (issue #137)

The validator's regression safety net is organised in three deliberately
distinct layers, each catching a different class of breakage. They are
additive, not redundant — a bug that slips one layer is the reason the
next layer exists.

| Layer | What it exercises | Transport | Where it lives | Status |
|-------|-------------------|-----------|----------------|--------|
| **1 — HTTP flow integration** | The full client journey through the real Hono app + DynamoDB Local + Mailpit, asserting the *protocol contract* composes end-to-end (each step consumes the exact token/id the previous step emitted). | In-process `app.request()` against DDB Local + Mailpit. | `validator/tests/flow.test.ts` | **Implemented** |
| **2 — Live smoke flow** | The same journey against a deployed beta stack over real HTTP (`smoke-flow-live.sh`), proving the deploy topology (Lambda + API GW + DDB + SES) wires up. | Real HTTPS against `beta.liftmark.app`. | `validator/scripts/smoke-flow-live.sh` (planned) | Deferred |
| **3 — iOS vs. beta** | The iOS client driving the live beta backend, proving the Swift client and the server agree on the wire format. | iOS UI/integration test against beta. | iOS test target (planned) | Deferred |

### Layer 1 — HTTP flow integration (`flow.test.ts`)

Layer 1 is a single Vitest suite that walks the entire happy path in
order, against the real Hono app and a live DynamoDB Local + Mailpit
stack (`make dev-up`):

```
signup → fetch verification email (Mailpit) → verify → login →
list tokens → mint PAT → push workout (PAT) → list inbox →
fetch inbox detail → ack inbox → push completed session (PAT) →
list outbox → fetch outbox detail → delete outbox → revoke PAT →
password reset (Mailpit) → re-login with new password
```

It is distinct from the per-route tests under `validator/tests/routes/`:
those prove each endpoint's contract *in isolation*, frequently
short-circuiting auth by minting a session JWT or PAT directly against
the repository layer. Layer 1 instead proves those contracts *compose* —
the access JWT returned by `/login` is the bearer `/v1/tokens` accepts;
the PAT plaintext returned by `/v1/tokens` is the bearer `/v1/workouts`
accepts; the `inbox_id`/`outbox_id` echoed back is the id the detail,
ack, and delete routes resolve. A field rename or status-code drift that
breaks the chain trips Layer 1 even when every isolated route test stays
green. That is the protocol-level breakage Layer 1 is meant to catch
before the deploy queue.

Endpoints exercised (the real, verified contract):

| Step | Method + path | Auth | Key assertion |
|------|---------------|------|---------------|
| signup | `POST /v1/auth/password/signup` | none | 201, `{ user_id, email }` |
| verify | `POST /v1/auth/password/verify` | verify JWT (from Mailpit) | 200, `{ verified: true, user_id }` |
| login | `POST /v1/auth/password/login` | none | 200, `{ access_jwt, refresh_token, user }` |
| list tokens | `GET /v1/tokens` | session JWT | 200, `{ tier, tokens[] }` |
| mint PAT | `POST /v1/tokens` | session JWT | 201, `plaintext` shown once |
| push workout | `POST /v1/workouts` | PAT | 201, `{ inbox_id, status: pending, summary }` |
| list inbox | `GET /v1/workouts` | PAT | item present, `source_token_id` matches PAT |
| inbox detail | `GET /v1/workouts/:id` | PAT | full parsed `workout` payload |
| ack inbox | `POST /v1/workouts/:id/ack` | PAT | 204, status → `ingested` |
| push session | `POST /v1/workouts/outbox` | PAT | 201, `{ outbox_id, session_name, dedup_hit: false }` |
| list outbox | `GET /v1/workouts/outbox` | PAT | row present with correct payload |
| outbox detail | `GET /v1/workouts/outbox/:id` | PAT | full session `payload` round-trips |
| delete outbox | `DELETE /v1/workouts/outbox/:id` | PAT | 204, subsequent GET 404 |
| revoke PAT | `DELETE /v1/tokens/:id` | session JWT | 204, `revoked_at` set |
| reset request | `POST /v1/auth/password/reset-request` | none | 204 (anti-enumeration) |
| reset | `POST /v1/auth/password/reset` | reset JWT (from Mailpit) | 200, old pw fails, new pw logs in |

Stripe/billing webhook is **not** in Layer 1: no webhook route exists in
the validator today (only a DDB GSI for subscription lookup). When a
`POST /v1/billing/webhook` route lands, add a Layer 1 step for it.

Running Layer 1:

```bash
cd validator
make dev-up                                   # DDB Local + Mailpit
DDB_ENDPOINT=http://localhost:8000 \
  SMTP_HOST=localhost SMTP_PORT=1025 SMTP_FROM=noreply@local.test \
  npx vitest run tests/flow.test.ts
```

The suite is gated on `DDB_ENDPOINT` + `SMTP_HOST` (the same `describe.skip`
pattern as every other live-integration test). Under plain `npm test` —
including the CI `validate (test)` job, which exports neither var — the
suite self-skips. It therefore adds **no** new CI job and **no** new
service dependency: it runs under the existing `npm test` whenever a
developer has the local stack up, and is a no-op everywhere else. It uses
a unique email per run and cleans up the outbox row + PAT it creates, so
it is robust against the sequential / shared-state Vitest config
(`fileParallelism: false`).

## Purpose

Browser-driven end-to-end tests covering all user-facing UI of the
LiftMark validator + website. The suite exists to make the validator
release pipeline safely auto-mergeable: a green E2E run pre-merge gates
the merge, and a green E2E run after the beta deploy gates promotion to
prod.

The suite is deliberately layered on top of the existing unit tests in
`validator/tests/`. Unit tests assert correctness of individual modules;
E2E asserts that those modules, the static website, and the deploy
topology compose into a working product from the browser's point of
view.

## Prod-gate coverage model

### What actually gates prod

The validator deploy pipeline (`.github/workflows/validator-ci.yml`) is a
linear chain, each stage a required predecessor of the next:

```
validate (Vitest: typecheck + npm test)
  → build
  → e2e-local   (Playwright vs local DDB+Mailpit stack)   ← gates prod
  → deploy-beta
  → smoke-beta
  → e2e-beta    (Playwright vs https://beta.liftmark.app)  ← gates prod
  → deploy-prod
```

`deploy-prod` needs `smoke-beta` AND `e2e-beta`; `deploy-beta` needs
`e2e-local`; `e2e-local`/`e2e-beta` both need `build`, which needs
`validate`. **Therefore Vitest, e2e-local, AND e2e-beta all hard-gate
prod.** A contract pinned by any one of them cannot regress into a prod
deploy. This is the load-bearing fact behind the division of labour below.

### Division of labour: Vitest owns logic, e2e owns topology

The Vitest route tests + `flow.test.ts` run the *exact same handler code*
that runs on Lambda — same conditional-expression semantics, in-process.
They are the authoritative owners of every **pure-handler contract** (auth
decisions, IDOR/tenancy isolation, scope enforcement, token rotation/reuse,
anti-enumeration, single-use reset, dedup, tier gates). e2e does **not**
re-assert these: duplicating a conditional that already runs identically
in-process buys zero topology signal and adds cost + flake.

e2e exists to catch the **topology delta** — the bytes/wiring that only
differ once the handler sits behind API Gateway + CloudFront + Lambda +
real SES: response *headers* (Set-Cookie attributes), *link hosts* built
from the deployed env, the *authorizer/scope middleware actually being
wired* in front of the route, and *real SES credentials resolving*. None of
those are visible to an in-process `app.request()`.

### Vitest-owned contracts (NOT duplicated in e2e)

| Contract | Owning Vitest test (file:line) |
|----------|-------------------------------|
| Cross-user IDOR — delete | `tests/routes/workouts.test.ts:722` ("user A cannot delete user B's inbox item (404)"); outbox: `tests/routes/workout_outbox.test.ts:299` |
| Cross-user IDOR — read/ack/list | `tests/routes/workouts.test.ts:673`, `:693`, `:748`; forged cursor `:654` |
| PAT scope 403 (write/ack/delete need `workouts:write`) | `tests/routes/workouts.test.ts:498`, `:517`, `:553`; outbox `:269`, `:322` |
| Missing/garbage bearer → 401 | `tests/routes/workouts.test.ts:486`, `:953` |
| Refresh rotation + reuse-revoke | `tests/routes/auth/refresh.test.ts:132`; concurrent rotation `:283`; absolute-expiry `:168` |
| Anti-enumeration uniform 401 (bad pw / unknown email / unverified) | `tests/routes/auth/password.test.ts:231`, `:570` |
| Reset single-use (stale-iat replay rejected) | `tests/routes/auth/password.test.ts:646` |
| Reset revokes every refresh token (H1) + `tokens_valid_after` cutoff | `tests/routes/auth/password.test.ts:597`; logout-all rotated-token reject `tests/routes/auth/refresh.test.ts:370` |
| Signup rolls back user+identity on email-send failure → 503, retry works | `tests/routes/auth/password.test.ts:247` |
| Outbox dedup on `client_session_id` | `tests/routes/workout_outbox.test.ts:132` |
| Tier gates (free 402 / trial 2-token 429 / pro unlimited) | `tests/routes/tokens.test.ts:170`, `:183`, `:199` |
| httpOnly refresh cookie SET by handler | `tests/routes/auth/password.test.ts:692`; refresh rotation cookie `tests/routes/auth/refresh.test.ts:419` |
| Protocol composes end-to-end (each step consumes prior step's token/id) | `tests/flow.test.ts` (Layer 1, see below) |

### e2e topology-delta tests (the four that earn an e2e slot)

| # | Topology delta it guards | Why Vitest can't see it | Where it lives | Mode |
|---|--------------------------|-------------------------|----------------|------|
| a | `lmwf_refresh` Set-Cookie carries `HttpOnly`, `Secure`, `SameSite=Strict`, `Path=/v1/auth` **over the wire** | In-process pins the `setCookie()` *call*; APIGW (multiValueHeaders) / CloudFront can strip/fold/rewrite the actual header bytes | `e2e/tests/auth-session.spec.ts` | both (esp. e2e-beta) |
| b | Verify/reset **email link host** == env `appBaseUrl` (beta→`beta.liftmark.app`) | The host comes from the Lambda's `LMWF_ENV`; a misconfigured env builds wrong-host links. Only readable where the email body is — Mailpit = local mode | `auth-signup-verify.spec.ts` (verify) + `auth-forgot-reset.spec.ts` (reset) | **local only** (guarded on `getMode()`) |
| c | A minted PAT authenticates a live `GET /v1/workouts`, then 401s after revoke | Proves the deployed APIGW authorizer + scope middleware are actually wired in front of the route and honour revocation over the wire — not just the in-process middleware logic | `e2e/tests/pat-live-auth.spec.ts` | both (esp. e2e-beta) |
| d | Real-SES signup → 201 (SES credentials resolve on the deployed stack) | The signup handler's email send is the last step before 201 and rolls back to 503 if it throws (`password.ts:282-325`); a 201 for the SES-verified address therefore proves SES creds resolve — invisible in-process where SMTP is Mailpit | `auth-signup-verify.spec.ts` (the existing signup POST, now explicitly asserted) | real send only in remote/beta |

### #137 incident-class → owning assertion

Issue #137 named three concrete failure classes. Each now has an owning
test that gates prod:

| #137 failure class | Owning assertion |
|--------------------|------------------|
| **SES placeholder credentials** (signup silently fails / 500s because the Lambda carried placeholder SES creds) | e2e test **(d)**: real `POST /v1/auth/password/signup` → 201 in remote/beta mode (`auth-signup-verify.spec.ts`). A 201 is only reachable if the real SES send succeeded (handler returns 503 on send failure, `password.ts:282-325`). Logic of the rollback itself is Vitest-pinned at `password.test.ts:247`. **Caveat below: this proves BETA SES, not PROD SES.** |
| **Reset-link misrouting** (reset email pointed at the wrong host) | e2e test **(b)**: link-host assertion in `auth-forgot-reset.spec.ts` (and the verify variant in `auth-signup-verify.spec.ts`), asserting `new URL(link).host === expectedEmailLinkHost()` and the reset link's path is `/account/reset`. Local-mode (Mailpit) — gates prod via e2e-local. |
| **Orphan signup rows** (user/identity rows left behind when the verification email failed to send) | Vitest `tests/routes/auth/password.test.ts:247` ("signup rolls back user + identity if email send fails (retry works)"): asserts 503 on send failure AND that a retry from the same address signs up cleanly (proves no orphan row blocking the dupe-check). Pure-handler logic — correctly owned by Vitest, not duplicated in e2e. |

#### Beta-vs-prod SES caveat (honest scope of (d))

e2e-beta runs against `beta.liftmark.app`, so test (d) proves **beta** SES
credentials resolve — NOT prod. The prod stack uses a separate SES identity
and IAM role; a prod-only SES-credential regression (the original #137
shape, if it recurred on the prod stack) would NOT be caught by (d). Closing
the prod variant requires a prod-safe smoke send (no test-secret backdoor on
prod), tracked under **#137 Layer 2** (`smoke-flow-live.sh`, deferred — see
the three-layer table above). Test (d) deliberately does not claim to close
the prod variant.

### Email-verification race — structurally prevented (no test)

There is no signup→verify race to test: the signup handler is strictly
sequential. `createUser` is awaited, then `createIdentity` is awaited, then
the verification email (carrying a token whose `sub` is the just-created
`identity_id`) is sent — all before the 201 returns (`password.ts:257-334`).
Verify then re-fetches the identity by id (`verifyToken` →
`getIdentityById`, `password.ts:351`). There is no window in which a verify
token references an identity that does not yet exist. This is an
architectural invariant, not a tested behaviour — documented here so a
future refactor that parallelises the writes knows it is load-bearing.

### Stripe / billing — KNOWN-UNTESTED, mandatory-on-arrival

No billing route exists in the validator today (only a DDB GSI for
subscription lookup). The following tests are **mandatory the moment a
`POST /v1/billing/webhook` (or equivalent) route lands** — a billing route
MUST NOT ship without them, each tied to its incident class:

| Required test (on arrival) | Incident class it guards | Owner |
|----------------------------|--------------------------|-------|
| Webhook signature verification: a body with a missing/invalid Stripe-Signature → 400, and a tampered body under a valid signature → 400 | Forged/replayed billing events granting entitlements | Vitest (pure-handler) |
| Entitlement-for-unknown-user: a webhook referencing a `customer`/`user_id` with no matching user → handled without 500 and without creating a phantom entitlement | Webhook race / orphaned entitlement granting access to a non-existent user | Vitest (pure-handler) |
| Live webhook POST reaches the deployed route + the signing secret resolves on the deployed stack (201/2xx for a correctly-signed test event) | Topology: the webhook route + Stripe signing-secret env are actually wired on Lambda (the billing analogue of the #137 SES-creds class) | e2e topology-delta |

Add a `flow.test.ts` Layer-1 step for the webhook at the same time (the spec
already flags this at the bottom of the Layer 1 endpoint table).

### Sharding decision: DO NOT SHARD

The e2e suite runs as a single Playwright job per mode (`fullyParallel`,
4 workers, chromium only). **Do not shard it across multiple CI jobs.**

Reasoning:
- The per-job fixed cost (`npm ci` + `playwright install --with-deps
  chromium` + OIDC role assumption + Lambda warm-up against beta) dominates
  the wall time of a small suite. Sharding multiplies that fixed cost by the
  shard count while only dividing the already-small test execution time.
- Sharding fans out N required checks on the PR (each shard is its own
  required status), increasing merge-coordination overhead for no bake-time
  value at the current size.
- The e2e-beta shards would all contend on one beta Lambda — sharding
  doesn't even buy real parallelism there; it just adds cold-start contention
  and flake surface.

**Trigger to revisit (measured, not guessed):** only when the *measured*
e2e-local wall time exceeds **~300s** OR the suite grows past **~50 tests**.
At that point, raise workers 4→6 FIRST (free, no fixed-cost multiplication);
shard 2-way only if that is insufficient. The 300s/50-test figures are
estimates to be replaced by a real measurement.

> Measured e2e-local wall time (this branch, single local run, chromium,
> Playwright auto-scaled to 6 workers on the dev machine): **13 tests, 2.0s**
> Playwright execution (`13 passed (2.0s)`). Even including the full
> `e2e-local.sh` setup (docker up + DDB bootstrap + astro build + validator
> boot) the run is a few seconds, far under the 300s trigger. Sharding would
> be pure overhead.

## Surface

The suite covers every user-facing page served by the website + every
backend endpoint the website reaches from the browser.

| Page                          | E2E spec                       | Critical assertions |
|-------------------------------|--------------------------------|---------------------|
| `/` (LMWF spec landing)       | `home.spec.ts`                 | Title renders, example markdown blocks visible, navigation links resolve. |
| `/spec`                       | `spec-page.spec.ts`            | Spec content renders, anchor links resolve, no console errors. |
| `/account/signup`             | `auth-signup-verify.spec.ts`   | Submit → 201 → verify link works → email shown as verified. Topology (b): verify-email link host == env appBaseUrl (local). Topology (d): real-SES signup 201 in remote mode. |
| `/account/login`              | `auth-login-logout.spec.ts`    | Bad creds error, good creds → `/account`. Sign out clears session. |
| (login response headers)      | `auth-session.spec.ts`         | Topology (a): `lmwf_refresh` Set-Cookie carries HttpOnly + Secure + SameSite=Strict + Path=/v1/auth over the wire. |
| `/account/forgot`             | `auth-forgot-reset.spec.ts`    | Submit always 204 (anti-enumeration). |
| `/account/reset?token=…`      | `auth-forgot-reset.spec.ts`    | Reset → new password works on login, old password fails. Topology (b): reset link host == env appBaseUrl + path `/account/reset` (local). |
| `/account/email-verified`     | `auth-signup-verify.spec.ts`   | Lands here after verify link click. |
| `/account` (dashboard)        | `account-pats.spec.ts`         | Create PAT, copy reveals once, list shows it, revoke removes it. |
| (PAT live API auth)           | `pat-live-auth.spec.ts`        | Topology (c): minted PAT authenticates `GET /v1/workouts`, then 401s after revoke (deployed authorizer + scope middleware wired). |
| `/account/outbox`             | `account-outbox.spec.ts`       | Seeded workout appears in list. |
| `/account/outbox/view?id=…`   | `account-outbox.spec.ts`       | Detail page renders LMWF, validates against `/validate`. |

Any new user-facing page added to the website MUST land with an entry in
this table and a corresponding `*.spec.ts`. The pre-merge E2E job is the
enforcement.

## Modes

The suite runs in three modes, selected by env var `LMWF_E2E_MODE`:

- `local` — used pre-merge in CI and on a developer's laptop. The
  validator runs on `localhost:3000` against DynamoDB Local + Mailpit
  (`make dev-up`). The website is built (`npm run build` under
  `website/`) and served from the same origin via a static-files
  middleware mounted on the validator (see "Local serving" below).
  Verification + reset tokens are extracted from Mailpit's REST API at
  `http://localhost:8025/api/v1/messages`.
- `remote` — used post-Beta-deploy. The suite runs against the public
  beta hostname (`https://beta.liftmark.app`). Email is real SES — the
  suite calls the test-only `/v1/__test__/mint-token` endpoint
  (see below) to obtain verification + reset tokens without inspecting
  email.
- `remote:prod` — reserved for ad-hoc verification against
  `https://liftmark.app`. Prod intentionally does NOT set the
  `E2E_TEST_SECRET` env var, so token-mint is unavailable — only the
  no-auth-required tests (`home.spec.ts`, `spec-page.spec.ts`) execute.
  Not wired into any pipeline; runnable locally for incident response.

## Test-only token endpoint

```
POST /v1/__test__/mint-token
X-Test-Secret: <shared secret>
{ "email": "...", "type": "email_verify" | "password_reset" }
→ 200 { "token": "<jwt>" }
```

Mints a fresh verify or reset JWT for the identity that owns the given
email. Used by the `remote` E2E mode to drive verification and reset
flows without touching SES.

Activation gate:
- The route is registered only when `process.env.E2E_TEST_SECRET` is a
  non-empty string AND `process.env.LMWF_ENV !== 'prod'`. Both checks
  fail closed: if either is wrong the route is not mounted at all
  (404, not 401), so a misconfigured prod deploy that accidentally
  carried the env var would still be safe.
- The secret is generated by CDK in the beta stack only
  (`Secrets Manager → lmwf-beta-e2e-test-secret`) and injected into the
  Lambda env. The prod stack does NOT create this secret and does NOT
  set the env var.
- Compares headers in constant time (`crypto.timingSafeEqual`) to keep
  timing-side-channel surface zero.

Unit tests cover: secret missing → 404; secret wrong → 404 (not 401, to
avoid disclosing existence); secret right + unknown email → 404; happy
path → 200 with a JWT that verifies under `JWT_SECRET`.

## Verified recipient for signup test

SES on beta is in sandbox mode: outbound mail is rejected for any
recipient that isn't explicitly verified. The signup test exercises the
real `POST /v1/auth/password/signup` → `sendVerificationEmail` path, so
the test recipient has to be verified or the endpoint 503s and the
test sees a `waitForResponse` timeout.

The remote E2E mode uses a single verified address
(`crusted_staid_0k@icloud.com`) for that one test. SES sandbox
verification is exact-match — plus-addressing variants count as
different addresses — so re-using one verified address is the only
viable option without graduating SES out of sandbox.

To keep that single address re-runnable across CI invocations, the
test calls a second test-only endpoint before signup:

```
POST /v1/__test__/delete-user-by-email
X-Test-Secret: <shared secret>
{ "email": "..." }
→ 200 { "deleted": true | false, "user_id"?: "..." }
```

Hard-deletes the user identified by the (`password`, email) identity,
along with every referencing row (identities, pat_tokens,
refresh_tokens, entitlements, workout_inbox, workout_outbox).
Idempotent — returns 200 with `deleted: false` when no such user
exists. Same activation gate as `/v1/__test__/mint-token`.

## Local serving

The validator gets one new affordance for E2E: when
`WEBSITE_DIST` is set to an absolute path, the Hono app mounts that
directory as static files at `/` BEFORE the API routes are matched
(but with API paths excluded from the static handler — the API routes
take precedence on conflict). In Lambda this env var is never set, so
the validator serves only API paths and CloudFront fronts the S3
website bucket.

This keeps E2E hitting a single origin (no CORS, no proxy config)
while the production topology stays untouched.

## Pipeline integration

`validator-ci.yml`:

- `e2e-local` — runs on `pull_request` AND `push`. Needs: `build`.
  Stands up DynamoDB Local + Mailpit as GHA service containers,
  bootstraps tables, starts the validator with `WEBSITE_DIST` pointing
  at the downloaded website bundle, runs Playwright. Required check on
  the PR. No deploy happens without this green.
- `e2e-beta` — runs on `push` only. Needs: `smoke-beta`. Executes the
  same Playwright spec set against `https://beta.liftmark.app` with
  `LMWF_E2E_MODE=remote` and the shared secret from GHA secrets. Blocks
  `deploy-prod`.

Static-only mode (`remote:prod`) is intentionally not wired into the
pipeline — it adds verification surface without bake-time value.

## Reliability budget

The suite targets:
- < 90 s wall time on `e2e-local` (parallel workers, chromium only).
- Zero flakes per 100 runs. A test that flakes twice in a row gets
  quarantined (skipped with explanatory `test.fixme`) rather than
  retried into the green — flakes hide real regressions and erode trust
  in the gate.
- Retries: 1 on CI (covers genuine network blips against beta CloudFront),
  0 locally (devs need to see flakes immediately, not work around them).

## Out of scope

- Multi-browser coverage (firefox/webkit). Chromium-only for v1; revisit
  if we see browser-specific UI bugs in the wild.
- Mobile viewport coverage. Account pages are responsive but not the
  primary surface; the iOS app is the mobile story.
- Performance budgets / Lighthouse checks. Separate concern from
  functional regression.
- Visual regression / screenshot diffing. Adds maintenance burden
  disproportionate to the bug class it catches at this stage.
