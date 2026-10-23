# LiftMark Data Model

> Canonical reference for all domain entities, their fields, constraints, defaults, relationships, and business rules.
>
> This data model defines the shared contract between app versions and platform implementations. Any implementation must represent these entities with these fields to ensure data portability and interoperability.

---

## Enums

| Name | Values | Usage |
|------|--------|-------|
| WeightUnit | `lbs`, `kg` | Weight measurement throughout the app |
| SetStatus | `pending`, `completed`, `skipped`, `failed` | SessionSet lifecycle |
| ExerciseStatus | `pending`, `in_progress`, `completed`, `skipped` | SessionExercise lifecycle |
| SessionStatus | `in_progress`, `completed`, `canceled` | WorkoutSession lifecycle |
| GroupType | `superset`, `section` | Exercise grouping. `superset` = performed together; `section` = organizational heading |
| Theme | `light`, `dark`, `auto` | UI theme preference |
| ApiKeyStatus | `verified`, `invalid`, `not_set` | Legacy Anthropic key status; read only by the one-time migration (see `spec/services/ai-providers.md`) |
| AIProvider | `anthropic`, `openai`, `gemini`, `ollama` | BYOK LLM provider |
| AIKeyStatus | `verified`, `unverified`, `invalid` | Per-provider-key verification state |
| ChartMetricType | `maxWeight`, `totalVolume`, `reps`, `time` | Exercise history chart metric selector |
| Trend | `improving`, `stable`, `declining` | Exercise progress direction (based on last 5 sessions, >5% threshold) |

---

## Entities

### WorkoutPlan

A reusable workout template that defines exercises and target sets. Created from LMWF markdown or AI generation.

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| id | string | Yes | UUID | Primary key |
| name | string | Yes | — | From `# Heading` in LMWF |
| description | string | No | — | Freeform notes from markdown |
| tags | string[] | Yes | [] | From `@tags:` directive |
| defaultWeightUnit | WeightUnit | No | — | From `@units:` directive |
| sourceMarkdown | string | No | — | Original LMWF text for reprocessing |
| createdAt | datetime | Yes | — | ISO 8601 |
| updatedAt | datetime | Yes | — | ISO 8601 |
| isFavorite | boolean | No | false | Pinned to favorites list |
| exercises | PlannedExercise[] | Yes | [] | Ordered list of exercises |

---

### PlannedExercise

An exercise within a WorkoutPlan, defining what to perform and in what order.

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| id | string | Yes | UUID | Primary key |
| workoutPlanId | string | Yes | — | FK to WorkoutPlan (cascade delete) |
| exerciseName | string | Yes | — | Freeform exercise name |
| orderIndex | number | Yes | — | 0-based position in workout |
| notes | string | No | — | Freeform notes from markdown |
| equipmentType | string | No | — | Freeform equipment (e.g., "barbell", "kettlebell") |
| groupType | GroupType | No | — | Grouping semantics |
| groupName | string | No | — | E.g., "Superset: Arms" or "Warmup" |
| parentExerciseId | string | No | — | FK to PlannedExercise (cascade); links child to superset/section parent |
| sets | PlannedSet[] | Yes | [] | Ordered list of target sets |

**Business rules**:
- Superset parent exercises (`groupType = superset`) have no sets of their own; their children hold the sets.
- Section parents (`groupType = section`) are organizational headers only.
- `orderIndex` determines display and execution order.

---

### PlannedSet

A single target set within a PlannedExercise. Measurement values (weight, reps, time, distance, RPE) are stored as SetMeasurement entries rather than inline fields.

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| id | string | Yes | UUID | Primary key |
| plannedExerciseId | string | Yes | — | FK to PlannedExercise (cascade) |
| orderIndex | number | Yes | — | 0-based position within exercise |
| entries | SetEntry[] | Yes | [] | Target measurements grouped by entry |
| restSeconds | number | No | — | Rest period after this set |
| isDropset | boolean | No | false | Drop set indicator |
| isPerSide | boolean | No | false | Per-side indicator for unilateral exercises |
| isAmrap | boolean | No | false | As Many Reps As Possible indicator |
| notes | string | No | — | Additional notes from set line |

**Business rules**:
- A set is either rep-based (targetReps) or time-based (targetTime), not both.
- isAmrap overrides targetReps — the rep count becomes a minimum/suggestion.
- isDropset indicates this set is part of a drop-set sequence with decreasing weight.
- For normal sets, `entries` contains one SetEntry at groupIndex=0 with target values.
- For drop sets, `entries` may contain multiple SetEntry elements (one per drop) with targets at groupIndex 0, 1, 2, etc.

---

### WorkoutSession

