# Settings Screen

## Purpose
Central configuration hub for the app. Manages appearance, workout preferences, gym/equipment, integrations (HealthKit, Live Activities, iCloud), AI assistance, data backup/restore, and app info.

## Route
`/(tabs)/settings` — Fourth tab in the bottom tab bar.

### Sub-routes (via settings/_layout.tsx Stack)
- `/settings/workout` — Workout Settings (units, timers, screen)
- `/settings/sync` — iCloud Sync settings
- `/settings/debug-logs` — Debug log viewer

## Layout
- **Body**: ScrollView with grouped sections
  1. **Header** — Title "Settings" + subtitle
  2. **Preferences** — Appearance (theme selector)
  3. **Workout** — Nav link to Workout Settings + Gym Management
  4. **Integrations** (iOS only) — iCloud Sync nav, HealthKit toggle, Live Activities toggle
  5. **AI Assistance** — Custom prompt text, API key management, button options
  6. **Data Management** — Backup export/import
  7. **Developer** (hidden by default, activated via easter egg) — Debug Logs nav link, Database export
  8. **About** — Version + Build info, Disclaimer, Open Source acknowledgements

## UI Elements

| Element | testID | Type |
|---------|--------|------|
| Loading state | `settings-loading` | View |
| Screen container | `settings-screen` | ScrollView |
| Theme picker (segmented) | `picker-theme` | Picker (segmented style) |
| Workout Settings nav | `workout-settings-button` | TouchableOpacity |
| Gym item | `gym-item` | TouchableOpacity |
| Set default gym | `set-default-{gym.id}` | TouchableOpacity |
| Add gym button | `add-gym-button` | TouchableOpacity |
| iCloud Sync nav | `sync-settings-button` | TouchableOpacity |
| HealthKit switch | `switch-healthkit` | Switch |
| Live Activities switch | `switch-live-activities` | Switch |
| Custom prompt input | `input-custom-prompt` | TextInput |
| API key input | `input-api-key` | TextInput |
| Toggle API key visibility | `toggle-api-key-visibility` | TouchableOpacity |
| Save API key | `save-api-key-button` | TouchableOpacity |
| Remove API key | `remove-api-key-button` | TouchableOpacity |
| Open Claude console | `open-claude-button` | TouchableOpacity |
| Show Open in Claude toggle | `switch-show-open-in-claude` | Switch |
| Button options section | `button-options-section` | View |
| Debug logs nav | `debug-logs-button` | TouchableOpacity |

## User Interactions
- **Tap theme segment** → updates theme to light/dark/auto and applies immediately (see Theme Application below)
- **Tap Workout Settings** → navigates to `/settings/workout`
- **Tap gym item** → navigates to `/gym/{gym.id}`
- **Tap star on non-default gym** → sets as default gym
- **Tap Add Gym** → Alert.prompt for gym name → creates gym → navigates to `/gym/{newGym.id}`
- **Tap iCloud Sync** → navigates to `/settings/sync`
- **Toggle HealthKit** → see HealthKit Integration Behavior below
- **Toggle Live Activities** → see Live Activities Toggle Behavior below
- **Edit custom prompt** → saves on blur
- **Enter API key + Save** → validates `sk-ant-` prefix, saves securely
- **Remove API key** → confirmation alert → removes key
- **Tap Open in Claude** → opens `https://console.anthropic.com`
- **Export Database** → see Database Export Behavior below
- **Import Database** → see Database Import Behavior below
- **Tap Debug Logs** → navigates to `/settings/debug-logs`

### Developer Mode Activation

The Developer section is hidden by default. Users activate it via a classic easter egg:

1. In the About section, tap the Version row 7 times within 2 seconds
2. On the 7th tap, toggle `developerModeEnabled` in settings
3. Show an alert confirming the new state:
   - Enabled: "Developer Mode Enabled" / "Developer options are now visible in Settings."
   - Disabled: "Developer Mode Disabled" / "Developer options have been hidden."
4. The setting persists across app launches via the `developer_mode_enabled` column in `user_settings`
5. The Developer section's visibility follows `developerModeEnabled` in **all** build configurations (Debug and Release alike), so the easter-egg toggle reliably shows/hides it as the confirmation alert promises. Build configuration does not override the setting.

**Tap behavior:**
- Each tap increments a counter
- Counter resets to 0 after 2 seconds of inactivity
- On reaching 7, toggle the setting and reset the counter

