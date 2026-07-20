# Active Workout Screen

## Purpose
Primary workout execution screen. Displays all exercises and sets for the active session, allows completing/skipping sets with weight/rep input, manages rest timers and exercise timers, and supports editing exercises and adding new ones mid-workout.

## Route
`/workout/active` — Navigated to after starting or resuming a workout.

## Layout
- **Header**: Custom header with Pause button (left), workout name (center), Notes button + Finish button (right). The Notes button is persistently reachable at all times during the session — the user should never lose a thought because they can't find the field. Add Exercise is intentionally NOT in the header; it lives in the bottom action bar so the top cluster stays readable on iPhone (GH #98).
- **Progress bar**: Below header. Two-tone fill — blue (`LiftMarkTheme.primary`) for the completed proportion, orange (`LiftMarkTheme.warning`) for the skipped proportion, and grey for the remainder. The label reads `"<completed + skipped> / <total> sets done"` so a session in which most pending sets were intentionally skipped does not visually read as "you missed something." When `skipped == 0` and `completed == total`, the completed segment uses `LiftMarkTheme.success` for the full-success affordance.
- **Body**: ScrollView of exercise sections, each containing SetRow components
- **Bottom action bar** (`active-workout-footer`): Pinned to the bottom safe-area inset. Houses the primary **Add Exercise** button (filled, `active-workout-add-exercise-button`) and a secondary **End Workout** button (bordered, `active-workout-footer-finish-button`). The bottom End-Workout button exists in addition to the top-bar Finish so the user does not have to reach the top-right corner on large iPhones (GH #99). Both buttons trigger the same finish confirmation flow. The bottom button is deliberately labelled "End Workout" rather than "Finish" so text-based UI test matchers (which target `Finish` / `Finish Anyway` / `Log Anyway` in the confirm alert) cannot accidentally match the bottom button when the alert is what should be hit.
- **Modals**: EditExerciseModal, AddExerciseModal (overlaid)

## UI Elements

| Element | testID | Type |
|---------|--------|------|
| Screen container | `active-workout-screen` | View |
| Header | `active-workout-header` | View |
| Pause button | `active-workout-pause-button` | TouchableOpacity |
| Notes button | `active-workout-notes-button` | Button |
| Finish button (top) | `active-workout-finish-button` | Button |
| Footer | `active-workout-footer` | View |
| Add exercise button (bottom) | `active-workout-add-exercise-button` | Button |
| Finish button (bottom) | `active-workout-footer-finish-button` | Button |
| Progress section | `active-workout-progress` | View |
| Scroll content | `active-workout-scroll` | ScrollView |
| Exercise card | `exercise-card-{index}` | View |
| Exercise timer start | `exercise-timer-start-button` | Button |
| Exercise timer done | `exercise-timer-done-button` | Button |
| YouTube link | `youtube-link-{exerciseName}` | Link |
| Add weight button (reps-only set) | `set-add-weight-button` | Button |

## User Interactions

### Workout Notes (GH #91)
- **Tap Notes button in header** → opens `SessionNotesSheet` pre-filled with the current session's notes.
- Notes are plain free text — no tags, structured fields, or auto-summarization.
- Notes belong to the *completed session record* and never mutate the source plan.
- Saving persists immediately via `SessionStore.updateActiveSessionNotes`, so notes survive app backgrounding or termination mid-session.
- The notes button icon changes to indicate whether notes already exist (`note.text` when present, `square.and.pencil` when empty).
- Empty / whitespace-only input is normalized to `nil` at the repository layer.

### Set Completion
- **Tap current set** → no-op (already expanded)
- **Edit weight/reps fields** → updates edit values; weight propagates to remaining pending sets in same exercise
- **Inline weight on reps-only sets (GH #194)**: a set logged as reps-only / bodyweight (no target weight) shows a compact **"add weight"** affordance (`set-add-weight-button`) in place of the weight field. Tapping it reveals the weight stepper/field inline so a weight can be logged without editing the exercise definition. The entered weight is saved against the user's default weight unit (`UserSettings.defaultWeightUnit`) since the set started unitless. Leaving the field blank logs no weight (the set stays reps-only) — adding weight is opt-in per set. The same affordance appears in the inline edit form for an already-logged reps-only set.
- **Complete button visibility**: The checkmark complete button is hidden when `targetTime != nil` (timed sets). Timed sets are completed exclusively via the ExerciseTimerView Done button. The Skip button remains visible for all set types.
- **Tap "Complete"** → records actual values from input fields, advances to next set
  - **Critical**: The actual values saved MUST be whatever the user has entered in the input fields at the time of tapping "Complete". If the user edited weight from 225 to 230, save 230. If the user edited reps from 5 to 6, save 6. The input fields are the source of truth, not the original target values.
  - If rest seconds defined and auto-start enabled: starts rest timer automatically
  - If rest seconds defined and auto-start disabled: shows Start/Skip rest suggestion
  - If all sets complete: triggers Finish flow
- **Tap "Skip"** → marks set as skipped, advances

### Drop Set Recording
- Drop sets (`isDropset == true`) display a full-width **"Add Drop"** button below the current entry inputs. The button is 44pt tall with a bordered outline style (`destructive` color with 0.3 opacity stroke) to provide a clear, distinct tap target that won't be confused with the "Complete Set" button below it.
- **Tap "+ Drop"** → adds a new entry row (next groupIndex) with weight/reps input fields. The weight field pre-fills with the previous entry's weight to make editing faster (user typically reduces weight).
- Multiple drops can be added before completing the set.
- **Tap "Complete"** → records all entries (each at its own groupIndex) as actual values on the single SessionSet.
- **Remove a drop** → swipe left or tap the minus button on a drop entry to remove it before completing.
- Completed drop sets display all entries in a compact format: "225×10 → 185×6 → 135×4" with a "Drop" badge.
- Drop sets with no added drops behave identically to normal sets (single entry at groupIndex=0).

### Set Editing (completed/skipped sets)
- **Tap completed/skipped set** → opens inline edit form with editable fields for weight, reps, and/or time (matching the set type). Time fields are editable TextFields for timed sets (not read-only).
- **Tap "Update"** → saves changes to completed set (including edited time for timed sets)
- **Tap again** → closes edit form

### Rest Timer
- After set completion with rest seconds: rest timer or suggestion appears inline after the completed set
- **Single visible instance**: At most one rest timer is rendered at a time, regardless of how many exercises have pending sets. The timer is scoped to the specific set whose completion started it (the *triggering set*), identified by `RestTimerState.triggeringSetId`. When the user completes sets out of order — leaving multiple exercise cards with pending sets — the timer appears only on the card that owns the triggering set, immediately below that set row. Other in-progress cards must not echo the same timer.
- **Survives card collapse**: Completing the last set of an exercise collapses its card (see Exercise Collapse Behavior), and the user can also collapse a card manually. The rest timer must remain visible through this — it is exactly when rest has just started. While the owning card is expanded the timer renders inline below the triggering set; while that card is collapsed the same timer renders under the card's header instead, so it is never hidden inside the collapsed content. The timer is still owned by exactly one card, so collapsing does not duplicate it (GH #212). This applies equally to single-exercise cards and superset cards.
- **Tap "Start"** → starts countdown timer with audio ticks at 5/4/3/2/1s and completion tone at 0 (when Countdown Sounds setting is enabled). Audio ticks must fire at whole-second boundaries — the timer display tick must be aligned to second boundaries (not offset by the fractional time at which the timer was started).
- **Tap "Skip"** → dismisses rest suggestion
- **Tap "Stop"** → stops running timer (including overrun)
- Timer completion plays completion sound, clears "Up Next" preview
- **Continue past zero (overrun)**: When the countdown reaches zero the timer does NOT auto-dismiss. It fires the zero-crossing alert (completion sound + haptic, gated by the Countdown Sounds setting), switches the timer color to amber (`LiftMarkTheme.warning`) and begins **counting up from zero** as an overrun indicator. The overrun display is formatted as `+M:SS` (e.g. `+0:23`, `+1:05`). The zero-crossing alert fires exactly once per timer instance — it does NOT re-fire on subsequent overrun ticks. Countdown audio ticks (5/4/3/2/1) only fire while in the counting-down phase; no ticks fire during overrun. The timer keeps ticking in overrun until the user taps **Stop** or the next set implicitly dismisses it (see Auto-dismiss below).
- **Auto-dismiss on next set**: If a rest timer is currently running (countdown OR overrun) and the user completes or skips the next set, the running rest timer is dismissed. If the newly completed set also has `restSeconds` defined, a new rest timer starts for that set's rest duration. The user's action of completing the next set implicitly signals they are done resting. A freshly-started timer always begins in the counting-down phase with a new `startDate` — overrun state does not carry across timer instances.
- **State machine**: The timer's runtime display state is derived by a pure, testable state machine (`RestTimerTick`) from three inputs — `totalSeconds`, `startDate`, and the current `Date()`. It exposes `phase` (`.counting` | `.overrun`), `remainingSeconds`, `overrunSeconds`, `isOverrun`, and a formatted `displayString`. The SwiftUI view renders from this tick and fires side effects (sound/haptic) based on observed phase transitions.
- **Background resilience**: Rest timer uses wall-clock `Date()` timestamps internally (not counter-based). A `startDate` is recorded on timer start, and the current tick is computed as `RestTimerTick.compute(totalSeconds:, startDate:, now:)`. The 1-second Timer is kept only for UI updates and must keep ticking during overrun. The timer responds to `scenePhase` changes to recalculate on foreground return. On return to foreground, the timer must restart its display update tick if it was running before backgrounding (the system may invalidate the Timer during extended background periods) — this applies equally in the counting-down and overrun phases.

### Exercise Timer (timed sets)
- ExerciseTimer component appears **inline directly below the current set row** (not at the bottom of the exercise card). This keeps the timer visually associated with the active set when multiple timed sets exist.
- ExerciseTimer component appears for sets with `targetTime`
- This applies equally to timed sets inside a superset: when the current pending set in the interleaved superset list has a `targetTime`, the same `ExerciseTimerView` renders directly below that set row. Re-pending a previously skipped timed set (via "Clear Log" in the edit menu) restores the timer.
- **Tap Start** → begins counting up toward target
- **Tap Pause** → pauses timer; elapsed time is frozen
- **Tap timer display** → toggles between count-up and count-down display modes:
  - **Count-up**: Shows elapsed time counting from 0 toward target (e.g., "0:00 → target")
  - **Count-down**: Shows remaining time counting from target toward 0 (e.g., "target → 0:00"). Displayed as `max(0, targetSeconds - elapsed)` while still counting down.
  - **Count-down overrun**: When the count-down reaches zero the timer does NOT auto-dismiss. It fires the zero-crossing completion cue (completion sound, gated by the Countdown Sounds setting — fires exactly once per timer instance, not on every overrun tick) and transitions to an overrun display. The timer color switches to amber (`LiftMarkTheme.warning`) and the display format becomes `+M:SS` (e.g. `+0:23`) counting up from zero, indicating how far past the target the user has gone. Overrun continues until the user taps **Done** (which logs `actualTime = elapsed`, including the overrun portion), **Pause**, or the set is otherwise completed. Toggling to count-up mode while in overrun simply shows the full elapsed time (which is > target) in the count-up success color. Overrun applies only to count-down mode; count-up mode has no overrun concept.
  - The **initial mode** for each new timed set is determined by the `defaultTimerCountdown` user setting (see [Settings → Default Timer Countdown Behavior](./settings.md)). Default is count-up (setting off). Users who prefer count-down can enable the setting to skip the per-set toggle.
  - Count-down mode is only available when `targetSeconds` is not nil. When no target exists, the timer always shows count-up regardless of the setting.
  - A small arrow icon (up or down) appears next to the timer text to indicate the current mode.
  - The toggle state is local to the timer instance and resets to the setting-defined default when a new timed set begins.
- **Done button** → visible immediately once the timer is started (including at 0:00 elapsed), whether the timer is running or paused. Always uses success (green) styling to be visually consistent with the "Complete Set" button. Logs the current elapsed time as `actualTime`.
- **Background resilience**: Exercise timer uses wall-clock `Date()` timestamps. A `startDate` is set on start/resume. On pause, elapsed time is accumulated into `pausedElapsed` and `startDate` is cleared. Total elapsed = `pausedElapsed + (startDate != nil ? Date().timeIntervalSince(startDate!) : 0)`. The timer responds to `scenePhase` changes to recalculate on foreground return. On return to foreground, the timer must restart its display update tick if it was running before backgrounding (the system may invalidate the Timer during extended background periods). The `onDisappear` handler must only invalidate the Timer scheduling object — it must NOT reset timer state (`startDate`, `pausedElapsed`, `isRunning`, `displayElapsed`), because SwiftUI may call `onDisappear` during app backgrounding while the timer should continue tracking time. Full state reset only happens in the explicit `stopTimer()` path (Done button or set completion).
- **Timer tick alignment**: Both rest timers and exercise timers must align their 1-second display ticks to whole-second boundaries. On start, compute the delay to the next whole second, fire the first tick at that boundary, then schedule repeating 1-second ticks. This ensures countdown sounds at 5/4/3/2/1s fire precisely when the displayed time transitions, not at arbitrary offsets.
- **On set completion (timed sets)**:
  - If the exercise timer was started (elapsed > 0): log `actualTime` as the elapsed seconds from the timer at the moment of completion. If the timer is running, capture the current elapsed time. If the timer is paused, capture the paused elapsed time.
  - If the exercise timer was NOT started (completed via the set checkmark without starting the timer): log `actualTime` as the `targetTime` value from the plan.
  - **After logging**: the timer is dismissed and reset to 0. If there is a next timed set, a fresh timer appears ready for the next set.

### Per-Side Timed Sets
- During session creation, each timed set (`targetTime != nil`) with `isPerSide == true` is **expanded** into two separate session sets: one with `side = "left"` and one with `side = "right"`.
- Both sets are visible upfront in the exercise card — they are not hidden or sequential within a single timer.
- Example: An exercise with `- 30s per side` × 2 sets produces 4 session sets: Set 1 Left, Set 1 Right, Set 2 Left, Set 2 Right.
- Each expanded set has its own independent ExerciseTimerView — no sequential left/right logic within the timer.
- The set row displays a side label badge ("Left" or "Right") next to the set number.
- Target label shows "/side" suffix to clarify the target is per-side (e.g., "Target: 1:00/side").
- `actualTime` is recorded independently per side (each set stores its own elapsed time).
- The `is_per_side` flag is preserved on both expanded sets for display purposes.
- **Non-timed** per-side sets (rep-based, e.g., `25 x 12 @perside`) are NOT expanded — they remain a single set with the `/side` badge, as they have no timer.
- **Order indexing**: Expanded sets use fractional-style ordering to maintain correct position. For a per-side set at `order_index` N, the left set gets `order_index` 2*N and the right set gets `order_index` 2*N+1 (all sets in the exercise are re-indexed during expansion).

### Plate Calculator
- For barbell exercises (detected by `PlateCalculator.isBarbellExercise`): shows plate breakdown in a blue info box **above** the weight × reps input row
- Font size: `.callout` for text, `.caption` for icon — sized for easy readability during a workout
- Format: "45lb bar + Xlbs per side" (via `PlateCalculator.formatCompletePlateSetup`)
- Updates live as the user edits the weight field
- Hidden when weight is less than bar weight or exercise is not a barbell exercise
- See `spec/services/plate-calculator.md` for full service specification

### Header Actions
- **Tap "Pause"** → confirmation alert → saves progress → navigates back
- **Tap "+" (Add Exercise)** → opens AddExerciseModal
- **Tap "Finish"** → behavior depends on workout state:
  - All complete → directly completes → navigates to `/workout/summary`
  - Incomplete (pending) sets remain → "Finish Workout?" alert. The incomplete count considers only **pending** sets (not skipped sets — those are intentional). Button text: "Finish Anyway" when pending > 0, "Finish" when 0. Message: "You have N incomplete sets. They will be marked as skipped." when pending > 0, or "Great job completing all your sets!" when 0.
    - Finish Anyway → completes workout → navigates to `/workout/summary`
    - Cancel → returns to active workout
  - **Majority skipped** → if >50% of total sets are skipped and <50% are completed, show a "Discard Workout?" confirmation with options:
    - "Discard" (destructive) → cancels session without logging, navigates back
    - "Log Anyway" → completes workout normally → navigates to `/workout/summary`
    - "Cancel" → returns to active workout

### YouTube Links
- Displayed at the **bottom of the expanded exercise card** (below all sets), not in the header
- Shown as a centered descriptive link: `Search "Exercise Name" on YouTube` with play.rectangle icon
- Hidden when the exercise card is collapsed
- Tapping opens YouTube search for the exercise

### Exercise Editing
- **Tap pencil icon** (top-right of exercise card header, 36x36 tap target, `.body` font) on exercise → opens Edit Exercise sheet with two tabs:
  - **Form tab** (default): structured fields for name, equipment, notes, and an editable list of sets (weight/reps/time/rest fields, add set, delete set via swipe, reorder via drag). Each set row exposes a per-set rest input (seconds, `edit-set-rest-{index}`). Empty rest input means "no rest" (stored as NULL).
  - **Markdown tab**: TextEditor with exercise in LMWF format (`## Name`, `@type: equipment`, notes, `- weight x reps @rest: Ns`); parsed on save via MarkdownParser. Rest is round-tripped via the `@rest:` modifier on each set line, so switching between Form and Markdown preserves user-entered rest values.
- **Sheet must display exercise data**: The edit sheet must always be pre-populated with the tapped exercise's current data (name, equipment, notes, sets). A blank or empty sheet is a bug — the sheet presentation must be bound directly to the exercise being edited.
- **Segmented picker** (`edit-exercise-mode-picker`) toggles between Form and Markdown tabs
- Switching tabs syncs data: Form→Markdown regenerates LMWF, Markdown→Form parses the text
- **Save** (`edit-exercise-save`) → updates exercise name/notes/equipment + applies set changes (add/update/delete)
- **Set completeness (TC-E14)**: a set with a weight but no reps **and** no time is incomplete — the LMWF spec and validator reject it (`liftmark-workout-format/examples/errors/tc-weight-no-reps.md`), so the Edit Exercise sheet must too. **Both** tabs enforce this:
  - **Markdown tab** already rejects it via `MarkdownParser.parseWorkout` (the parse fails and the error is shown).
  - **Form tab** must apply the same rule: on Save, if any set has a positive weight but neither reps nor time, the save is blocked and an inline error is shown (`edit-exercise-form-error`) naming the offending set, e.g. *Set 2 — Incomplete set: "26 lbs". Weight with unit requires reps (x 5) or time (x 60s)*. A weighted carry must be entered as weight + time (`26 lbs x 30s`), not weight alone.
  - A bodyweight/reps-only set (no weight) is unaffected; weight is optional, reps/time are what a weight requires.
- **Cancel** (`edit-exercise-cancel`) → dismisses without saving

| Element | testID | Type |
|---------|--------|------|
| Mode picker | `edit-exercise-mode-picker` | Picker |
| Name field | `edit-exercise-name` | TextField |
| Equipment field | `edit-exercise-equipment` | TextField |
| Notes field | `edit-exercise-notes` | TextEditor |
| Form container | `edit-exercise-form` | Form |
| Markdown editor | `edit-exercise-markdown` | TextEditor |
| Markdown view | `edit-exercise-markdown-view` | View |
| Form validation error | `edit-exercise-form-error` | Text |
| Add Set button | `edit-exercise-add-set` | Button |
| Save button | `edit-exercise-save` | Button |
| Cancel button | `edit-exercise-cancel` | Button |
| Set weight field | `edit-set-weight-{index}` | TextField |
| Set reps field | `edit-set-reps-{index}` | TextField |
| Set time field | `edit-set-time-{index}` | TextField |
| Set rest field | `edit-set-rest-{index}` | TextField |

### Add Exercise
- **Tap "+" in header** → opens AddExerciseModal with markdown template
- Enter exercise markdown → **Save** → parses and adds exercise to session
- **Accepted input**: The sheet accepts either a full workout markdown (`# Title` + `## Exercise` + sets) or a standalone exercise block (`## Exercise` + sets with no workout header). When no `# Workout` header is present the parser is invoked with a synthetic header prepended — users should not have to type a workout title just to add a single exercise mid-session. The example hint text shows the standalone form.

### Section Display
- Workouts may contain organizational sections (e.g., Warmup, Main Workout, Cool Down) defined by section headers in the LMWF format.
- Section header dividers give priority horizontal space to the section name text (`layoutPriority(1)`, `fixedSize`), with divider lines flexing to fill remaining width. When text wraps, it is centered.
- Section headers (`groupType == .section`, empty sets) are **not** rendered as exercise cards — they are purely organizational.
- Exercises within a section (`parentExerciseId` pointing to the section header) are rendered as **individual standalone exercise cards**, identical to top-level exercises.
- Section children must not be skipped or treated as orphans — they are the primary content of the workout.
- A workout can freely mix sections, supersets within sections, and top-level exercises.

### Superset Display
- Superset exercises are grouped into a **single combined card** showing all children together
- The superset parent (`groupType == .superset`, empty sets) provides the card header with a purple circular icon (arrow.triangle.2.circlepath), a solid purple "SUPERSET" capsule tag, and the superset title
- Children (`parentExerciseId` pointing to parent) are grouped under the parent card
- The card subtitle lists children with their display numbers (e.g., "3. Tricep Pushdown + 4. Overhead Extension")
- Sets are displayed **interleaved round-robin**: child A set 1, child B set 1, child A set 2, child B set 2, etc.
- Each set row shows the exercise name label to identify which exercise it belongs to
- The superset parent and its children are NOT rendered as separate standalone cards
- **Single-member supersets**: a superset parent with only one child is not a real superset (nothing to alternate with). The lone child is rendered as a standalone exercise card, not a grouped superset card. A superset is grouped only when it has 2 or more members (`SupersetGrouping.isRealSuperset`). The plan (pre-start) view applies the same rule, so both views render single-member supersets identically.
- **Exercise numbering**: Superset parents and section headers are excluded from the numbered badge index. Only exercises with sets (regular exercises and superset children) receive a sequential number. A superset with 2 children counts as 2 exercises in the numbering sequence.
- **Session creation**: When creating a session from a plan, `parentExerciseId` must be mapped from plan exercise IDs to the corresponding session exercise IDs so superset grouping is preserved

### Exercise Card Tinting
- Each exercise card on the active workout screen is tinted by its *aggregate set status*, providing an at-a-glance signal of how the exercise was resolved. The rule applies only to **finalized** exercises — every set must have a terminal status (`.completed` or `.skipped`). A single `.pending` (or `.failed`) set keeps the card neutral.
- Tint states map from `[SessionSet.status]` as follows:

| Aggregate state | Treatment | Background |
|-----------------|-----------|------------|
| All sets completed | Green tint | `secondaryBackground` + Success overlay at 18% opacity |
| All sets skipped | Amber tint | `secondaryBackground` + Warning overlay at 18% opacity |
| Mixed (some completed, some skipped; all finalized) | Diagonal split (green → amber) | `secondaryBackground` + `LinearGradient(Success 22%, Warning 22%)` from top-leading to bottom-trailing |
| Any pending set (not started or in progress) | Neutral | `secondaryBackground` |

- The `.failed` status is not one of the two finalized terminal states for this rule and keeps the card neutral so the user notices the failure.
- Tint overlays are layered on top of the existing `secondaryBackground` so that text contrast is preserved in both light and dark mode. The existing 60% opacity fade applied when an exercise is fully finalized is retained and composes with the tint.
- **Supersets** use the same rule, aggregating statuses across all child exercises' sets so the superset card reflects the combined state.
- The mapping is implemented as a pure function `ExerciseCardTint.from(statuses:)` in `Views/Workout/ExerciseCardTint.swift`; all tint decisions MUST go through it so behavior remains centrally testable.
- **Accessibility**: when non-neutral, the card exposes an `accessibilityValue` of "All sets completed", "All sets skipped", or "Mixed completed and skipped sets".

### Exercise Collapse Behavior
- Completed exercises (all sets completed or skipped) automatically collapse to a compact summary showing: exercise name, completion status badge, and a brief summary (e.g., "3/3 sets completed")
- Collapsed exercises can be tapped to expand and view full set detail
- When an exercise's last set is completed, it collapses and scroll focus moves to the next exercise
- The currently active exercise (containing the current pending set) is always expanded
- User can manually expand/collapse any exercise
- **Tap target**: The entire exercise header row (number badge, exercise name, spacer area, set count) must be tappable to toggle collapse. The button label HStack must use `.contentShape(Rectangle())` so that transparent spacer areas forward taps. Additional `.padding(.vertical, 4)` ensures a comfortable vertical tap target.
- **Exercise timer persistence**: When a timed exercise has a running (or paused) ExerciseTimerView and the user collapses the exercise card, the timer state must be preserved. The ExerciseTimerView must remain in the SwiftUI view hierarchy (hidden visually when collapsed) so that its `@State` variables (`startDate`, `pausedElapsed`, `isRunning`, `displayElapsed`) survive collapse/expand cycles. The timer is rendered outside the collapsed content block with `.opacity(0)`, `.frame(height: 0)`, and `.clipped()` when collapsed, ensuring it is invisible and takes no space but remains alive in the view tree.

| Element | testID | Type |
|---------|--------|------|
| Collapsed exercise summary | `exercise-collapsed-{exerciseId}` | TouchableOpacity |
| Collapse/expand toggle | `exercise-toggle-{exerciseId}` | TouchableOpacity |

### Live Activities (iOS)
- **On appear**: If `liveActivitiesEnabled` setting is true and Live Activities are available, starts a Live Activity showing the current workout state (exercise name, set progress, overall progress). This handles both initial workout start and resume-after-pause.
- **On set completion**: Updates the Live Activity with the new current exercise/set and progress. If a rest timer starts, includes rest timer countdown in the Live Activity.
- **On set skip**: Updates the Live Activity with the new current exercise/set and progress.
- **On pause (dismiss)**: Ends the Live Activity before dismissing the view. The Live Activity must not persist after the active workout screen is dismissed via the Pause button.
- **On disappear (any navigation away)**: Ends the Live Activity. This is a safety net — if the view disappears for any reason (back navigation, swipe, tab switch), the Live Activity must be cleaned up.
- **On finish**: Ends the Live Activity with a "Workout Complete" message.
- **On discard**: Ends the Live Activity with a "Workout Discarded" message.
- **No duplicates**: At no point during the workout lifecycle should more than one Live Activity banner exist. The `startWorkoutLiveActivity()` call on appear must await cleanup of any existing activity before creating a new one (see Live Activities service spec).
- All Live Activity calls are guarded behind `settingsStore.settings?.liveActivitiesEnabled == true` and `LiveActivityService.shared.isAvailable()`.

### YouTube Links
- See "YouTube Links" section above — displayed at bottom of expanded exercise card, not in the header

## Navigation
- Back (via Pause) → previous screen
- `/workout/summary` — after finishing workout

## Data Integrity

- All exercises from the workout plan MUST persist throughout the entire workout session — no exercise may be removed except by explicit user action
- Workout data MUST survive app backgrounding, foreground transitions, and sync operations
- On crash recovery (app kill/restart), the active session MUST be restored from the database with all exercises and sets intact, including their completion status

## Error/Empty States
- **No active session**: LoadingView with "Loading workout..."
- **Store error**: Alert dialog with error message

## SetRow Component
Renders individual sets with multiple visual states:
- **Pending**: Shows target weight/reps (e.g., "135 lbs x 5"), neutral styling
- **Current (active form)**: Blue highlight, weight/reps input fields pre-filled with target values, Skip and Complete buttons. Uses consistent padding (spacingXS vertical, spacingSM horizontal) matching other set rows. Larger fonts (.title3.monospacedDigit() for inputs) and 44pt minimum tap targets. Layout is two rows: top row has inputs + skip button, bottom row has a full-width "Complete Set" button to separate it from skip and provide a large tap target. For per-side sets, a side label badge ("Left" or "Right") is displayed next to the set indicator, before the input fields.
  - **Stepper buttons**: Input fields are flanked by minus/plus stepper buttons (`minus.circle` / `plus.circle` icons) for quick adjustment during workouts. All values are clamped to a minimum of 0. Stepper buttons use `.secondaryLabel` color and `.callout` font size for reps/time, `.body` for weight.
    - **Weight**: +/-5 for lbs, +/-2.5 for kg (unit-aware). Applied to main weight field and drop set weight fields.
    - **Reps**: +/-1 per tap. Applied to main reps field and drop set reps fields.
    - **Time**: +/-5 seconds per tap for targets under 90 seconds; +/-30 seconds per tap for targets of 90 seconds or more (coarser steps so long holds don't need a dozen taps). Applied to timed exercise input fields.
  - **Target hint**: When a target exists, a "Target: 185 lbs x 5" hint line is always present in the layout to reserve its vertical space. It is only visible (opacity 1) when the user has changed weight or reps from the target values; otherwise it is hidden (opacity 0). This prevents the "Complete Set" button from jumping when the hint appears or disappears.
- **Up Next preview**: Compact single-line with "UP NEXT" label
- **Completed**: Green background, shows actual values (weight + reps), "Tap to edit"
- **Skipped**: Yellow/warning background, "Skipped", "Tap to edit"
- **Editing (completed/skipped)**: Expanded form with Update button

### Set Data Display Requirements

**Critical**: Every set row MUST display the weight when it exists in the set data (`targetWeight` for pending/current sets, `actualWeight` for completed sets). A set row that shows only reps (e.g., "x 5") when weight data exists (e.g., 135 lbs) is a bug. The weight is the primary data point for strength training and must always be visible.

Set rows must display contextually appropriate fields based on exercise type:
- **Weighted sets** (`targetWeight` exists, `targetTime` nil): show weight field with unit (lbs/kg) and reps field
- **Timed sets** (`targetTime` exists, no `targetWeight`): show editable time input field labeled "Time (m:ss)", not "weight". The field value is displayed in `M:SS` (e.g. "1:15" for 75 seconds); typed input accepts either `M:SS` ("1:15") or raw seconds ("75" — normalized back to "1:15" on the next stepper tap or edit). The user can adjust the target time before starting the timer.
- **Weighted timed sets** (`targetWeight` AND `targetTime` exist, no `targetReps`): show weight input field with unit AND editable time input field. No reps field. Complete button hidden — timer Done button completes the set. The user-edited weight from the input field must be saved as `actualWeight` when the timer completes. The user-edited time is used as the new target for the timer.
- **Bodyweight rep sets** (no `targetWeight`, `targetReps` exists): show reps only, no weight field

| Set State | Weight Display | Reps Display | Time Display |
|-----------|---------------|-------------|-------------|
| Pending | Target weight + unit (e.g., "135 lbs") | Target reps (e.g., "x 5") | Target time in M:SS (e.g., "1:00") |
| Current | Pre-filled in weight input field | Pre-filled in reps input field | Pre-filled in editable time input field |
| Current (weighted-timed) | Pre-filled weight input field + unit | — (no reps) | Pre-filled in editable time input field (completed via timer) |
| Completed | Actual weight + unit | Actual reps | Actual time in M:SS |
| Skipped | "Skipped" label (no weight/reps) | — | — |

### Duration Display Consistency

All user-facing durations MUST render as `M:SS` (e.g. "0:45", "1:15") via the shared `DurationFormat.mmss` helper, matching the exercise and rest timers. This covers: the timed-set input field, pending/completed set rows, exercise card set summaries, rest placeholders, workout detail plan rows, inbox preview, history views and charts, and Live Activity set details. Raw-seconds display (e.g. "75", "60s") in any of these surfaces is a bug.

Exception — LMWF source syntax is not display: previews of LMWF lines (e.g. `- 30s @rest: 60s` in the exercise edit sheets), LMWF serialization, and parser warnings keep the format's `Ns` notation. The edit-sheet Form-tab time/rest inputs stay in raw seconds because they author LMWF values and sit directly above the `Ns` source preview.

`DurationFormat` MUST have unit tests covering formatting (including zero, sub-minute, minute boundary, and negative clamping) and input parsing (`M:SS` and raw seconds, rejecting malformed input).

### Rest Timer inline
- Shows after the last completed set when rest is needed
- Running timer: circular countdown display with Stop button
- Suggestion: "Rest: Xs" with Start/Skip buttons

### Rest Placeholder
- Between pending sets that have rest seconds: faint "--- Rest M:SS ---" divider (e.g. "Rest 1:30")
