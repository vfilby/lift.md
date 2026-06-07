# Import/Export Schema

> Portable interchange formats for LiftMark data. Defines the JSON export format, LMWF markdown import format, and database backup format.
>
> Source of truth: `src/services/workoutExportService.ts`, `src/services/fileImportService.ts`, `src/services/databaseBackupService.ts`

> **Schema `$id` migration (GH #248)**: the export schemas' `$id` URLs moved
> from `https://liftmark.app/schemas/…` to `https://getlift.md/schemas/…`. The
> `$id` is a JSON-Schema *identifier*, not a fetch location — every consumer
> (`tools/validate_export.py`, the iOS `WorkoutExportIntegrationTests`) loads the
> schema by local file path, so the rename is brand-only and breaks no resolver.
> For any external party that did dereference the old URL, the redirect topology
> (see `services/lmwf-validator.md`) 301-redirects `liftmark.app/schemas/*` to
> `getlift.md/schemas/*`, so the old identifier still resolves to the same file.

---

## JSON Export Format

> **Machine-readable schemas**: [`schemas/liftmark-export-single.schema.json`](schemas/liftmark-export-single.schema.json) and [`schemas/liftmark-export-multi.schema.json`](schemas/liftmark-export-multi.schema.json) (JSON Schema draft 2020-12). Use `tools/validate_export.py` to validate export files.

### Multi-Session Export

Exported by `exportSessionsAsJson()`. Contains all completed workout sessions.

**File naming**: `liftmark_workouts_{YYYY-MM-DD_HH-MM-SS}.json`

```json
{
  "exportedAt": "2026-02-20T10:30:00.000Z",
  "appVersion": "1.5.0",
  "sessions": [
    {
      "name": "Push Day",
      "date": "2026-02-20",
      "startTime": "2026-02-20T10:00:00.000Z",
      "endTime": "2026-02-20T11:15:00.000Z",
      "duration": 4500,
      "notes": "Felt strong today",
      "status": "completed",
      "exercises": [
        {
          "exerciseName": "Bench Press",
          "orderIndex": 0,
          "notes": null,
          "equipmentType": "barbell",
          "groupType": null,
          "groupName": null,
          "status": "completed",
          "sets": [
            {
              "orderIndex": 0,
              "targetWeight": 135,
              "targetWeightUnit": "lbs",
              "targetReps": 10,
              "targetTime": null,
              "targetRpe": null,
              "restSeconds": 90,
              "actualWeight": 135,
              "actualWeightUnit": "lbs",
              "actualReps": 10,
              "actualTime": null,
              "actualRpe": 7,
              "completedAt": "2026-02-20T10:05:00.000Z",
              "status": "completed",
              "notes": null,
              "tempo": null,
              "isDropset": false,
              "isPerSide": false
            }
          ]
        }
      ]
    }
  ]
}
```

### Single-Session Export

Exported by `exportSingleSessionAsJson()`. Contains one session.

**File naming**: `workout-{sanitized-name}-{YYYY-MM-DD}.json`

Name sanitization rules:
1. Lowercase
2. Strip diacritics (NFD normalize, remove combining marks)
3. Remove non-alphanumeric characters (except spaces/hyphens)
4. Spaces to hyphens
5. Collapse multiple hyphens
6. Trim leading/trailing hyphens
7. Truncate to 50 characters
8. Fallback to "workout" if empty

```json
{
  "exportedAt": "2026-02-20T10:30:00.000Z",
  "appVersion": "1.5.0",
  "session": {
    "name": "Push Day",
    "date": "2026-02-20",
    "startTime": "...",
    "endTime": "...",
    "duration": 4500,
    "notes": null,
    "status": "completed",
    "exercises": [ "..." ]
  }
}
```

### Exported Fields Reference

The export format **strips all internal IDs** (no `id`, `workoutSessionId`, `sessionExerciseId`, `workoutPlanId`, `parentExerciseId`, `parentSetId`, `dropSequence`). This makes the format portable and human-readable.

#### Top-Level Envelope

| Field | Type | Description |
|-------|------|-------------|
| `exportedAt` | `string` | ISO 8601 timestamp of export |
| `appVersion` | `string` | App version from `expo.config.version` |
| `sessions` | `Session[]` | Array (multi-export) |
| `session` | `Session` | Single object (single-export) |

#### Session Object

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `name` | `string` | No | Workout name |
| `date` | `string` | No | ISO date (YYYY-MM-DD) |
| `startTime` | `string` | Yes | ISO 8601 datetime |
| `endTime` | `string` | Yes | ISO 8601 datetime |
| `duration` | `number` | Yes | Seconds |
| `notes` | `string` | Yes | |
| `status` | `string` | No | Always `"completed"` for exports |
| `exercises` | `Exercise[]` | No | |

#### Exercise Object

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `exerciseName` | `string` | No | |
| `orderIndex` | `number` | No | |
| `notes` | `string` | Yes | |
| `equipmentType` | `string` | Yes | |
| `groupType` | `string` | Yes | `"superset"` or `"section"` |
| `groupName` | `string` | Yes | |
| `status` | `string` | No | |
| `sets` | `Set[]` | No | |

#### Set Object

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `orderIndex` | `number` | No | |
| `targetWeight` | `number` | Yes | |
| `targetWeightUnit` | `string` | Yes | `"lbs"` or `"kg"` |
| `targetReps` | `number` | Yes | |
| `targetTime` | `number` | Yes | Seconds |
| `targetRpe` | `number` | Yes | |
| `restSeconds` | `number` | Yes | |
| `actualWeight` | `number` | Yes | |
| `actualWeightUnit` | `string` | Yes | `"lbs"` or `"kg"` |
| `actualReps` | `number` | Yes | |
| `actualTime` | `number` | Yes | Seconds |
| `actualRpe` | `number` | Yes | |
| `completedAt` | `string` | Yes | ISO 8601 |
| `status` | `string` | No | |
| `notes` | `string` | Yes | |
| `tempo` | `string` | Yes | |
| `isDropset` | `boolean` | Yes | |
| `isPerSide` | `boolean` | Yes | |

---

## Unified Export Format

> **Machine-readable schema**: [`schemas/liftmark-export-unified.schema.json`](schemas/liftmark-export-unified.schema.json) (JSON Schema draft 2020-12). Sample at [`../../test-fixtures/unified-export-sample.json`](../../test-fixtures/unified-export-sample.json).

Exported by `exportUnifiedJson()` in both React Native and Swift apps. Contains all app data: plans, completed sessions, gyms, and settings (excluding API keys). Designed for cross-platform transfer between the React Native and Swift app versions.

**File naming**: `liftmark_export_{YYYY-MM-DD_HH-MM-SS}.json`

### Envelope

| Field | Type | Description |
|-------|------|-------------|
| `formatVersion` | `string` | Schema version, currently `"1.0"` |
| `exportedAt` | `string` | ISO 8601 timestamp of export |
| `appVersion` | `string` | App version at export time |
| `plans` | `Plan[]` | Workout plans with exercises and sets |
| `sessions` | `Session[]` | Completed workout sessions |
| `gyms` | `Gym[]` | Gym locations |
| `settings` | `object` | User preferences (no sensitive data) |

### Plan Object

All internal IDs (`id`, `createdAt`, `updatedAt`) are stripped.

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `name` | `string` | No | Plan name |
| `description` | `string` | Yes | |
| `tags` | `string[]` | Yes | |
| `defaultWeightUnit` | `string` | Yes | `"lbs"` or `"kg"` |
| `sourceMarkdown` | `string` | Yes | Original LMWF markdown |
| `isFavorite` | `boolean` | No | |
| `exercises` | `PlannedExercise[]` | No | |

### Planned Exercise Object

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `exerciseName` | `string` | No | |
| `orderIndex` | `number` | No | |
| `notes` | `string` | Yes | |
| `equipmentType` | `string` | Yes | |
| `groupType` | `string` | Yes | `"superset"` or `"section"` |
| `groupName` | `string` | Yes | |
| `sets` | `PlannedSet[]` | No | |

### Planned Set Object

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `orderIndex` | `number` | No | |
| `targetWeight` | `number` | Yes | |
| `targetWeightUnit` | `string` | Yes | `"lbs"` or `"kg"` |
| `targetReps` | `number` | Yes | |
| `targetTime` | `number` | Yes | Seconds |
| `targetRpe` | `number` | Yes | |
| `restSeconds` | `number` | Yes | |
| `tempo` | `string` | Yes | |
| `notes` | `string` | Yes | |
| `isDropset` | `boolean` | No | |
| `isPerSide` | `boolean` | No | |

### Gym Object

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `name` | `string` | No | |
| `isDefault` | `boolean` | No | |
| `createdAt` | `string` | Yes | ISO 8601 |

### Settings Object

Safe subset of user preferences. API keys and sensitive data are excluded.

| Field | Type | Description |
|-------|------|-------------|
| `defaultWeightUnit` | `string` | `"lbs"` or `"kg"` |
| `enableWorkoutTimer` | `boolean` | |
| `autoStartRestTimer` | `boolean` | |
| `theme` | `string` | `"light"`, `"dark"`, or `"auto"` |
| `keepScreenAwake` | `boolean` | |
| `customPromptAddition` | `string` | Optional |

### Import Merge Semantics

Both React Native and Swift apps use the same merge rules:

- **Plans**: Deduplicated by `name`. If a plan with the same name exists, the import is skipped.
- **Sessions**: Deduplicated by `name` + `date`. If a session with the same name and date exists, it is skipped.
- **Gyms**: Deduplicated by `name`. Imported gyms are never set as default.
- **Settings**: Not imported (only exported for reference/manual migration).

Import is wrapped in a database transaction — if any insert fails, all changes are rolled back.

### Exercise Names

Exercise names in all export formats are **raw** (as stored in the database), not normalized. The [exercise dictionary](exercise-dictionary.md) is used only for display and aggregation within the app — it does not affect exported data. This ensures exports are a faithful representation of what the user entered.

### Cross-Platform Compatibility

The unified format is designed for data transfer between the React Native and Swift app versions. Both platforms export and import the same schema. Note:

- The React Native `template_sets` table lacks `is_amrap` and `notes` columns — these fields are exported by Swift but not inserted by the React Native importer.
- Both platforms handle the `session` (single) and `sessions` (array) formats on import.

---

## LMWF Markdown Import Format

Imported via `fileImportService.ts`. Reads `.txt`, `.md`, or `.markdown` files and passes content to the LMWF parser (`MarkdownParser.ts`).

### File Constraints

| Constraint | Value |
|------------|-------|
| Max file size | 1 MB |
| Accepted extensions | `.txt`, `.md`, `.markdown` |
| Accepted URL schemes | `file://`, `liftmark://` |
| Encoding | UTF-8 text |

### Import Flow

1. File URL received (via iOS share sheet or "Open In")
2. URL normalized (`liftmark://` converted to `file://`)
3. Extension validated against whitelist
4. File existence and size checked
5. Content read synchronously via `File.textSync()`
6. Content returned as markdown string for LMWF parsing

### LMWF Quick Reference

Full spec in `liftmark-workout-format/LIFTMARK_WORKOUT_FORMAT_SPEC.md`. Example:

```markdown
# Push Day
@tags: strength, upper
@units: lbs

## Bench Press
- 135 x 5
- 185 x 5
- 225 x 5

## Incline Dumbbell Press
- 50 x 10 @RPE 7
- 50 x 10 @RPE 8
```

### FileImportResult

```typescript
interface FileImportResult {
  success: boolean;
  markdown?: string;    // Raw file content on success
  fileName?: string;    // Original filename
  error?: string;       // Error message on failure
}
```

---

## Database Backup Format

Full SQLite database export/import via `databaseBackupService.ts`.

### Export

**File naming**: `liftmark_backup_{YYYY-MM-DD_HH-MM-SS}.db`

- Copies the raw SQLite database file from `Documents/SQLite/liftmark.db` to the cache directory
- Output is a complete SQLite database file, not a text format
- Shared via iOS share sheet (`expo-sharing`)

### Import

Destructive operation — replaces the entire database.

**Validation checks**:
1. File exists
2. File size > 0 and >= 1024 bytes
3. SQLite magic header verified (first 16 bytes: `SQLite format 3\0`)

**Required tables** (validated by the service):
- `workout_templates`
- `template_exercises`
- `template_sets`
- `user_settings`
- `gyms`
- `gym_equipment`
- `workout_sessions`
- `session_exercises`
- `session_sets`

**Import flow**:
1. Validate imported file (header check)
2. Create backup of current database (`backup_before_import.db` in cache)
3. Close current database connection
4. Wait 500ms for connection to fully close
5. Delete current database file
6. Copy imported file to database location
7. Reopen database — triggers the migration system (`DatabaseMigrator`), which also runs the one-time GRDB bridge if the imported DB still carries a legacy `schema_version` row and no `grdb_migrations` table. See [`../services/migrator.md`](../services/migrator.md).
8. Clean up backup on success
9. On failure: restore from backup, reopen original database

### Safety

- Automatic backup before import
- Automatic restore on failure
- Error messages indicate data is intact after failed import