| Element | testID | Type | Purpose |
|---------|--------|------|---------|
| Version row (tap target) | `version-info-row` | Button | 7-tap easter egg to toggle developer mode |
| Disclaimer row | `disclaimer-button` | NavigationLink | Opens legal/health disclaimer |
| Open Source row | `open-source-button` | NavigationLink | Opens Open Source acknowledgements sub-screen |

### Open Source Acknowledgements

A sub-screen listing the third-party open source packages shipped in the app, with links to each project's homepage and license text. Must be kept in sync with `mobile-apps/ios/Package.resolved` and `project.yml` — adding or removing a package requires updating this list.

**Current packages:**

| Package | License | Homepage | License URL |
|---------|---------|----------|-------------|
| GRDB.swift | MIT | https://github.com/groue/GRDB.swift | https://github.com/groue/GRDB.swift/blob/master/LICENSE |
| Sentry Cocoa | MIT | https://github.com/getsentry/sentry-cocoa | https://github.com/getsentry/sentry-cocoa/blob/main/LICENSE.md |

**UI elements:**

| Element | testID | Type | Purpose |
|---------|--------|------|---------|
| Open Source screen | `open-source-screen` | List | Root container |
| Package row | `oss-package-{name}` | View | Package name + license + homepage link + license link |

### Theme Application

The theme selector (Light / Dark / Auto) MUST actually control the app's color scheme. Selecting a theme persists the preference AND applies the corresponding appearance immediately to the entire app:

| Selection | Behavior |
|-----------|----------|
| **Light** | Forces light appearance regardless of system setting. All screens use light backgrounds, dark text. |
| **Dark** | Forces dark appearance regardless of system setting. All screens use dark backgrounds, light text. |
| **Auto** | Follows the device's system appearance setting. Changes automatically when the user toggles system dark mode. |

**Implementation requirement** (iOS): The app MUST set `overrideUserInterfaceStyle` on the root window (or equivalent SwiftUI `preferredColorScheme`) when the theme changes. Simply storing the preference without applying it is a bug. The theme change must be visible immediately — no app restart required.

**Visual indicator**: The currently active theme button should be visually distinct (e.g., filled/highlighted) so the user can see which mode is selected.

### HealthKit Integration Behavior

The HealthKit toggle has a multi-step authorization flow. The toggle state must reflect the actual OS-level authorization status, not just an internal app preference.

**Toggle states:**

| OS Authorization | Toggle State | Behavior on Tap |
|-----------------|-------------|-----------------|
| Not yet requested | Off, enabled | Requests HealthKit authorization via system prompt. If granted → toggle turns on and setting is saved. If denied → toggle stays off, shows explanatory alert. |
| Authorized | On, enabled | Toggling off disables the app-level integration (stops writing new workouts to Health). Toggling back on re-enables without re-prompting. |
| Denied at OS level | Off, disabled | Toggle is disabled (grayed out). A helper label below the toggle reads: "Apple Health access was denied. To enable, go to Settings > Privacy & Security > Health > LiftMark." Tapping the label/link opens the system Settings app to the Health privacy page. |
| Not available (non-iOS) | Hidden | The entire HealthKit row is hidden on platforms without HealthKit. |

**What "enabled" means**: When HealthKit is enabled, completed workout sessions are automatically saved to Apple Health during `completeWorkout()`. The saved data includes workout duration, activity type (strength training), total volume, and a deduplication UUID.

**Additional UI elements:**

| Element | testID | Type | Purpose |
|---------|--------|------|---------|
| HealthKit status label | `healthkit-status-label` | Text | Shows authorization status or instructions |
| Open Health Settings link | `healthkit-open-settings` | Button | Opens iOS Settings > Health (visible only when denied) |

### Live Activities Toggle Behavior

The Live Activities toggle must check OS-level permission before allowing the user to enable it.

**Toggle states:**

| OS Permission | Toggle State | Behavior |
|--------------|-------------|----------|
| Allowed (or not yet requested) | Enabled, reflects app setting | Toggling on/off updates the app setting normally. |
| Disabled at OS level (Settings > LiftMark > Live Activities = off) | Off, disabled | Toggle is disabled (grayed out). A helper label below reads: "Live Activities are disabled for this app. To enable, go to Settings > LiftMark > Live Activities." Tapping opens the app's system Settings page. |
| Not available (pre-iOS 16.2) | Hidden | The entire Live Activities row is hidden. |

