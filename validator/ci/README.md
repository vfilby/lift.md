# Concourse pipeline for `liftmark-validator`

`pipeline.yml` is the source of truth for the Concourse side of the
validator deploy. It is intentionally kept structurally parallel to
`.github/workflows/validator-ci.yml` so both CI systems run the same
six-stage flow:

```
validate (typecheck + test, parallel)
   └─► build (validator/dist + website/dist)
         └─► deploy-beta (cdk deploy → Lambda + site upload)
               └─► smoke-beta
                     └─► deploy-prod
                           └─► smoke-prod
```

If you change one pipeline, change the other.

## Set / update the pipeline

The pipeline is paused by default ("paused for the demo" per
[`ad2b5ce`](../../.git)). Re-apply it with:

```bash
fly -t <target> set-pipeline -p liftmark-validator \
    -c validator/ci/pipeline.yml \
    -l validator/ci/vars.local.yml

fly -t <target> unpause-pipeline -p liftmark-validator
```

`<target>` is whatever you named your `fly login` target (see your
`~/.flyrc`).

## Variables file (NOT committed)

`vars.local.yml` is git-ignored — it holds the AWS credentials Concourse
uses to assume the per-env CDK bootstrap roles. Layout:

```yaml
aws_access_key_id_beta:     AKIA…
aws_secret_access_key_beta: …
aws_access_key_id_prod:     AKIA…
aws_secret_access_key_prod: …
```

The credential pairs correspond to the CI deploy IAM users created by
`validator/cdk/iam/ci-deploy-{beta,prod}-policy.json`. Those users only
hold `sts:AssumeRole` on the env's CDK bootstrap roles — no static perms
on Lambda, S3, or CloudFront — so leaking them is bounded by what those
roles can do.

Rotate by issuing a new access key in IAM, updating `vars.local.yml`,
re-running `fly set-pipeline`, then deleting the old key in IAM.

## Why both CI systems?

We're currently evaluating GHA vs Concourse for this project. To make the
comparison honest, the deploy logic itself lives in CDK
(`validator/cdk/stack.ts` — including the website upload via
`BucketDeployment`), so both pipelines do essentially the same thing:
build, then `cdk deploy`. The pipeline files only differ in how each
system expresses "trigger on push to main, run these jobs in this order,
gate the next on the previous". That keeps the two systems verifiably in
sync — divergence shows up as a structural diff in this file vs the GHA
workflow, not as a subtle behavioural drift.
