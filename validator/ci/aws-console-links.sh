#!/usr/bin/env bash
# Emit markdown links to the AWS console for the just-deployed env. Writes
# to $GITHUB_STEP_SUMMARY when set (GHA runs render it as markdown under
# the job summary) and to stdout otherwise (Concourse, ad-hoc local runs).
#
# Called from both .github/workflows/validator-ci.yml and
# validator/ci/pipeline.yml, after the CDK deploy step, so we don't have
# to duplicate AWS-console URL composition in two pipeline files.
#
# Usage:
#   aws-console-links.sh <env_name> <outputs_file>
#
# Examples:
#   aws-console-links.sh beta validator/cdk/outputs-beta.json
#   aws-console-links.sh prod validator/cdk/outputs-prod.json

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <env_name> <outputs_file>" >&2
  exit 64
fi

ENV_NAME="$1"
OUTPUTS_FILE="$2"

case "$ENV_NAME" in
  beta)
    ACCOUNT_ID=323146837100
    STACK=LmwfBetaValidatorStack
    DOMAIN=beta.liftmark.app
    ;;
  prod)
    ACCOUNT_ID=825347768149
    STACK=LmwfProdValidatorStack
    DOMAIN=liftmark.app
    ;;
  *)
    echo "unknown env: $ENV_NAME (expected beta|prod)" >&2
    exit 64
    ;;
esac

# Both envs share the same Identity Center instance + role; we only switch
# the target account. Hardcoded because the start URL is the same one in
# `aws sso login` stderr — not a secret.
SSO_START_URL="https://d-9267c0eeab.awsapps.com/start"
ROLE_NAME="AdministratorAccess"
REGION="us-west-2"

# Read CDK stack outputs. Use python3 because it's already a smoke-test
# dependency, so the runtime is guaranteed in both CI images.
read_output() {
  local key="$1"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]][sys.argv[3]])" \
    "$OUTPUTS_FILE" "$STACK" "$key"
}

FUNCTION_NAME=$(read_output FunctionName)
DISTRIBUTION_ID=$(read_output DistributionId)
SITE_BUCKET=$(read_output SiteBucketName)

# SSO portal deep-link: lands you on the account-role chooser; one click
# from there into the console with valid creds for THIS env.
sso_console_url="${SSO_START_URL}/#/console?account_id=${ACCOUNT_ID}&role_name=${ROLE_NAME}"

# Direct console URLs — work once you've authenticated via the portal link
# above. (Trying to chain destinations through ?destination= in the SSO
# URL works but is fragile across console redesigns; two clicks is fine.)
cfn_url="https://${REGION}.console.aws.amazon.com/cloudformation/home?region=${REGION}#/stacks/stackinfo?stackId=${STACK}"
lambda_url="https://${REGION}.console.aws.amazon.com/lambda/home?region=${REGION}#/functions/${FUNCTION_NAME}?tab=monitoring"
# CloudFront is global / console pinned to us-east-1.
cf_url="https://us-east-1.console.aws.amazon.com/cloudfront/v4/home#/distributions/${DISTRIBUTION_ID}"
s3_url="https://${REGION}.console.aws.amazon.com/s3/buckets/${SITE_BUCKET}"

OUT_FILE="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

{
  echo "## AWS console — ${ENV_NAME} (account ${ACCOUNT_ID})"
  echo
  echo "Site: <https://${DOMAIN}/>"
  echo
  echo "**[🔐 Open AWS console via SSO](${sso_console_url})** — authenticates this browser session for the ${ENV_NAME} account, then the deep-links below open instantly."
  echo
  echo "Resource deep-links:"
  echo
  echo "- [CloudFormation stack — ${STACK}](${cfn_url})"
  echo "- [Lambda — ${FUNCTION_NAME}](${lambda_url})"
  echo "- [CloudFront distribution — ${DISTRIBUTION_ID}](${cf_url})"
  echo "- [S3 site bucket — ${SITE_BUCKET}](${s3_url})"
  echo
} >> "$OUT_FILE"
