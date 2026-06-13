# beta.getlift.md cutover (GH #248 beta layer)

Status: IaC authored + statically verified (typecheck + `cdk synth` for all
phases). The cutover itself is a **credentialed, multi-phase deploy** — the
steps below are the runbook. Prod already serves canonically from `getlift.md`;
this brings **beta** off `beta.liftmark.app` onto `beta.getlift.md`.

Unblocks the `[iOS] E2E (beta)` workflow ([ios-e2e-beta.md](ios-e2e-beta.md)),
which targets `https://beta.getlift.md`.

## Why beta is not a one-line config add

Prod's canonical `getlift.md` is a `VANITY_DOMAINS` apex zone living in the prod
account, so its zone + wildcard cert come from `LmwfDnsFoundationStack` and the
prod main stack (same account) can attach the cert + write A-records directly.

Beta's canonical `beta.getlift.md` is a **subdomain delegated into that
prod-account `getlift.md` zone**, but beta's CloudFront distribution lives in the
**beta account** — and a CloudFront ACM cert must live in the same account
(us-east-1) as the distribution. So beta cannot reuse the prod-account
`*.getlift.md` wildcard. Instead, mirroring today's `beta.liftmark.app`:

- the **beta edge stack** owns a `beta.getlift.md` hosted zone **+ its own cert**
  in the beta account, and
- the prod `getlift.md` zone **delegates** to it via a hardcoded NS record.

This also creates a chicken-and-egg: a DNS-validated cert can't validate until
the zone is delegated, and the delegation NS aren't known until the zone exists.
Hence the phased `EnvConfig.betaCutoverPhase` (`config.ts`): `zone-only` ships
the zone (no cert) to mint stable NS; `live` adds the cert + canonical serving
once delegation is up. Same shape as the `VanityDomain.issueCert` deferral.

## What the IaC does per phase

| | edge stack (beta acct) | beta validator | prod `getlift.md` zone |
| --- | --- | --- | --- |
| **undefined** (today) | env zone+cert only | serves `beta.liftmark.app` | — |
| **'zone-only'** | + `beta.getlift.md` zone, NS output | unchanged (apex) | — |
| **'live'** | + `beta.getlift.md` cert | canonical dist for `beta.getlift.md`; `beta.liftmark.app` → 301/308 + AASA; `APP_BASE_URL`/CORS → `beta.getlift.md` | NS delegation (once `BETA_GETLIFT_MD_NS` filled) |

`APP_BASE_URL` (new Lambda env, `servingWebOrigin(env)`) makes the email-link
host follow the phase automatically; `password.ts` `appBaseUrl()` reads it and
falls back to the old `LMWF_ENV` hardcode if unset.

## Deploy runbook (operator)

This is **not a single automatic deploy.** Merging the current IaC is inert (no
cutover); the cutover is a phased sequence of config edits. The per-phase
`cdk deploy` IS automated by `validator-ci.yml` — every phase below is a normal
PR/merge to `main`, and because each touches `validator/**` the pipeline runs
`deploy-beta` (→ `LmwfBetaEdgeStack LmwfBetaValidatorStack`) then `deploy-prod`
(→ `LmwfProd*`). What the pipeline CANNOT do, and what makes this manual:
1. flip `betaCutoverPhase` (a code edit, 3 times: zone-only → live);
2. read the beta zone's 4 NS values and paste them into `BETA_GETLIFT_MD_NS`
   (Route 53 assigns NS only at zone-creation time — same hardcoded-NS pattern
   as the existing `beta.liftmark.app` delegation); and
3. wait for DNS propagation between delegation and 'live'.

