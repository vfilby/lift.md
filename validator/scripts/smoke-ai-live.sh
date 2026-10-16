#!/usr/bin/env bash
# Post-deploy smoke test for AI plan editing (POST /v1/ai/plan/edit).
#
# Seeds a throwaway pro user through the beta-only /v1/__test__ router, sends
# a three-line plan with the instruction "add one warm-up set", asserts a 200
# whose plan_markdown passes /validate, then deletes the user. One real
# Bedrock call — so this costs money and needs Nova model access in the
# account; the CI job gates it on AI_SMOKE=1.
#
# Usage:
#   LMWF_E2E_TEST_SECRET=… scripts/smoke-ai-live.sh https://beta.getlift.md
#
# Exits non-zero if the edit does not return 200, the response lacks
# plan_markdown / summary / quota, or the returned plan fails /validate.
# See spec/services/ai-plan-editing.md → Beta smoke.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <base_url>" >&2
  exit 64
fi
if [ -z "${LMWF_E2E_TEST_SECRET:-}" ]; then
  echo "LMWF_E2E_TEST_SECRET must be set (beta /v1/__test__ gate)" >&2
  exit 64
fi

BASE_URL="${1%/}"
EMAIL="ai-smoke-$(date +%s)-$RANDOM@example.com"
TMP="$(mktemp -d)"
trap 'cleanup' EXIT

cleanup() {
  # Best effort: remove the seeded user so beta doesn't accumulate smoke rows.
  curl -s -o /dev/null --max-time 30 -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Test-Secret: $LMWF_E2E_TEST_SECRET" \
    -d "{\"email\":\"$EMAIL\"}" \
    "$BASE_URL/v1/__test__/delete-user-by-email" || true
  rm -rf "$TMP"
}

json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

echo "==> seed pro user ($EMAIL)"
seed_status=$(curl -s --max-time 30 -o "$TMP/seed.json" -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -H "X-Test-Secret: $LMWF_E2E_TEST_SECRET" \
  -d "{\"email\":\"$EMAIL\",\"tier\":\"pro\",\"display_name\":\"AI Smoke\"}" \
  "$BASE_URL/v1/__test__/seed-user")
if [ "$seed_status" != "201" ]; then
  echo "FAIL: seed-user returned $seed_status: $(head -c 300 "$TMP/seed.json")" >&2
  exit 2
fi
JWT=$(json "d['session_jwt']" < "$TMP/seed.json")
echo "    ✓ seeded"

PLAN='# Push Day\n@units: lbs\n\n## Bench Press\n- 135 x 5\n- 185 x 5\n- 225 x 5\n'
echo "==> POST $BASE_URL/v1/ai/plan/edit (\"add one warm-up set\")"
start=$(date +%s)
edit_status=$(curl -s --max-time 60 -o "$TMP/edit.json" -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $JWT" \
  -d "{\"plan_markdown\":\"$PLAN\",\"instruction\":\"add one warm-up set\",\"context\":{\"units\":\"lbs\",\"equipment\":[\"barbell\"]}}" \
  "$BASE_URL/v1/ai/plan/edit")
elapsed=$(( $(date +%s) - start ))
if [ "$edit_status" != "200" ]; then
  echo "FAIL: /v1/ai/plan/edit returned $edit_status after ${elapsed}s: $(head -c 500 "$TMP/edit.json")" >&2
  exit 2
fi
summary=$(json "d['summary']" < "$TMP/edit.json")
model=$(json "d['model']" < "$TMP/edit.json")
remaining=$(json "d['quota']['remaining']" < "$TMP/edit.json")
echo "    ✓ 200 in ${elapsed}s  model=$model  quota.remaining=$remaining"
echo "    summary: $summary"

echo "==> validate returned plan_markdown"
python3 - "$TMP/edit.json" "$TMP/validate-req.json" <<'EOF'
import json, sys
edit = json.load(open(sys.argv[1]))
assert isinstance(edit.get("plan_markdown"), str) and edit["plan_markdown"].strip(), "missing plan_markdown"
assert isinstance(edit.get("summary"), str), "missing summary"
assert isinstance(edit.get("quota"), dict) and "limit" in edit["quota"], "missing quota"
json.dump({"markdown": edit["plan_markdown"]}, open(sys.argv[2], "w"))
EOF
validate_status=$(curl -s --max-time 30 -o "$TMP/validate.json" -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$TMP/validate-req.json" \
  "$BASE_URL/validate")
if [ "$validate_status" != "200" ]; then
  echo "FAIL: /validate returned $validate_status: $(head -c 300 "$TMP/validate.json")" >&2
  exit 2
fi
success=$(json "d['success']" < "$TMP/validate.json")
if [ "$success" != "True" ]; then
  echo "FAIL: returned plan did not validate: $(head -c 500 "$TMP/validate.json")" >&2
  exit 2
fi
exercises=$(json "d['summary']['exerciseCount']" < "$TMP/validate.json")
echo "    ✓ plan validates ($exercises exercise(s))"
echo
echo "✓ AI plan-edit smoke passed"
