.PHONY: build test test-smoke test-unit test-ui clean resolve generate release-alpha screenshots

SCHEME = LiftMark
PROJECT = LiftMark.xcodeproj
DESTINATION = 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0'

# App Store screenshot capture. capture-screenshots.sh drives the screenshot
# UI scenario on its OWN throwaway simulators — iPhone 17 Pro Max (1320×2868,
# the 6.9" slot) and iPad Pro 13-inch M4 (2064×2752, the 13" slot) — capturing
# both light and dark appearance into Screenshots/<device>/{light,dark}/.
# Pass --only iphone (or ipad) via SCREENSHOT_ARGS to capture just one device.
# Set SCREENSHOT_UDID to reuse a specific simulator (kept, not deleted), and
# add --keep via SCREENSHOT_ARGS to leave created sims booted for inspection.
SCREENSHOT_UDID =
SCREENSHOT_ARGS =

resolve:
	swift package resolve

generate: Config/Sentry.xcconfig
	./scripts/gen-sentry-config.sh
	xcodegen generate

# Auto-copy the example xcconfig on first generate so fresh checkouts work.
# Contributors should replace the placeholder DSN with their own for Sentry to
# send events — see spec/services/sentry.md.
Config/Sentry.xcconfig:
	@cp Config/Sentry.xcconfig.example Config/Sentry.xcconfig
	@echo "Created Config/Sentry.xcconfig from .example — edit it to add your Sentry DSN if you want crash reports."

build:
	xcodebuild -scheme $(SCHEME) -project $(PROJECT) -destination $(DESTINATION) build

# Run the entire suite (unit + full UI) via the Full test plan. This is what
# the nightly CI workflow runs; Smoke is the default plan, so -testPlan Full is
# required here to avoid silently shrinking to the PR-gate subset.
test:
	xcodebuild test -scheme $(SCHEME) -project $(PROJECT) -testPlan Full -destination $(DESTINATION)

# Run exactly the PR gate: full unit suite + render-only UI subset (fast).
test-smoke:
	xcodebuild test -scheme $(SCHEME) -project $(PROJECT) -testPlan Smoke -destination $(DESTINATION)

# Run unit tests only (fast, no simulator UI needed)
test-unit:
	xcodebuild test -scheme $(SCHEME) -project $(PROJECT) \
		-testPlan Full -only-testing:LiftMarkTests \
		-destination $(DESTINATION)

# Run UI tests only (full UI suite — Full plan, not the Smoke subset)
test-ui:
	xcodebuild test -scheme $(SCHEME) -project $(PROJECT) \
		-testPlan Full -only-testing:LiftMarkUITests \
		-destination $(DESTINATION)

clean:
	xcodebuild clean -scheme $(SCHEME)
	rm -rf .build build

# Capture App Store screenshots in light + dark on an isolated simulator.
# See scripts/capture-screenshots.sh. Re-run any time after app changes.
screenshots:
	./scripts/capture-screenshots.sh $(if $(SCREENSHOT_UDID),--udid $(SCREENSHOT_UDID)) $(SCREENSHOT_ARGS)

# Manually re-trigger the release pipeline against current main.
# Pushes to main also trigger it automatically; use this to re-run without an empty commit.
release-alpha:
	@echo "Triggering release pipeline..."
	gh workflow run "[iOS] Release Pipeline" --ref main
	@echo "Workflow triggered. Monitor at: https://github.com/$$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions"