The `cdk deploy` commands below are what the pipeline runs (and what to run for an
out-of-band manual deploy under the env's OIDC role). Stack ids:
`LmwfBetaEdgeStack`, `LmwfBetaValidatorStack`, `LmwfProdValidatorStack`.

**Phase 1 — zone-only (mint NS):**
1. Set `ENVS.beta.betaCutoverPhase = 'zone-only'` in `validator/cdk/config.ts`;
   merge. The pipeline's `deploy-beta` creates the `beta.getlift.md` zone.
2. (Or out-of-band: `cdk deploy LmwfBetaEdgeStack`.)
3. Read the `BetaCanonicalZoneNameServers` output — `deploy-beta` prints it via
   `cat outputs-beta.json`; for a manual deploy it's a CfnOutput.
4. Paste the 4 NS values into `BETA_GETLIFT_MD_NS` in `config.ts`.

**Phase 2 — delegate (publish NS in getlift.md):**
5. Merge the `BETA_GETLIFT_MD_NS` edit (still `betaCutoverPhase: 'zone-only'`).
   The pipeline's `deploy-prod` publishes the `beta` NS record in the
   `getlift.md` zone (the delegation gates on the NS array being non-empty, not
   on beta's phase). (Out-of-band: `cdk deploy LmwfProdValidatorStack`.) Wait
   for `dig NS beta.getlift.md` to resolve to the beta zone.

**Phase 3 — live (cert + serve):** flip `betaCutoverPhase` AND the pipeline's
own beta gate in ONE commit, because after the cutover `beta.liftmark.app/version`
308-redirects and `smoke-test-live.sh` does NOT follow redirects (no `-L`) — a
stale beta URL turns the post-deploy `smoke-beta`/`e2e-beta` gate red and blocks
`deploy-prod`. In the same commit:
6. Set `betaCutoverPhase = 'live'`.
7. In `.github/workflows/validator-ci.yml`, point the `smoke-beta`, `e2e-beta`,
   and Lambda warm-up URLs at `https://beta.getlift.md` (mirrors how
   `smoke-prod` targets `getlift.md`).
8. Merge → the pipeline deploys `LmwfBetaEdgeStack LmwfBetaValidatorStack`: the
   cert validates (zone now delegated), the canonical distribution comes up, and
   `beta.liftmark.app` flips to redirect-but-serve-AASA. `smoke-beta` then hits
   `beta.getlift.md/version` (200) and passes.
9. Manual smoke: `curl -I https://beta.getlift.md/version` (200), `curl -I
   https://beta.liftmark.app/account` (301 → beta.getlift.md), `curl
   https://beta.liftmark.app/.well-known/apple-app-site-association` (200, served
   locally).

**Phase 4 — run iOS e2e:**
10. The `[iOS] E2E (beta)` workflow already targets `beta.getlift.md` — run it via
    `workflow_dispatch` to confirm green.

## Follow-up app changes (post-'live', separate commit, NOT pipeline-gated)

The iOS app's hardcoded beta host is **intentionally not committed with the IaC** —
flipping it before `beta.getlift.md` serves would break beta for current TestFlight
testers. Once Phase 3 is live (and `beta.liftmark.app` redirects), ship in the next
app build:

- `mobile-apps/ios/.../APIClient.swift` beta base → `https://beta.getlift.md`.
- `mobile-apps/ios/.../LoginView.swift` `accountWebBase` beta → `beta.getlift.md`.

Old app builds keep working via the `beta.liftmark.app` 308/301 redirects; the
`APP_BASE_URL` env already flips email links automatically at deploy. (The iOS
e2e workflow does not depend on this flip — it injects the host via
`--api-base-url`.)

## Verification done here

- `bun x tsc --noEmit` (cdk + validator src): clean.
- `cdk synth` (via bun) for `undefined` / `zone-only` / `live`: all exit 0, each
  producing exactly the resources in the table above; the prod NS delegation
  emits only when `BETA_GETLIFT_MD_NS` is populated.
- Off-phase (committed) diff is behaviorally neutral: the only change is the new
  `APP_BASE_URL` env, whose value equals the prior hardcode.
- `cdk deploy` and live DNS resolution are credentialed and remain operator
  steps (no AWS access from CI authoring).
