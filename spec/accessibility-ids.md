# Accessibility / Test IDs

This document is the **contract** between the LiftMark specification and E2E tests. Every `testID` used in the codebase is listed here, organized by screen. E2E tests reference these IDs via `by.id()` to locate elements.

Implementations on any platform must attach these identifiers to the corresponding UI elements to maintain E2E test compatibility.

---

## Onboarding Screen

| ID | Element Type | Purpose |
|----|-------------|---------|
| `onboarding-screen` | View | Onboarding screen container |
| `onboarding-accept-button` | Button | "I Understand" disclaimer acceptance |

---

## Tab Bar

| ID | Element Type | Purpose |
|----|-------------|---------|
| `tab-home` | Pressable | Home tab button |
| `tab-workouts` | Pressable | Plans tab button |
| `tab-history` | Pressable | Workouts (history) tab button |
| `tab-settings` | Pressable | Settings tab button |

---

## Home Screen (`(tabs)/index`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `home-screen` | View | Root container for the home screen |
| `resume-workout-banner` | TouchableOpacity | Banner to resume an active workout session |
| `max-lift-tile-{index}` | TouchableOpacity | Max lift display tile (0-3 by default). Long-press to customize. |
| `recent-plans` | View | Container for the recent plans section |
| `empty-state` | View | Empty state when no plans exist |
| `workout-card-{plan.id}` | TouchableOpacity | A recent plan card (navigates to workout detail) |
| `button-import-workout` | TouchableOpacity | "Create Plan" button (navigates to import modal) |

### Exercise Picker Modal (shown on tile long-press)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `exercise-picker-modal` | View | Modal container |
| `exercise-picker-cancel` | TouchableOpacity | Cancel button to dismiss the modal |
| `exercise-picker-search` | TextInput | Search input to filter exercises |
| `exercise-picker-free-entry` | TouchableOpacity | Button to use the search text as a custom exercise name |
| `exercise-option-{name}` | TouchableOpacity | A selectable exercise in the list (e.g., `exercise-option-Pull-Up`) |

---

## Plans Screen (`(tabs)/workouts`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `workouts-screen` | View | Root container for the plans screen |
| `search-input` | TextInput | Search input to filter plans by name |
| `filter-toggle` | TouchableOpacity | Expand/collapse filter controls |
| `switch-filter-favorites` | Switch | Toggle to show only favorited plans |
| `switch-filter-equipment` | Switch | Toggle to filter by available equipment |
| `gym-option-{gym.id}` | TouchableOpacity | Gym selector option within equipment filter |
| `workout-list` | FlatList | List of workout plan cards |
| `workout-{plan.id}` | View | Outer container for a plan card |
| `favorite-{plan.id}` | TouchableOpacity | Heart icon to toggle plan favorite status |
| `workout-card-{plan.id}` | TouchableOpacity | Tappable content area of a plan card |
| `workout-card-index-{index}` | View | Indexed wrapper for plan card content |
| `delete-{plan.id}` | TouchableOpacity | Delete button (revealed on swipe) |
| `empty-state` | View | Empty state container |
| `button-import-empty` | TouchableOpacity | "Import Plan" button in empty state |
| `button-setup-equipment` | TouchableOpacity | "Set Up Equipment" button when equipment filter shows no results |

---

## History Screen (`(tabs)/history`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `history-screen` | View | Root container for the history screen |
| `history-export-button` | TouchableOpacity | Export all sessions button in header |
| `history-list` | FlatList | List of completed session cards |
| `history-session-card` | TouchableOpacity | A completed session card |
| `history-empty-state` | View | Empty state when no sessions exist |

---

## Settings Screen (`(tabs)/settings`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `settings-screen` | ScrollView | Root container for settings |
| `settings-loading` | View | Loading state container |
| `picker-theme` | Picker (segmented) | Theme selector (Light/Dark/Auto) |
| `workout-settings-button` | TouchableOpacity | Navigate to workout settings sub-screen |
| `gym-item` | TouchableOpacity | A gym list item (navigates to gym detail) |
| `set-default-{gym.id}` | TouchableOpacity | Set a gym as default |
| `add-gym-button` | TouchableOpacity | Add a new gym |
| `sync-settings-button` | TouchableOpacity | Navigate to iCloud sync settings |
| `switch-healthkit` | Switch | Toggle Apple Health integration |
| `healthkit-status-label` | Text | Shows HealthKit authorization status or instructions |
| `healthkit-open-settings` | Button | Opens iOS Settings > Health (visible only when denied) |
| `switch-live-activities` | Switch | Toggle Live Activities |
| `live-activities-status-label` | Text | Shows Live Activities permission status or instructions |
| `live-activities-open-settings` | Button | Opens app system Settings (visible only when disabled at OS level) |
| `input-custom-prompt` | TextInput | Custom AI prompt addition input |
| `input-api-key` | TextInput | Anthropic API key input |
| `toggle-api-key-visibility` | TouchableOpacity | Show/hide API key text |
| `save-api-key-button` | TouchableOpacity | Save the entered API key |
| `remove-api-key-button` | TouchableOpacity | Remove the stored API key |
| `open-claude-button` | TouchableOpacity | Open Anthropic console in browser |
| `button-options-section` | View | Section for button option settings |
| `switch-show-open-in-claude` | Switch | Toggle "always show Open in Claude" button |
| `debug-logs-button` | TouchableOpacity | Navigate to debug logs screen |

---

