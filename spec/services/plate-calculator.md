# Plate Calculator Service Specification

## Purpose

Calculate the optimal combination of weight plates needed per side of a barbell to reach a target weight. Displayed as an informational breakdown on the Active Workout screen for barbell exercises.

## Public API

### `isBarbellExercise(exerciseName, equipmentType?): boolean`

Determines whether an exercise uses a barbell and should show the plate calculator.

**Logic (evaluated in order):**
1. If `equipmentType` contains "barbell" (case-insensitive) → `true`.
2. If `exerciseName` contains "barbell" (case-insensitive) → `true`.
3. If `exerciseName` contains any exclusion keyword → `false`.
4. If `exerciseName` matches any known barbell exercise → `true`.
5. Otherwise → `false`.

**Exclusion keywords:** `dumbbell`, `kettlebell`, `bodyweight`, `cable`, `machine`

**Known barbell exercises:** `deadlift`, `bench press`, `overhead press`, `strict press`, `power clean`, `hang clean`, `clean and jerk`, `snatch`, `front squat`, `back squat`, `romanian deadlift`, `rdl`, `bent over row`, `pendlay row`

All matching is case-insensitive substring matching.

### `calculatePlates(totalWeight, unit?, barWeight?): PlateBreakdown`

Calculates the optimal plate combination using a greedy algorithm.

**Parameters:**
- `totalWeight` — The target total weight (bar + plates).
- `unit` — `'lbs'` (default) or `'kg'`.
- `barWeight` — Override bar weight. Defaults to standard bar for the unit.

**Algorithm:**
1. Subtract bar weight from total weight.
2. Divide by 2 to get weight per side.
3. If weight per side is negative, return empty breakdown with `isAchievable: false`.
4. Starting from the heaviest available plate, greedily fit as many as possible.
5. Move to the next smaller plate and repeat.
6. If remaining weight after all plates is < 0.01, mark as achievable.

### `formatPlateBreakdown(breakdown): string`

Formats the per-side plate list as a human-readable string.

**Examples:**
- `"45lbs + 25lbs + 5lbs"` (one of each)
- `"2×45lbs + 10lbs"` (two 45s and one 10)
- `"Bar only"` (no plates needed)
- `"45lbs + 25lbs (+0.5lbs short)"` (not exactly achievable)

### `formatCompletePlateSetup(breakdown): string`

Formats the complete setup including bar weight.

**Example:** `"45lb bar + 135lbs per side"`

### Number formatting

All weight values (plate weights, per-side totals, bar weight) are formatted for
display by rounding to the nearest 0.01 and then rendering with the fewest decimal
places needed:

- Whole numbers show no decimal: `45` → `"45"`.
- Half/quarter increments keep their precision: `2.5` → `"2.5"`, `1.25` → `"1.25"`.
- Per-side totals that land on a quarter-plate boundary must **not** be truncated
  to a single decimal. A 112.5 lb target on a 45 lb bar is 33.75 lb per side and
  must read `"45lb bar + 33.75lbs per side"` — never `"33.8"` (GH #211).

The `(+N short)` remainder suffix is the lone exception: it is an approximate
"can't be made with standard plates" hint and is rendered with one decimal place.

## Types

### PlateBreakdown

| Field         | Type    | Description |
|---------------|---------|-------------|
| weightPerSide | number  | Total plate weight per side (excluding bar) |
| unit          | string  | `'lbs'` or `'kg'` |
| plates        | array   | Array of `{ weight: number, count: number }` per side, heaviest first |
| isAchievable  | boolean | Whether the target is exactly reachable with standard plates |
| remainder     | number? | Remaining weight if not achievable |
| barWeight     | number  | Bar weight used in the calculation |

## Reference Data

### Standard Bar Weights

| Unit | Bar Weight |
|------|-----------|
| lbs  | 45        |
| kg   | 20        |

### Standard Plate Weights (per side, heaviest first)

| Pounds | Kilograms |
|--------|-----------|
| 45     | 25        |
| 35     | 20        |
| 25     | 15        |
| 10     | 10        |
| 5      | 5         |
| 2.5    | 2.5       |
|        | 1.25      |

## Active Workout Integration

On the Active Workout screen, for exercises identified as barbell exercises by `isBarbellExercise`:

- Display the plate breakdown in a blue info box above the weight input fields.
- Update the breakdown whenever the target or actual weight value changes.
- Show the per-side plate list using `formatPlateBreakdown`.

## Error Handling

- If `totalWeight` is less than the bar weight, return a breakdown with `isAchievable: false`, empty plates, and a negative remainder. The UI should handle this gracefully (e.g., show "Bar only" or hide the info box).
- Floating-point comparison uses a tolerance of 0.01 for the achievability check.
