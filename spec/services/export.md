# Export Service Specification

## Purpose

Export workout sessions as portable JSON files for sharing and data portability. Exported files contain a clean representation of workout data with internal IDs stripped.

## Public API

### `exportSessionsAsJson(): Promise<string>`

Export all completed workout sessions as a single JSON file. Returns the file URI of the written file.

### `exportSingleSessionAsJson(session): Promise<string>`

Export a single workout session as a JSON file. Returns the file URI of the written file.

### `exportPlanAsMarkdown(plan): URL`

Export a workout plan's original LMWF markdown source as a `.md` file written to the cache directory. Returns the file URL of the written file. Throws `ExportError.noMarkdownSource` if `plan.sourceMarkdown` is null or empty. The returned URL is presented via the shared `.shareSheet(item:)` modifier so the user can save/AirDrop/share the file.

### `buildSessionFileName(name, date): string`

Build a sanitized filename from a workout name and date string.

## Behavior Rules

### File Format

Bulk export:
```json
{
  "exportedAt": "<ISO 8601 timestamp>",
  "appVersion": "<version from app constants>",
  "sessions": [...]
}
```

Single session export:
```json
{
  "exportedAt": "<ISO 8601 timestamp>",
  "appVersion": "<version from app constants>",
  "session": {...}
}
```

### Session Data Shape

Each session object includes: name, date, start time, end time, duration, notes, status, and an exercises array.

Each exercise object includes: exerciseName, orderIndex, notes, equipmentType, groupType, groupName, status, and a sets array.

Each set object includes: all target values (weight, unit, reps, time, rpe), all actual values, status, notes, tempo, isDropset, and isPerSide.

Internal database IDs and foreign keys are stripped from the output.

### File Naming

- Bulk export: `liftmark_workouts_{timestamp}.json`
- Single export: `workout-{sanitized-name}-{date}.json`
- Plan markdown export: `plan-{sanitized-name}.md`

### Name Sanitization

The sanitization process for filenames:
1. Convert to lowercase.
2. Strip diacritical marks (accents).
3. Remove special characters.
4. Replace spaces with hyphens.
5. Truncate to a maximum of 50 characters.

### File Location

All exported files are written to the app's cache directory.

## Dependencies

- `expo-file-system` (`Paths.cache`, `File`) for file writing.
- `expo-constants` for reading the app version.
- Session repository for loading completed sessions.

## Error Handling

- Throws `ExportError("No completed workouts to export")` when `exportSessionsAsJson()` is called with no completed sessions available.
- Throws `ExportError.noMarkdownSource` ("No markdown source available.") when `exportPlanAsMarkdown()` is called and `plan.sourceMarkdown` is null or empty.
- File system errors propagate as exceptions.
