# XCUITest Runner

Reads the shared YAML E2E scenario files and executes them as XCUITest tests against the Swift iOS app.

## Files

- **TestSpecRunner.swift** — Loads scenario YAML files, parses them into `TestScenario` models via [Yams](https://github.com/jpsim/Yams), and orchestrates execution via `ActionAdapter`. Embeds a small `YAMLValue` wrapper that preserves the keyed-subscript API used throughout the runner.
- **ActionAdapter.swift** — Maps each YAML action type (`tap`, `waitFor`, `expect`, etc.) to XCUITest API calls.

## Integration

These files are consumed by the XCUITest target at `mobile-apps/ios/LiftMarkUITests/` (via symlinks). To add them to an Xcode project:

1. Add both `.swift` files to the UI test target.
2. Add the Yams SPM package as a **test-target-only** dependency (do not link it from the app target).
3. Ensure the test target can access `e2e-spec/scenarios/` and `e2e-spec/fixtures/` at runtime.
4. Set the `PROJECT_DIR` environment variable in the test scheme, or rely on `#filePath` resolution.

## Timeout scaling (slow runners)

Every wait in `ActionAdapter` is multiplied by `UITestTiming.scale`, read once from the `UITEST_TIMEOUT_SCALE` environment variable in the test-runner process (default `1.0`). On a slow CI host — e.g. an older Intel Mac, where simulator boot, app launch, and animations run 2–3× slower than Apple Silicon — bump it so the suite absorbs the extra latency without loosening timeouts on fast dev machines:

```bash
xcodebuild test -scheme LiftMark -project LiftMark.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' \
  -only-testing:LiftMarkUITests \
  UITEST_TIMEOUT_SCALE=2.5
```

The test-runner process does **not** inherit the host shell's environment (nor `SIMCTL_CHILD_*`), so the value is passed as a build setting on the `xcodebuild` line and expanded into the runner's environment via the test scheme (`project.yml` → `schemes.LiftMark.test.environmentVariables: UITEST_TIMEOUT_SCALE: "$(UITEST_TIMEOUT_SCALE)"`). Unset (e.g. local `make test-ui`) → `1.0`. The runner logs the resolved value at start: `[UITestTiming] UITEST_TIMEOUT_SCALE=2.5 (all UI-test timeouts ×2.5)`.

Note: raising the scale only adds wall-clock on *failures* (and any genuinely slow element) — a passing wait returns as soon as the element appears, so a generous scale is cheap for green runs.

## Dependencies

YAML parsing is delegated to [Yams](https://github.com/jpsim/Yams) — a libyaml-backed Swift library used by SwiftLint and SourceKitten. It handles the full YAML 1.1 core schema (mappings, sequences, scalars, flow arrays, comments, quoted strings) with battle-tested behavior.

Yams is scoped to the UI test target only; the app binary does not link it.