An actual workout instance being performed or already completed. Created from a WorkoutPlan.

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| id | string | Yes | UUID | Primary key |
| workoutPlanId | string | No | — | FK to WorkoutPlan (set null on delete); null if custom/imported |
| name | string | Yes | — | Copied from plan name at session creation |
| date | date | Yes | — | ISO date (YYYY-MM-DD) |
| startTime | datetime | No | — | ISO 8601 |
| endTime | datetime | No | — | ISO 8601, set on completion |
| duration | number | No | — | Seconds, calculated on completion |
| notes | string | No | — | Workout-level free-text notes. Editable mid-session, promptable at the finish screen, editable later from history. Whitespace-only input is normalized to null. See `spec/screens/active-workout.md`, `spec/screens/workout-summary.md`, `spec/screens/history-detail.md`, and GH #91. |
| exercises | SessionExercise[] | Yes | [] | Ordered list of exercises |
| status | SessionStatus | Yes | in_progress | Session lifecycle state |

**Business rules**:
- Only one session can have `status = in_progress` at a time.
- `duration` is computed as `endTime - startTime` in seconds on completion.
- Deleting a plan sets workoutPlanId to null (preserves session history).
- `notes` belong to the session, not the plan. Editing session notes never mutates the source plan. LMWF export emits session notes as the workout-level freeform notes block (see `liftmark-workout-format/LIFTMARK_WORKOUT_FORMAT_SPEC.md` §Workout Header).

---

### SessionExercise

An exercise within an active or completed workout session.

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| id | string | Yes | UUID | Primary key |
| workoutSessionId | string | Yes | — | FK to WorkoutSession (cascade) |
| exerciseName | string | Yes | — | Copied from plan or user-entered |
| orderIndex | number | Yes | — | 0-based position |
| notes | string | No | — | |
| equipmentType | string | No | — | |
| groupType | GroupType | No | — | |
| groupName | string | No | — | |
| parentExerciseId | string | No | — | FK to SessionExercise (cascade) |
| sets | SessionSet[] | Yes | [] | Ordered list of sets |
| status | ExerciseStatus | Yes | pending | |

**Business rules**:
- Exercise status auto-completes when all its sets are completed or skipped.
- "Trackable" exercises are those with `sets.length > 0` (excludes superset parent headers).

---

### SessionSet

A single set within a session exercise, tracking both target and actual performance. Measurement values are stored as SetMeasurement entries rather than inline fields.

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| id | string | Yes | UUID | Primary key |
| sessionExerciseId | string | Yes | — | FK to SessionExercise (cascade) |
| orderIndex | number | Yes | — | 0-based position |
| entries | SetEntry[] | Yes | [] | Target and actual measurements grouped by entry |
| restSeconds | number | No | — | Rest period after this set |
| completedAt | datetime | No | — | ISO 8601 |
| status | SetStatus | Yes | pending | |
| notes | string | No | — | |
| isDropset | boolean | No | false | |
| isPerSide | boolean | No | false | |
| isAmrap | boolean | No | false | |
| side | string | No | — | "left" or "right" for expanded per-side timed sets, nil otherwise |

**Business rules**:
- On completion, if no actual values are provided, values are copied from targets.
- Each entry in `entries` has a groupIndex, target values, and actual values.
- For normal sets: one entry at groupIndex=0.
- For drop sets: multiple entries (one per drop) at groupIndex 0, 1, 2, etc. During recording, user can add drops dynamically.
- Completing a set automatically advances the session to the next pending set.
- During session creation, timed per-side sets (`isPerSide && targetTime != nil`) are expanded into two sets with `side = "left"` and `side = "right"`. Each gets its own timer and records `actualTime` independently.

---

### SetMeasurement

A single measurement value associated with a set. Measurements are stored in a normalized table rather than inline on the set.

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| id | string | Yes | UUID | Primary key |
| setId | string | Yes | — | FK to SessionSet or PlannedSet (no cascade — explicit delete required) |
| parentType | string | Yes | — | `"session"` or `"planned"` |
| role | string | Yes | — | `"target"` or `"actual"` |
| kind | string | Yes | — | `"weight"`, `"reps"`, `"time"`, `"distance"`, `"rpe"` |
| value | number | Yes | — | Numeric value |
| unit | string | No | — | `"lbs"`, `"kg"`, `"meters"`, `"km"`, `"miles"`, `"feet"`, `"yards"`, `"s"` — nil for dimensionless (reps, RPE) |
| groupIndex | number | Yes | 0 | Groups co-recorded measurements into entries |
| updatedAt | datetime | No | — | ISO 8601 for sync |

**Business rules**:
- Measurements with the same `(setId, groupIndex)` belong to the same entry.
- groupIndex=0 for normal sets. Drop sets use 0, 1, 2, etc.
- No ON DELETE CASCADE — deleting a set requires explicitly deleting its measurements first.

---

### SetEntry (Facade)

Not persisted directly — assembled from SetMeasurement rows at read time.

| Field | Type | Description |
|-------|------|-------------|
| groupIndex | number | Entry position (0 for normal sets, 0..N for drop sets) |
| target | EntryValues? | Target measurements (from plan) |
| actual | EntryValues? | Actual measurements (from recording) |

### EntryValues (Facade)

