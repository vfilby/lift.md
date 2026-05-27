#!/usr/bin/env bash
# Run the Playwright E2E suite against a locally-served validator +
# website stack. Used pre-merge in CI (validator-ci.yml `e2e-local`
# job) and by developers on their laptops.
#
# Boots: DynamoDB Local + Mailpit (docker compose), table bootstrap,
# astro build → dist/, validator (Hono) serving dist/* at the root.
# Runs Playwright at http://localhost:3001, tears down on exit.
#
# Run without arguments to execute the full suite. Pass anything (e.g.
# 'home.spec.ts') to forward as an argv to `playwright test`.
#
# Env knobs:
#   PLAYWRIGHT_PORT — port the validator listens on (default 3001).
#   KEEP_RUNNING=1 — leave the validator + docker stack up after the run
#                    finishes (useful for debugging). Default tears down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALIDATOR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$VALIDATOR_DIR/.." && pwd)"
WEBSITE_DIR="$REPO_ROOT/website"
E2E_DIR="$VALIDATOR_DIR/e2e"

PORT="${PLAYWRIGHT_PORT:-3001}"
BASE_URL="http://localhost:$PORT"
# Stable secret so the test process + validator share a value without
# inter-process plumbing. Not used outside the local stack.
LOCAL_TEST_SECRET="e2e-local-secret-do-not-use-in-prod-1234567890ab"

SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -z "${KEEP_RUNNING:-}" ]; then
    (cd "$VALIDATOR_DIR" && docker compose down) >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "==> docker compose up (DynamoDB Local + Mailpit)"
cd "$VALIDATOR_DIR"
docker compose up -d

echo "==> waiting for DynamoDB Local"
until docker compose ps dynamodb-local --format json 2>/dev/null | grep -q '"Health":"healthy"'; do sleep 0.3; done
echo "==> waiting for Mailpit"
until docker compose ps mailpit --format json 2>/dev/null | grep -q '"Health":"healthy"'; do sleep 0.3; done

echo "==> bootstrap DDB tables"
npx tsx scripts/ddb-local-bootstrap.ts

echo "==> reset Mailpit inbox"
curl -fsS -X DELETE "http://localhost:8025/api/v1/messages" >/dev/null || true

echo "==> build website"
cd "$WEBSITE_DIR"
if [ ! -d "$WEBSITE_DIR/node_modules" ]; then
  npm ci --no-audit --no-fund
fi
npm run build

echo "==> ensure validator deps"
cd "$VALIDATOR_DIR"
if [ ! -d "$VALIDATOR_DIR/node_modules" ]; then
  npm ci --no-audit --no-fund
fi

echo "==> start validator (PORT=$PORT, WEBSITE_DIST=$WEBSITE_DIR/dist)"
export PORT="$PORT"
export WEBSITE_DIST="$WEBSITE_DIR/dist"
export DDB_ENDPOINT="http://localhost:8000"
export DDB_TABLE_USERS="lmwf-local-users"
export DDB_TABLE_IDENTITIES="lmwf-local-identities"
export DDB_TABLE_PAT_TOKENS="lmwf-local-pat_tokens"
export DDB_TABLE_ENTITLEMENTS="lmwf-local-entitlements"
export DDB_TABLE_REFRESH_TOKENS="lmwf-local-refresh_tokens"
export DDB_TABLE_WORKOUT_INBOX="lmwf-local-workout_inbox"
export DDB_TABLE_WORKOUT_OUTBOX="lmwf-local-workout_outbox"
export AWS_REGION="us-west-2"
export AWS_ACCESS_KEY_ID="local"
export AWS_SECRET_ACCESS_KEY="local"
export SMTP_HOST="localhost"
export SMTP_PORT="1025"
export SMTP_FROM="noreply@local.test"
export JWT_SECRET="local-jwt-secret-do-not-use-in-prod-1234567890ab"
export E2E_TEST_SECRET="$LOCAL_TEST_SECRET"
export LMWF_ENV="beta"
export BUILD_COMMIT="local"
export BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Run validator in background; log to a file the runner can dump on
# failure but stay out of Playwright's stdout.
LOG_FILE="$(mktemp -t lmwf-validator-e2e.XXXXXX)"
npx tsx src/server.ts >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

echo "==> wait for /version"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if curl -fsS "$BASE_URL/version" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FAIL: validator exited during boot" >&2
    cat "$LOG_FILE" >&2
    exit 2
  fi
  sleep 0.4
done
if ! curl -fsS "$BASE_URL/version" >/dev/null 2>&1; then
  echo "FAIL: validator did not respond on $BASE_URL/version" >&2
  cat "$LOG_FILE" >&2
  exit 2
fi
echo "    ✓ validator up"

cd "$E2E_DIR"
if [ ! -d "$E2E_DIR/node_modules" ]; then
  echo "==> install Playwright deps"
  npm ci --no-audit --no-fund
fi
if [ ! -d "$HOME/Library/Caches/ms-playwright" ] && [ ! -d "$HOME/.cache/ms-playwright" ]; then
  echo "==> install Playwright browsers"
  npx playwright install --with-deps chromium
fi

echo "==> playwright test"
export LMWF_E2E_MODE="local"
export LMWF_E2E_BASE_URL="$BASE_URL"
export LMWF_E2E_TEST_SECRET="$LOCAL_TEST_SECRET"
export LMWF_E2E_MAILPIT_URL="http://localhost:8025"

if [ "$#" -gt 0 ]; then
  npx playwright test "$@"
else
  npx playwright test
fi
