.PHONY: install build deploy-beta deploy-prod dev

install:
	npm install

dev:
	npm run dev

build:
	npm run build

deploy-beta: build
	aws s3 sync dist/ s3://liftmark-beta-site-323146837100/ \
	  --profile liftmark-beta --delete
	@DIST_ID=$$(jq -r '."LmwfBetaValidatorStack"."DistributionId"' ../validator/cdk/outputs-beta.json); \
	  aws cloudfront create-invalidation --profile liftmark-beta \
	    --distribution-id $$DIST_ID --paths "/*"

deploy-prod: build
	# Mirror of deploy-beta — wired in once liftmark-prod-site bucket exists.
	@echo "Prod deploy not yet wired — pending prod account migration"
	@exit 1