| Field | Type | Description |
|-------|------|-------------|
| weight | MeasuredWeight? | Weight value + unit |
| reps | number? | Rep count |
| time | number? | Seconds |
| distance | MeasuredDistance? | Distance value + unit |
| rpe | number? | Rate of Perceived Exertion, 1-10 |

---

### UserSettings

Singleton record for user preferences.

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| id | string | Yes | UUID | Primary key |
| defaultWeightUnit | WeightUnit | Yes | lbs | |
| enableWorkoutTimer | boolean | Yes | true | |
| autoStartRestTimer | boolean | Yes | true | |
| theme | Theme | Yes | auto | |
| notificationsEnabled | boolean | Yes | true | |
| customPromptAddition | string | No | — | Appended to AI workout generation prompts |
| anthropicApiKey | string | No | — | Legacy. Migrated into the Keychain provider-key list (`ai_provider_keys`), NOT in database |
| anthropicApiKeyStatus | ApiKeyStatus | No | not_set | Legacy. Read only by the one-time migration; no longer written |
| healthKitEnabled | boolean | Yes | false | Sync to Apple Health |
| liveActivitiesEnabled | boolean | Yes | true | Show on lock screen |
| keepScreenAwake | boolean | Yes | true | During active workouts |
| showOpenInClaudeButton | boolean | Yes | false | Always show "Open in Claude" button |
| hasAcceptedDisclaimer | boolean | Yes | false | Whether user has accepted the onboarding disclaimer |
| homeTiles | string[] | No | [Squat, Deadlift, Bench Press, Overhead Press] | Custom home screen max lift tiles |
| createdAt | datetime | Yes | — | ISO 8601 |
| updatedAt | datetime | Yes | — | ISO 8601 |

**Business rules**:
- Exactly one record exists; initialized on first launch.
- BYOK provider keys (`AIProviderKey`: provider, key, model, Ollama base URL, `AIKeyStatus`) live as an ordered list in the Keychain, never in the database. See `spec/services/ai-providers.md`.
- The actual API key must be stored in platform-native secure storage, not in the main database.

---

### Gym

A gym location for organizing equipment availability.

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| id | string | Yes | UUID | Primary key |
| name | string | Yes | — | e.g., "Home Gym", "LA Fitness" |
| isDefault | boolean | Yes | false | Only one gym should be default at a time |
| createdAt | datetime | Yes | — | ISO 8601 |
| updatedAt | datetime | Yes | — | ISO 8601 |

**Business rules**:
- A default gym ("My Gym") is created on first launch.
- Cannot delete the last gym.
- Setting a new default unsets all other gyms' isDefault first.

---

### GymEquipment

Equipment availability at a specific gym.

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| id | string | Yes | UUID | Primary key |
| gymId | string | Yes | — | FK to Gym (cascade on delete) |
| name | string | Yes | — | Equipment name; must be unique within a gym |
| isAvailable | boolean | Yes | true | Whether currently available |
| lastCheckedAt | datetime | No | — | Updated when toggling availability |
| createdAt | datetime | Yes | — | ISO 8601 |
| updatedAt | datetime | Yes | — | ISO 8601 |

**Business rules**:
- Equipment name must be unique within a gym.
- Equipment is deleted when its gym is deleted.
- Preset equipment categories available for quick-add (see below).

---

### Exercise (Catalog — Not Persisted)

A catalog entry for exercise suggestions and history aggregation. Not currently persisted to a dedicated table — exercise names are stored inline on PlannedExercise/SessionExercise.

| Field | Type | Required | Default |
|-------|------|----------|---------|
| id | string | Yes | UUID |
| name | string | Yes | — |
| category | string | No | — |
| muscleGroups | string[] | No | — |
| equipmentType | string | No | — |
| description | string | No | — |
| isCustom | boolean | Yes | — |
| createdAt | datetime | Yes | — |

---

## Relationships

```
WorkoutPlan 1──* PlannedExercise 1──* PlannedSet 1──* SetMeasurement (parentType=planned)
     │
     │ (FK, set null on delete)
     ▼
WorkoutSession 1──* SessionExercise 1──* SessionSet 1──* SetMeasurement (parentType=session)

Gym 1──* GymEquipment

PlannedExercise ──> PlannedExercise (parentExerciseId, self-ref for supersets/sections)
SessionExercise ──> SessionExercise (parentExerciseId, self-ref for supersets/sections)
```

---

## Preset Equipment

| Category | Items |
|----------|-------|
| **Free Weights** | Barbell, Dumbbells, Kettlebells, Weight Plates, EZ Curl Bar |
| **Benches & Racks** | Flat Bench, Incline Bench, Adjustable Bench, Squat Rack, Power Rack, Smith Machine |
| **Machines** | Cable Machine, Lat Pulldown, Leg Press, Leg Curl, Leg Extension, Chest Press Machine, Shoulder Press Machine, Row Machine |
| **Cardio** | Treadmill, Stationary Bike, Rowing Machine, Elliptical, Stair Climber |
| **Other** | Pull-up Bar, Dip Station, Resistance Bands, TRX/Suspension Trainer, Medicine Ball, Battle Ropes, Foam Roller |
