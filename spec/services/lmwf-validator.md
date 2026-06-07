# LMWF Validator Service

## Purpose
HTTP validation service for the LiftMark Workout Format (LMWF). Accepts markdown text and returns structured validation results. Deployed as an AWS Lambda behind API Gateway.

## Endpoints
- `POST /validate` — see [Request](#request) / [Response](#response)
- `GET /version` — see [Version](#version)

## Endpoint
`POST /validate`

## Request
Accepts either JSON or raw markdown:

**JSON (Content-Type: application/json):**
```json
{
  "markdown": "# Push Day\n@units: lbs\n\n## Bench Press\n- 225 x 5\n"
}
```

**Raw (Content-Type: text/markdown):**
```
# Push Day
@units: lbs

## Bench Press
- 225 x 5
```

## Response

### Success (200)
```json
{
  "success": true,
  "summary": {
    "workoutName": "Push Day",
    "defaultWeightUnit": "lbs",
    "tags": [],
    "exerciseCount": 1,
    "totalSetCount": 1,
    "exercises": [
      {
        "name": "Bench Press",
        "equipmentType": null,
        "notes": null,
        "setCount": 1,
        "groupType": null,
        "parentExercise": null
      }
    ]
  },
  "errors": [],
  "warnings": []
}
```

### Validation Failure (200)
```json
{
  "success": false,
  "summary": null,
  "errors": [
    {
      "line": 5,
      "message": "Exercise \"Bench Press\" has no sets",
      "code": "NO_SETS"
    }
  ],
  "warnings": []
}
```

### Bad Request (400)
Returned when the request is structurally malformed (missing body, invalid JSON,
non-string markdown field, or empty/whitespace-only markdown). Uses the same
response shape as `Validation Failure (200)` so callers can rely on a single
parse path. The `errors` array holds the bad-request reason as plain text;
`success` is always `false` and `summary` is always `null`.

```json
{
  "success": false,
  "summary": null,
  "errors": ["Missing or empty markdown field"],
  "warnings": []
}
```

Possible `errors[0]` values:
- `"Missing request body"` — JSON content-type with no body at all
- `"Invalid JSON body"` — JSON content-type with malformed JSON
- `"markdown field must be a string"` — JSON body where `markdown` is the wrong type
- `"Missing or empty markdown field"` — markdown is missing, empty, or whitespace-only

### Payload Too Large (413)
Same shape as `Bad Request (400)`. Triggered when input exceeds 1MB, 50,000 lines,
500 exercises, or 10,000 total sets.

### Response Headers
Every `/validate` response carries `X-Validator-Version: <commit-sha>` identifying
the deployed Lambda code. Useful for confirming which build a client is hitting
without an extra round trip to `/version`.

## Version
`GET /version`

Returns deploy metadata. Used by smoke tests to assert a deploy actually landed
and by humans/clients to confirm which build is live.

```json
{
  "commit": "520e85003a2b…",
  "builtAt": "2026-05-24T13:37:00Z",
  "env": "beta"
}
```

- `commit` — full git SHA of the deploy source (40 chars), or `"unknown"` if the
  Lambda was deployed without a `buildCommit` CDK context value.
- `builtAt` — ISO 8601 UTC timestamp of when CDK packaged the deploy.
- `env` — `"beta"` or `"prod"`.

Always served with `Cache-Control: no-store` to bypass any CloudFront caching.
Returns 200 even when `commit` is `"unknown"`; staleness is something callers
detect by comparing values, not an error condition.

## Error/Warning Codes
Matches the iOS parser error and warning codes exactly:
- `NO_WORKOUT_HEADER` — No valid workout header found
- `NO_SETS` — Exercise has no sets
- `INVALID_SET_FORMAT` — Set line could not be parsed
- `NEGATIVE_WEIGHT` — Weight value is negative
- `INVALID_REPS_TIME` — Reps/time value is not positive
- `INVALID_RPE` — RPE outside 1-10 range
- `INVALID_UNITS` — Unrecognized @units value
- `HIGH_REPS` (warning) — Rep count > 100
- `SHORT_REST` (warning) — Rest < 10 seconds
- `LONG_REST` (warning) — Rest > 600 seconds

## Test Parity
The TypeScript parser MUST pass the same test cases as the native iOS parser (`MarkdownParserTests.swift`). Both parsers must produce identical results for identical inputs. Any new test case added to either parser must be added to both.

## Domains & Hosting Topology

The service is fronted by CloudFront. As of the canonical-domain migration
(GH #248), **`getlift.md` is canonical and serves everything** — site, API, LMWF
spec, export schemas, and AASA — entirely from the apex (no functional
subdomains). The whole `liftmark.app` family is now **redirect-only**, kept alive
solely so old links and shipped-app deep-links don't break. Beta mirrors this:
**`beta.getlift.md`** is the all-in-one beta environment, and `beta.liftmark.app`
redirects to it.

> **Migration status (GH #248):** the **prod** cutover (table below) is
> implemented — `getlift.md` serves everything; `liftmark.app` / `liftmd.app` /
> `workoutformat.liftmark.app` are redirect-only. The **beta** half
> (`beta.getlift.md`) is a tracked follow-up: it needs a cross-account DNS
> delegation deploy (create the beta-account zone, read its NS, delegate from
> the `getlift.md` zone, issue the cert), so until that lands beta still serves
> from `beta.liftmark.app` and the e2e pipeline runs against it. The table and
> the `beta.getlift.md` rows describe the target end state.

The **one** exception to "liftmark.app redirects everything" is the AASA path:
Apple does NOT follow redirects when fetching `apple-app-site-association`, and
already-installed apps are pinned to `liftmark.app`, so `liftmark.app` MUST keep
serving its AASA (200) for those installs to retain Universal Links + password
autofill until they update. It is the sole thing still *served* from
`liftmark.app`.

| Domain | Role | Site pages (`/`, `/install.sh`, …) | API paths (`/validate`, `/v1/*`, `/version`) | `/.well-known/apple-app-site-association` |
|---|---|---|---|---|
| **`getlift.md`** | **Canonical (prod)** — serves everything | **Serves** (own CloudFront distribution; S3 `website/dist` + API proxy behaviors + spec/schemas) | **Serves** | **Serves** (200, `application/json`, no redirect) |
| **`liftmark.app`** | Legacy → redirect-only (AASA excepted) | **301 → `getlift.md`** (same path) | **308 → `getlift.md`** (method + body preserved; shipped apps replay then reauth) | **Serves** (200 — sole exception; Apple does NOT follow AASA redirects, old installs pinned here) |
| **`workoutformat.liftmark.app`** | Legacy spec alias → redirect | **301 → `getlift.md`** (path-preserving: `/spec.md` → `getlift.md/spec.md`) | 308 → `getlift.md` | 301 → `getlift.md` (no shipped app pins this host's AASA) |
| **`liftmd.app`** | Legacy short domain | **301 → `getlift.md`** (everything) | 301 → `getlift.md` | 301 → `getlift.md` |
| **`beta.getlift.md`** | **Beta (all-in-one)** | Serves | Serves | Serves |
| **`beta.liftmark.app`** | Legacy beta → redirect | **301 → `beta.getlift.md`** | **308 → `beta.getlift.md`** | 301 → `beta.getlift.md` (test installs only; reauth acceptable) |

### CloudFront WAF (body-size policy)

The CloudFront-scoped WAFv2 web ACL (`lmwf-<env>-cloudfront`, defined in
`validator/cdk/edge-stack.ts`) runs AWS managed rule groups (CommonRuleSet,
KnownBadInputs, IpReputation) plus per-IP rate limits. Two settings exist
specifically so legitimate large request bodies are **not blocked at the edge**:

- **`SizeRestrictions_BODY` is overridden to `Count`** in the CommonRuleSet.
  Its default action blocks any body > 8 KB, which silently 403s a completed
  workout push (`POST /v1/workouts/outbox`) — a real session is ~19 KB+ — at
  CloudFront, *before* the request reaches API Gateway (so it never appears in
  the API access log, and the iOS client used to drop it as a "forbidden"
  error). The route enforces its own 1 MB body cap server-side and the
  rate-based rules still bound abuse, so demoting this rule to Count is safe.
- **`associationConfig.requestBody.CLOUDFRONT.defaultSizeInspectionLimit = KB_64`**
  so the remaining managed rules (SQLi/XSS/etc.) still inspect realistic
  payloads instead of letting large bodies past uninspected.

The matching client guard (treat an edge/WAF 403 as transient, never drop the
queued workout) is specified in [workout-outbox.md](workout-outbox.md).

The CFN execution role for the **us-east-1** edge stack therefore needs WAFv2
write permissions (`wafv2:Get/Create/Update/DeleteWebACL`, tag + logging-config
actions); these live in `LmwfCdkDeployPolicyExtra` (`deploy-policy-extra.json`),
attached to **both** region exec roles by `iam/refresh-deploy-policy.sh`.

Redirect semantics:

- **Site pages** (GET) redirect **301 (permanent)** to the canonical host, path
  preserved.
- **API paths** (`/validate`, `/v1/*`, `/version`) redirect **308 (permanent,
  method + body preserved)** rather than 301/302 — a 301/302 on a `POST` lets the
  client downgrade to `GET` and drop the body, which would break a shipped app's
  workout push. With 308 the shipped iOS app replays the exact request to
  `getlift.md`; because session/refresh cookies are scoped per-host it then
  reauthenticates against the canonical host (accepted — see GH #248).
- **AASA** (`/.well-known/apple-app-site-association`) is the **one path NOT
  redirected on `liftmark.app`**: Apple does not follow redirects for it, so it
  keeps serving 200 for already-installed apps pinned to `liftmark.app`. Every
  other `liftmark.app` path — and *all* paths on `liftmd.app` / `beta.liftmark.app`
  / `workoutformat.liftmark.app` — redirects.
- Per-path redirect/exclusion is implemented as a CloudFront Function (not a
  second `BucketDeployment` / Lambda@Edge — see the BucketDeployment layer-limit
  constraint in the AASA section of `password-manager.md`).

## Deployment
- Runtime: Node.js 22 on AWS Lambda (arm64)
- Infrastructure: AWS CDK (`validator/cdk/`) — edge stack (us-east-1: hosted zone, ACM cert, CLOUDFRONT-scoped WAFv2 web ACL) + main stack (Lambda, HTTP API, DynamoDB, CloudFront, DNS, alarms). In prod the canonical `getlift.md` distribution serves the site + API + spec + schemas, while the `liftmark.app` / `liftmd.app` / `workoutformat.liftmark.app` distributions handle the redirect topology above (liftmark.app's distribution additionally serves the AASA exception). Beta serves everything from `beta.getlift.md`, with `beta.liftmark.app` redirecting to it.
- The public `/validate` and `/version` endpoints require no authentication; the `/v1/*` auth/PAT/workout routes are bearer-authenticated (session JWT or PAT)

### Edge security controls
- **CORS**: explicit origin allowlist (no wildcard), derived per-env via `corsAllowedOrigins()` in `validator/cdk/config.ts` — the canonical serving origin (prod: `getlift.md`; beta: `beta.getlift.md`) and (beta only) the local Astro dev origin. The legacy `liftmark.app` hosts are *not* in the allowlist: browser requests there get redirected (308/301) to the canonical origin before any XHR, so they never originate a cross-origin request from a legacy host. `allowCredentials: true` so the SameSite refresh-token cookie flow works.
- **Security response headers**: a CloudFront `ResponseHeadersPolicy` is attached to every behavior — strict CSP (`default-src 'self'`, no `unsafe-inline`; inline site scripts load via CSP hashes), HSTS (1y, includeSubDomains, preload), `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` + `frame-ancestors 'none'`, `Referrer-Policy: strict-origin-when-cross-origin`.
- **WAF**: CLOUDFRONT-scoped WAFv2 web ACL (in the us-east-1 edge stack, wired to the distribution via `crossRegionReferences`) — AWS managed rule groups (Common, KnownBadInputs, AmazonIpReputationList), a broad per-IP rate limit, and a stricter per-IP rate-based rule scoped to `/v1/auth/*` to blunt credential stuffing. Per-account application lockout is a deferred follow-up (needs a DDB counter table).
- **Access logging**: the HTTP API stage writes a JSON access log (source IP, route, status, auth subject/principal) to CloudWatch Logs.
