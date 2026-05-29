# Deploy User IAM Policies

Two inline policies for two IAM users:

- **`deploy-user-policy.json`** — human user `liftmark-deploy`, MFA-gated. Used by Vincent's CLI via SSO. (NOTE: file still references the pre-move account `341556346945`; current beta is `323146837100`.)
- **`ci-deploy-beta-policy.json`** — CI user `liftmark-ci-deploy-beta` in account `323146837100`, no MFA (machine creds can't satisfy MFA). Used by Concourse to deploy `LmwfBetaEdgeStack` + `LmwfBetaValidatorStack`.
- **`ci-deploy-prod-policy.json`** — CI user `liftmark-ci-deploy-prod` in account `825347768149`, same structure as the beta CI policy. Used by Concourse to deploy `LmwfProdEdgeStack` + `LmwfProdValidatorStack` when the manual gate is clicked.

Both grant `sts:AssumeRole` on the LiftMark-namespaced CDK bootstrap roles (`cdk-lmwf-*`) in both `us-west-2` (Lambda + API Gateway origin + S3 + CloudFront) and `us-east-1` (CloudFront cert + WAF). All real permissions live in the bootstrap roles themselves, scoped by `../deploy-policy.json`, which CDK maintains.

> The `ci-deploy-*` users are being retired in favour of GitHub Actions OIDC — see below. They are removed once OIDC is live (issue #171).

## GitHub Actions OIDC (deploy auth) — replaces the static-key CI users

The GitHub Actions deploy jobs (`.github/workflows/validator-ci.yml`) authenticate to AWS via **OIDC**, not long-lived access keys (security finding **M4**, issue #171). Per stage account there is:

- a GitHub OIDC identity provider (`token.actions.githubusercontent.com`), and
- a role `GitHubActionsDeploy` whose trust is scoped to a single GitHub Environment `sub`
  (`repo:vfilby/liftmark:environment:beta` / `…:environment:production`) and whose only
  permissions are to `sts:AssumeRole` the `cdk-lmwf-*` bootstrap roles (plus the e2e secret
  read in beta).

These files are the reviewable record; they are **bootstrap tier** — applied once per account
from a privileged SSO session, NOT part of the CDK app and NOT run by the pipeline (the role is
what the pipeline assumes, so the pipeline can't create it; a deploy identity must not manage
itself — same tier as `cdk bootstrap` and the `ci-deploy-*`/`deploy-user` policies here).

- `github-oidc-trust-beta.json` / `github-oidc-trust-prod.json` — role trust policies
- `github-oidc-perms-beta.json` / `github-oidc-perms-prod.json` — role permission policies
- `setup-oidc.sh` — applies the above for one stage (SSO login → provider → role → policy)

### Apply

```bash
# from validator/cdk/iam/ — uses your SSO profile (default liftmark-beta / liftmark-prod;
# override with PROFILE=...). Re-runnable: updates the role in place if it already exists.
./setup-oidc.sh beta
./setup-oidc.sh prod
```

The script prints the role ARN and the `gh variable set` command to publish it to the
matching GitHub Environment, e.g.:

```bash
gh variable set AWS_DEPLOY_ROLE_ARN --repo vfilby/liftmark --env beta \
  --body "arn:aws:iam::323146837100:role/GitHubActionsDeploy"
gh variable set AWS_DEPLOY_ROLE_ARN --repo vfilby/liftmark --env production \
  --body "arn:aws:iam::825347768149:role/GitHubActionsDeploy"
```

Also restrict each GitHub Environment (Settings → Environments → beta / production) with a
**deployment branch policy** of `main`, so only `main` can claim the environment `sub`.

Once OIDC is confirmed working (test via `gh workflow run Validator --ref main`), delete the
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` environment secrets and the `liftmark-ci-deploy-*`
IAM users + policies.

## `../deploy-policy.json` privilege-escalation hardening (L11)

The scoped CFN execution policy is the blast radius once `cdk-lmwf-deploy-role` is assumed. Three guardrails close the classic "create a role, attach AdministratorAccess, PassRole it to a Lambda" escalation primitive:

- **`iam:PassRole` is constrained to `lambda.amazonaws.com`** (`Condition: iam:PassedToService`). The deploy role can only hand the roles it creates to Lambda — not to EC2/CodeBuild/etc.
- **`iam:AttachRolePolicy` is allowlisted** (`Condition: iam:PolicyARN`) to exactly the managed policies CDK actually attaches: `AWSLambdaBasicExecutionRole` (the only AWS-managed policy the synth attaches today) plus `LmwfCdkDeployPolicy` itself. Arbitrary policies — including `AdministratorAccess` — can no longer be attached. **If a future stack legitimately needs another managed policy, add its ARN to this allowlist or the deploy fails closed.**
- **`iam:PassRole` / `AttachRolePolicy` are split into their own statements** so the conditions apply only to those actions (a `Condition` on the combined statement would have wrongly gated `CreateRole`/`PutRolePolicy` too).

Not added in code, but recommended: a **permissions boundary on `CreateRole`** (`Condition: StringEquals iam:PermissionsBoundary = <boundary-arn>`). This requires (a) creating a boundary managed policy and (b) configuring CDK to attach it (`@aws-cdk/core:permissionsBoundary` context / `PermissionsBoundary` aspect) so synthesized roles carry it — otherwise every `cdk deploy` fails. Left as a follow-up because it is a coordinated change across bootstrap + app config, not a code-only tweak.

The `CloudFrontDistribution` statement keeps `Resource: "*"`: `cloudfront:CreateDistribution` (and the OAC/Function/Invalidation actions) do not support resource-level ARNs — the distribution ARN does not exist until creation — so `*` is genuinely required by the CloudFront API. The actions are account-scoped and the policy is only reachable post-assume-role, so this is acceptable.

## Applying

AWS Console → IAM → Users → `liftmark-deploy` → Permissions → Create inline policy → paste the JSON → name it `CdkAssumeBootstrapRoles`.

Or via CLI from an admin session:

```bash
aws iam put-user-policy \
  --user-name liftmark-deploy \
  --policy-name CdkAssumeBootstrapRoles \
  --policy-document file://deploy-user-policy.json
```

For the CI user (one-time setup per env):

```bash
# beta
aws --profile liftmark-beta iam create-user --user-name liftmark-ci-deploy-beta
aws --profile liftmark-beta iam put-user-policy \
  --user-name liftmark-ci-deploy-beta \
  --policy-name CdkAssumeBootstrapRolesBeta \
  --policy-document file://ci-deploy-beta-policy.json
aws --profile liftmark-beta iam create-access-key --user-name liftmark-ci-deploy-beta

# prod
aws --profile liftmark-prod iam create-user --user-name liftmark-ci-deploy-prod
aws --profile liftmark-prod iam put-user-policy \
  --user-name liftmark-ci-deploy-prod \
  --policy-name CdkAssumeBootstrapRolesProd \
  --policy-document file://ci-deploy-prod-policy.json
aws --profile liftmark-prod iam create-access-key --user-name liftmark-ci-deploy-prod
```

The `create-access-key` output is the only time the secret is visible — copy `AccessKeyId` + `SecretAccessKey` straight into Concourse:

```bash
fly -t home set-pipeline -p liftmark-validator -c liftmark-validator.yml \
  -v aws_access_key_id=<beta-key>      -v aws_secret_access_key=<beta-secret> \
  -v aws_access_key_id_prod=<prod-key> -v aws_secret_access_key_prod=<prod-secret>
```

### Prod prerequisites (before clicking the deploy gate)

- CDK bootstrap is run in account `825347768149` for both `us-west-2` and `us-east-1` with `--qualifier lmwf --toolkit-stack-name LmwfCdkToolkit` (otherwise the assume-role targets in `ci-deploy-prod-policy.json` won't exist).
- The `liftmark.app` hosted zone gets created by `LmwfProdEdgeStack` — after the first deploy, the registrar's nameservers need to be updated to the new HZ's NS records (`HostedZoneNameServers` output).

## Prerequisites

- Both regions must be CDK-bootstrapped with the `lmwf` qualifier and the `LmwfCdkToolkit` stack name. If you haven't already:

  ```bash
  cdk bootstrap aws://341556346945/us-west-2 \
    --qualifier lmwf --toolkit-stack-name LmwfCdkToolkit

  cdk bootstrap aws://341556346945/us-east-1 \
    --qualifier lmwf --toolkit-stack-name LmwfCdkToolkit
  ```

  **ALWAYS pass `--cloudformation-execution-policies arn:aws:iam::<account>:policy/LmwfCdkDeployPolicy`** to both bootstrap calls so the scoped execution policy (`../deploy-policy.json`) is applied to the CFN deploy role. Omitting the flag falls back to CDK's default `AdministratorAccess` on the deploy role — meaning anyone who can assume `cdk-lmwf-deploy-role` (humans via MFA, CI via the static key) gets full admin in the account. (L11)

  > ⚠️ **Meatspace residual:** the deploy role's `--cloudformation-execution-policies` can only be set at bootstrap time — it cannot be retrofitted from this repo. If a prior bootstrap was run without the flag, the deploy role is still `AdministratorAccess` today regardless of the hardened `deploy-policy.json`. **On the next bootstrap (or a one-off `cdk bootstrap` re-run) of each account, pass the scoped policy flag** to remediate. Verify the current state with `aws cloudformation describe-stacks --stack-name LmwfCdkToolkit` → `CloudFormationExecutionPolicies` output.

  To create or refresh the managed policy:

  ```bash
  # first time
  aws iam create-policy \
    --policy-name LmwfCdkDeployPolicy \
    --policy-document file://../deploy-policy.json

  # subsequent updates
  aws iam create-policy-version \
    --policy-arn arn:aws:iam::341556346945:policy/LmwfCdkDeployPolicy \
    --policy-document file://../deploy-policy.json \
    --set-as-default
  ```

- Bootstrap roles trust the account root (default for `cdk bootstrap` without `--trust` overrides).
- User must have MFA configured and be accessed via aws-vault (or another MFA-prompting flow).

## Why two regions?

CloudFront requires its ACM certificate in `us-east-1`. The deploy is split into `LmwfEdgeStack` (us-east-1, cert only) and `LmwfValidatorStack` (us-west-2, everything else). CDK's `crossRegionReferences` ties them together via SSM parameters.

## Why the `lmwf` qualifier?

The default CDK qualifier (`hnb659fds`) creates roles, buckets, and SSM parameters with names that would be shared by any other project using default bootstrap in the same AWS account. The `lmwf` qualifier plus the `LmwfCdkToolkit` stack name keep all LiftMark CDK infrastructure in its own namespace. It is wired into the code via `cdk.json` (`@aws-cdk/core:bootstrapQualifier` context + `toolkitStackName` top-level field).
