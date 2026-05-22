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
- **Freeform notes**: Any text after the header (before first exercise) is treated as workout notes.
  - For **workout plans** (templates): these are planning / coaching notes authored up front.
  - For **completed session exports** (LMWF export of a finished workout): these are the user's free-text notes on the session — how it felt, energy, soreness, PR context, etc. The same syntax is used for both; the semantics are determined by the document's role, not by a separate modifier. This keeps LMWF a single canonical format and lets a completed session round-trip through parse → encode → parse cleanly.

### Examples

**Minimal:**
```markdown
# Push Day
```

**With freeform notes:**
```markdown
# Push Day A

Feeling strong today, going for PRs on bench.
Sleep was good, nutrition on point.

## Bench Press
- 225 x 5
```

**With tags:**
```markdown
# Push Day A
@tags: push, strength, upper

Ready to hit some PRs today!

## Bench Press
- 225 x 5
```

**With default units:**
```markdown
# Push Day
@units: kg

Prefer using kilograms - easier for tracking.

## Bench Press
- 100 x 5
- 110 x 5
- 120 kg x 3
- 225 lbs x 1

## Overhead Press
- 50 x 8
- 55 x 8
```

**Flexible header levels for document organization:**
```markdown
# My Training Log

Weekly notes: Focusing on progressive overload this month.

## Week 1 - Day 1: Push
@tags: push

Great session, felt strong.

### Bench Press
- 225 x 5
- 245 x 3

### Overhead Press
- 135 x 8
```

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
```markdown
# Push Day

## Bench Press

Retract scapula, touch chest on every rep.
Focus on driving through the floor.

- 135 lbs x 5 reps
- 185 lbs x 5 reps
- 225 lbs x 5 reps
```

**With optional type:**
```markdown
# Workout

## Bench Press
@type: barbell

- 135 lbs x 5 reps
- 185 lbs x 5 reps

## Band Pull-Apart
@type: resistance band

- 20 reps
- 20 reps
```

**Superset (nested headers):**
```markdown
# Arm Day

## Superset: Arms

### Dumbbell Curl
- 30 lbs x 12
- 30 lbs x 12
- 30 lbs x 10

### Tricep Extension
- 40 lbs x 12
- 40 lbs x 12
- 40 lbs x 12
```

**Multiple supersets:**
```markdown
# Upper Body Finisher

## Superset 1

### Cable Fly
- 30 lbs x 15
- 30 lbs x 15

### Dumbbell Pullover
- 50 lbs x 15
- 50 lbs x 15

## Superset 2

### Lateral Raise
- 20 lbs x 12
- 20 lbs x 12

### Face Pull
- 40 lbs x 15
- 40 lbs x 15
```

---

## Set Format

### Basic Syntax

```
- [weight] [unit] x [reps] [reps_unit] [@modifiers]
- [distance] [distance_unit] [@modifiers]
```

### Components

1. **Weight** (optional for bodyweight):
   - Number (integer or decimal)
   - Can be omitted for bodyweight exercises

2. **Weight Unit**:
   - `lbs` - Pounds
   - `kg` - Kilograms
   - `bw` - Bodyweight (can be omitted if no weight specified)

3. **Reps** (optional for time-based and distance-based):
   - Number (integer)
   - `AMRAP` - As Many Reps As Possible
   - Can be omitted for time-based and distance-based exercises

4. **Time/Rep Unit** (optional):
   - `reps` - Repetitions (default, can be omitted)
   - `s` or `sec` - Seconds (for time-based exercises)
   - `m` or `min` - Minutes (for time-based exercises)

5. **Distance** (optional):
   - Number (integer or decimal) followed by a distance unit
   - `meters` - Meters (note: "m" is reserved for minutes, not meters)
   - `km` - Kilometers
   - `miles` or `mi` - Miles
   - `feet` or `ft` - Feet
   - `yards` or `yd` - Yards

### Set Types

There are four distinct set types. A single set is exactly one of these:

| Set Type | Description | Examples |
|----------|-------------|---------|
| **Weight + Reps** | Resistance exercise with rep count | `225 lbs x 5`, `100 kg x 8` |
| **Time-based** | Duration exercise, optionally weighted | `60s`, `45 lbs x 60s` |
| **Distance-based** | Distance target for cardio/conditioning | `200 meters`, `1 mile` |
| **Bodyweight Reps** | Reps with no external load | `10`, `bw x 12`, `AMRAP` |

Distance sets cannot be combined with weight or reps. Weight and distance in the same set (e.g., weighted carries with a distance) is not supported; use weight+time or separate distance sets instead.

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

# Distance-based (cardio, rowing, running)
- 200 meters     # Sprint distance
- 0.5 km         # Half kilometer
- 1 mile         # One mile run
- 400 yards      # Yard distance
- 100 ft         # Short distance
- 1.5 mi         # Mile abbreviation
- 800 meters     # Middle distance

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
| `@dropset` | flag | Drop set — user adds weight drops during recording | `@dropset` |
| `@perside` | flag | Per-side indicator — primarily for **timed** per-side sets where the rep value alone (e.g., `30s`) carries no side cue. For rep-based sets, prefer trailing prose like `per side` or `each leg`, which is auto-detected. | `30s @perside` |

### Examples

