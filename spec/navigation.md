# Navigation Specification

This document describes the complete navigation structure of LiftMark, including the tab bar, screen hierarchy, navigation parameters, deep link support, and gesture behavior.

## Tab Bar

The app uses a bottom tab bar with 4 tabs. The tab bar is always visible except when the active workout, workout summary, or modal screens are presented.

| Tab | Label | Icon | Route | Screen |
|-----|-------|------|-------|--------|
| 1 | LiftMark | `home` (Ionicons) | `(tabs)/index` | Home Screen |
| 2 | Plans | `clipboard-outline` (Ionicons) | `(tabs)/workouts` | Workouts Screen |
| 3 | Workouts | `barbell-outline` (Ionicons) | `(tabs)/history` | History Screen |
| 4 | Settings | `settings` (Ionicons) | `(tabs)/settings` | Settings Screen |

Each tab button has a testID for E2E testing: `tab-home`, `tab-workouts`, `tab-history`, `tab-settings`.

Active tab tint: theme `tabIconSelected` (default `#007AFF`).
Inactive tab tint: theme `tabIconDefault` (default `#8E8E93`).

### Tab Bar Content Clearance

**Critical layout constraint**: On all tab screens, interactive UI elements (buttons, cards, toggles, links) MUST be fully visible and tappable. No interactive element may be positioned behind, underneath, or obscured by the tab bar — including translucent, frosted glass, or "liquid glass" style tab bars. Scroll content areas must account for the tab bar height via safe area insets or bottom padding so that the last interactive element can be scrolled fully above the tab bar.

---

## Screen Hierarchy

### Root Stack

The root navigator is a native stack (`Stack`) that contains the tab navigator and all non-tab screens. It provides shared header styling from the theme.

```
Root
  |-- onboarding                [fullScreenCover, shown once when hasAcceptedDisclaimer=false]
  |
Root Stack
  |-- (tabs)                    [headerShown: false]
  |     |-- index               Home
  |     |-- workouts            Plans
  |     |-- history             Workouts (History)
  |     |-- settings            Settings
  |
  |-- modal/import              [presentation: modal] Import Workout
  |-- workout/[id]              Workout Detail
  |-- workout/active            [headerShown: false, gestureEnabled: false] Active Workout
  |-- workout/summary           [headerShown: false, gestureEnabled: false] Workout Summary
  |-- history/[id]              History Detail
  |-- gym/[id]                  [presentation: card] Gym Detail
  |-- settings/_layout          [headerShown: false] Settings Sub-Stack
  |     |-- workout             Workout Settings
  |     |-- sync                iCloud Sync
  |     |-- debug-logs          Debug Logs
  |-- cloudkit-test             [presentation: card] CloudKit Test
```

### Global Overlay

An `ActiveWorkoutBanner` component is rendered above the stack navigator. When a workout session is active and the user is not on the active workout screen, a banner appears at the top of every screen allowing the user to tap to resume.

---

## Screen Details

### Tab 1: Home Screen

**Route**: `(tabs)/index`
**Title**: "LiftMark"
**testID**: `home-screen`

**Content**:
- **Resume Workout Banner** (`resume-workout-banner`): Shown when an active session exists. Displays workout name and set progress. Tapping navigates to `/workout/active`.
- **Max Lifts Section**: A grid of customizable tiles (`max-lift-tile-{index}`, indices 0-3 by default) showing the user's best weight for selected exercises. Long-press (400ms) opens an exercise picker modal to change the tile.
- **Recent Plans Section** (`recent-plans`): Shows the 3 most recent workout plans. Each plan card (`workout-card-{plan.id}`) navigates to `/workout/{plan.id}`. Empty state (`empty-state`) shown when no plans exist.
- **Create Plan Button** (`button-import-workout`): Placed at the end of the scroll content (not fixed/pinned outside the scroll area). Must be visible above the tab bar. Navigates to `/modal/import`.

**Exercise Picker Modal** (`exercise-picker-modal`): Shown when long-pressing a tile. Contains a search input (`exercise-picker-search`), cancel button (`exercise-picker-cancel`), a list of exercise options (`exercise-option-{name}`), and a free-entry option (`exercise-picker-free-entry`) for custom exercise names.

---

### Tab 2: Plans Screen (Workouts)

**Route**: `(tabs)/workouts`
**Title**: "Plans"
**testID**: `workouts-screen`

