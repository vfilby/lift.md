# LMWF Parser Service Specification

## Purpose

Parse LiftMark Workout Format (LMWF) markdown into WorkoutPlan objects. LMWF is a custom markdown-based format that represents workout plans using headers for structure, list items for sets, and @-prefixed metadata for configuration.

## Public API

### `parseWorkout(markdown: string): ParseResult<WorkoutPlan>`

Parse markdown text into a workout plan. Returns a result object containing the parsed plan (if successful), validation errors, and validation warnings.

## Behavior Rules

### Document Structure

- One workout per document.
- Flexible header levels: the workout can be any H1-H6 header.
- Exercises must be exactly one header level below the workout header.
- The workout header is detected as the first header that has child headers containing list items (sets).
- Freeform text after headers is captured as notes for that header's context (workout notes or exercise notes).

### Workout Metadata

- `@tags:` comma-separated tags attached to the workout (e.g., `@tags: strength, upper`).
- `@units:` weight unit for the workout, either `lbs` or `kg`. Aliases `lb` and `kgs` are accepted and normalized.

### Exercises

- Detected as headers one level below the workout header.
- `@type:` optional equipment type annotation on exercises.

### Supersets

- Headers containing the word "superset" (case-insensitive) are treated as superset groups.
- Child exercise headers within a superset can be at ANY deeper header level.

### Sections

- Nested headers that do not contain the "superset" keyword are treated as organizational sections (e.g., Warmup, Main Workout, Cool Down).
- A section header is a header at exercise level that has child headers containing sets, but does not contain the word "superset".
- Exercises within a section are child headers one level below the section header.
- Section exercises are parsed as individual exercises belonging to that section — they are not grouped like superset exercises.
- Sections are purely organizational; they do not affect how exercises or sets are parsed.
- A workout can mix sections, supersets within sections, and top-level exercises freely.

**Example:**

```markdown
# Lower Body Workout
@units: lbs

## Warmup              ← Section header (organizational)
### Arm Circles        ← Exercise within section
- 30s
### Band Pull-Aparts   ← Exercise within section
- x 15

## Main Workout        ← Section header
### Deadlift           ← Exercise within section
- 135 x 5
- 225 x 3

## Bench Press         ← Top-level exercise (no section)
- 185 x 5
```

See `test-fixtures/sections-with-exercises.md` and `test-fixtures/sections-supersets-test.md` for comprehensive test cases.

### Set Formats

| Format | Example | Meaning |
|---|---|---|
| `weight x reps` | `225 x 5` | Weighted set |
| `weight unit x reps` | `225 lbs x 5` | Weighted set with explicit unit |
| `bw x reps` or `x reps` | `bw x 10` | Bodyweight set |
| Single number | `15` | Bodyweight reps |
| `time` | `60s`, `2m` | Timed set |
| `weight x time` | `135 x 30s` | Weighted timed hold |
| `weight for time` | `135 for 30s` | Weighted timed hold (alternate syntax) |
| `AMRAP` | `AMRAP` | As many reps as possible (bodyweight) |
| `weight x AMRAP` | `225 x AMRAP` | Weighted AMRAP |

### Set Modifiers

Modifiers use the `@` prefix and appear after set content on the same line.

| Modifier | Type | Description |
|---|---|---|
| `@rpe` | Value (1-10) | Rate of perceived exertion |
| `@rest` | Time value | Rest period; triggers countdown timer in app |
| `@tempo` | X-X-X-X | Eccentric-pause-concentric-pause tempo |
| `@dropset` | Flag | Marks set as a drop set |
| `@perside` | Flag | Marks set as per-side (unilateral) |

**Auto-detection**: If an exercise's notes contain any of the following keywords (case-insensitive), all timed sets (`targetTime != nil`) in that exercise are automatically flagged with `isPerSide = true`. Rep-based sets are not affected. This allows writing the keyword once in the exercise notes rather than `@perside` on every set line.

Recognized keywords: "per side", "per leg", "per arm", "each side", "each leg", "each arm", "each"

**Test requirements for auto-detection keywords:**
- "per side" flags timed sets as isPerSide (existing)
- "per leg" flags timed sets as isPerSide
- "per arm" flags timed sets as isPerSide
- "each side" flags timed sets as isPerSide
- "each leg" flags timed sets as isPerSide
- "each arm" flags timed sets as isPerSide
- "each" flags timed sets as isPerSide
- Rep-based sets with any of these keywords are NOT flagged

Trailing text after all modifiers on a set line is captured as set notes.

### Line Preprocessing

- Normalizes line endings: CRLF and CR are converted to LF.
- Parses headers (one to six `#` followed by at least one space, then text), list items (lines starting with `-`), and metadata lines (lines starting with `@`). Everything else is plain text.
- A **malformed header** is a trimmed line matching `^#{1,6}[^#\s]` — header marks with no space before the text (`#push day`). It is plain text to the structural parser, but it is also recorded so it can be reported as `MALFORMED_HEADER` (below) with the corrected line (`# push day`).

### Quick Fixes

`LMWFParseResult.fixes` (`[LMWFQuickFix]`) lists machine-applicable corrections for diagnostics that have an unambiguous repair. Each fix is `{ line, original, replacement }`: a 1-based line number in the normalized document, the trimmed text currently on that line, and the full corrected line. `LMWFQuickFix.applying(_:to:)` applies a batch to a markdown string: it normalizes line endings, and for each fix replaces the line **only if** its trimmed text still equals `original` (indentation is preserved), so a stale fix never clobbers text the user has since changed. Today the only producer is `MALFORMED_HEADER`; both parsers (Swift and the TypeScript validator) emit identical fixes. `errors` and `warnings` remain plain strings for existing consumers.

## Validation Errors (Blocking)

These prevent a successful parse and must be reported in the errors array:

- No workout header found in the document.
- `MALFORMED_HEADER` — reported *before* the no-workout-header error, once per malformed header line in the document, whenever no workout header is found. Message: `Line N: Header "#push day" is missing a space after "#". Write "# push day".` Each carries a quick fix. (GH #472: the generic message alone gave the user nothing to act on.)
- No exercises found in the workout.
- Exercise has no sets.
- Negative weight value.
- Invalid `@units` value (not lbs, lb, kg, or kgs).
- Invalid set format (cannot be parsed as any recognized format).
- Invalid RPE value (not in range 1-10).
- Invalid rest time format.
- Invalid tempo format (not X-X-X-X pattern).

## Validation Warnings (Non-blocking)

These are reported but do not prevent parsing:

- Very high rep count (greater than 100).
- Very short rest period (less than 10 seconds).
- Very long rest period (greater than 600 seconds).
- Unknown modifier (unrecognized @-prefixed token on a set line).
- `STANDALONE_MODIFIER` — a set modifier on its own line where it has no effect.
- `IGNORED_LINE` — a non-empty, non-set line after an exercise's first set; the text is not captured.
- `MALFORMED_HEADER` — a malformed header (see Line Preprocessing) after an exercise's first set. Reported instead of `IGNORED_LINE`, with the same message as the error form plus: `Until it is fixed, the set lines below it count toward the exercise above.` Carries a quick fix.

## Dependencies

- `generateId()` from `utils/id` for assigning unique identifiers to parsed entities.

## Error Handling

The parser returns a `ParseResult` object that contains errors and warnings arrays. It does not throw exceptions for invalid input; all parse failures are reported through the result object.