```markdown
# Rest periods (triggers timer in app)
- 315 lbs x 3 reps @rest: 3m
- 315 lbs x 3 reps @rest: 180s

# Drop set (user adds weight drops during recording)
- 100 lbs x 12 reps @dropset

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

### Deprecated Modifiers

The `@rpe` and `@tempo` modifiers are still parsed for backward compatibility but are deprecated in favor of freeform notes. A deprecation warning is emitted when they are used.

**RPE rounding behavior:** `@rpe` values are rounded to the nearest integer and clamped to the 1–10 range. If the value is adjusted, a warning is emitted (e.g., `RPE rounded to nearest integer (8.3 → 8)`). Integer values (e.g., 7, 8, 9) are stored without a rounding warning.

### `@amrap` is not a modifier

`@amrap` is **not** a recognized modifier — there is no set-line flag for AMRAP. Express AMRAP through the rep value instead:

```markdown
- 135 lbs x AMRAP
- bw x AMRAP
```

If `@amrap` appears on a set line it is treated as a deprecated modifier and the parser emits a `DEPRECATED_AMRAP` warning pointing to the rep-value form. The set still parses; the flag has no effect.

### Descriptive Information (Use Freeform Notes)

For tempo, RPE, and other descriptive data, use freeform notes:

```markdown
# Modifier Examples
@tags: demo

## Bench Press

Going for slow tempo today - 3-0-1-0 on all sets.
Felt really strong, first set was maybe a 7, last set was a hard 9.

- 185 lbs x 8 reps @rest: 90s
- 205 lbs x 6 reps @rest: 90s
- 225 lbs x 4 reps @rest: 90s

## Pause Squat

2 second pause at bottom, really focusing on staying tight.

- 315 lbs x 3 reps @rest: 180s
- 315 lbs x 3 reps @rest: 180s
```

---

## Examples

### Example 1: Beginner Full Body

```markdown
# Full Body A
@tags: beginner, full-body

First week back, keeping it light and focusing on form.

## Squat
- 135 x 5
- 135 x 5
- 135 x 5

## Bench Press
- 95 x 5
- 95 x 5
- 95 x 5

## Barbell Row
- 85 x 8
- 85 x 8
- 85 x 8
```

### Example 2: Advanced Powerlifting

```markdown
# Squat Day - Week 3 Heavy
@tags: powerlifting, squat, heavy

Competition prep, 4 weeks out. Feeling good, bodyweight at 220.

## Low Bar Squat

Competition depth, belt on work sets starting at 315.
Warmups felt easy (RPE 4-5), working sets got tough (8-9.5).

- 135 lbs x 5 reps @rest: 60s
- 225 lbs x 5 reps @rest: 90s
- 315 lbs x 3 reps @rest: 120s
- 365 lbs x 1 reps @rest: 180s
- 405 lbs x 3 reps @rest: 300s
- 405 lbs x 3 reps @rest: 300s
- 405 lbs x 3 reps @rest: 300s

## Pause Squat

2 second pause at bottom, 3-2-3-0 tempo, no belt.

- 315 lbs x 3 reps @rest: 180s
- 315 lbs x 3 reps @rest: 180s
- 315 lbs x 3 reps @rest: 180s

## Front Squat
- 225 lbs x 5 reps @rest: 120s
- 225 lbs x 5 reps @rest: 120s
- 225 lbs x 5 reps @rest: 120s

## Leg Curl
- 90 lbs x 12 reps @rest: 60s
- 90 lbs x 12 reps @rest: 60s
- 90 lbs x 12 reps @rest: 60s
```

### Example 3: Bodybuilding with Supersets

```markdown
# Chest & Triceps
@tags: bodybuilding, push, hypertrophy

## Barbell Bench Press
- 135 lbs x 12 reps @rest: 90s
- 185 lbs x 10 reps @rest: 90s
- 205 lbs x 8 reps @rest: 90s
- 205 lbs x 8 reps @rest: 90s

## Incline Dumbbell Press
- 70 lbs x 12 reps @rest: 90s
- 75 lbs x 10 reps @rest: 90s
- 75 lbs x 9 reps @rest: 90s

## Superset: Chest Finisher

### Cable Fly
- 30 lbs x 15 reps @rest: 30s
- 30 lbs x 15 reps @rest: 30s
- 30 lbs x 12 reps @rest: 30s

### Dumbbell Pullover
- 50 lbs x 15 reps @rest: 90s
- 50 lbs x 15 reps @rest: 90s
- 50 lbs x 15 reps @rest: 90s

## Tricep Pushdown

Final set is a drop set.

- 60 lbs x 15 reps @rest: 60s
- 70 lbs x 12 reps @rest: 60s
- 80 lbs x 10 reps @rest: 60s
- 60 lbs x 15 reps @dropset
```

### Example 4: Bodyweight & Time-Based

```markdown
# Calisthenics
@tags: bodyweight, calisthenics

## Pull-ups
- 10 @rest: 120s
- 8 @rest: 120s
- 6 @rest: 120s
- AMRAP

## Dips
- 12 @rest: 90s
- 10 @rest: 90s
- 8 @rest: 90s

## Plank

Adding weight on last two sets.

- 60s @rest: 30s
- 45 lbs x 60s @rest: 30s
- 45 lbs for 45s

## Weighted Plank Hold
- 45 lbs for 45s @rest: 60s
- 25 lbs for 60s

## Hanging Leg Raise
- 15 @rest: 60s
- 12 @rest: 60s
- 10 @rest: 60s
```

### Example 5: CrossFit/HIIT Circuit

```markdown
# Workout: EMOM 20
@tags: crossfit, conditioning, EMOM

Every minute on the minute for 20 minutes

## Kettlebell Swing
@type: other
- 53 lbs x 15 reps

## Box Jump
@type: bodyweight
- 24 inches x 10 reps

## Burpee
@type: bodyweight
- 10