**Content**:
- **Search Input** (`search-input`): Filters plans by name.
- **Filter Toggle** (`filter-toggle`): Expands/collapses filter controls.
  - **Favorites Filter** (`switch-filter-favorites`): Toggle to show only favorited plans.
  - **Equipment Filter** (`switch-filter-equipment`): Toggle to filter plans by available equipment at a selected gym. Gym options (`gym-option-{gym.id}`) appear when enabled.
- **Workout List** (`workout-list`): FlatList of plan cards. Each card:
  - Container: `workout-{plan.id}`
  - Favorite button: `favorite-{plan.id}` (heart icon toggle)
  - Tappable content: `workout-card-{plan.id}` -- navigates to `/workout/{plan.id}` (phone) or selects for split view (tablet).
  - Index view: `workout-card-index-{index}`
  - Swipe-to-delete: `delete-{plan.id}`
- **Empty State** (`empty-state`): Shows contextual message based on active filters.
  - Import button (`button-import-empty`): Navigates to `/modal/import`.
  - Setup equipment button (`button-setup-equipment`): Navigates to gym detail or settings.

**Tablet Behavior**: On iPad, uses a split view. The left pane shows the plan list; the right pane shows `WorkoutDetailView` for the selected plan.

---

### Tab 3: History Screen (Workouts)

**Route**: `(tabs)/history`
**Title**: "Workouts"
**testID**: `history-screen`

**Header Right**: Export button (`history-export-button`) with share icon. Exports all completed sessions as JSON via the system share sheet. Shows an ActivityIndicator while exporting.

**Content**:
- **Session List** (`history-list`): FlatList of completed workout sessions with pull-to-refresh. Each card (`history-session-card`) shows:
  - Session name, date (relative: Today/Yesterday/weekday/date)
  - Start time, duration
  - Stats: sets completed, exercise count, total volume
  - On phone: tapping navigates to `/history/{session.id}`
  - On tablet: tapping selects for split view
- **Empty State** (`history-empty-state`): "No Workouts Yet" message.

**Tablet Behavior**: Split view with session list on left and `HistoryDetailView` on right.

---

### Tab 4: Settings Screen

**Route**: `(tabs)/settings`
**Title**: "Settings"
**testID**: `settings-screen` (or `settings-loading` while loading)

**Content** (scrollable, grouped into sections):

1. **Preferences**
   - **Appearance**: Theme selector using iOS `Picker` with `.segmented` style (`picker-theme`).

2. **Workout**
   - **Workout Settings** (`workout-settings-button`): Navigation row to `/settings/workout`.
   - **My Gyms**: List of gym items (`gym-item`). Each navigates to `/gym/{gym.id}`. Non-default gyms have a "set default" button (`set-default-{gym.id}`). Add Gym button (`add-gym-button`) prompts for name then navigates to the new gym's detail page.

3. **Integrations** (iOS only)
   - **iCloud Sync** (`sync-settings-button`): Navigation row to `/settings/sync`.
   - **Apple Health** (if HealthKit available): Toggle (`switch-healthkit`).
   - **Live Activities** (if available): Toggle (`switch-live-activities`).

4. **AI Assistance**
   - **Workout Prompts**: Custom prompt text input (`input-custom-prompt`).
   - **AI Provider Keys**: Ordered, reorderable list of BYOK keys (`ai-key-row-{index}`) and an "Add Key" button (`add-ai-key-button`). The button opens the Add Key sheet: provider picker, key/URL/model inputs, Save/Cancel. See `spec/screens/settings.md`.
   - **Button Options** (`button-options-section`): Toggle for "Show Open in Claude button" (`switch-show-open-in-claude`). Only visible when API key is set.

5. **Data Management**
   - **Backup & Restore**: Export database button, Import database button (destructive, with confirmation).

6. **Developer** (non-dev builds only)
   - **Debug Logs** (`debug-logs-button`): Navigation row to `/settings/debug-logs`.

7. **About**
   - **App Information**: Version and build info.

---

### Workout Detail Screen

**Route**: `workout/[id]`
**Title**: "Workout Details"
**Header Back Title**: "Back"

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `id` | string | The workout plan ID |

