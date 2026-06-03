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

The service is fronted by CloudFront. As of the canonical-domain change, the
public website lives at **`getlift.md`**; `liftmark.app` and `liftmd.app` are
retained for the iOS app's API + password-autofill needs and for redirecting
legacy traffic to the canonical site. This is **prod-only** — beta is unaffected
and continues to serve everything (site + API) from `beta.liftmark.app`.

| Domain | Role | Site pages (`/`, `/install.sh`, …) | API paths (`/validate`, `/v1/*`, `/version`) | `/.well-known/apple-app-site-association` |
|---|---|---|---|---|
| **`getlift.md`** | Canonical site | **Serves** (own CloudFront distribution; same S3 `website/dist` content + same API proxy behaviors) | **Serves** | Serves (200, `application/json`, no redirect) |
| **`liftmark.app`** | App API + AASA host; legacy site → redirect | **302 → `getlift.md`** (same path) | **Serves** (unchanged — iOS app calls these) | **Serves** (unchanged — Apple does NOT follow redirects for AASA, so it must NOT be redirected) |
| **`workoutformat.liftmark.app`** | Legacy alias of `liftmark.app` | **302 → `getlift.md`** | Serves | Serves |
| **`liftmd.app`** | Legacy short domain | **302 → `getlift.md`** (everything) | 302 → `getlift.md` | 302 → `getlift.md` |
| **`beta.liftmark.app`** | Beta (all-in-one) | Serves | Serves | Serves |

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

- Redirects are **302 (temporary)** initially; they are to be promoted to **301
  (permanent)** once the canonical move is proven stable.
- On `liftmark.app` / `workoutformat.liftmark.app` the redirect applies **only**
  to site pages. The API paths (`/validate`, `/v1/*`, `/version`) and the AASA
  path (`/.well-known/apple-app-site-association`) are explicitly excluded so the
  shipped iOS app's API calls and password autofill keep working without a new
  build. Per-path redirect/exclusion is implemented as a CloudFront Function (not
  a second `BucketDeployment` / Lambda@Edge — see the BucketDeployment layer-limit
  constraint in the AASA section of `password-manager.md`).
- `liftmd.app` redirects **all** paths (it never hosted the app's API or AASA).

## Deployment
- Runtime: Node.js 22 on AWS Lambda (arm64)
- Infrastructure: AWS CDK (`validator/cdk/`) — edge stack (us-east-1: hosted zone, ACM cert, CLOUDFRONT-scoped WAFv2 web ACL) + main stack (Lambda, HTTP API, DynamoDB, CloudFront, DNS, alarms). In prod the canonical `getlift.md` distribution serves the site + API, while the `liftmark.app` / `liftmd.app` distributions handle the redirect topology above.
- The public `/validate` and `/version` endpoints require no authentication; the `/v1/*` auth/PAT/workout routes are bearer-authenticated (session JWT or PAT)

### Edge security controls
- **CORS**: explicit origin allowlist (no wildcard), derived per-env via `corsAllowedOrigins()` in `validator/cdk/config.ts` — the env site domain (prod: the canonical `getlift.md`, plus `liftmark.app` and its legacy `workoutformat.` subdomain so requests originating from the redirecting hosts still pass), and (beta only) the local Astro dev origin. `allowCredentials: true` so the SameSite refresh-token cookie flow works.
- **Security response headers**: a CloudFront `ResponseHeadersPolicy` is attached to every behavior — strict CSP (`default-src 'self'`, no `unsafe-inline`; inline site scripts load via CSP hashes), HSTS (1y, includeSubDomains, preload), `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` + `frame-ancestors 'none'`, `Referrer-Policy: strict-origin-when-cross-origin`.
- **WAF**: CLOUDFRONT-scoped WAFv2 web ACL (in the us-east-1 edge stack, wired to the distribution via `crossRegionReferences`) — AWS managed rule groups (Common, KnownBadInputs, AmazonIpReputationList), a broad per-IP rate limit, and a stricter per-IP rate-based rule scoped to `/v1/auth/*` to blunt credential stuffing. Per-account application lockout is a deferred follow-up (needs a DDB counter table).
- **Access logging**: the HTTP API stage writes a JSON access log (source IP, route, status, auth subject/principal) to CloudWatch Logs.