## Row
@type: machine
- 200 meters
```

### Example 6: Olympic Lifting

```markdown
# Workout: Snatch Technique
@tags: weightlifting, snatch, technique

## Snatch
@type: barbell

Focus on third pull, fast elbows.

- 45 lbs x 5 reps @rest: 90s
- 75 lbs x 3 reps @rest: 90s
- 95 lbs x 2 reps @rest: 120s
- 115 lbs x 2 reps @rest: 150s
- 135 lbs x 1 reps @rest: 180s
- 155 lbs x 1 reps @rest: 180s
- 165 lbs x 1 reps @rest: 180s
- 165 lbs x 1 reps @rest: 180s

## Snatch Pull
@type: barbell
- 175 lbs x 3 reps @rest: 120s
- 185 lbs x 3 reps @rest: 120s
- 185 lbs x 3 reps @rest: 120s

## Overhead Squat
@type: barbell
- 95 lbs x 5 reps @rest: 90s
- 115 lbs x 3 reps @rest: 90s
- 135 lbs x 3 reps @rest: 90s
- 135 lbs x 3 reps @rest: 90s
```

### Example 7: Workout with Warmup and Cooldown

```markdown
# Push Day
@tags: strength, push

## Warmup

### Arm Circles
- 10 reps

### Band Pull-Aparts
- 20 reps

### Light Bench Press
- 45 lbs x 10
- 95 lbs x 5

## Bench Press

Last two sets felt hard - 8/10 and 9/10 effort.

- 135 lbs x 5 @rest: 120s
- 185 lbs x 5 @rest: 180s
- 225 lbs x 5 @rest: 180s
- 245 lbs x 3

## Overhead Press

Final set was tough, really close to failure.

- 95 lbs x 8 @rest: 90s
- 115 lbs x 8 @rest: 90s
- 135 lbs x 6

## Cooldown

### Chest Stretch
- 60s

### Shoulder Stretch
- 60s

### Foam Rolling
- 2m
```

### Example 8: Rehabilitation/Physical Therapy

```markdown
# Knee Rehab - Day 3
@tags: rehab, knee, physical-therapy

No pain during exercises, feeling good. PT says I can progress weight next week.

## Terminal Knee Extension
- 10 lbs x 20 reps @rest: 30s
- 10 lbs x 20 reps @rest: 30s
- 10 lbs x 20 reps @rest: 30s

## Wall Sit
- 30s @rest: 60s
- 30s @rest: 60s
- 30s @rest: 60s

## Single Leg Balance

Eyes closed on last set.

- 45s @rest: 30s
- 45s @rest: 30s
- 30s

## Leg Curl
- 20 lbs x 15 reps @rest: 45s
- 20 lbs x 15 reps @rest: 45s
```

### Example 9: Distance-Based Conditioning

```markdown
# Rowing and Running
@tags: cardio, conditioning

## Rowing
- 500 meters @rest: 90s
- 500 meters @rest: 90s
- 500 meters @rest: 90s

## Sprint Intervals

Short sprints with full recovery.

- 200 meters @rest: 120s
- 200 meters @rest: 120s
- 200 meters @rest: 120s
- 200 meters @rest: 120s

## Easy Run
- 1.5 miles

## Sled Push
- 100 ft @rest: 60s
- 100 ft @rest: 60s
- 100 ft @rest: 60s

## Shuttle Run
- 50 yards @rest: 45s
- 50 yards @rest: 45s
- 50 yards @rest: 45s
```

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
12. ✅ Distance must be positive number with valid unit (meters/km/miles/mi/feet/ft/yards/yd) (if provided)

### Warnings (non-blocking)
- ⚠️ Duplicate exercise names (suggests merge or rename)
- ⚠️ Very high rep count (>100, might be typo)
- ⚠️ Very short rest (<10s, might be typo)
- ⚠️ Very long rest (>10m, might be typo)
- ⚠️ Mixed section levels — exercises and sections (groups with nested headers) at the same heading level. This is valid but may indicate structural issues (e.g., `## Warmup` as a section alongside `## Bench Press` as a standalone exercise).
- ⚠️ `EXERCISE_ALIAS_SUGGESTION` — alias used in place of canonical name (e.g., `Bench` → `Bench Press`)
- ⚠️ `EXERCISE_NAME_SUGGESTION` — fuzzy "did you mean?" hint for likely typos near a canonical name

### Error Examples

