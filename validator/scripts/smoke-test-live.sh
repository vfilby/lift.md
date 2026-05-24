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
  curl -fsS --max-time 30 -X POST "$ENDPOINT" \
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

echo "--- valid/ (expect success: true) ---"
for f in "$VALID_DIR"/*.md; do
  name=$(basename "$f")
  if response=$(post "$f" 2>/dev/null) && [ "$(printf '%s' "$response" | extract_success)" = "true" ]; then
    valid_ok=$((valid_ok + 1))
    printf '  OK   %s\n' "$name"
  else
    valid_fail=$((valid_fail + 1))
    failures+=("valid/$name")
    printf '  FAIL %s\n' "$name"
    printf '       response: %s\n' "${response:-<curl error>}" | head -c 400
    printf '\n'
  fi
done

echo
echo "--- errors/ (expect success: false) ---"
for f in "$ERROR_DIR"/*.md; do
  name=$(basename "$f")
  if response=$(post "$f" 2>/dev/null) && [ "$(printf '%s' "$response" | extract_success)" = "false" ]; then
    error_ok=$((error_ok + 1))
    printf '  OK   %s\n' "$name"
  else
    error_fail=$((error_fail + 1))
    failures+=("errors/$name")
    printf '  FAIL %s\n' "$name"
    printf '       response: %s\n' "${response:-<curl error>}" | head -c 400
    printf '\n'
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
