# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Ground Rules

1. Spec-based Project

- Anytime you add a feature, fix a bug, or performance maintenance you first update the spec
- Spec changes should always include tests tests required to validate the changes.
- Once the spec is correct update the app to match the spec.

2. Delegate to subagents and teams

- Use sub-agent delegation and agent teams liberally to reduce context degradation.
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

3. Verification Before Done
- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself, "Would a staff engineer approve this?"
- Run tests, check logs, and demonstrate correctness.

4. Demand Elegance (Balanced)
- For non-trivial changes, pause and ask, "Is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes
- Don't over-engineer.
- Challenge your own work before presenting it



## Repository Structure

- `mobile-apps/ios/` — Native Swift iOS app
- `validator/` — LMWF validation service (TypeScript, AWS Lambda)
- `liftmark-workout-format/` — LiftMark Workout Format specification (CC BY-SA 4.0)
- `website/` — Project website
- `spec/` — Shared specifications
- `e2e-spec/` — Shared E2E test specifications
- `docs/` — Documentation
- `assets/` — Shared assets
- `tools/` — Data export/validation test tools (Python)
- `prompts/` — Prompt templates
- `test-workouts/` — Test workout files
- `test-fixtures/` — Test fixture files

## Build & Development

All app commands run from `mobile-apps/ios/`:

```bash
# From repo root — delegating Makefile
make build            # Build the app
make test             # Run all tests
make test-unit        # Run unit tests only
make test-ui          # Run UI tests only
make generate         # Regenerate Xcode project
make release-alpha    # Trigger TestFlight build

# Or from mobile-apps/ios/ directly
cd mobile-apps/ios
make build
make test
make test-unit
make test-ui
make generate
make release-alpha
```

## Release

Always push commits to main before releasing — `make release-alpha` creates a GitHub release tag that triggers a TestFlight build, but does NOT push commits.

### CloudKit schema gate

If a release touches `mobile-apps/ios/LiftMark/Services/CKRecordMapper.swift` (or `CKRecordMapper+SetMeasurement.swift`), the CloudKit Production schema must be promoted via CloudKit Dashboard BEFORE the build reaches devices, or every save against the affected record type fails with CKError 12 / 2006 and the data silently never reaches iCloud.

Pre-flight check:

```bash
python tools/check_ckrecord_drift.py
```

Exits non-zero if any new `record["..."]` field has been added since the last `deploy/*` tag. When it fires, update `mobile-apps/ios/cloudkit-schema.ckdb`, import it via CloudKit Dashboard, and "Deploy Schema Changes" to Production before releasing.

## Architecture

Native Swift iOS fitness tracking app.

### Directory Layout (mobile-apps/ios/)

```
mobile-apps/ios/
  LiftMark.xcodeproj/
  LiftMark/
    App/                    -- @main entry, ContentView
    Models/                 -- Data types
    Views/                  -- All SwiftUI views (grouped by feature)
    Database/               -- GRDB layer
    Services/               -- Business logic
    Stores/                 -- @Observable state
    Navigation/             -- Routing
    Theme/                  -- Visual constants
    Utils/                  -- Helpers
    Resources/
      Assets.xcassets       -- App icon, colors, images
      Sounds/               -- Audio files for timers
  LiftMarkTests/            -- Unit tests
  LiftMarkUITests/          -- E2E tests (YAML runner)
  LiftMarkWidgets/          -- Live Activity widget extension
```

### LiftMark Workout Format (LMWF)

Custom markdown-based format for workout plans. Full spec in `liftmark-workout-format/LIFTMARK_WORKOUT_FORMAT_SPEC.md`. Licensed under CC BY-SA 4.0.

```markdown
# Push Day
@tags: strength, upper
@units: lbs

## Bench Press
- 135 x 5
- 185 x 5
- 225 x 5
```

## License

- **App code**: [Mozilla Public License 2.0](LICENSE)
- **LMWF spec**: [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)