**Invalid - No workout header:**
```markdown
## Squats
- 225 x 5
```
❌ No workout header found. Must have a header (# Workout Name) with exercises below it.

**Invalid - No exercises:**
```markdown
# Empty Workout
@tags: test

Some notes but no exercises.
```
❌ No workout header found. Must have a header (# Workout Name) with exercises below it.

**Invalid - No sets:**
```markdown
# Workout: Test
## Bench Press
```
❌ No workout header found. Must have a header (# Workout Name) with exercises below it.

**Invalid - Negative weight:**
```markdown
# Workout: Test
## Squat
- -135 x 5
```
❌ Line 3: Invalid set format: "-135 x 5". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 2: Exercise "Squat" has no sets

**Invalid - Invalid rest time:**
```markdown
# Workout: Test
## Bench Press
- 225 x 5 @rest: -30s
```
❌ Line 3: Invalid rest time format: -30s. Expected format: "180s" or "3m"

**Invalid - Invalid units:**
```markdown
# Workout: Test
@units: pounds

## Bench Press
- 225 x 5
```
❌ Line 2: Invalid @units value "pounds". Must be "lbs" or "kg"

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

This is **bold** and *italic*

## Squat

Focus on *depth* and **power**

- 225 x 5
```
**Interpretation:** Valid - preserve markdown in freeform notes for display

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
- Sets format: - [weight] [unit] x [reps] or - [weight] [unit] for [time] or - [distance] [distance_unit]
- Distance units: meters, km, miles, mi, feet, ft, yards, yd (note: "m" means minutes, NOT meters)
- If @units is set, weight units can be omitted: - [weight] x [reps]
- Functional modifiers: @rest (triggers timer), @dropset (enables multi-drop recording), @perside (per-side timer)
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
```markdown
# Quick Bench
## Bench Press
- 135 x 5
```

**TC-V02: Basic two exercises**
```markdown
# Upper Body
## Bench Press
- 135 x 5
- 185 x 5
- 225 x 3

## Overhead Press
- 95 x 8
- 105 x 6
```

**TC-V03: Bodyweight only (all formats)**
```markdown
# Bodyweight Circuit

## Pull-ups
- 10
- 8
- 6

## Push-ups
- x 20
- x 15
- x 12

## Dips
- bw x 12
- bw x 10
- bw x 8
```

**TC-V04: Time-based only (all time units)**
```markdown
# Stretching Routine

## Plank
- 60s
- 45s

## Wall Sit
- 2m
- 90sec

## Dead Hang
- 1min
- 45s
```

**TC-V05: Tags metadata**
```markdown
# Push Day
@tags: strength, push, upper, chest, triceps, shoulders

## Bench Press
- 225 x 5
- 225 x 5
```

**TC-V06: Default units — lbs**
```markdown
# Leg Day
@units: lbs

## Squat
- 225 x 5
- 275 x 3
- 315 x 1

## Leg Press
- 360 x 10
- 450 x 8
```

**TC-V07: Default units — kg**
```markdown
# European Gym Session
@units: kg

## Squat
- 100 x 5
- 120 x 3
- 140 x 1

## Bench Press
- 80 x 8
- 90 x 5
```

**TC-V08: Freeform notes everywhere**
```markdown
# Push Day - Week 4

Deload week. Keep everything at 70% of max.
Feeling a bit tired from travel but should be fine.

## Bench Press

Retract scapula, arch back, feet flat.
Focus on bar path — slight J-curve.
Last week was 225x5, aiming for easy 185x8 today.

- 135 x 8
- 185 x 8
- 185 x 8

## Overhead Press

Brace hard, squeeze glutes.
These have been feeling great lately.

- 95 x 8
- 95 x 8
```

**TC-V09: Decimal weights**
```markdown
# Dumbbell Work
@units: kg

## Dumbbell Curl
- 12.5 x 10
- 15 x 8
- 17.5 x 6

## Lateral Raise
- 7.5 x 12
- 10 x 10

## Wrist Curl
- 2.5 x 20
- 5 x 15
```

**TC-V10: Explicit units on every set**
```markdown
# Mixed Units Workout

## Squat
- 135 lbs x 5 reps
- 185 lbs x 5 reps
- 225 lbs x 3 reps

## Romanian Deadlift
- 60 kg x 8 reps
- 80 kg x 6 reps

## Plank
- 60s
- 45 lbs x 60s
```

### Valid Test Cases — Medium

**TC-V11: Mixed units per set**
```markdown
# International Gym

## Dumbbell Press
- 50 lbs x 10
- 25 kg x 8
- 55 lbs x 8
- 27.5 kg x 6
```

**TC-V12: AMRAP variations**
```markdown
# AMRAP Test Day

## Bench Press
- 225 lbs x AMRAP

## Pull-ups
- bw x AMRAP
- x AMRAP

## Push-ups
- AMRAP

## Dumbbell Row
- 50 lbs x amrap
```

**TC-V13: Rest modifiers — boundary values**
```markdown
# Rest Timer Testing

## Speed Bench
- 135 x 3 @rest: 10s
- 135 x 3 @rest: 30s
- 135 x 3 @rest: 60s

## Heavy Squat
- 405 x 3 @rest: 3m
- 405 x 3 @rest: 180s
- 405 x 3 @rest: 300s

## Max Deadlift
- 500 x 1 @rest: 600s
```

**TC-V14: Dropset**
```markdown
# Hypertrophy Arms

## Bicep Curl
- 40 lbs x 10 @rest: 60s
- 35 lbs x 10 @rest: 60s
- 30 lbs x 12 @dropset

## Tricep Pushdown
- 80 lbs x 10 @rest: 60s
- 70 lbs x 12 @dropset
```

**TC-V15: Per-side — explicit modifier**
```markdown
# Unilateral Core

## Side Plank
- 30s @perside
- 45s @perside
- 60s @perside

## Pallof Hold
- 30s @perside @rest: 30s
- 30s @perside @rest: 30s
```

**TC-V16: Per-side — auto-detected from exercise notes**
```markdown
# Unilateral Mobility

## Side Plank
per side
- 60s
- 45s

## Single Leg RDL Hold
each leg
- 30s
- 30s

## Single Arm Hang
each arm
- 20s
- 15s
```

**TC-V17: Per-side — auto-detected from trailing text**
```markdown
# Stretching

## Standing Quad Stretch
Pull heel to glutes, keep knees together
- 60s per leg

## Pigeon Pose
- 90s per side

## Shoulder Stretch
- 45s each side

## Calf Stretch
- 30s each leg
```

**TC-V18: "for" syntax for time-based sets**
```markdown
# Holds and Carries

## Weighted Plank
- 45 lbs for 60s
- 45 lbs for 45s
- 25 lbs for 60s

## Farmer Carry
- 70 lbs for 45s
- 70 lbs for 30s

## Dead Hang
- bw for 60s
- bw for 45s
```

**TC-V19: Single superset**
```markdown
# Quick Arms

## Superset: Biceps and Triceps

### Barbell Curl
- 65 lbs x 10
- 65 lbs x 10
- 65 lbs x 8

### Skull Crusher
- 55 lbs x 10
- 55 lbs x 10
- 55 lbs x 8
```

**TC-V20: Multiple supersets**
```markdown
# Superset Madness

## Superset: Chest and Back
### Bench Press
- 185 lbs x 10
- 185 lbs x 10
### Barbell Row
- 155 lbs x 10
- 155 lbs x 10

## Superset: Shoulders
### Lateral Raise
- 20 lbs x 12
- 20 lbs x 12
### Rear Delt Fly
- 15 lbs x 15
- 15 lbs x 15

## Superset: Arms
### Hammer Curl
- 30 lbs x 12
- 30 lbs x 12
### Tricep Kickback
- 20 lbs x 12
- 20 lbs x 12
```

### Valid Test Cases — Complex

**TC-V21: Sections — warmup and cooldown**
```markdown
# Full Session
@tags: strength, structured

## Warmup

### Jumping Jacks
- 30

### Arm Circles
- 20

### Empty Bar Bench
- 45 lbs x 10

## Bench Press
- 135 lbs x 5 @rest: 90s
- 185 lbs x 5 @rest: 120s
- 225 lbs x 3 @rest: 180s

## Incline Dumbbell Press
- 60 lbs x 10 @rest: 90s
- 60 lbs x 10 @rest: 90s

## Cooldown

### Chest Stretch
- 60s

### Shoulder Dislocates
- 15

### Foam Rolling
- 2m
```

**TC-V22: Sections and supersets combined**
```markdown
# Push Day Complete
@tags: push, hypertrophy

## Warmup

### Band Pull-Aparts
- 20
- 20

### Light Bench
- 45 lbs x 10
- 95 lbs x 5

## Bench Press
- 185 lbs x 8 @rest: 120s
- 205 lbs x 6 @rest: 120s
- 225 lbs x 4 @rest: 180s

## Superset: Chest Isolation

### Cable Fly
- 30 lbs x 15 @rest: 30s
- 30 lbs x 15 @rest: 30s

### Pec Deck
- 120 lbs x 12 @rest: 60s
- 120 lbs x 12 @rest: 60s

## Superset: Triceps

### Tricep Pushdown
- 60 lbs x 12 @rest: 30s
- 60 lbs x 12 @rest: 30s

### Overhead Extension
- 40 lbs x 12 @rest: 60s
- 40 lbs x 12 @rest: 60s

## Cooldown

### Chest Stretch
- 60s

### Tricep Stretch
- 45s
```

**TC-V23: Deep header nesting (H3 workout)**
```markdown
# Training Log

## 2026 Program

### Week 1 - Push Day
@tags: push, week1

#### Bench Press
- 185 lbs x 5
- 205 lbs x 5
- 225 lbs x 3

#### Overhead Press
- 95 lbs x 8
- 115 lbs x 6
```

**TC-V24: Mixed set types in one exercise**
```markdown
# Functional Fitness

## Kettlebell Complex

Swing, hold, then max reps to finish.

- 53 lbs x 15
- 53 lbs x 60s
- 53 lbs x 45s
- 53 lbs x AMRAP

## Plank Progression
- 60s
- 45 lbs x 45s
- 45 lbs for 30s
- AMRAP
```

**TC-V25: All modifiers combined**
```markdown
# Modifier Showcase

## Bench Press

Heavy sets with rest, finishing with drops.

- 225 lbs x 5 @rest: 180s
- 225 lbs x 5 @rest: 180s
- 225 lbs x 5 @rest: 180s
- 185 lbs x 8 @dropset

## Side Plank Hold
- 45s @perside @rest: 30s
- 30s @perside @rest: 30s

## Single Arm Farmer Hold
- 70 lbs x 30s @perside @rest: 60s
- 70 lbs x 30s @perside
```

**TC-V26: Large workout (10 exercises, 50+ sets)**
```markdown
# Full Body - Week 8 Day 1
@tags: full-body, strength, hypertrophy, week8
@units: lbs

Today is the big one. Eat well, sleep well, lift well.

## Squat
- 135 x 5 @rest: 60s
- 225 x 5 @rest: 90s
- 315 x 3 @rest: 120s
- 365 x 3 @rest: 180s
- 365 x 3 @rest: 180s

## Bench Press
- 135 x 5 @rest: 60s
- 185 x 5 @rest: 90s
- 225 x 5 @rest: 120s
- 245 x 3 @rest: 180s
- 245 x 3 @rest: 180s

## Barbell Row
- 135 x 8 @rest: 60s
- 155 x 8 @rest: 90s
- 185 x 6 @rest: 90s
- 185 x 6 @rest: 90s
- 185 x 6 @rest: 90s

## Overhead Press
- 95 x 8 @rest: 60s
- 115 x 6 @rest: 90s
- 135 x 4 @rest: 120s
- 135 x 4 @rest: 120s
- 135 x 4 @rest: 120s

## Romanian Deadlift
- 135 x 8 @rest: 60s
- 185 x 8 @rest: 90s
- 225 x 6 @rest: 90s
- 225 x 6 @rest: 90s
- 225 x 6 @rest: 90s

## Dumbbell Lateral Raise
- 20 x 12 @rest: 45s
- 20 x 12 @rest: 45s
- 20 x 12 @rest: 45s
- 15 x 15 @dropset

## Barbell Curl
- 65 x 10 @rest: 60s
- 75 x 8 @rest: 60s
- 85 x 6 @rest: 60s
- 65 x 12 @dropset

## Tricep Pushdown
- 60 x 12 @rest: 60s
- 70 x 10 @rest: 60s
- 80 x 8 @rest: 60s
- 60 x 12 @dropset

## Plank
- 60s @rest: 30s
- 45 lbs x 45s @rest: 30s
- 45 lbs x 30s

## Hanging Leg Raise
- 15 @rest: 60s
- 12 @rest: 60s
- 10
```

**TC-V27: Exercise @type metadata**
```markdown
# Equipment Variety

## Bench Press
@type: barbell
- 225 lbs x 5

## Incline Press
@type: dumbbell
- 70 lbs x 10

## Cable Fly
@type: cable
- 30 lbs x 15

## Leg Press
@type: machine
- 360 lbs x 10

## Band Pull-Apart
@type: resistance band
- 20

## Goblet Squat
@type: kettlebell
- 53 lbs x 12
```

**TC-V28: Unknown metadata — silently ignored**
```markdown
# Forward Compatible Workout
@tags: test
@program: 5/3/1
@week: 3
@foo: bar

## Bench Press
@type: barbell
@video: https://example.com/bench
@difficulty: intermediate
- 225 lbs x 5
- 225 lbs x 5
```

**TC-V29: Deprecated modifiers (@rpe, @tempo)**
```markdown
# Legacy Format Workout

## Squat
- 315 lbs x 5 @rpe: 7 @rest: 180s
- 315 lbs x 5 @rpe: 8 @rest: 180s
- 315 lbs x 5 @rpe: 9 @rest: 180s

## Bench Press
- 185 lbs x 8 @tempo: 3-0-1-0 @rest: 90s
- 205 lbs x 6 @tempo: 3-0-1-0 @rest: 90s
- 225 lbs x 4 @tempo: 2-1-2-0 @rest: 120s

## Overhead Press
- 95 lbs x 8 @rpe: 6 @tempo: 2-0-1-0
- 115 lbs x 6 @rpe: 8 @tempo: 2-0-1-0
```

**TC-V29b: RPE rounding to nearest integer**
```markdown
# RPE Rounding Test

## Squat
- 225 x 5 @rpe: 8
- 225 x 5 @rpe: 8.5
- 225 x 5 @rpe: 8.3
- 225 x 5 @rpe: 8.7
```
✅ Parses successfully
- Set 1: targetRpe = 8 (no rounding warning)
- Set 2: targetRpe = 9 (⚠️ RPE rounded to nearest integer (8.5 → 9))
- Set 3: targetRpe = 8 (⚠️ RPE rounded to nearest integer (8.3 → 8))
- Set 4: targetRpe = 9 (⚠️ RPE rounded to nearest integer (8.7 → 9))
⚠️ @rpe is deprecated — use freeform notes instead (on all 4 sets)

**TC-V30: Every valid set format**
```markdown
# Every Set Format

## Weight and Reps Variations
- 225 x 5
- 225 lbs x 5
- 225 lbs x 5 reps
- 100 kg x 5
- 100 kg x 5 reps
- 27.5 x 10

## Bodyweight Variations
- 10
- x 10
- bw x 10

## Time Variations
- 60s
- 2m
- 90sec
- 1min

## Weighted Time Variations
- 45 lbs x 60s
- 100 kg x 30s
- 25 lbs for 45s
- 50 kg for 30s
- bw for 60s
- bw x 30s

## Distance Variations
- 200 meters
- 0.5 km
- 1 mile
- 1.5 mi
- 100 feet
- 100 ft
- 400 yards
- 50 yd

## AMRAP Variations
- 135 x AMRAP
- 135 lbs x AMRAP
- bw x AMRAP
- x AMRAP
- AMRAP
```

### Valid Test Cases — Distance

**TC-V31: Distance sets — all units**
```markdown
# Distance Workout

## Sprint
- 200 meters

## Long Run
- 5 km

## Mile Repeats
- 1 mile
- 1 mi

## Short Sprints
- 100 feet
- 100 ft

## Shuttle Runs
- 50 yards
- 50 yd
```

**TC-V32: Distance sets with decimal values**
```markdown
# Decimal Distances

## Morning Run
- 1.5 miles
- 2.5 km

## Track Work
- 0.5 km
- 1.25 miles
```

**TC-V33: Distance sets with rest modifiers**
```markdown
# Interval Training

## Rowing Intervals
- 500 meters @rest: 90s
- 500 meters @rest: 90s
- 500 meters @rest: 90s

## Sprint Intervals
- 200 meters @rest: 120s
- 200 meters @rest: 120s
- 200 meters @rest: 120s
```

**TC-V34: Mixed distance and other set types**
```markdown
# CrossFit WOD

## Rowing
- 500 meters

## Bench Press
- 135 lbs x 10

## Running
- 400 meters

## Plank
- 60s
```

### Invalid Test Cases — Structure Errors

**TC-E01: Empty file**
```markdown

```
❌ No workout header found. Must have a header (# Workout Name) with exercises below it.

**TC-E02: Whitespace only**
```markdown

```
❌ No workout header found. Must have a header (# Workout Name) with exercises below it.

**TC-E03: No headers — just text and sets**
```markdown
This is just some text about a workout.
Bench press was great today.
- 225 x 5
- 245 x 3
Some more notes.
```
❌ No workout header found. Must have a header (# Workout Name) with exercises below it.

**TC-E04: Header but no exercises**
```markdown
# My Workout Plan
@tags: planning

Just some notes about what I want to do today.
Maybe bench press and squats.
No actual exercises defined though.
```
❌ No workout header found. Must have a header (# Workout Name) with exercises below it.

**TC-E05: Exercise with no sets**
```markdown
# Push Day
## Bench Press

Great exercise, love it.

## Overhead Press

Another favorite.
```
❌ No workout header found. Must have a header (# Workout Name) with exercises below it.

**TC-E06: One exercise missing sets (others valid)**
```markdown
# Upper Body
## Bench Press
- 225 x 5
- 225 x 5

## Overhead Press

Forgot to add sets here.

## Barbell Row
- 155 x 8
- 155 x 8
```
❌ Line 6: Exercise "Overhead Press" has no sets

**TC-E07: Same-level headers (no hierarchy)**
```markdown
# Push Day
# Bench Press
- 225 x 5
# Overhead Press
- 135 x 8
```
❌ No workout header found. Must have a header (# Workout Name) with exercises below it.

**TC-E08: Exercise headers without workout header**
```markdown
## Bench Press
- 225 x 5
- 245 x 3

## Squat
- 315 x 5
```
❌ No workout header found. Must have a header (# Workout Name) with exercises below it.

### Invalid Test Cases — Unit/Format Errors

**TC-E09: Invalid units — "pounds"**
```markdown
# Push Day
@units: pounds

## Bench Press
- 225 x 5
```
❌ Line 2: Invalid @units value "pounds". Must be "lbs" or "kg"

**TC-E10: Invalid units — "kilograms"**
```markdown
# European Session
@units: kilograms

## Squat
- 100 x 5
```
❌ Line 2: Invalid @units value "kilograms". Must be "lbs" or "kg"

**TC-E11: Negative weight**
```markdown
# Bad Weights
## Squat
- -135 x 5
- -225 x 3
```
❌ Line 3: Invalid set format: "-135 x 5". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 4: Invalid set format: "-225 x 3". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 2: Exercise "Squat" has no sets

**TC-E12: Negative decimal weight**
```markdown
# Bad Decimal
## Dumbbell Curl
- -0.5 lbs x 10
- -2.5 kg x 8
```
❌ Line 3: Invalid set format: "-0.5 lbs x 10". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 4: Invalid set format: "-2.5 kg x 8". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 2: Exercise "Dumbbell Curl" has no sets

**TC-E13: Unparseable set text**
```markdown
# Bad Sets
## Bench Press
- felt great today
- really pushed hard
- best session ever
```
❌ Line 3: Invalid set format: "felt great today". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 4: Invalid set format: "really pushed hard". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 5: Invalid set format: "best session ever". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 2: Exercise "Bench Press" has no sets

**TC-E14: Weight with unit but no reps/time**
```markdown
# Incomplete Sets
## Squat
- 135 lbs
- 225 lbs
- 100 kg
```
❌ Line 3: Incomplete set: "135 lbs". Weight with unit requires reps (x 5) or time (x 60s). For distance, omit the weight (e.g., "200 meters")
❌ Line 4: Incomplete set: "225 lbs". Weight with unit requires reps (x 5) or time (x 60s). For distance, omit the weight (e.g., "200 meters")
❌ Line 5: Incomplete set: "100 kg". Weight with unit requires reps (x 5) or time (x 60s). For distance, omit the weight (e.g., "200 meters")
❌ Line 2: Exercise "Squat" has no sets

**TC-E15: Zero reps**
```markdown
# Zero Reps
## Bench Press
- 225 x 0
- 185 x 0
```
❌ Line 3: Reps/time must be positive
❌ Line 4: Reps/time must be positive
❌ Line 2: Exercise "Bench Press" has no sets

**TC-E16: Zero time**
```markdown
# Zero Time
## Plank
- 0s
- 0m
```
❌ Line 3: Reps/time must be positive
❌ Line 4: Reps/time must be positive
❌ Line 2: Exercise "Plank" has no sets

### Invalid Test Cases — Modifier Errors

**TC-E17: Negative rest time**
```markdown
# Bad Rest
## Bench Press
- 225 x 5 @rest: -30s
- 225 x 5 @rest: -60s
```
❌ Line 3: Invalid rest time format: -30s. Expected format: "180s" or "3m"
❌ Line 4: Invalid rest time format: -60s. Expected format: "180s" or "3m"

**TC-E18: Non-numeric rest**
```markdown
# Bad Rest Format
## Squat
- 315 x 5 @rest: abc
- 315 x 3 @rest: long
```
❌ Line 3: Invalid rest time format: abc. Expected format: "180s" or "3m"
❌ Line 4: Invalid rest time format: long. Expected format: "180s" or "3m"

**TC-E19: RPE below range (0)**
```markdown
# RPE Below Range
## Squat
- 315 x 5 @rpe: 0
```
❌ Line 3: RPE must be between 1-10, got: 0

**TC-E20: RPE above range (11+)**
```markdown
# RPE Above Range
## Squat
- 405 x 1 @rpe: 11
- 405 x 1 @rpe: 15
```
❌ Line 3: RPE must be between 1-10, got: 11
❌ Line 4: RPE must be between 1-10, got: 15

**TC-E21: RPE non-numeric**
```markdown
# RPE Bad Format
## Bench Press
- 225 x 5 @rpe: hard
- 225 x 3 @rpe: max
```
❌ Line 3: Invalid RPE format: hard
❌ Line 4: Invalid RPE format: max

**TC-E22: Tempo — wrong segment count**
```markdown
# Bad Tempo
## Squat
- 225 x 5 @tempo: 3-0-1
- 225 x 5 @tempo: 2-1
```
❌ Line 3: Invalid tempo format: 3-0-1. Expected format: "X-X-X-X" (e.g., "3-0-1-0")
❌ Line 4: Invalid tempo format: 2-1. Expected format: "X-X-X-X" (e.g., "3-0-1-0")

**TC-E23: Tempo — non-numeric**
```markdown
# Tempo Nonsense
## Bench Press
- 185 x 8 @tempo: slow
- 205 x 6 @tempo: fast-down
```
❌ Line 3: Invalid tempo format: slow. Expected format: "X-X-X-X" (e.g., "3-0-1-0")
❌ Line 4: Invalid tempo format: fast-down. Expected format: "X-X-X-X" (e.g., "3-0-1-0")

**TC-E24: Rest — non-numeric unit**
```markdown
# Bad Rest Unit
## Bench Press
- 225 x 5 @rest: minutes
- 225 x 3 @rest: forever
```
❌ Line 3: Invalid rest time format: minutes. Expected format: "180s" or "3m"
❌ Line 4: Invalid rest time format: forever. Expected format: "180s" or "3m"

### Invalid Test Cases — Distance Errors

**TC-E31: Zero distance**
```markdown
# Zero Distance
## Sprint
- 0 meters
- 0 km
```
❌ Line 3: Distance must be positive
❌ Line 4: Distance must be positive
❌ Line 2: Exercise "Sprint" has no sets

**TC-E32: Negative distance**
```markdown
# Negative Distance
## Sprint
- -100 meters
```
❌ Line 3: Invalid set format: "-100 meters". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 2: Exercise "Sprint" has no sets

**TC-E33: Distance with reps (invalid combination)**
```markdown
# Distance With Reps
## Sprint
- 200 meters x 5
```
❌ Line 3: Invalid set format: "200 meters x 5". Distance sets cannot have reps. Write separate sets or use freeform notes for programming.

**TC-E34: Weight with distance (unsupported combination)**
```markdown
# Weighted Distance
## Farmer Carry
- 70 lbs x 100 meters
```
❌ Line 3: Invalid set format: "70 lbs x 100 meters". Combined weight and distance is not supported.

### Invalid Test Cases — Combined/Edge Errors

**TC-E25: Valid workout with one bad set**
```markdown
# Mostly Good Workout
## Bench Press
- 135 x 5
- 185 x 5
- this set was amazing
- 225 x 3
```
❌ Line 5: Invalid set format: "this set was amazing". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"

**TC-E26: All sets unparseable**
```markdown
# All Bad Sets
## Bench Press
- went heavy
- felt strong
- crushed it
```
❌ Line 3: Invalid set format: "went heavy". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 4: Invalid set format: "felt strong". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 5: Invalid set format: "crushed it". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 2: Exercise "Bench Press" has no sets

**TC-E27: Multiple error types at once**
```markdown
# Kitchen Sink of Errors
@units: stones

## Bench Press
- great set
- -100 x 5

## Overhead Press

## Squat
- 225 x 0
```
❌ Line 2: Invalid @units value "stones". Must be "lbs" or "kg"
❌ Line 5: Invalid set format: "great set". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 6: Invalid set format: "-100 x 5". Expected format: "weight unit x reps" or "time" or "distance" or "AMRAP"
❌ Line 4: Exercise "Bench Press" has no sets
❌ Line 8: Exercise "Overhead Press" has no sets
❌ Line 11: Reps/time must be positive
❌ Line 10: Exercise "Squat" has no sets

**TC-E28: Empty exercise name**
```markdown
# Push Day
##
- 225 x 5
```
❌ No workout header found. Must have a header (# Workout Name) with exercises below it.

**TC-E29: Multiple negative rest values**
```markdown
# Push Day
## Bench Press
- 225 x 5 @rest: -60s
- 225 x 5 @rest: -120s
- 225 x 3 @rest: -180s
```
❌ Line 3: Invalid rest time format: -60s. Expected format: "180s" or "3m"
❌ Line 4: Invalid rest time format: -120s. Expected format: "180s" or "3m"
❌ Line 5: Invalid rest time format: -180s. Expected format: "180s" or "3m"

**TC-E30: Superset with no child exercises**
```markdown
# Arm Day
## Superset: Arms

No actual child exercises here, just notes.

## Barbell Curl
- 65 x 10
```
❌ Line 2: Exercise "Superset: Arms" has no sets

---

## Changelog

### Version 1.2 (2026-03-30)
- **Added distance-based sets** — new set type for cardio/conditioning exercises
- Supported distance units: `meters`, `km`, `miles`/`mi`, `feet`/`ft`, `yards`/`yd`
- Note: `m` remains reserved for minutes — use `meters` for metric distance
- Distance sets are standalone targets (no combined weight+distance or distance+reps)
- Added Example 9 (distance-based conditioning workout)
- Added test cases TC-V31 through TC-V34 (valid) and TC-E31 through TC-E34 (invalid)

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
9. ✅ **Distance-Based Sets**: Standalone set type for cardio/conditioning (e.g., `200 meters`, `1 mile`)
   - `m` stays as minutes — use `meters` for metric distance (avoids ambiguity)
   - No combined weight+distance (e.g., weighted carries use either weight+time or distance, not both)
   - No distance+reps combination — repeat as separate sets instead
   - No unit conversion between distance units

---

**Document Version:** 1.4
**Last Updated:** 2026-05-22