## Workout Detail Screen (`workout/[id]`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `workout-detail-loading` | View | Loading state container |
| `workout-detail-view` | ScrollView | Main detail view (from WorkoutDetailView component) |
| `favorite-button-detail` | TouchableOpacity | Toggle favorite status |
| `start-workout-button` | TouchableOpacity | Start a workout session from this plan |
| `superset-{index}` | View | Superset group container |
| `exercise-{exercise.id}` | View | Exercise container |
| `set-{set.id}` | View | Individual set display |

---

## Active Workout Screen (`workout/active`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `active-workout-screen` | View | Root container |
| `active-workout-header` | View | Header bar container |
| `active-workout-pause-button` | TouchableOpacity | Pause the workout and go back |
| `active-workout-add-exercise-button` | TouchableOpacity | Open the add exercise modal |
| `active-workout-finish-button` | TouchableOpacity | Finish the workout |
| `active-workout-progress` | View | Progress bar and text container |
| `active-workout-scroll` | ScrollView | Scrollable exercise content |

---

## Workout Summary Screen (`workout/summary`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `workout-summary-screen` | View | Root container |
| `workout-summary-scroll` | ScrollView | Scrollable summary content |
| `workout-summary-success-header` | View | Success header with checkmark |
| `workout-summary-highlights` | View | Workout highlights / achievements section |
| `workout-summary-stats` | View | Stats grid (duration, sets, reps, volume) |
| `workout-summary-completion` | View | Completion rate card |
| `workout-summary-exercises` | View | Per-exercise summary list |
| `workout-summary-done-button` | TouchableOpacity | Done button (returns to home) |

---

## History Detail Screen (`history/[id]`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `history-detail-screen` | View | Root container |
| `history-detail-view` | ScrollView | Detail view (from HistoryDetailView component) |
| `exercise-card-enlarge-{exerciseName}` | View | Long-press target on an exercise card; opens the enlarged view (GH #432) |
| `enlarged-view` | View | Full-screen enlarged exercise view |
| `enlarged-view-close` | Button | Closes the enlarged view |

---

## Import Workout Modal (`modal/import`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `import-modal` | View | Root container |
| `button-cancel` | TouchableOpacity | Cancel and dismiss the modal |
| `button-import` | TouchableOpacity | Import the entered markdown |
| `button-copy-prompt` | TouchableOpacity | Copy AI prompt to clipboard |
| `button-generate` | TouchableOpacity | Generate workout via Anthropic API |
| `button-open-claude` | TouchableOpacity | Copy prompt and open Claude.ai |
| `input-markdown` | TextInput | Markdown input field |

---

## Gym Detail Screen (`gym/[id]`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `gym-detail-screen` | View | Root container |
| `input-gym-name` | TextInput | Gym name edit input |
| `edit-gym-name-button` | TouchableOpacity | Enter gym name edit mode |
| `save-gym-name` | TouchableOpacity | Save edited gym name |
| `cancel-edit-gym-name` | TouchableOpacity | Cancel gym name edit |
| `set-default-button` | TouchableOpacity | Set this gym as the default |
| `switch-equipment-{item.id}` | Switch | Toggle equipment availability |
| `button-remove-equipment-{item.id}` | TouchableOpacity | Remove an equipment item |
| `preset-equipment-button` | TouchableOpacity | Open preset equipment selection modal |
| `preset-{item}` | TouchableOpacity | A preset equipment checkbox item |
| `save-presets-button` | TouchableOpacity | Save preset equipment selection |
| `input-new-equipment` | TextInput | Custom equipment name input |
| `button-add-equipment` | TouchableOpacity | Add custom equipment |
| `delete-gym-button` | TouchableOpacity | Delete this gym |

---

## iCloud Sync Screen (`settings/sync`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `sync-settings-screen` | View | Root container |
| `sync-status-badge` | View | Colored badge showing iCloud status |
| `sync-status-label` | Text | Human-readable status text |
| `sync-status-description` | Text | Detailed explanation of current status |
| `switch-enable-sync` | Switch | Toggle sync on/off |
| `sync-last-synced` | Text | Timestamp of last sync |
| `sync-now-button` | Button | Manual sync trigger |
| `sync-check-status` | Button | Refresh iCloud status |
| `sync-info-text` | Text | Explanatory description about iCloud Sync |

---

## Workout Settings Screen (`settings/workout`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `workout-settings-screen` | View | Root container |
| `button-unit-lbs` | TouchableOpacity | Select pounds as default unit |
| `button-unit-kg` | TouchableOpacity | Select kilograms as default unit |
| `switch-workout-timer` | Switch | Toggle rest timer visibility |
| `switch-auto-start-rest` | Switch | Toggle auto-start rest timer |
| `switch-keep-screen-awake` | Switch | Toggle keep screen awake during workouts |
| `switch-default-timer-countdown` | Switch | Toggle default exercise timer mode (off = count-up, on = count-down) |

---

## Debug Logs Screen (`settings/debug-logs`)

| ID | Element Type | Purpose |
|----|-------------|---------|
| `debug-logs-screen` | View | Root container |
| `debug-logs-actions` | View | Action buttons container |
| `debug-logs-export` | TouchableOpacity | Export logs to clipboard |
| `debug-logs-clear` | TouchableOpacity | Clear all logs |
| `debug-logs-loading` | View | Loading state container |
| `debug-logs-list` | ScrollView | Log entries list |
| `debug-logs-empty` | Text | Empty state text |

