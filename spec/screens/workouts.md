# Workouts Screen

## Purpose
Browse, search, filter, and manage all imported workout plans. Supports tablet split-view for side-by-side list + detail.

## Route
`/(tabs)/workouts` — Second tab in the bottom tab bar.

## Layout
- **Header**: Tab header from navigator
- **Body** (phone): Inbox section + Search bar + filter panel + FlatList of plan cards
- **Body** (tablet): Inbox section (top of left pane) + SplitView with list on left, WorkoutDetailView on right
- **Footer**: None

### Inbox section

Always visible at the top of the screen, between the header and the search bar. Surfaces workouts pushed to this user from outside the app (e.g., via Claude Code + PAT — see [`../services/workout-inbox.md`](../services/workout-inbox.md)).

- Header row: "Inbox" + a count badge (hidden when zero).
- When empty: a single muted row reading "No new workouts in your inbox."
- When non-empty: one row per inbox item showing the workout name, exercise count, set count, and a relative-time stamp ("2h ago"). Tap opens an Inbox Detail sheet (read-only preview + actions). The exercise/set counts use the shared plan-count definition below, so an inbox row reports the same numbers its promoted plan will.
- Each row has a leading swipe action **Discard** (red) and trailing swipe actions **Add to Plans** and **Start**. Long-press shows the same three actions in a context menu.
- Items in the Inbox section are NOT in the user's plan library yet. They do not respond to search, filter, or favorite. They are not exported via backup.

## UI Elements

| Element | testID | Type |
|---------|--------|------|
| Screen container | `workouts-screen` | View |
| Inbox section | `inbox-section` | View |
| Inbox count badge | `inbox-count-badge` | View |
| Inbox empty row | `inbox-empty` | View |
| Inbox row (per item) | `inbox-row-{inbox_id}` | View |
| Inbox row Discard | `inbox-row-discard-{inbox_id}` | Button |
| Inbox row Add to Plans | `inbox-row-add-{inbox_id}` | Button |
| Inbox row Start | `inbox-row-start-{inbox_id}` | Button |
| Inbox detail sheet | `inbox-detail-sheet` | Sheet |
| Search input | `search-input` | TextInput |
| Filter toggle | `filter-toggle` | TouchableOpacity |
| Favorites filter switch | `switch-filter-favorites` | Switch |
| Equipment filter switch | `switch-filter-equipment` | Switch |
| Gym option (per gym) | `gym-option-{gym.id}` | TouchableOpacity |
| Workout list | `workout-list` | FlatList |
| Workout card container | `workout-{item.id}` | View (Swipeable) |
| Workout card tap area | `workout-card-{item.id}` | TouchableOpacity |
| Workout card index | `workout-card-index-{index}` | View |
| Favorite button | `favorite-{item.id}` | TouchableOpacity |
| Swipe-delete button | `delete-{item.id}` | TouchableOpacity |
| Empty state | `empty-state` | View |
| Import button (empty) | `button-import-empty` | TouchableOpacity |
| Setup equipment button | `button-setup-equipment` | TouchableOpacity |

## User Interactions
- **Tap inbox row** → opens Inbox Detail sheet (read-only preview + Discard / Add to Plans / Start actions)
- **Swipe inbox row left** → reveals Add to Plans + Start
- **Swipe inbox row right** → reveals Discard
- **Tap Inbox → Add to Plans** → promotes item to a plan, removes from inbox, deletes server row
- **Tap Inbox → Start** → promotes (as above) and opens the new plan's detail screen so the user can tap Start there (v1)
- **Tap Inbox → Discard** → removes from local inbox + deletes server row (no confirmation; can re-push externally)
- **Type in search** → filters plans by query
- **Toggle "Show Filters"** → expands/collapses filter card
- **Toggle favorites switch** → filters to favorited plans only
- **Toggle equipment switch** → filters plans by available equipment at selected gym
- **Tap gym option** → selects gym for equipment filtering
- **Tap plan card** → phone: navigates to `/workout/{id}`; tablet: selects plan in split view
- **Tap favorite heart** → toggles favorite status
- **Swipe left on card** → reveals red Delete button
- **Tap Delete** → removes plan from store
- **Tap "Import Plan" (empty state)** → navigates to `/modal/import`
- **Tap "Set Up Equipment" (equipment empty)** → navigates to gym detail or settings
- **Tap "Start Workout" (tablet detail)** → checks for active session, starts workout, navigates to `/workout/active`
- **Tap "Reprocess" (tablet detail)** → re-parses plan from markdown with confirmation alert

## Navigation
- `/workout/{id}` — phone plan card tap
- `/modal/import` — empty state import button
- `/workout/active` — after starting workout
- `/gym/{defaultGym.id}` — equipment setup button

## Workout Detail View

Displayed when a plan card is tapped (phone: push navigation, tablet: right pane of split view).

### Layout
- **Header card**: Plan name, favorite toggle, description, tags
- **Stats grid**: Exercise count, set count, weight units
- **Reprocess button**: Shown if plan has `sourceMarkdown`
- **Exercise list**: Cards for each exercise or superset group

### Plan counts (shared definition)

Every place that shows a plan's exercise/set tally — plan cards (Plans + Home), this detail header, the inbox row + preview, and the import/edit confirmation — reads one shared definition so the same plan never reports two different numbers:

- **Exercise count** = exercises the user performs, **excluding structural headers**: an empty section header (`groupType == .section`, no sets) or an empty superset parent (`groupType == .superset`, no sets). Superset children and regular exercises each count once. This matches exercise numbering (structural headers get no number).
- **Set count** = the sum of every exercise's planned sets.

Implemented as `WorkoutPlan.displayExerciseCount` / `WorkoutPlan.plannedSetCount` (with `PlannedExercise.isStructuralHeader` as the single predicate). Counting a plan ad-hoc with `exercises.count` is a bug — it includes structural headers and drifts from the rest of the app.

### Exercise Display Rules

Exercises are grouped by section (`groupType == .section`), then within each section:

- **Regular exercises**: Rendered as individual cards with numbered index, exercise name, equipment, notes, and set list
- **Superset groups**: A superset parent (`groupType == .superset`, empty sets) and its children (`parentExerciseId` pointing to parent) are rendered as a **single combined card**:
  - Card header shows a "SUPERSET" badge and the parent exercise name (e.g., "Superset: Triceps")
  - Sets are displayed **interleaved round-robin** across children: child A set 1, child B set 1, child A set 2, child B set 2, etc. Each set row is prefixed with the exercise name to identify which exercise it belongs to.
  - The superset parent exercise is NOT rendered as a separate standalone card
  - Children of a superset are NOT rendered as separate standalone cards
- **Exercise numbering**: Superset parents are excluded from the numbered index. Only exercises with sets (regular exercises and superset children) receive a number.

### UI Elements (Detail)

| Element | testID | Type |
|---------|--------|------|
| Detail scroll view | `workout-detail-view` | ScrollView |
| Favorite button | `favorite-button-detail` | Button |
| Start workout button | `start-workout-button` | Button |
| Share button | `share-plan-button` | ToolbarItem |
| Exercise card | `exercise-{exercise.id}` | View |
| Superset card | `superset-card-{parent.id}` | View |
| Set row | `set-{set.id}` | View |

## Error/Empty States
- **No plans**: "No plans yet" + "Import your first workout plan to get started" + Import Plan button
- **No search results**: "No plans found" + "Try a different search term"
- **Equipment filter no results**: "No plans available" + "All plans require unavailable equipment..." + "Set Up Equipment" button
- **Store error**: Alert dialog with error message
