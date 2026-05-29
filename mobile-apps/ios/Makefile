.PHONY: build test test-unit test-ui clean resolve generate release-alpha screenshots

SCHEME = LiftMark
PROJECT = LiftMark.xcodeproj
DESTINATION = 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0'

# App Store screenshot capture. Defaults to the 6.9" Pro Max simulator
# (1320×2868), which App Store Connect now accepts in lieu of 6.5"/6.7"
# slots. Override SCREENSHOT_DESTINATION to target a different simulator
# (e.g. iPhone 14 Plus for legacy 1284×2778 slots).
SCREENSHOT_DESTINATION = 'platform=iOS Simulator,name=iPhone 17 Pro Max'
SCREENSHOT_RESULT_BUNDLE = build/Screenshots.xcresult
SCREENSHOT_OUTPUT_DIR = Screenshots

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

# Run all tests (unit + UI)
test:
	xcodebuild test -scheme $(SCHEME) -project $(PROJECT) -destination $(DESTINATION)

# Run unit tests only (fast, no simulator UI needed)
test-unit:
	xcodebuild test -scheme $(SCHEME) -project $(PROJECT) \
		-only-testing:LiftMarkTests \
		-destination $(DESTINATION)

# Run UI tests only
test-ui:
	xcodebuild test -scheme $(SCHEME) -project $(PROJECT) \
		-only-testing:LiftMarkUITests \
		-destination $(DESTINATION)

clean:
	xcodebuild clean -scheme $(SCHEME)
	rm -rf .build build

# Capture App Store screenshots. Drives the screenshot UI test scenario,
# writes a result bundle, then extracts named PNG attachments into
# $(SCREENSHOT_OUTPUT_DIR)/. Re-run any time after app changes.
screenshots:
	@rm -rf $(SCREENSHOT_RESULT_BUNDLE) $(SCREENSHOT_OUTPUT_DIR)
	@mkdir -p $(SCREENSHOT_OUTPUT_DIR)
	SIMCTL_CHILD_SCREENSHOTS=1 xcodebuild test -scheme $(SCHEME) -project $(PROJECT) \
		-only-testing:LiftMarkUITests/LiftMarkUITests/testScreenshots \
		-destination $(SCREENSHOT_DESTINATION) \
		-resultBundlePath $(SCREENSHOT_RESULT_BUNDLE)
	./scripts/extract-screenshots.sh $(SCREENSHOT_RESULT_BUNDLE) $(SCREENSHOT_OUTPUT_DIR)
	@echo ""
	@echo "Screenshots written to $(SCREENSHOT_OUTPUT_DIR)/"
	@ls -1 $(SCREENSHOT_OUTPUT_DIR)/

# Manually re-trigger the release pipeline against current main.
# Pushes to main also trigger it automatically; use this to re-run without an empty commit.
release-alpha:
	@echo "Triggering release pipeline..."
	gh workflow run "[iOS] Release Pipeline" --ref main
	@echo "Workflow triggered. Monitor at: https://github.com/$$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions"
