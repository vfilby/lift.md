# LiftMark Workout Format (LMWF) Specification v1.0

> This specification is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
> See `LICENSE` for details.

## Overview

The LiftMark Workout Format (LMWF) is a markdown-based format designed for easy workout creation and import. It's optimized to be:

- **LLM-Friendly**: Simple structure that AI assistants can easily generate
- **Human-Readable**: Clear syntax that humans can write and edit
- **Flexible**: Supports simple to advanced workout tracking
- **Extensible**: Easy to add new features without breaking existing workouts

---

## Table of Contents

1. [Basic Structure](#basic-structure)
2. [Workout Header](#workout-header)
3. [Exercise Blocks](#exercise-blocks)
4. [Set Format](#set-format)
5. [Modifiers](#modifiers)
6. [Examples](#examples)
7. [Validation Rules](#validation-rules)
8. [Edge Cases](#edge-cases)
9. [Future Extensions](#future-extensions)

---

## Basic Structure

Every workout follows this hierarchical structure:

```
# [Workout Name]
[Optional freeform notes/description]

## [Exercise Name]
[Optional freeform notes]
- [Set 1]
- [Set 2]
- [Set N]

## [Next Exercise]
...
```

**Key Principles:**
- **One Workout Per File**: Each markdown file contains a single workout
- **Flexible Headers**: Workout can be any header level (H1-H6), exercise must be one level below
- **Freeform Notes**: Any text between headers is treated as notes
- **Minimal Metadata**: No required `@` metadata, keep it simple
- **Name = Header**: The header text is the name (no "Workout:" prefix needed)

---

## Workout Header

### Required
- Any header level (H1-H6) - The header text is the workout name

### Optional Metadata
- `@tags: [tag1, tag2, ...]` - Comma-separated tags for organization
- `@units: [lbs|kg]` - Default weight unit for this workout (if not specified on individual sets)
- **Freeform notes**: Any text after the header (before first exercise) is treated as workout notes

### Examples

**Minimal:**
```markdown
# Push Day
```

**With freeform notes:**
<!-- EXAMPLE: valid/push-day-with-notes.md -->

**With tags:**
<!-- EXAMPLE: valid/push-day-with-tags.md -->

**With default units:**
<!-- EXAMPLE: valid/push-day-with-units.md -->

**Flexible header levels for document organization:**
<!-- EXAMPLE: valid/flexible-headers.md -->

Note: The workout is "Week 1 - Day 1: Push" (the first header with exercises). Headers above it are for document organization.

---

## Exercise Blocks

### Required
- Header one level below workout header - The header text is the exercise name

### Optional Metadata
- `@type: [equipment]` - Freeform equipment type (e.g., `barbell`, `dumbbell`, `cable`, `resistance band`, `kettlebell`) - completely optional
- **Freeform notes**: Any text after the exercise header (before first set) is treated as exercise notes

### Exercise Name Resolution

Exercise names are permissive — any string is a valid exercise. However, downstream features (barbell math, history matching, muscle-group tagging) key on **canonical names** drawn from a bundled exercise dictionary.

The validator and the app share a curated alias table (`spec/data/exercise-dictionary.json`). When a written name matches a known alias (case-insensitive), it resolves to the canonical form. Example: `Bench` → `Bench Press`, `RDL` → `Romanian Deadlift`, `OHP` → `Overhead Press`.

To help users discover the canonical form, the validator emits two non-blocking warnings:

- **`EXERCISE_ALIAS_SUGGESTION`** — fires when an exact alias is used in place of the canonical name. The set still parses normally; the warning suggests renaming so identity-keyed features engage reliably.
- **`EXERCISE_NAME_SUGGESTION`** — fires when a name doesn't match any alias but fuzzy-matches a canonical name (typo recovery). Suggests a "did you mean?" candidate.

Names that match neither path are passed through unchanged and receive no warning.

### Examples

**Simple exercise:**
```markdown
## Bench Press
- 135 x 5
- 185 x 5
- 225 x 5
```

**With freeform notes:**
<!-- EXAMPLE: valid/exercise-with-notes.md -->

**With optional type:**
<!-- EXAMPLE: valid/exercise-with-type.md -->

**Superset (nested headers):**
<!-- EXAMPLE: valid/superset.md -->

**Multiple supersets:**
<!-- EXAMPLE: valid/multiple-supersets.md -->

---

## Set Format

### Basic Syntax

```
- [weight] [unit] x [reps] [reps_unit] [@modifiers]
```

### Components

1. **Weight** (optional for bodyweight):
   - Number (integer or decimal)
   - Can be omitted for bodyweight exercises

2. **Weight Unit**:
   - `lbs` - Pounds
   - `kg` - Kilograms
   - `bw` - Bodyweight (can be omitted if no weight specified)

3. **Reps** (optional for time-based):
   - Number (integer)
   - `AMRAP` - As Many Reps As Possible
   - Can be omitted for time-based exercises

4. **Time/Rep Unit** (optional):
   - `reps` - Repetitions (default, can be omitted)
   - `s` or `sec` - Seconds (for time-based exercises)
   - `m` or `min` - Minutes (for time-based exercises)

### Flexible Formats

All of these are valid:

```markdown
# Minimal (assumes reps, no unit)
- 225 x 5

# Explicit
- 225 lbs x 5 reps

# Kilograms
- 100 kg x 5 reps

# Bodyweight
- bw x 10
- x 10          # Bodyweight implied
- 10            # Single number = bodyweight reps

# Time-based (duration exercises)
- 60s           # 60 seconds (plank, hold)
- 2m            # 2 minutes
- 90 sec        # 90 seconds

# Time-based with weight
- 45 lbs x 60s  # Weighted plank with 45lb plate for 60 seconds
- 100 kg x 30s  # Weighted holds
- 25 lbs for 45s # Alternative "for" syntax
- bw for 60s    # Bodyweight "for" syntax

# AMRAP
- 135 x AMRAP
- bw x AMRAP
```

---

## Modifiers

Modifiers provide functional metadata that affects how the app behaves. They use `@key: value` format at the end of the set line.

**Design Philosophy**: Only include modifiers that change app behavior. Descriptive information (tempo, effort level, etc.) should be written as freeform notes since the app displays them anyway.

### Available Modifiers

| Modifier | Values | Description | Example |
|----------|--------|-------------|---------|
| `@rest` | Number + `s`/`m` | Rest timer after set (triggers countdown in app) | `@rest: 180s` or `@rest: 3m` |
| `@dropset` | flag | Drop set indicator (changes UI tracking) | `@dropset` |
| `@perside` | flag | Per-side indicator — primarily for **timed** per-side sets where the rep value alone (e.g., `30s`) carries no side cue. For rep-based sets, prefer trailing prose like `per side` or `each leg`, which is auto-detected. | `30s @perside` |

### Examples

```markdown
# Rest periods (triggers timer in app)
- 315 lbs x 3 reps @rest: 3m
- 315 lbs x 3 reps @rest: 180s

# Drop set (UI shows connected sets)
- 100 lbs x 12 reps
- 70 lbs x 10 reps @dropset
- 50 lbs x 8 reps @dropset

# Per-side (explicit modifier)
- 30s @perside
- 45s @perside

# Per-side (auto-detected from exercise notes)
# Recognized keywords: per side, per leg, per arm, each side, each leg, each arm, each
## Side Plank
per side
- 60s
- 45s

## Single Leg RDL Hold
each leg
- 30s
- 30s

# Per-side (auto-detected from set-line trailing text)
# Same keywords recognized inline on the set line itself
## Standing Quad Stretch
Pull heel to glutes, keep knees together
- 60s per leg

## Pigeon Pose
- 90s per side

# Multiple modifiers
- 225 lbs x 5 reps @rest: 180s

# AMRAP (to failure implied)
- 135 lbs x AMRAP
- bw x AMRAP
```

### `@amrap` is not a modifier

`@amrap` is **not** a recognized modifier — there is no set-line flag for AMRAP. Express AMRAP through the rep value instead:

```markdown
- 135 lbs x AMRAP
- bw x AMRAP
```

If `@amrap` appears on a set line it is treated as a deprecated modifier and the parser emits a `DEPRECATED_AMRAP` warning pointing to the rep-value form. The set still parses; the flag has no effect.

### Descriptive Information (Use Freeform Notes)

For tempo, RPE, and other descriptive data, use freeform notes:

<!-- EXAMPLE: valid/modifiers-rest-and-dropset.md -->

---

## Examples

### Example 1: Beginner Full Body

<!-- EXAMPLE: valid/beginner-full-body.md -->

### Example 2: Advanced Powerlifting

<!-- EXAMPLE: valid/advanced-powerlifting.md -->

### Example 3: Bodybuilding with Supersets

<!-- EXAMPLE: valid/bodybuilding-supersets.md -->

### Example 4: Bodyweight & Time-Based

<!-- EXAMPLE: valid/bodyweight-time-based.md -->

### Example 5: CrossFit/HIIT Circuit

<!-- EXAMPLE: valid/crossfit-hiit.md -->

### Example 6: Olympic Lifting

<!-- EXAMPLE: valid/olympic-lifting.md -->

### Example 7: Workout with Warmup and Cooldown

<!-- EXAMPLE: valid/warmup-cooldown.md -->

### Example 8: Rehabilitation/Physical Therapy

<!-- EXAMPLE: valid/rehabilitation.md -->

---

## Validation Rules

### Required Elements
1. ✅ Must have workout header (any header level H1-H6)
2. ✅ Must have at least one exercise (one level below workout header)
3. ✅ Each exercise must have at least one set

### Format Rules
4. ✅ Workout name cannot be empty
5. ✅ Exercise names cannot be empty
6. ✅ Sets must start with `-` (list item)
7. ✅ Weight must be positive number (if provided)
8. ✅ Reps must be positive number or "AMRAP" (if provided)
9. ✅ Time must be positive number with valid unit (s/sec/m/min) (if provided)
10. ✅ Rest time must be positive number with valid unit (s/sec/m/min) (if provided)
11. ✅ Default units must be "lbs" or "kg" (if provided)

### Warnings (non-blocking)
- ⚠️ Duplicate exercise names (suggests merge or rename)
- ⚠️ Very high rep count (>100, might be typo)
- ⚠️ Very short rest (<10s, might be typo)
- ⚠️ Very long rest (>10m, might be typo)
- ⚠️ `EXERCISE_ALIAS_SUGGESTION` — alias used in place of canonical name (e.g., `Bench` → `Bench Press`)
- ⚠️ `EXERCISE_NAME_SUGGESTION` — fuzzy "did you mean?" hint for likely typos near a canonical name

### Error Examples

**Invalid - No workout header:**
<!-- EXAMPLE: errors/no-workout-header.md EXPECT_ERROR -->

**Invalid - No exercises:**
<!-- EXAMPLE: errors/no-exercises.md EXPECT_ERROR -->

**Invalid - No sets:**
<!-- EXAMPLE: errors/no-sets.md EXPECT_ERROR -->

**Invalid - Negative weight:**
<!-- EXAMPLE: errors/negative-weight.md EXPECT_ERROR -->

**Invalid - Invalid rest time:**
<!-- EXAMPLE: errors/invalid-rest.md EXPECT_ERROR -->

**Invalid - Invalid units:**
<!-- EXAMPLE: errors/invalid-units.md EXPECT_ERROR -->

---

## Edge Cases

### Handling Ambiguity

**Case 1: Single number - is it reps or weight?**
```markdown
- 10
```
**Interpretation:** 10 bodyweight reps (weight requires unit)

**Case 2: Number with unit only**
```markdown
- 135 lbs
```
**Interpretation:** Invalid - must have reps or time

**Case 3: Mixed units in same exercise**
```markdown
## Dumbbell Press
- 50 lbs x 10
- 25 kg x 8
```
**Interpretation:** Valid - parser respects per-set units

**Case 4: Extra whitespace**
```markdown
## Squat
-    225   lbs  x   5   reps   @rpe:  8
```
**Interpretation:** Valid - parser is whitespace-tolerant

**Case 5: Bodyweight meaning - Does weight include user's bodyweight?**
```markdown
## Squat
- 225 lbs x 5     # 225 lbs barbell, bodyweight not counted

## Pull-up
- 10              # Bodyweight only
- 25 lbs x 8      # Bodyweight + 25lb weight belt

## Plank
- 60s             # Bodyweight only
- 45 lbs x 45s    # Bodyweight + 45lb plate on back
```
**Interpretation:** Weight always represents **external/additional resistance only**. User's bodyweight is never included in the weight number. This convention works for all exercises:
- **Barbell exercises** (Squat, Bench, Deadlift): Weight = bar + plates
- **Bodyweight + load** (Pull-up, Dip, Plank): Weight = additional resistance
- **Bodyweight only**: No weight specified, or weight = 0

**Why this works:** For progress tracking, we only care about changes in external load over time, not absolute total load. Consistency within an exercise is what matters.

**Case 6: Markdown formatting in notes**
```markdown
# Workout: Test
@notes: This is **bold** and *italic*

## Squat
@notes: Focus on *depth* and **power**
- 225 x 5
```
**Interpretation:** Valid - preserve markdown in notes for display

**Case 7: Special characters in names**
```markdown
## Barbell Back Squat (Low Bar)
- 315 x 5

## DB Bench Press - 30° Incline
- 80 x 10
```
**Interpretation:** Valid - allow special characters in names

---

## Parsing Strategy

### Parser Behavior

1. **Case Insensitive Units**: `LBS`, `lbs`, `Lbs` all valid
2. **Whitespace Tolerant**: Multiple spaces, tabs handled
3. **Line Endings**: Support CRLF, LF, CR
4. **UTF-8 Encoding**: Support international characters
5. **Partial Parse**: Continue parsing after non-critical errors
6. **Error Recovery**: Provide helpful error messages with line numbers

### Parsing Steps

1. **Split into lines** and normalize line endings
2. **Identify workout header**:
   - Find the first header that has child headers containing list items (sets)
   - That's the workout (one workout per file)
3. **Extract workout metadata**:
   - Lines starting with `@` immediately after header
   - All other text until next header = freeform notes
4. **Identify exercises** (headers one level below workout):
   - Must have at least one set (list item with `-`)
5. **For each exercise**:
   - Extract `@` metadata lines
   - Collect freeform notes (text before first set)
   - Parse sets (lines starting with `-`)
6. **Validate structure** against rules
7. **Return parse result** with data + errors/warnings

### Header Level Detection

**Strategy**: One workout per file with flexible header levels for document organization

**Simple Rule**: First header (any level H1-H6) = workout name, next level down = exercises

```markdown
# My Training Notes         ← Document organization (ignored)

Notes about my training program and goals.

## Push Day                 ← WORKOUT (first header with exercises)
@tags: strength, push

### Bench Press             ← Exercise (one level below workout)
- 225 x 5

### Overhead Press          ← Exercise
- 135 x 8
```

Or with deeper nesting:

```markdown
# 2026 Training Log         ← Document organization

## January                  ← Document organization

### Week 1                  ← Document organization

#### Push Day A             ← WORKOUT (first header with exercises)

##### Bench Press           ← Exercise (one level below workout)
- 225 x 5
```

**Detection Logic**:
1. Find the first header that has child headers containing list items (sets) - that's the workout
2. All headers one level below the workout header = exercises
3. Headers containing "superset" (case-insensitive) with child exercises = superset grouping
   - Child exercises can be at ANY header level below the superset (not limited to parent+1)
   - Example: H2 superset can have H3, H4, or H5 exercises
4. Other nested headers under exercises = section grouping (warmup, cooldown, etc.)

**Superset vs Section Grouping Example**:
```markdown
### Push Day              ← Workout (has exercises below)

#### Warmup               ← Section (no "superset" in name)
##### Arm Circles         ← Exercise (warmup exercise)
- 10

#### Bench Press          ← Exercise (main work)
- 225 x 5

#### Superset: Chest      ← Superset (contains "superset")
##### Cable Fly           ← Exercise (part of superset)
- 30 x 15

##### Pullover            ← Exercise (part of superset)
- 50 x 15

#### Cooldown             ← Section (no "superset" in name)
##### Stretching          ← Exercise (cooldown)
- 60s
```

**Key Rules**:
- If header name contains "superset" (case-insensitive), it's a superset. Otherwise, it's a section grouping.
- Superset exercises can be at ANY header level below the superset header (not limited to parent+1)
  - Valid: H2 Superset → H4 Exercises (skipping H3)
  - Valid: H1 Superset → H3 Exercises (skipping H2)
  - Valid: H3 Superset → H4 Exercises (standard parent+1)

### Parse Result Structure

```typescript
interface ParseResult {
  success: boolean;
  workout?: WorkoutTemplate;
  errors: ParseError[];
  warnings: ParseWarning[];
}

interface ParseError {
  line: number;
  message: string;
  code: string;
}

interface ParseWarning {
  line: number;
  message: string;
  code: string;
}
```

---

## Future Extensions

### Potential v2.0 Features

**Plates calculation:**
```markdown
- 315 lbs x 5 @plates: 45,45,25,10
```

**Cardio tracking:**
```markdown
## Running
@type: cardio
- 5km in 25m @pace: 5:00/km @heart_rate: 165
```

**Complex set schemes:**
```markdown
## Bench Press
- 225 x 5,5,5 @rest_between: 10s  # Cluster set
- 135 x 20 @pause: 5,10,15        # Rest-pause set
```

**Video references:**
```markdown
## Squat
@video: https://youtube.com/watch?v=xyz
- 315 x 5
```

**Workout programming:**
```markdown
# Workout: Week 1 - Day 1
@program: 5/3/1
@week: 1
@cycle: 1
```

---

## LLM Prompt Template

When asking an LLM to generate a workout, use this template:

```
Create a workout in LiftMark Workout Format (LMWF) for [describe workout goal/type].

Format requirements:
- Start with workout name as a header: # [Workout Name]
- Add @tags if relevant
- Add @units: lbs or @units: kg to set default weight units (optional)
- Freeform notes go after the header
- Each exercise is one header level below: ## [Exercise Name]
- Exercise notes are freeform text after exercise header
- Sets format: - [weight] [unit] x [reps] or - [weight] [unit] for [time]
- If @units is set, weight units can be omitted: - [weight] x [reps]
- Functional modifiers: @rest (triggers timer), @dropset (UI behavior), @perside (per-side timer)
- Descriptive data (tempo, RPE, etc.) goes in freeform notes
- For supersets, use nested headers with "superset" in the name
  - Header containing "superset" (case-insensitive) becomes the superset parent
  - Child exercises can be at any deeper header level (not limited to parent+1)
  - Example: ## Superset: Arms, then ### Exercise1, ### Exercise2
  - Also valid: ## Superset: Arms, then #### Exercise1, #### Exercise2
- AMRAP implies to failure (no need for separate failure flag)

Example:
# Push Day
@tags: strength, push
@units: lbs

Feeling good today, going for PRs.

## Bench Press

Focus on bar path and leg drive.
Last set felt like an 8/10 effort.

- 135 x 5 @rest: 120s
- 185 x 5 @rest: 180s
- 225 x 5

## Plank
- 45 for 60s
- 45 for 45s
```

---

## Appendix: Validated Test Cases

All test cases below are validated against the LMWF parser at spec generation time. Valid examples must parse successfully; error examples must produce the expected validation errors. Error messages shown are generated directly from the parser.

### Valid Test Cases — Simple

**TC-V01: Minimal single exercise**
<!-- EXAMPLE: valid/tc-minimal-single-exercise.md -->

**TC-V02: Basic two exercises**
<!-- EXAMPLE: valid/tc-basic-two-exercises.md -->

**TC-V03: Bodyweight only (all formats)**
<!-- EXAMPLE: valid/tc-bodyweight-only.md -->

**TC-V04: Time-based only (all time units)**
<!-- EXAMPLE: valid/tc-time-based-only.md -->

**TC-V05: Tags metadata**
<!-- EXAMPLE: valid/tc-with-tags.md -->

**TC-V06: Default units — lbs**
<!-- EXAMPLE: valid/tc-units-lbs.md -->

**TC-V07: Default units — kg**
<!-- EXAMPLE: valid/tc-units-kg.md -->

**TC-V08: Freeform notes everywhere**
<!-- EXAMPLE: valid/tc-freeform-notes-everywhere.md -->

**TC-V09: Decimal weights**
<!-- EXAMPLE: valid/tc-decimal-weights.md -->

**TC-V10: Explicit units on every set**
<!-- EXAMPLE: valid/tc-explicit-units-every-set.md -->

### Valid Test Cases — Medium

**TC-V11: Mixed units per set**
<!-- EXAMPLE: valid/tc-mixed-units-per-set.md -->

**TC-V12: AMRAP variations**
<!-- EXAMPLE: valid/tc-amrap-variations.md -->

**TC-V13: Rest modifiers — boundary values**
<!-- EXAMPLE: valid/tc-rest-modifiers-range.md -->

**TC-V14: Dropset chain**
<!-- EXAMPLE: valid/tc-dropset-chain.md -->

**TC-V15: Per-side — explicit modifier**
<!-- EXAMPLE: valid/tc-perside-explicit.md -->

**TC-V16: Per-side — auto-detected from exercise notes**
<!-- EXAMPLE: valid/tc-perside-auto-exercise-notes.md -->

**TC-V17: Per-side — auto-detected from trailing text**
<!-- EXAMPLE: valid/tc-perside-auto-trailing-text.md -->

**TC-V18: "for" syntax for time-based sets**
<!-- EXAMPLE: valid/tc-for-syntax-time.md -->

**TC-V19: Single superset**
<!-- EXAMPLE: valid/tc-single-superset.md -->

**TC-V20: Multiple supersets**
<!-- EXAMPLE: valid/tc-multiple-supersets.md -->

### Valid Test Cases — Complex

**TC-V21: Sections — warmup and cooldown**
<!-- EXAMPLE: valid/tc-sections-warmup-cooldown.md -->

**TC-V22: Sections and supersets combined**
<!-- EXAMPLE: valid/tc-sections-and-supersets.md -->

**TC-V23: Deep header nesting (H3 workout)**
<!-- EXAMPLE: valid/tc-deep-header-nesting.md -->

**TC-V24: Mixed set types in one exercise**
<!-- EXAMPLE: valid/tc-mixed-set-types.md -->

**TC-V25: All modifiers combined**
<!-- EXAMPLE: valid/tc-all-modifiers-combined.md -->

**TC-V26: Large workout (10 exercises, 50+ sets)**
<!-- EXAMPLE: valid/tc-large-workout.md -->

**TC-V27: Exercise @type metadata**
<!-- EXAMPLE: valid/tc-exercise-type-metadata.md -->

**TC-V28: Unknown metadata — silently ignored**
<!-- EXAMPLE: valid/tc-unknown-metadata-ignored.md -->

**TC-V29: Deprecated modifiers (@rpe, @tempo)**
<!-- EXAMPLE: valid/tc-deprecated-modifiers.md -->

**TC-V30: Every valid set format**
<!-- EXAMPLE: valid/tc-all-set-formats.md -->

### Invalid Test Cases — Structure Errors

**TC-E01: Empty file**
<!-- EXAMPLE: errors/tc-empty-file.md EXPECT_ERROR -->

**TC-E02: Whitespace only**
<!-- EXAMPLE: errors/tc-whitespace-only.md EXPECT_ERROR -->

**TC-E03: No headers — just text and sets**
<!-- EXAMPLE: errors/tc-no-headers.md EXPECT_ERROR -->

**TC-E04: Header but no exercises**
<!-- EXAMPLE: errors/tc-header-no-exercises.md EXPECT_ERROR -->

**TC-E05: Exercise with no sets**
<!-- EXAMPLE: errors/tc-exercise-no-sets.md EXPECT_ERROR -->

**TC-E06: One exercise missing sets (others valid)**
<!-- EXAMPLE: errors/tc-one-exercise-missing-sets.md EXPECT_ERROR -->

**TC-E07: Same-level headers (no hierarchy)**
<!-- EXAMPLE: errors/tc-same-level-headers.md EXPECT_ERROR -->

**TC-E08: Exercise headers without workout header**
<!-- EXAMPLE: errors/tc-only-exercise-no-workout.md EXPECT_ERROR -->

### Invalid Test Cases — Unit/Format Errors

**TC-E09: Invalid units — "pounds"**
<!-- EXAMPLE: errors/tc-invalid-units-pounds.md EXPECT_ERROR -->

**TC-E10: Invalid units — "kilograms"**
<!-- EXAMPLE: errors/tc-invalid-units-kilograms.md EXPECT_ERROR -->

**TC-E11: Negative weight**
<!-- EXAMPLE: errors/tc-negative-weight.md EXPECT_ERROR -->

**TC-E12: Negative decimal weight**
<!-- EXAMPLE: errors/tc-negative-decimal-weight.md EXPECT_ERROR -->

**TC-E13: Unparseable set text**
<!-- EXAMPLE: errors/tc-unparseable-set-text.md EXPECT_ERROR -->

**TC-E14: Weight with unit but no reps/time**
<!-- EXAMPLE: errors/tc-weight-no-reps.md EXPECT_ERROR -->

**TC-E15: Zero reps**
<!-- EXAMPLE: errors/tc-zero-reps.md EXPECT_ERROR -->

**TC-E16: Zero time**
<!-- EXAMPLE: errors/tc-zero-time.md EXPECT_ERROR -->

### Invalid Test Cases — Modifier Errors

**TC-E17: Negative rest time**
<!-- EXAMPLE: errors/tc-negative-rest.md EXPECT_ERROR -->

**TC-E18: Non-numeric rest**
<!-- EXAMPLE: errors/tc-rest-non-numeric.md EXPECT_ERROR -->

**TC-E19: RPE below range (0)**
<!-- EXAMPLE: errors/tc-rpe-zero.md EXPECT_ERROR -->

**TC-E20: RPE above range (11+)**
<!-- EXAMPLE: errors/tc-rpe-above-ten.md EXPECT_ERROR -->

**TC-E21: RPE non-numeric**
<!-- EXAMPLE: errors/tc-rpe-non-numeric.md EXPECT_ERROR -->

**TC-E22: Tempo — wrong segment count**
<!-- EXAMPLE: errors/tc-tempo-three-segments.md EXPECT_ERROR -->

**TC-E23: Tempo — non-numeric**
<!-- EXAMPLE: errors/tc-tempo-non-numeric.md EXPECT_ERROR -->

**TC-E24: Rest — non-numeric unit**
<!-- EXAMPLE: errors/tc-rest-empty-value.md EXPECT_ERROR -->

### Invalid Test Cases — Combined/Edge Errors

**TC-E25: Valid workout with one bad set**
<!-- EXAMPLE: errors/tc-valid-workout-one-bad-set.md EXPECT_ERROR -->

**TC-E26: All sets unparseable**
<!-- EXAMPLE: errors/tc-all-sets-invalid.md EXPECT_ERROR -->

**TC-E27: Multiple error types at once**
<!-- EXAMPLE: errors/tc-multiple-errors.md EXPECT_ERROR -->

**TC-E28: Empty exercise name**
<!-- EXAMPLE: errors/tc-empty-exercise-name.md EXPECT_ERROR -->

**TC-E29: Multiple negative rest values**
<!-- EXAMPLE: errors/tc-sets-before-exercise.md EXPECT_ERROR -->

**TC-E30: Superset with no child exercises**
<!-- EXAMPLE: errors/tc-nested-superset-no-children.md EXPECT_ERROR -->

---

## Changelog

### Version 1.4 (2026-05-22)
- **Exercise name resolution via alias table** — `spec/data/exercise-dictionary.json` is now consulted by the validator. Two new non-blocking warnings: `EXERCISE_ALIAS_SUGGESTION` (alias used; suggests canonical) and `EXERCISE_NAME_SUGGESTION` (fuzzy "did you mean?"). Names that match neither path pass through silently.

### Version 1.3 (2026-05-22)
- **Clarified `@amrap` is not a modifier** — AMRAP is expressed via the rep value (`x AMRAP`). The parser now emits a `DEPRECATED_AMRAP` warning when `@amrap` appears as a set-line flag.
- **Sharpened `@perside` guidance** — primary use case is timed per-side sets (`30s @perside`); rep-based sets should prefer auto-detected trailing prose ("per side", "each leg").

### Version 1.1 (2026-01-16)
- **Simplified to one workout per file** - removed multi-workout support for cleaner mental model
- **Simplified modifiers** to only functional ones: `@rest`, `@dropset`, `@perside`
- Deprecated `@rpe` and `@tempo` — still parsed for compatibility, but freeform notes are preferred
- Clarified time units in set format components
- Updated examples to use freeform notes for descriptive data
- Simplified header detection logic (first header with exercises = workout)

### Version 1.0 (2026-01-03)
- Initial specification
- Basic workout structure
- Exercise and set format
- Modifiers: rpe, rest, tempo, dropset
- Superset and circuit support

---

## License

This specification is part of the LiftMark2 project.

---

## Design Decisions Made

Based on user feedback, the following design decisions were implemented:

1. ✅ **Freeform Notes**: Notes are now freeform text after headers, not `@notes:` metadata
2. ✅ **Optional Type**: `@type` is completely optional for exercises
3. ✅ **Time-based with Weight**: Supports `45 lbs x 60s` and `45 lbs for 60s` for weighted holds
4. ✅ **Flexible Headers**: Workouts can be any header level (H1-H6), exercises one level below
5. ✅ **No Date Required**: Date removed - import date and workout date are handled separately
6. ✅ **Name = Header**: Header text is the name, no prefix needed
7. ✅ **Superset Support**: Uses nested headers (e.g., `## Superset: Arms` with `### Exercise` children)
8. ✅ **Simplified Modifiers**:
   - Only functional modifiers: `@rest` (triggers timer), `@dropset` (changes UI), `@perside` (per-side timer)
   - Deprecated `@rpe` and `@tempo` — still parsed for compatibility, but freeform notes are preferred
   - `@dropset` and `@perside` are flags, not `@dropset: true`
   - AMRAP implies failure, no separate flag needed

---

**Document Version:** 1.1
**Last Updated:** 2026-01-16
