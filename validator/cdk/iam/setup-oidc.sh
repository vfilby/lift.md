#!/usr/bin/env bash
#
# Bootstrap the GitHub Actions OIDC deploy role for one stage account.
#
# BOOTSTRAP TIER — run ONCE per account from a privileged SSO session. This is
# deliberately NOT part of the CDK app and NOT run by the pipeline: the role
# created here is what the pipeline authenticates as, so a pipeline-run deploy
# can't create it (chicken-and-egg), and a deploy identity must not manage
# itself. Lives alongside the other hand-applied IAM here (ci-deploy-*,
# deploy-user). See README "GitHub Actions OIDC (deploy auth)" and issue #171.
#
# Usage:
#   ./setup-oidc.sh beta
#   ./setup-oidc.sh prod
#   PROFILE=my-sso-profile ./setup-oidc.sh beta    # override the SSO profile
#
set -euo pipefail

STAGE="${1:-}"
REPO="vfilby/lift.md"
ROLE_NAME="GitHubActionsDeploy"
# Thumbprint is no longer security-critical for the GitHub provider (AWS
# validates the token against its own trust store) but the create API still
# requires the field.
GH_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

case "$STAGE" in
  beta) ACCT=323146837100; GH_ENV=beta;       PROFILE="${PROFILE:-liftmark-beta}" ;;
  prod) ACCT=825347768149; GH_ENV=production; PROFILE="${PROFILE:-liftmark-prod}" ;;
  *)    echo "usage: $0 <beta|prod>   (set PROFILE=... to override the SSO profile)"; exit 2 ;;
esac

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRUST="$DIR/github-oidc-trust-$STAGE.json"
PERMS="$DIR/github-oidc-perms-$STAGE.json"

echo "==> SSO login (profile: $PROFILE)"
aws sso login --profile "$PROFILE"
export AWS_PROFILE="$PROFILE"

echo "==> verifying we are in account $ACCT"
GOT="$(aws sts get-caller-identity --query Account --output text)"
if [ "$GOT" != "$ACCT" ]; then
  echo "WRONG ACCOUNT: got $GOT, expected $ACCT ($STAGE) — aborting" >&2
  exit 1
fi

PROVIDER_ARN="arn:aws:iam::${ACCT}:oidc-provider/token.actions.githubusercontent.com"
echo "==> ensuring GitHub OIDC provider exists"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  echo "    provider already present"
else
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list "$GH_THUMBPRINT"
  echo "    provider created"
fi

echo "==> creating/updating role $ROLE_NAME (trust: $(basename "$TRUST"))"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$TRUST"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST" \
    --description "GitHub Actions OIDC deploy role (security M4, issue #171)"
fi

echo "==> attaching permissions (policy: $(basename "$PERMS"))"
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name deploy --policy-document "file://$PERMS"

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
echo ""
echo "==> done. Role ARN: $ROLE_ARN"
echo ""
echo "Next, publish it to the GitHub environment (run locally, with gh authed to the repo):"
echo "  gh variable set AWS_DEPLOY_ROLE_ARN --repo $REPO --env $GH_ENV --body \"$ROLE_ARN\""
