.PHONY: test test-watch typecheck install install-cdk bundle sync-dict \
        website-build \
        dev-up dev-down dev-bootstrap \
        synth diff-beta diff-prod deploy-beta deploy-prod \
        destroy-beta destroy-prod sso-login

# ── App dependencies ──
install:
	npm install

# ── CDK dependencies ──
install-cdk:
	cd cdk && npm install

# ── Tests ──
test:
	npx vitest run

test-watch:
	npx vitest

typecheck:
	npx tsc --noEmit

# ── Sync exercise dictionary from spec/ canonical source ──
sync-dict:
	cp ../spec/data/exercise-dictionary.json src/data/exercise-dictionary.json

# ── Local dev stack (DynamoDB Local + Mailpit in Docker + table bootstrap) ──
# Mailpit web UI: http://localhost:8025  (SMTP listener on localhost:1025)
dev-up:
	docker compose up -d
	@echo "Waiting for DynamoDB Local to become healthy..."
	@until docker compose ps dynamodb-local --format json 2>/dev/null | grep -q '"Health":"healthy"'; do sleep 0.5; done
	@echo "Waiting for Mailpit to become healthy..."
	@until docker compose ps mailpit --format json 2>/dev/null | grep -q '"Health":"healthy"'; do sleep 0.5; done
	@echo "Mailpit UI: http://localhost:8025"
	npx tsx scripts/ddb-local-bootstrap.ts

dev-bootstrap:
	npx tsx scripts/ddb-local-bootstrap.ts

dev-down:
	docker compose down

# ── Bundle Lambda code ──
# @node-rs/argon2 ships a platform-specific .node binary that esbuild can't
# inline. We mark it external and install the linux-arm64 variant into
# dist/node_modules at bundle time. Lambda runtime requires it from there.
bundle: sync-dict
	rm -rf dist
	mkdir -p dist
	npx esbuild src/handler.ts \
		--bundle \
		--platform=node \
		--target=node22 \
		--outfile=dist/handler.js \
		--format=cjs \
		--loader:.json=json \
		--external:@node-rs/argon2
	@printf '{"dependencies":{"@node-rs/argon2":"^2.0.2"}}\n' > dist/package.json
	# --cpu/--os/--libc tells npm to install the Lambda-platform variant of
	# the argon2 .node binary even when bundling from a different host. We
	# need optional deps here — that's how napi-rs ships its binaries.
	cd dist && npm install \
		--cpu=arm64 --os=linux --libc=glibc \
		--omit=dev --no-audit --no-fund --no-package-lock --silent

# ── Website build ──
# CDK's BucketDeployment in stack.ts uploads ../website/dist to the per-env
# site bucket. Building here (not inside cdk synth) keeps the CDK app pure
# TS and the build tool boundary explicit.
website-build:
	cd ../website && npm ci --no-audit --no-fund && npm run build

# ── CDK commands ──
# Auth: AWS SSO via `aws sso login --sso-session liftmark`. Each env has
# its own profile (liftmark-beta, liftmark-prod) configured in ~/.aws/config.
# Beta and prod each get two stacks: an edge stack (us-east-1, hosted zone +
# CloudFront cert) and a validator stack (main region, Lambda + API + DDB +
# CloudFront + DNS + alarms).

sso-login:
	aws sso login --sso-session liftmark

# Credential-free; just synth all stacks to check the templates compile.
synth:
	cd cdk && npx cdk synth --no-staging

diff-beta: bundle website-build
	cd cdk && npx cdk diff --profile liftmark-beta --strict \
	    LmwfBetaEdgeStack LmwfBetaValidatorStack

diff-prod: bundle website-build
	cd cdk && npx cdk diff --profile liftmark-prod --strict \
	    LmwfProdEdgeStack LmwfProdValidatorStack

# Deploy metadata: commit SHA + ISO 8601 UTC timestamp, surfaced via the
# /version endpoint and X-Validator-Version response header.
BUILD_COMMIT    := $(shell git rev-parse HEAD)
BUILD_TIMESTAMP := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

deploy-beta: bundle website-build
	cd cdk && npx cdk deploy --profile liftmark-beta --require-approval never \
	    --context buildCommit=$(BUILD_COMMIT) \
	    --context buildTimestamp=$(BUILD_TIMESTAMP) \
	    --outputs-file outputs-beta.json \
	    LmwfBetaEdgeStack LmwfBetaValidatorStack

deploy-prod: bundle website-build
	cd cdk && npx cdk deploy --profile liftmark-prod --require-approval any-change \
	    --context buildCommit=$(BUILD_COMMIT) \
	    --context buildTimestamp=$(BUILD_TIMESTAMP) \
	    --outputs-file outputs-prod.json \
	    LmwfProdEdgeStack LmwfProdValidatorStack

destroy-beta:
	cd cdk && npx cdk destroy --profile liftmark-beta \
	    LmwfBetaEdgeStack LmwfBetaValidatorStack

destroy-prod:
	cd cdk && npx cdk destroy --profile liftmark-prod \
	    LmwfProdEdgeStack LmwfProdValidatorStack