**Checking permission**: On iOS, use `ActivityAuthorizationInfo().areActivitiesEnabled` (or the platform equivalent) to determine whether Live Activities are permitted at the OS level. This check should run each time the settings screen appears, not just once.

**Additional UI elements:**

| Element | testID | Type | Purpose |
|---------|--------|------|---------|
| Live Activities status label | `live-activities-status-label` | Text | Shows permission status or instructions |
| Open App Settings link | `live-activities-open-settings` | Button | Opens iOS Settings for this app (visible only when disabled at OS level) |

### Database Export Behavior

Tapping "Export Database" creates a timestamped copy of the database and presents the iOS share sheet so the user can save, AirDrop, or share the file.

**Flow:**
1. User taps "Export Database" button (`export-database-button`)
2. App calls `DatabaseBackupService.exportDatabase()` to create a timestamped `.db` file in the caches directory
3. On success: presents a share sheet (`UIActivityViewController`) with the exported file URL
4. On failure: shows an alert with the error message

**Account sign-in sheet presentation** (`SettingsAccountSection` / `SettingsView`): the `LoginView` sheet presented by the Account section's **Sign in** button (`account-sign-in`) MUST be hosted on a *stably-mounted* view, not on the `SettingsAccountSection` body. That section's body is a transparent `Group` whose content swaps between the signed-in and signed-out branches; a `.sheet` hung off it is, in practice, attached to whichever branch is currently rendered. A re-render during launch settling (stores loading: auth, inbox, feature flags) tears that branch down and re-establishes it, dropping the in-flight presentation — so the **first** "Sign in" tap flashed the sheet up and immediately dismissed it, and the user had to tap a second time (GH #279, the same class of instability documented in `Views/Shared/AuthSyncBannerView.swift`). A `.background`-anchored sheet on the `Group` did **not** fix it — it is launch-timing, not purely structural. The fix: `showingLogin` state and `.sheet(isPresented:)` live in `SettingsView` (whose settings-loaded body is stable across auth re-renders), and `SettingsAccountSection` receives a `Binding<Bool>` it flips from the button. The first tap must present reliably.

**Share sheet presentation**: All file-export share sheets must use the `.shareSheet(item: Binding<ExportFile?>)` view modifier (see `Views/Shared/ShareSheet.swift`). The modifier presents `UIActivityViewController` directly on the key window's top-most view controller instead of wrapping it in a SwiftUI `.sheet`. Wrapping `UIActivityViewController` in a `UIHostingController` via `UIViewControllerRepresentable` causes a blank-sheet race on first tap (GH #70) because the activity VC's extension-service introspection runs concurrently with the hosting controller's transition. Direct UIKit presentation also defers one runloop tick so any pending file writes flush before iOS reads the URL for type/preview info. Callers set an `@State var exportFile: ExportFile?` and apply `.shareSheet(item: $exportFile)`; setting `exportFile = ExportFile(url: url)` after the file is written triggers presentation, and the binding is cleared on dismissal.

**UI elements:**

| Element | testID | Type | Purpose |
|---------|--------|------|---------|
| Export button | `export-database-button` | Button | Triggers database export |

**Error states:**
- Database file not found → alert: "Database file not found. Please restart the app."
- File copy failure → alert with error description

### Database Import Behavior

Tapping "Import Workouts" opens a file picker for `.db` files. After selection, the app validates the file, asks for confirmation, then replaces the database.

**Flow:**
1. User taps "Import Workouts" button (`import-workouts-button`)
2. System file picker opens, filtered to `.db`/`.sqlite`/`.database` files
3. User selects a file
4. App validates the file via `DatabaseBackupService.validateDatabaseFile(at:)`:
   - Checks SQLite magic header
   - Checks minimum file size (1024 bytes)
   - Verifies required tables exist
5. If invalid → alert: "The selected file is not a valid LiftMark database."
6. If valid → confirmation alert: "Replace all data? This will replace all your workout data with the imported database. This cannot be undone."
7. User confirms → app calls `DatabaseBackupService.importDatabase(from:)`:
   - Creates safety backup of current database
   - Closes database connection
   - Replaces database file
   - Reopens database connection
   - On failure: restores from safety backup
8. On success → alert: "Import successful! Your data has been replaced."
9. On failure → alert with error message; original data is restored

**UI elements:**

| Element | testID | Type | Purpose |
|---------|--------|------|---------|
| Import button | `import-workouts-button` | Button | Opens file picker for import |

**Error states:**
- Invalid file format → alert: "The selected file is not a valid LiftMark database."
- Import failure → alert with error description; data restored from backup

## Navigation
- `/settings/workout` — workout settings
- `/settings/sync` — iCloud sync
- `/settings/debug-logs` — debug logs
- `/gym/{id}` — gym detail

## Error/Empty States
- **Settings not loaded**: LoadingView with "Loading settings..."
- **Error from settings/gym store**: Alert dialog
- **Invalid API key format**: Alert "Anthropic API keys must start with sk-ant-..."
- **Invalid database file**: Alert "Selected file is not a valid LiftMark database"
- **Export/import failure**: Alert with error message

---

## Sub-screen: Workout Settings

### Route: `/settings/workout`

### Purpose
Configure weight units, rest timer behavior, and screen preferences.

### UI Elements

| Element | testID | Type |
|---------|--------|------|
| Screen container | `workout-settings-screen` | View |
| LBS button | `button-unit-lbs` | TouchableOpacity |
| KG button | `button-unit-kg` | TouchableOpacity |
| Weight step fine button | `button-step-fine` | TouchableOpacity |
| Weight step coarse button | `button-step-coarse` | TouchableOpacity |
| Workout timer switch | `switch-workout-timer` | Switch |
| Auto-start rest timer switch | `switch-auto-start-rest` | Switch |
| Keep screen awake switch | `switch-keep-screen-awake` | Switch |
| Countdown sounds switch | `switch-countdown-sounds` | Switch |
| Default timer countdown switch | `switch-default-timer-countdown` | Switch |

### Default Timer Countdown Behavior

The "Start timer in countdown mode" toggle under Rest Timer controls the **initial** display mode of the large exercise timer (`ExerciseTimerView`) on timed sets.

- **Off (default)**: Exercise timers start in count-up mode — elapsed time counts from 0 toward target.
- **On**: Exercise timers start in count-down mode — remaining time counts from target toward 0.
- Users may still tap the timer display at any time during a set to toggle between modes. The setting only controls the initial value for each new set; it does not disable the per-exercise tap toggle.
- Persisted via the `default_timer_countdown` column in `user_settings` (see [database-schema.md](../data/database-schema.md)).

### Weight Step Behavior

The "Weight Step" picker under Units controls the increment used by the weight stepper buttons (`+` / `−`) on the active workout set row. The picker offers two tiers — **fine** (default) and **coarse** — labeled by the current default weight unit.

| Tier   | lbs step | kg step |
|--------|----------|---------|
| Fine   | 2.5 lbs  | 1.25 kg |
| Coarse | 5 lbs    | 2.5 kg  |

- Each set uses the tier mapped to that set's unit (lbs or kg), not the default unit. A kg set in an otherwise-lbs workout still gets the metric step value.
- Persisted via the `default_weight_step_lbs` REAL column in `user_settings` (2.5 = fine tier, 5.0 = coarse tier). The column stores the lbs representation for wire compatibility; the kg value is derived at display time (see [database-schema.md](../data/database-schema.md)).

---

## Sub-screen: iCloud Sync

### Route: `/settings/sync`

### Purpose
iCloud sync configuration. Shows current CloudKit account status, allows enabling/disabling sync, and provides status information about sync state.

### Layout

The screen MUST display meaningful content — it must never appear as an empty screen. The layout is a ScrollView with grouped sections:

1. **iCloud Status Section** — Shows the current iCloud account status with a colored badge:

   | Status | Badge Color | Label | Description |
   |--------|------------|-------|-------------|
   | `available` | Green | "iCloud Available" | "Your iCloud account is connected and ready for sync." |
   | `noAccount` | Orange | "No iCloud Account" | "Sign in to iCloud in your device Settings to enable sync." |
   | `restricted` | Red | "Restricted" | "iCloud access is restricted on this device (e.g., parental controls)." |
   | `couldNotDetermine` | Gray | "Unknown" | "Could not determine iCloud status. Try again later." |
   | `error` | Red | "Error" | "An error occurred checking iCloud status." |

2. **Sync Controls Section** — Only shown when status is `available`:
   - **Enable Sync** toggle — Enables/disables automatic background sync
   - **Last Synced** row — Absolute date/time of last successful sync (e.g., "Mar 1, 2026 at 3:45 PM"), or "Not yet synced" if no sync has occurred. Uses `DateFormatter` with `medium` date style and `short` time style.
   - **Uploaded** row — Number of records uploaded in the last sync (hidden when no sync has occurred yet)
   - **Downloaded** row — Number of records downloaded in the last sync (hidden when no sync has occurred yet)
   - **Conflicts** row — Number of conflicts resolved in the last sync (hidden when 0 or no sync)
   - **Sync Now** button — Manually triggers a sync operation

3. **Sync Info Section** — Always visible:
   - Description text: "iCloud Sync keeps your workout plans, session history, and settings in sync across all your devices signed into the same iCloud account."
   - If sync is not available, shows guidance: "To use iCloud Sync, sign in to iCloud in your device's Settings app."

4. **Status Footer** — When sync tables exist but sync is not active, show: "Sync infrastructure is ready. Enable sync above to start syncing your data."

### UI Elements

| Element | testID | Type | Purpose |
|---------|--------|------|---------|
| Screen container | `sync-settings-screen` | View | Root container |
| Status badge | `sync-status-badge` | View | Shows iCloud status with color |
| Status label | `sync-status-label` | Text | Human-readable status text |
| Status description | `sync-status-description` | Text | Detailed explanation of current status |
| Enable sync toggle | `switch-enable-sync` | Switch | Toggle sync on/off |
| Last synced date | `sync-last-synced` | Text | Absolute date/time of last sync, or "Not yet synced" |
| Records uploaded | `sync-records-uploaded` | Text | Count of records uploaded in last sync (hidden until first sync) |
| Records downloaded | `sync-records-downloaded` | Text | Count of records downloaded in last sync (hidden until first sync) |
| Conflicts resolved | `sync-records-conflicts` | Text | Count of conflicts resolved (hidden when 0 or no sync) |
| Sync now button | `sync-now-button` | Button | Manual sync trigger |
| Check status button | `sync-check-status` | Button | Refresh iCloud status |
| Info text | `sync-info-text` | Text | Explanatory description |

### Behavior
- On screen appear: automatically calls `getAccountStatus()` and loads last sync stats from persistent storage
- **Check Status** button: re-fetches status (useful after user signs into iCloud in system Settings)
- **Enable Sync** toggle: only interactive when status is `available`; grayed out otherwise
- **Sync Now** button: only enabled when sync is enabled and status is `available`; shows a spinner during sync; updates last synced date and record counts on completion
- **Last Synced** date/time: displayed as absolute date (not relative); formatted as "MMM d, yyyy 'at' h:mm a"; shows "Not yet synced" when no sync has occurred; updates immediately after a successful Sync Now
- **Uploaded / Downloaded / Conflicts** rows: only visible after at least one successful sync; update immediately after Sync Now completes; persisted across app launches (stored alongside last sync date in sync metadata)

---

## Sub-screen: Debug Logs

### Route: `/settings/debug-logs`

### Purpose
View, filter, and export application logs for troubleshooting production issues.

### UI Elements

| Element | testID | Type |
|---------|--------|------|
| Screen container | `debug-logs-screen` | View |
| Actions bar | `debug-logs-actions` | View |
| Export button | `debug-logs-export` | TouchableOpacity |
| Clear button | `debug-logs-clear` | TouchableOpacity |
| Loading state | `debug-logs-loading` | View |
| Logs list | `debug-logs-list` | ScrollView |
| Share button | `debug-logs-share` | Button |
| Empty state | `debug-logs-empty` | Text |

### Behavior

**Log sharing:**
- "Share Logs" writes the exported log JSON to a timestamped temp file in the caches directory and presents the iOS share sheet
- "Copy to Clipboard" copies the log JSON to the system clipboard
- "Clear Logs" shows a confirmation alert before deleting all logs

**Log display:**
- Uses `List` with `.insetGrouped` style following standard iOS patterns
- Device info section shows platform, OS version, app version, and build type as standard list rows
- Log statistics by level (debug/info/warn/error) shown inline
- Filterable log list with level filter chips
- Each log entry is expandable to show metadata and stack traces
- Maximum 200 logs displayed

