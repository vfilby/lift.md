.PHONY: install build dev

install:
	npm install

dev:
	npm run dev

build:
	npm run build

# Deploys are driven from validator/Makefile — the validator CDK stack
# uploads website/dist to the per-env S3 bucket via BucketDeployment and
# triggers the CloudFront invalidation in the same step. Run:
#
#   cd ../validator && make deploy-beta     # or deploy-prod
#
# That target builds the site (this Makefile's `build`) before invoking cdk.
