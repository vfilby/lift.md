# LMWF Validator

Validation service for the [LiftMark Workout Format (LMWF)](../liftmark-workout-format/LIFTMARK_WORKOUT_FORMAT_SPEC.md). Accepts workout markdown and returns structured validation results.

**Live endpoint:** `https://workoutformat.liftmark.app/validate`

## Usage

### JSON request

```bash
curl -X POST https://workoutformat.liftmark.app/validate \
  -H "Content-Type: application/json" \
  -d '{
    "markdown": "# Push Day\n@units: lbs\n\n## Bench Press [barbell]\n- 225 x 5\n- 245 x 3"
  }'
```

### Send a file

```bash
curl -X POST https://workoutformat.liftmark.app/validate \
  -H "Content-Type: text/markdown" \
  --data-binary @my-workout.md
```

### Response (valid)

```json
{
  "success": true,
  "summary": {
    "workoutName": "Push Day",
    "defaultWeightUnit": "lbs",
    "tags": [],
    "exerciseCount": 1,
    "totalSetCount": 2,
    "exercises": [
      {
        "name": "Bench Press [barbell]",
        "setCount": 2,
        "groupType": null,
        "groupName": null,
        "parentExerciseId": null
      }
    ]
  },
  "errors": [],
  "warnings": []
}
```

### Response (invalid)

```json
{
  "success": false,
  "summary": null,
  "errors": [
    "No workout header found. Must have a header (# Workout Name) with exercises below it."
  ],
  "warnings": []
}
```

### Using with AI agents

POST the markdown as JSON, check `success` in the response, and iterate on any `errors`:

```
1. Generate workout markdown
2. POST to https://workoutformat.liftmark.app/validate
3. If success: done
4. If errors: fix the issues and retry from step 2
```

## Format reference

See the full [LMWF Markdown Specification](../liftmark-workout-format/LIFTMARK_WORKOUT_FORMAT_SPEC.md) for the workout format.

Quick example:

```markdown
# Push Day
@tags: strength, upper
@units: lbs

## Bench Press [barbell]
- 135 x 8 @rest: 90s
- 185 x 5 @rest: 120s
- 225 x 3 @rest: 180s

## Overhead Press [barbell]
- 95 x 8
- 115 x 5

## Lateral Raises [dumbbell]
- 20 x 12
- 20 x 12
```

## Development

```bash
# Install dependencies
make install
make install-cdk

# Run tests
make test

# Type check
make typecheck

# Deploy (credentials in aws-vault under profile `liftmark-validator-deploy`)
make deploy
```

### Local dev stack

The validator runs as a regular Node HTTP server locally (via Hono's
node-server adapter) — no AWS account or Lambda emulator required.
DynamoDB Local in Docker provides storage parity with prod.

```bash
# Start DDB Local + create tables from the same schemas CDK uses
make dev-up

# Run the validator on http://localhost:3000
DDB_ENDPOINT=http://localhost:8000 npm run dev

# Hit it
curl -X POST http://localhost:3000/validate \
  -H "Content-Type: application/json" \
  -d '{"markdown":"# Test\n## Squat\n- 135 x 5"}'

# Tear down (data persists in the lmwf-dynamodb-data volume)
make dev-down
```

Table schemas live in `src/infra/tables.ts` and are consumed by both
the CDK stack (`cdk/stack.ts`) and the local bootstrap script
(`scripts/ddb-local-bootstrap.ts`). Add a table by appending to that
file, then run `make dev-up` locally and `make deploy` to roll it out.

## Credentials & deploy setup

Deploys go through AWS CDK, which authenticates via [aws-vault](https://github.com/99designs/aws-vault). Credentials never sit plaintext on disk — aws-vault's encrypted file backend holds the access key, and the unlock passphrase comes from 1Password. MFA is mandatory on every deploy.

### Identity model

- **IAM user:** `liftmark-deploy` (account `323146837100`, region `us-west-2`)
- **Attached policy:** the minimal inline policy at `cdk/iam/deploy-user-policy.json` — `sts:AssumeRole` on the four `cdk-hnb659fds-*` bootstrap roles, gated on `aws:MultiFactorAuthPresent`. Nothing else.
- **Bootstrap roles** hold the actual CloudFormation / Lambda / S3 / IAM permissions. CDK assumes them automatically during deploy.

This means a leaked static access key is useless without the MFA code and the bootstrap role trust — the blast radius is limited to whatever the bootstrap roles themselves can do.

### Required 1Password items

All under `op://Private/AWS Credential Vault/`:

| Item | Purpose |
|---|---|
| `password` | Unlocks the aws-vault file backend (shared across all profiles) |
| `liftmark-validator-deploy` (with TOTP attribute) | MFA seed for the `liftmark-validator-deploy` aws-vault profile — the fish wrapper auto-supplies the code via `--mfa-token` |

### aws-vault + 1Password fish wrapper

Add to `~/.config/fish/config.fish` (sample integration — works for any aws-vault profile whose 1Password item follows the naming convention above):

```fish
# aws-vault: use encrypted file backend (works identically local and over SSH)
set -gx AWS_VAULT_BACKEND file

# Lazy-load aws-vault passphrase from 1Password on first use per shell.
# For `exec <profile>` calls, auto-fetch TOTP from 1Password if stored at
# op://Private/AWS Credential Vault/<profile>.
function aws-vault
    if not set -q AWS_VAULT_FILE_PASSPHRASE
        set -gx AWS_VAULT_FILE_PASSPHRASE (op read "op://Private/AWS Credential Vault/password")
    end

    if test (count $argv) -ge 2; and test "$argv[1]" = "exec"
        set -l profile $argv[2]
        set -l totp (op read "op://Private/AWS Credential Vault/$profile?attribute=otp" 2>/dev/null)
        if test -n "$totp"
            command aws-vault exec $profile --mfa-token $totp $argv[3..-1]
            return $status
        end
    end

    command aws-vault $argv
end
```

### One-time setup on a new machine

1. Install prerequisites: `brew install aws-vault 1password-cli` (plus 1Password desktop app with CLI integration enabled).
2. Sign in to the 1Password CLI: `eval (op signin)` (fish) — triggers TouchID.
3. Confirm the two items above exist under `op://Private/AWS Credential Vault/`.
4. Import the AWS access key/secret into aws-vault: `aws-vault add liftmark-validator-deploy` — paste the values when prompted.
5. Add `mfa_serial` to `~/.aws/config` so aws-vault enforces MFA:
   ```
   [profile liftmark-validator-deploy]
   region = us-west-2
   output = json
   mfa_serial = arn:aws:iam::323146837100:mfa/liftmark-validator-deploy
   ```
6. Verify: `aws-vault exec liftmark-validator-deploy -- aws sts get-caller-identity`.

### Daily flow

```fish
# Once per shell session — fish wrapper fires, TouchID prompts for 1Password,
# aws-vault caches an MFA'd STS session for ~1 hour.
aws-vault exec liftmark-validator-deploy -- true

# All subsequent make targets in that shell inherit the cached session.
make deploy
```

If you skip the warm-up call and go straight to `make deploy`, the Make recipe runs under `/bin/sh` which doesn't load the fish wrapper — aws-vault will prompt for the MFA code manually. Not broken, just less slick.

## Infrastructure

- **Runtime:** Node.js 20 on AWS Lambda (arm64, 256MB)
- **API:** API Gateway v2 (HTTP API) with CORS
- **Domain:** `workoutformat.liftmark.app` (ACM cert + Route 53)
- **Throttle:** 100 burst / 50 sustained requests per second
- **IaC:** AWS CDK (see `cdk/`)
