# LiftMark

[![iOS Release Pipeline](https://github.com/vfilby/lift.md/actions/workflows/release-pipeline.yml/badge.svg?branch=main)](https://github.com/vfilby/lift.md/actions/workflows/release-pipeline.yml)
[![iOS Nightly UI Suite](https://github.com/vfilby/lift.md/actions/workflows/swift-nightly.yml/badge.svg?branch=main)](https://github.com/vfilby/lift.md/actions/workflows/swift-nightly.yml)
[![Validator](https://github.com/vfilby/lift.md/actions/workflows/validator-ci.yml/badge.svg?branch=main)](https://github.com/vfilby/lift.md/actions/workflows/validator-ci.yml)

Public beta: https://testflight.apple.com/join/u8EJFzYu

I have tried many different fitness apps and programs to help me create and track workouts but they tend to be limited in what they allow you to do and they make it difficult to import of export workouts.  I have spent nearly as much time "creating" or "tweaking" workouts as I have actually working out in some cases. I want something that gives me all the benefits of tracking without the tedium.

Liftmark let's you import workouts written in a simple text based format - LiftMark Workout Format (LMWF) - and create a structured workout that you can use to track during the workout and see historical stats as well.

With GenAI at our finger tips it is incredibly easy to create and import workouts.

## Features

- **Import workouts** from plain-text LMWF markdown format
- **Browse and search** workouts by name or tags
- **Active workout tracking** — start a session, log sets/reps/weight in real time
- **Rest timer** with configurable durations
- **Workout history** — review past sessions and track progress
- **Exercise history** — see per-exercise trends over time
- **Gym & equipment management** — filter workouts by available equipment
- **Export & share** — export workout history as JSON, share individual workouts
- **HealthKit integration** — sync workouts to Apple Health
- **Live Activities** — track active workout from the lock screen
- **AI workout generation** — generate workouts via Anthropic API
- **Dark mode** with system auto-detection
- **Superset & section support** in workout plans

## Usage

### Importing a Workout

1. Tap "Import Workout" on the home screen
2. Paste your workout in LMWF format:

```markdown
# Push Day A
@tags: push, chest, shoulders
@units: lbs

## Bench Press
- 135 x 10 @rest: 120s
- 185 x 8 @rest: 120s
- 225 x 5 @rest: 120s

## Incline Dumbbell Press
- 60 x 12
- 60 x 12
- 60 x 12
```

3. Tap "Import" to save

You can also share `.txt` or `.md` files directly to LiftMark from other apps.

### Viewing Workouts

- Browse all workouts on the "Workouts" tab
- Search by name or tags
- Filter by available gym equipment
- Tap a workout to view details

### Tracking a Workout

- Tap "Start Workout" from a workout detail screen
- Log actual weight and reps for each set
- Rest timer appears between sets
- View workout summary on completion

### History

- Review completed workouts on the "History" tab
- Tap a session to see full details
- Export history as JSON for backup

### Settings

Configure your preferences:
- **Weight Unit**: LBS or KG (default for new workouts)
- **Theme**: Light, Dark, or Auto
- **Gym Management**: Define gyms and available equipment
- **HealthKit**: Sync workouts to Apple Health
- **Live Activities**: Track workouts from lock screen
- **AI Generation**: Configure API key for AI workout generation

## LMWF Format

The LiftMark Workout Format is a markdown-based syntax for defining workouts. The LMWF specification is openly licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) — anyone is free to use, adapt, and build on it.

See `liftmark-workout-format/LIFTMARK_WORKOUT_FORMAT_SPEC.md` for the full specification.

## Tech Stack

- **Swift 6.0** / SwiftUI
- **GRDB.swift** for SQLite database
- **HealthKit**, **ActivityKit**, **CloudKit** via Apple frameworks
- **XCTest** / **XCUITest** for unit and UI testing

See `CLAUDE.md` for build commands and developer documentation.

## License

The application code is licensed under the [Mozilla Public License 2.0](LICENSE).

The [LMWF specification](liftmark-workout-format/LIFTMARK_WORKOUT_FORMAT_SPEC.md) is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
