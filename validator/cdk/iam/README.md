# Deploy User IAM Policies

Two inline policies for two IAM users:

- **`deploy-user-policy.json`** — human user `liftmark-deploy`, MFA-gated. Used by Vincent's CLI via SSO. (NOTE: file still references the pre-move account `341556346945`; current beta is `323146837100`.)
- **`ci-deploy-beta-policy.json`** — CI user `liftmark-ci-deploy-beta` in account `323146837100`, no MFA (machine creds can't satisfy MFA). Used by Concourse to deploy `LmwfBetaEdgeStack` + `LmwfBetaValidatorStack`.

Both grant `sts:AssumeRole` on the LiftMark-namespaced CDK bootstrap roles (`cdk-lmwf-*`) in both `us-west-2` (Lambda + API Gateway origin + S3 + CloudFront) and `us-east-1` (CloudFront cert). All real permissions live in the bootstrap roles themselves, scoped by `../deploy-policy.json`, which CDK maintains.

## Applying

AWS Console → IAM → Users → `liftmark-deploy` → Permissions → Create inline policy → paste the JSON → name it `CdkAssumeBootstrapRoles`.

Or via CLI from an admin session:

```bash
aws iam put-user-policy \
  --user-name liftmark-deploy \
  --policy-name CdkAssumeBootstrapRoles \
  --policy-document file://deploy-user-policy.json
```

For the CI user (one-time setup against beta account):

```bash
# create user, attach policy, mint access key
aws --profile liftmark-beta iam create-user --user-name liftmark-ci-deploy-beta
aws --profile liftmark-beta iam put-user-policy \
  --user-name liftmark-ci-deploy-beta \
  --policy-name CdkAssumeBootstrapRolesBeta \
  --policy-document file://ci-deploy-beta-policy.json
aws --profile liftmark-beta iam create-access-key --user-name liftmark-ci-deploy-beta
```

The `create-access-key` output is the only time the secret is visible — copy `AccessKeyId` + `SecretAccessKey` straight into Concourse (`fly set-pipeline -v aws_access_key_id=… -v aws_secret_access_key=…`).

## Prerequisites

- Both regions must be CDK-bootstrapped with the `lmwf` qualifier and the `LmwfCdkToolkit` stack name. If you haven't already:

  ```bash
  cdk bootstrap aws://341556346945/us-west-2 \
    --qualifier lmwf --toolkit-stack-name LmwfCdkToolkit

  cdk bootstrap aws://341556346945/us-east-1 \
    --qualifier lmwf --toolkit-stack-name LmwfCdkToolkit
  ```

  Pass `--cloudformation-execution-policies arn:aws:iam::341556346945:policy/LmwfCdkDeployPolicy` to either bootstrap call if you want the scoped execution policy (`../deploy-policy.json`) applied to the CFN deploy role. Omitting that flag uses CDK's default `AdministratorAccess` for the deploy role, which is acceptable for a single-project account.

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
