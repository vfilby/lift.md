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

## Deployment
- Runtime: Node.js 20 on AWS Lambda (arm64)
- Infrastructure: AWS SAM (`template.yaml`)
- CORS: All origins allowed
- No authentication required
