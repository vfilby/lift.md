#!/usr/bin/env bash
#
# M4 Phase C (issue #171) — make the L11 scoped CFN execution policy real.
#
# Two things, per stage account, from a privileged SSO session:
#   1. Create/refresh the LmwfCdkDeployPolicy managed policy from
#      ../deploy-policy.json (so #166's PassRole/AttachRolePolicy conditions
#      are what's actually on AWS). Re-run this any time deploy-policy.json
#      changes.
#   2. Verify the CDK bootstrap (LmwfCdkToolkit) in BOTH regions actually wired
#      that policy as the CFN execution policy. If not, the cdk-lmwf-deploy-role
#      is still AdministratorAccess regardless of the hardened JSON — the script
#      prints the exact `cdk bootstrap` re-run to fix it (it does NOT re-bootstrap
#      for you; that's a deliberate toolkit-stack change you run yourself).
#
# Usage:
#   ./refresh-deploy-policy.sh beta
#   ./refresh-deploy-policy.sh prod
#   PROFILE=my-sso-profile ./refresh-deploy-policy.sh beta
#
set -euo pipefail

STAGE="${1:-}"
QUALIFIER="lmwf"
TOOLKIT="LmwfCdkToolkit"
POLICY_NAME="LmwfCdkDeployPolicy"
REGIONS=(us-west-2 us-east-1)

case "$STAGE" in
  beta) ACCT=323146837100; PROFILE="${PROFILE:-liftmark-beta}" ;;
  prod) ACCT=825347768149; PROFILE="${PROFILE:-liftmark-prod}" ;;
  *)    echo "usage: $0 <beta|prod>   (set PROFILE=... to override the SSO profile)"; exit 2 ;;
esac

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DOC="$DIR/../deploy-policy.json"
POLICY_ARN="arn:aws:iam::${ACCT}:policy/${POLICY_NAME}"
[ -f "$POLICY_DOC" ] || { echo "deploy-policy.json not found at $POLICY_DOC" >&2; exit 1; }

echo "==> SSO login (profile: $PROFILE)"
aws sso login --profile "$PROFILE"
export AWS_PROFILE="$PROFILE"

echo "==> verifying we are in account $ACCT"
GOT="$(aws sts get-caller-identity --query Account --output text)"
[ "$GOT" = "$ACCT" ] || { echo "WRONG ACCOUNT: got $GOT, expected $ACCT ($STAGE) — aborting" >&2; exit 1; }

# ── 1. Create or refresh the managed policy ──────────────────────────────────
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  # Managed policies allow at most 5 versions — prune the oldest non-default
  # before adding a new default, so re-runs never wedge on the limit.
  COUNT="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'length(Versions)' --output text)"
  if [ "$COUNT" -ge 5 ]; then
    OLDEST="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
      --query 'sort_by(Versions[?IsDefaultVersion==`false`],&CreateDate)[0].VersionId' --output text)"
    echo "==> pruning oldest policy version $OLDEST (at the 5-version limit)"
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST"
  fi
  echo "==> refreshing $POLICY_NAME (new default version)"
  aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "file://$POLICY_DOC" --set-as-default >/dev/null
else
  echo "==> creating $POLICY_NAME"
  aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document "file://$POLICY_DOC" >/dev/null
fi
echo "    $POLICY_ARN is current"

# ── 2. Verify the bootstrap wired it as the CFN execution policy ─────────────
echo "==> checking CDK bootstrap ($TOOLKIT) CFN execution policy per region"
NEEDS_FIX=0
for region in "${REGIONS[@]}"; do
  VAL="$(aws cloudformation describe-stacks --stack-name "$TOOLKIT" --region "$region" \
    --query 'Stacks[0].Parameters[?ParameterKey==`CloudFormationExecutionPolicies`].ParameterValue' \
    --output text 2>/dev/null || echo "STACK_MISSING")"
  if [ "$VAL" = "STACK_MISSING" ]; then
    echo "  [$region] ✗ no $TOOLKIT stack found — account/region not bootstrapped?"
    NEEDS_FIX=1
  elif printf '%s' "$VAL" | grep -q "$POLICY_NAME"; then
    echo "  [$region] ✓ scoped → $VAL"
  else
    echo "  [$region] ✗ NOT scoped (CloudFormationExecutionPolicies='${VAL:-<empty = AdministratorAccess>}')"
    echo "            deploy role is still AdministratorAccess — re-bootstrap to fix:"
    echo "            npx cdk bootstrap aws://${ACCT}/${region} \\"
    echo "              --profile ${PROFILE} \\"
    echo "              --qualifier ${QUALIFIER} --toolkit-stack-name ${TOOLKIT} \\"
    echo "              --cloudformation-execution-policies ${POLICY_ARN}"
    NEEDS_FIX=1
  fi
done

echo ""
if [ "$NEEDS_FIX" -eq 0 ]; then
  echo "==> $STAGE: Phase C complete — policy current and bootstrap scoped in all regions."
else
  echo "==> $STAGE: policy refreshed, but run the printed 'cdk bootstrap' command(s) above to scope the deploy role, then re-run this script to confirm."
fi
