.PHONY: test build deploy diff destroy typecheck install install-cdk bundle sync-dict

# Wrap AWS-calling commands in aws-vault-op, which pulls the file-backend
# passphrase and MFA TOTP from 1Password before invoking aws-vault. Falls back
# to plain aws-vault if the wrapper isn't installed. MFA is enforced via
# ~/.aws/config. Override with AWS_VAULT= to bypass (e.g. in CI where
# credentials come from the environment).
ifeq ($(shell command -v aws-vault-op 2>/dev/null),)
$(warning aws-vault-op not found — falling back to aws-vault (expect passphrase + MFA prompts))
AWS_VAULT_CMD := aws-vault
else
AWS_VAULT_CMD := aws-vault-op
endif

AWS_VAULT ?= $(AWS_VAULT_CMD) exec liftmark-validator-deploy --

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

# ── Bundle Lambda code ──
bundle: sync-dict
	npx esbuild src/handler.ts \
		--bundle \
		--platform=node \
		--target=node22 \
		--outfile=dist/handler.js \
		--format=cjs \
		--loader:.json=json

# ── CDK commands ──
# Both stacks deploy together: LmwfEdgeStack (us-east-1 cert) and
# LmwfValidatorStack (Lambda + API + S3 + CloudFront).
build: bundle
	cd cdk && $(AWS_VAULT) npx cdk synth --all

diff: bundle
	cd cdk && $(AWS_VAULT) npx cdk diff --strict --all

deploy: bundle
	cd cdk && $(AWS_VAULT) npx cdk deploy --all --require-approval any-change \
	    --outputs-file outputs.json

destroy:
	cd cdk && $(AWS_VAULT) npx cdk destroy --all