**Content**: Renders `WorkoutDetailView` component (`workout-detail-view`), which shows:
- Favorite toggle button (`favorite-button-detail`)
- Plan name, tags, description, notes
- Exercise list with sets, organized by sections and supersets
  - Superset containers: `superset-{index}`
  - Exercise containers: `exercise-{exercise.id}`
  - Set items: `set-{set.id}`
- Start Workout button (`start-workout-button`): Checks for existing active session. If none, starts a new session and navigates to `/workout/active`. If one exists, offers to resume.
- Reprocess button: Re-parses the plan from stored markdown.

**Loading State**: `workout-detail-loading`

---

### Active Workout Screen

**Route**: `workout/active`
**Title**: "Active Workout" (header hidden)
**testID**: `active-workout-screen`

**Gesture**: Back swipe disabled (`gestureEnabled: false`). Hardware back button navigates back (Android).

**Header** (`active-workout-header`):
- Pause button (`active-workout-pause-button`): Shows confirmation alert, then pauses session and navigates back.
- Workout name (centered, truncated)
- Add Exercise button (`active-workout-add-exercise-button`): Opens the Add Exercise modal.
- Finish button (`active-workout-finish-button`): If sets remain, shows 3-option alert (Continue / Finish Anyway / Discard). If all sets complete, immediately completes and navigates to `/workout/summary` (via `router.replace`).

**Progress Bar** (`active-workout-progress`): Visual bar and text showing "X / Y sets completed".

**Workout Content** (`active-workout-scroll`): Scrollable list of exercises organized into:
- **Sections**: Named groups (Warmup/Cooldown detected by keywords) with styled dividers.
- **Supersets**: Groups of exercises with interleaved sets and a "SUPERSET" badge.
- **Single Exercises**: Individual exercises with sequential sets.

Each exercise shows:
- Number, name, equipment type, notes
- YouTube search link (opens external browser)
- Edit button (opens Edit Exercise modal)
- Sets rendered as `SetRow` components with inline editing

**Timers**:
- **Rest Timer**: Countdown timer between sets. Can auto-start or show Start/Skip buttons based on settings.
- **Exercise Timer**: Count-up timer for time-based sets.
- Audio cues: tick sounds at 3/2/1 seconds, completion sound when timer ends.

**Screen Behavior**: Keeps screen awake during workout (if `keepScreenAwake` setting enabled).

**Modals**:
- **Edit Exercise Modal**: Edit exercise name, equipment type, notes. Add/delete/modify sets.
- **Add Exercise Modal**: Simple markdown template for adding new exercises.

---

### Workout Summary Screen

**Route**: `workout/summary`
**Title**: "Workout Complete" (header hidden)
**testID**: `workout-summary-screen`

**Gesture**: Back swipe disabled.

**Content** (`workout-summary-scroll`):
- **Success Header** (`workout-summary-success-header`): Checkmark, "Workout Complete!", workout name.
- **Highlights** (`workout-summary-highlights`): Personal records and achievements (if any).
- **Stats Grid** (`workout-summary-stats`): Duration, Sets Completed, Total Reps, Total Volume.
- **Completion Card** (`workout-summary-completion`): Sets completed, sets skipped, completion rate.
- **Exercise Summary** (`workout-summary-exercises`): Per-exercise breakdown with completion status.
- **Done Button** (`workout-summary-done-button`): Clears the session and navigates to `/(tabs)` (home) via `router.replace`.

---

### History Detail Screen

**Route**: `history/[id]`
**Title**: Session name (dynamic)
**Header Back Title**: "Back"
**testID**: `history-detail-screen`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `id` | string | The workout session ID |

**Header Right**: Share button (exports single session as JSON).

**Content**: Renders `HistoryDetailView` component (`history-detail-view`) showing:
- Session metadata (date, time, duration)
- Exercise-by-exercise breakdown with actual weights, reps, and status
- Delete option (with confirmation alert)

---

### Import Workout Modal

**Route**: `modal/import`
**Presentation**: Modal
**Title**: "Import Workout"
**testID**: `import-modal`

**Parameters** (optional, from deep link/file import):
| Param | Type | Description |
|-------|------|-------------|
| `prefilledMarkdown` | string | Pre-populated markdown content |
| `fileName` | string | Name of the imported file |

