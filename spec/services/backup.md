# Backup Service Specification

## Purpose

Export and import complete database backups for data portability and disaster recovery. This allows users to create full snapshots of their data and restore from them.

## Public API

### `getDatabasePath(): Promise<string>`

Get the file path to the current SQLite database file.

### `exportDatabase(): Promise<string>`

Export a copy of the current database file. Returns the file URI of the exported backup.

### `importDatabase(fileUri: string): Promise<void>`

Replace the current database with the contents of an imported database file. This is a destructive operation that replaces all existing data.

### `validateDatabaseFile(fileUri: string): Promise<boolean>`

Validate that a file is a legitimate SQLite database suitable for import.

## Behavior Rules

### Export

- Writes a clean, fully-consistent copy of the current database to the **cache directory**.
- Backup filename format: `liftmark_backup_{timestamp}.db`
- **WAL-safe consistent copy (required):** the export MUST be produced through the live database connection, NOT by a raw `FileManager.copyItem` of the `liftmark.db` file. The database runs in WAL mode, so committed data — and, on a freshly-migrated database, whole `CREATE TABLE` commits — can still live in the `liftmark.db-wal` sidecar until a checkpoint folds it into the main file. Copying only the main file can therefore yield a backup that is **missing recent writes or entire tables**, depending on WAL/checkpoint timing (the source of historical flakiness in `DatabaseBackupServiceTests`).
  - **Mechanism:** `VACUUM INTO '<export-path>'`, executed on the live GRDB connection (`DatabaseManager.vacuumInto(_:)`, via `writeWithoutTransaction` since `VACUUM` cannot run inside a transaction). This emits a brand-new database file reflecting the complete current logical state regardless of WAL position. The output is a **single, self-contained file with no `-wal`/`-shm` sidecars** — ideal for sharing/import. The destination path must not pre-exist; any stale file is removed first. The live database's WAL mode is left untouched.
  - A checkpoint-then-copy (`PRAGMA wal_checkpoint(TRUNCATE)` immediately before a file copy taken with no concurrent writer) is an acceptable fallback that achieves the same correctness, but `VACUUM INTO` is preferred because it is atomic and sidecar-free.
- **Scope:** cache-dir export is for **user-initiated exports only** (share sheet, manual backup to Files/iCloud Drive). iOS may evict the cache directory under storage pressure, so this path is **not** suitable for safety backups that must persist until the next launch. The pre-upgrade backup written by the GRDB migration bridge lives in Application Support instead — see "Pre-upgrade backup" below.
- **Known issue:** the cache-dir location has a second drawback even for user-initiated flows — cache can evict mid-share-sheet. Flagged for follow-up; not in scope for the GRDB migration work.

### Import

Import is a destructive operation that replaces all existing data. The process follows these steps in order:

1. Create a safety backup of the current database before making any changes.
2. Close the current database connection (with a 500ms delay to allow pending operations to complete).
3. Delete the current database file.
4. Copy the import file to the database location.
5. Reopen the database to verify the import is valid.
6. On failure at any step: restore the database from the safety backup created in step 1.

### Pre-upgrade backup

Distinct from the user-initiated export above. Created by the one-time GRDB migration bridge before any schema mutation. See [`migrator.md`](migrator.md) §2 for full semantics.

- **Location:** `<Application Support>/LiftMark/pre-grdb-bridge.bak.db`. Application Support is not OS-evictable (unlike Caches) and not user-visible in Files.app (unlike Documents).
- **Copy mechanism:** GRDB's `Database.backup(to:)` (SQLite Online Backup API), **not** `FileManager.copyItem`. A raw file copy can produce a torn backup when WAL pages or in-flight transactions are open; the Online Backup API locks page-by-page and guarantees a consistent destination.
- **Post-backup verification:** `PRAGMA integrity_check = "ok"`, `validateDatabaseFile(at:)` passes, row counts per required table match the live DB, and `schema_version.version` matches.
- **Retention:** not deleted as part of the bridge transaction. Deletion triggers (any of):
  - Successful bridge followed by 7 successful app launches with no `migrator_*_failed` telemetry on the same device. Tracked via `UserDefaults` key `migrator.bridge.postSuccessfulLaunchCount`.
  - User-initiated via Settings → Debug → "Delete GRDB bridge backup".
  - App uninstall (Application Support is removed with the app bundle).
- **Restore path:** see [`migrator.md`](migrator.md) §2.6. Restore uses `FileManager.copyItem` because the destination path is no longer hot at that point.

### Validation

A file is considered a valid database if it meets all of the following criteria:

- The file exists.
- File size is at least 1024 bytes.
- The first 16 bytes match the SQLite magic header.
- The database contains all required tables:
  - `workout_templates`
  - `template_exercises`
  - `template_sets`
  - `user_settings`
  - `gyms`
  - `gym_equipment`
  - `workout_sessions`
  - `session_exercises`
  - `session_sets`

## Dependencies

- `expo-file-system` (`Paths`, `File`, `Directory`) for file operations.
- `expo-sharing` for sharing exported backup files.
- Database module (`db`) for connection management.

## Error Handling

- Export errors propagate as exceptions.
- Import errors trigger automatic restoration from the safety backup. If restoration also fails, the error from the original import failure is thrown.
- Validation returns `false` for any file that does not meet all criteria; it does not throw.
