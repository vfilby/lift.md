# LiftMark Build

# ── aws-vault wrapper (mirrors validator/Makefile) ──
ifeq ($(shell command -v aws-vault-op 2>/dev/null),)
$(warning aws-vault-op not found — falling back to aws-vault (expect passphrase + MFA prompts))
AWS_VAULT_CMD := aws-vault
else
AWS_VAULT_CMD := aws-vault-op
endif

AWS_VAULT ?= $(AWS_VAULT_CMD) exec liftmark-validator-deploy --

.PHONY: help build test test-smoke test-unit test-ui generate release-alpha tools-test tools-validate tools-generate spec-generate spec-check website-install website-dev website-build website-deploy

help:
	@echo "LiftMark Build"
	@echo ""
	@echo "App (mobile-apps/ios/):"
	@echo "  make build          - Build the app"
	@echo "  make test           - Run all tests (full UI suite)"
	@echo "  make test-smoke     - Run the PR gate (unit + render-only UI subset)"
	@echo "  make test-unit      - Run unit tests only"
	@echo "  make test-ui        - Run UI tests only"
	@echo "  make generate       - Regenerate Xcode project"
	@echo "  make release-alpha  - Trigger TestFlight build"
	@echo ""
	@echo "Spec:"
	@echo "  make spec-generate  - Generate LMWF spec from template (validates examples)"
	@echo "  make spec-check     - Validate spec examples without generating"
	@echo ""
	@echo "Tools:"
	@echo "  make tools-test       - Run tools tests"
	@echo "  make tools-validate   - Validate JSON export (FILE=path.json)"
	@echo "  make tools-generate   - Generate export fixture (ARGS='--single -o out.json')"
	@echo ""
	@echo "Website (workoutformat.liftmark.app):"
	@echo "  make website-install  - Install Astro dependencies"
	@echo "  make website-dev      - Start local dev server"
	@echo "  make website-build    - Build static site into website/dist/"
	@echo "  make website-deploy   - Build, sync to S3, and invalidate CloudFront"

build:
	cd mobile-apps/ios && make build

test:
	cd mobile-apps/ios && make test

test-smoke:
	cd mobile-apps/ios && make test-smoke

test-unit:
	cd mobile-apps/ios && make test-unit

test-ui:
	cd mobile-apps/ios && make test-ui

generate:
	cd mobile-apps/ios && make generate

release-alpha:
	cd mobile-apps/ios && make release-alpha

# Spec
spec-generate:
	cd liftmark-workout-format && npx --prefix=../validator tsx generate-spec.ts

spec-check:
	cd liftmark-workout-format && npx --prefix=../validator tsx generate-spec.ts --check

# Tools
tools-test:
	cd tools && make test

tools-validate:
	@if [ -z "$(FILE)" ]; then echo "Usage: make tools-validate FILE=path/to/file.json"; exit 1; fi
	python tools/validate_export.py $(FILE)

tools-generate:
	python tools/generate_export.py $(ARGS)

# ── Website (workoutformat.liftmark.app) ──
# Infrastructure (S3 bucket + CloudFront distribution) is managed by
# validator/cdk. Deploy infra with `cd validator && make deploy`. The
# targets below only handle the static site content.

website-install:
	cd website && npm install

website-dev:
	cd website && npm run dev

website-build:
	cd website && npm run build

# Deploy: two-pass sync for cache headers (hashed assets long-cache,
# everything else short-cache), then invalidate CloudFront.
#
# Resolves BUCKET and DIST in this order:
#   1. If set in the environment: BUCKET=... DIST=... make website-deploy
#   2. Otherwise, read from validator/cdk/outputs.json (written by `make deploy`)
# The deploy user does not have cloudformation:DescribeStacks directly —
# that's held by the assumed CDK deploy role. Outputs file is the cleanest
# way to pass deploy-time values to follow-up targets.
OUTPUTS_FILE := validator/cdk/outputs.json

website-deploy: website-build
	@if [ -z "$$BUCKET" ]; then \
	    if [ -f $(OUTPUTS_FILE) ]; then \
	        BUCKET=$$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["LmwfValidatorStack"]["SiteBucketName"])' $(OUTPUTS_FILE)); \
	    fi; \
	fi; \
	if [ -z "$$DIST" ]; then \
	    if [ -f $(OUTPUTS_FILE) ]; then \
	        DIST=$$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["LmwfValidatorStack"]["DistributionId"])' $(OUTPUTS_FILE)); \
	    fi; \
	fi; \
	if [ -z "$$BUCKET" ] || [ -z "$$DIST" ]; then \
	    echo "error: BUCKET/DIST not set and $(OUTPUTS_FILE) not found."; \
	    echo "Either run 'cd validator && make deploy' first, or override:"; \
	    echo "  BUCKET=<name> DIST=<id> make website-deploy"; \
	    exit 1; \
	fi; \
	echo "bucket: $$BUCKET"; \
	echo "distribution: $$DIST"; \
	echo "→ sync immutable hashed assets (long cache)"; \
	$(AWS_VAULT) aws s3 sync website/dist/ s3://$$BUCKET/ \
	    --exclude "*" --include "_astro/*" \
	    --cache-control "public, max-age=31536000, immutable"; \
	echo "→ sync remaining files (short cache) with prune"; \
	$(AWS_VAULT) aws s3 sync website/dist/ s3://$$BUCKET/ \
	    --exclude "_astro/*" \
	    --cache-control "public, max-age=300" \
	    --delete; \
	echo "→ invalidate CloudFront"; \
	$(AWS_VAULT) aws cloudfront create-invalidation \
	    --distribution-id $$DIST \
	    --paths "/*" \
	    --query 'Invalidation.Id' --output text