**Content**:
- **Header**: Cancel button (`button-cancel`), title, Import button (`button-import`, disabled when empty or processing).
- **AI Prompt Section**: Expandable prompt viewer with Copy button (`button-copy-prompt`).
  - Generate button (`button-generate`): Visible when at least one usable AI provider key is set. Calls the providers in list order to generate a workout.
  - Open in Claude button (`button-open-claude`): Copies prompt and opens Claude.ai.
- **Markdown Input** (`input-markdown`): Multi-line text input for LMWF markdown.
- **Quick Guide**: Reference card for LMWF syntax.

**Import Flow**: Parses markdown via LMWF parser. Shows errors on failure, warnings with Continue/Cancel options, success alert then navigates back.

---

### Gym Detail Screen

**Route**: `gym/[id]`
**Presentation**: Card
**Title**: Gym name (dynamic)
**Header Back Title**: "Settings"
**testID**: `gym-detail-screen`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `id` | string | The gym ID |

**Content**:
- **Gym Information**: Name display/edit (`input-gym-name`, `edit-gym-name-button`, `save-gym-name`, `cancel-edit-gym-name`). Default badge. Set as Default button (`set-default-button`).
- **Equipment**: List of equipment items with availability toggle (`switch-equipment-{item.id}`) and remove button (`button-remove-equipment-{item.id}`).
  - Preset Equipment button (`preset-equipment-button`): Opens modal with categorized presets (`preset-{item}`). Save button (`save-presets-button`).
  - Custom equipment input (`input-new-equipment`) and Add button (`button-add-equipment`).
- **Danger Zone**: Delete Gym button (`delete-gym-button`). Only shown when more than one gym exists. Requires confirmation.

---

### Settings Sub-Screens

#### Workout Settings

**Route**: `settings/workout`
**Title**: "Workout Settings"
**testID**: `workout-settings-screen`

**Content**:
- **Units**: Default weight unit segmented control (`button-unit-lbs`, `button-unit-kg`).
- **Rest Timer**: Workout timer toggle (`switch-workout-timer`), auto-start rest timer toggle (`switch-auto-start-rest`).
- **Screen**: Keep screen awake toggle (`switch-keep-screen-awake`).

#### iCloud Sync

**Route**: `settings/sync`
**Title**: "iCloud Sync"

**Content**: Experimental iCloud sync settings. Check Status button, Enable Sync toggle (disabled until account status is "available"), and a CloudKit Test Screen button (navigates to `/cloudkit-test`).

#### Debug Logs

**Route**: `settings/debug-logs`
**Title**: "Debug Logs"
**testID**: `debug-logs-screen`

**Content**:
- Device info header
- Log statistics by level
- Action buttons (`debug-logs-actions`): Export (`debug-logs-export`), Clear (`debug-logs-clear`)
- Log list (`debug-logs-list`): Scrollable list of log entries with timestamp, level, category, message, and optional metadata/stack trace.
- Loading state: `debug-logs-loading`
- Empty state: `debug-logs-empty`

---

## Deep Link / URL Scheme Support

The app registers for file import URLs. When the app receives an incoming URL:

1. The URL is checked via `isFileImportUrl()` from `fileImportService`.
2. If it's a file import URL, the file is read via `readSharedFile()`.
3. On success, the app navigates to `/modal/import` with `prefilledMarkdown` and `fileName` parameters.
4. On failure, an alert is shown.

Each URL is processed only once (tracked via a `Set<string>`).

---

## Back Button Behavior and Gestures

| Screen | Back Gesture | Back Button | Notes |
|--------|-------------|-------------|-------|
| Tab screens | N/A | N/A | Tabs switch, no back |
| `workout/[id]` | Swipe back | "Back" | Returns to previous tab |
| `workout/active` | **Disabled** | Hardware back (Android) goes back | Custom Pause button for exit |
| `workout/summary` | **Disabled** | N/A | Done button replaces nav to home |
| `history/[id]` | Swipe back | "Back" | Returns to history tab |
| `modal/import` | Swipe down to dismiss | Cancel button | Confirms discard if content exists |
| `gym/[id]` | Swipe back | "Settings" | Returns to settings |
| `settings/*` | Swipe back | "Settings" | Returns to settings tab |
| `cloudkit-test` | Swipe back | "Back" | Returns to sync settings |

**Navigation after workout completion**: `router.replace('/workout/summary')` is used so the active workout screen is removed from the stack. From summary, `router.replace('/(tabs)')` returns to home, removing summary from the stack.
