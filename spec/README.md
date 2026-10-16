# LiftMark Functional Specification

## Overview

LiftMark is an iOS fitness tracking application built for strength training enthusiasts. It allows users to create, import, and execute structured workout plans, track completed workout sessions with detailed set-level data, manage gym locations and equipment, and integrate with Apple Health, iCloud, and Live Activities.

## Purpose of This Spec

This specification is an **implementation-agnostic functional description** of LiftMark. Its purpose is to enable multi-platform builds (e.g., Android, web, desktop) by documenting **what** the application does, not **how** it is implemented. Any platform that implements the behaviors described in these spec files should produce a functionally equivalent LiftMark experience.

## Glossary

| Term | Definition |
|------|-----------|
| **Workout Plan** | A reusable template defining a sequence of exercises and their target sets. Created by importing LMWF markdown or AI generation. |
| **Session** | A single execution of a workout plan. Tracks actual performance (weights, reps, times) against the plan's targets. Sessions can be active (in progress), paused, or completed. |
| **Exercise** | A named movement within a workout plan or session (e.g., "Bench Press", "Squat"). May include equipment type and freeform notes. |
| **Set** | A single bout of an exercise. Defined by target weight, reps or duration, and optional modifiers. During a session, sets are completed with actual values or skipped. |
| **Rep** | A single repetition of an exercise movement. |
| **Superset** | Two or more exercises performed back-to-back without rest between them. Represented as a group with interleaved sets during execution. |
| **Section** | A named grouping within a workout (e.g., "Warmup", "Cooldown"). Sections organize exercises visually but don't change execution behavior. |
| **LMWF** | LiftMark Workout Format. A custom markdown-based format for defining workout plans. See `liftmark-workout-format/LIFTMARK_WORKOUT_FORMAT_SPEC.md` for the full specification. |
| **Gym** | A named location where the user works out. Each gym has its own set of available equipment. One gym is designated as the default. |
| **Equipment** | A piece of exercise equipment (e.g., "barbell", "dumbbell", "cable machine") associated with a gym. Equipment can be toggled available/unavailable. Plans can be filtered by equipment availability. |
| **Rest Timer** | A countdown timer that starts (automatically or manually) after completing a set. Duration is defined per-set via the `@rest` modifier in LMWF. |
| **Exercise Timer** | A count-up timer for time-based exercises (e.g., planks, holds). Tracks elapsed seconds against a target duration. |
| **AMRAP** | "As Many Reps As Possible." A set type where the user performs reps to failure rather than targeting a specific count. |
| **Drop Set** | A technique where weight is reduced after a set and another set is performed immediately. Marked with the `@dropset` modifier. |
| **Favorite** | A plan can be marked as a favorite for quick filtering on the Plans tab. |
| **Highlights** | Post-workout achievements calculated from session data (e.g., personal records, volume milestones). Displayed on the workout summary screen. |
| **Home Tiles** | Customizable tiles on the home screen showing the user's best weight for selected exercises. Default: Squat, Deadlift, Bench Press, Overhead Press. |

## Spec Directory Structure

```
spec/
  README.md              -- This file. Overview, glossary, and usage guide.
  data-model.md          -- Entities, relationships, constraints, enums.
  navigation.md          -- Tab bar structure, screen hierarchy, navigation flows,
                            parameters, deep links, and gesture behavior.
  accessibility-ids.md   -- Complete registry of testID values organized by screen.
                            The contract between the spec and E2E tests.
  ios-project.md         -- iOS project requirements: Xcode project structure,
                            targets, entitlements, capabilities, App Store
                            deployment, and build settings. Any iOS implementation
                            MUST follow this spec to be deployable.
  screens/               -- Per-screen specs (layout, elements, interactions).
  flows/                 -- Per-flow specs (user journeys, step-by-step).
  services/              -- Per-service specs (AI generation, AI plan editing, backup, CloudKit sync,
                            exercise history, export, file import, HealthKit,
                            Live Activities, LMWF parser, logger, plate calculator,
                            secure storage, workout highlights, workout history).
                            Note: Audio service is explicitly out of scope.
  data/                  -- Data portability contracts (import/export schema,
                            common exercises list).
```

## How Implementations Should Use This Spec

1. **Navigation**: Implement the screen hierarchy and navigation flows described in `navigation.md`. Each screen's purpose, parameters, and transitions are documented.

2. **Test IDs**: Use the IDs in `accessibility-ids.md` as the accessibility/test identifier contract. E2E tests reference these IDs, so implementations must attach them to the corresponding UI elements.

3. **LMWF Parsing**: The `liftmark-workout-format/LIFTMARK_WORKOUT_FORMAT_SPEC.md` file in the main repository defines the workout format. Any implementation must parse and produce LMWF-compliant data.

4. **Data Model**: The glossary above defines the core domain objects. Implementations should model their data layer around these concepts, regardless of the storage technology used.

5. **Platform Adaptations**: Where this spec describes iOS-specific features (HealthKit, Live Activities, iCloud), implementations on other platforms should either provide equivalent functionality or gracefully omit those features.
