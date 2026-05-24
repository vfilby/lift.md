#!/usr/bin/env bash
# Post-deploy smoke test: validate every LMWF example fixture against a live
# validator and assert success vs. expected outcome.
#
# Usage:
#   scripts/smoke-test-live.sh <base_url>
#
# Examples:
#   scripts/smoke-test-live.sh https://beta.liftmark.app
#   scripts/smoke-test-live.sh https://workoutformat.liftmark.app
#
# Exits non-zero if any fixture returns an unexpected success/failure result.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <base_url>" >&2
  exit 64
fi

BASE_URL="${1%/}"
ENDPOINT="$BASE_URL/validate"

# Resolve repo root from this script's location so the script is callable
# from any cwd (Concourse worker, local make target, ad-hoc).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALID_DIR="$REPO_ROOT/liftmark-workout-format/examples/valid"
ERROR_DIR="$REPO_ROOT/liftmark-workout-format/examples/errors"

if [ ! -d "$VALID_DIR" ] || [ ! -d "$ERROR_DIR" ]; then
  echo "error: example dirs not found under $REPO_ROOT/liftmark-workout-format/examples/" >&2
  exit 65
fi

post() {
  # --retry handles transient curl/network failures (worker host has
  # flaky outbound on some paths — see Concourse setup notes). We do
  # NOT use -f because we want to inspect 4xx response bodies (the
  # validator returns structured error JSON on bad input).
  curl -sS --max-time 30 \
    --retry 3 --retry-delay 1 --retry-all-errors --retry-connrefused \
    -X POST "$ENDPOINT" \
    -H 'Content-Type: text/markdown' \
    --data-binary @"$1"
}

# Strip JSON parsing dependence on jq by using python3 — available on every
# image we'd ever use. Reads from stdin, prints "true"/"false"/"<missing>".
extract_success() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('success', '<missing>')).lower())"
}

valid_ok=0
valid_fail=0
error_ok=0
error_fail=0
failures=()

echo "==> POST $ENDPOINT (timeout 30s/req)"
echo

check_one() {
  local f="$1" expected="$2" name response curl_rc actual
  name=$(basename "$f")
  # Stay under the CloudFront WAF rate limit (84 fixtures back-to-back
  # without throttling triggers 429s that retry can't always recover from
  # cleanly).
  sleep 0.3
  set +e
  response=$(post "$f" 2>/tmp/smoke.curl.err)
  curl_rc=$?
  set -e
  if [ "$curl_rc" -ne 0 ]; then
    printf '  FAIL %s (curl exit=%d: %s)\n' "$name" "$curl_rc" "$(tr -d '\n' < /tmp/smoke.curl.err | head -c 200)"
    return 1
  fi
  actual=$(printf '%s' "$response" | extract_success 2>/dev/null || echo "<unparseable>")
  if [ "$actual" = "$expected" ]; then
    printf '  OK   %s\n' "$name"
    return 0
  fi
  printf '  FAIL %s (success=%s, expected %s)\n' "$name" "$actual" "$expected"
  printf '       response: %s\n' "$(printf '%s' "$response" | head -c 300)"
  return 1
}

echo "--- valid/ (expect success: true) ---"
for f in "$VALID_DIR"/*.md; do
  if check_one "$f" "true"; then
    valid_ok=$((valid_ok + 1))
  else
    valid_fail=$((valid_fail + 1))
    failures+=("valid/$(basename "$f")")
  fi
done

echo
echo "--- errors/ (expect success: false) ---"
for f in "$ERROR_DIR"/*.md; do
  if check_one "$f" "false"; then
    error_ok=$((error_ok + 1))
  else
    error_fail=$((error_fail + 1))
    failures+=("errors/$(basename "$f")")
  fi
done

echo
echo "==> Summary"
printf '  valid/   %d OK, %d FAIL\n' "$valid_ok" "$valid_fail"
printf '  errors/  %d OK, %d FAIL\n' "$error_ok" "$error_fail"

if [ "${#failures[@]}" -gt 0 ]; then
  echo
  echo "==> FAILURES (${#failures[@]}):"
  for name in "${failures[@]}"; do
    echo "  - $name"
  done
  exit 1
fi

echo
echo "✓ All fixtures match expected outcomes against $ENDPOINT"
