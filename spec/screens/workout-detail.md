# Workout Detail Screen

## Purpose
Display full details of a workout plan template — exercises, sets, tags, metadata — with actions to start the workout, reprocess from markdown, and toggle favorite.

## Route
`/workout/[id]` — Dynamic route. Accessed by tapping a plan card from Home or Workouts screens.

## Layout
- **Header**: Native stack header with plan name as title, share button (share icon) in headerRight
- **Body**: WorkoutDetailView component (ScrollView) containing:
  1. **Header card**: Plan name, favorite button, description, tags, meta stats (exercises count, total sets, units), Edit and Reprocess buttons
  2. **Exercises section**: Grouped by sections (warmup/cooldown/default) with exercise cards showing set details
- **Footer**: Fixed "Start Workout" button pinned to the bottom of the screen, outside the ScrollView

**Critical**: The "Start Workout" button must be **always visible without scrolling**. It must be positioned as a fixed/sticky element pinned to the bottom of the screen, outside the ScrollView content area. The button must not require the user to scroll past all exercises to reach it. This is essential for long workout plans with many exercises.

## UI Elements

| Element | testID | Type |
|---------|--------|------|
| Loading state | `workout-detail-loading` | View |
| Detail view container | `workout-detail-view` | ScrollView |
| Share button (header) | `share-plan-button` | TouchableOpacity |
| Favorite button | `favorite-button-detail` | TouchableOpacity |
| Start Workout button | `start-workout-button` | TouchableOpacity |
| Exercise card (single) | `exercise-{exercise.id}` | View |
| Superset card | `superset-{globalIndex}` | View |
| Set row | `set-{set.id}` | View |
| YouTube link | `youtube-link-{exerciseName}` | Link |
| Edit markdown button | `edit-plan-markdown-button` | Button |
| Edit with AI button | `edit-plan-ai-button` | Button |
| Edit with AI upsell row | `edit-plan-ai-upsell` | Button |
| Reprocess button | `reprocess-plan-button` | Button |
| Exercise edit button | `edit-plan-exercise-{exerciseName}` | Button |

## User Interactions
- **Tap share button (header)** → exports the plan's original LMWF markdown (`sourceMarkdown`) to a `plan-{sanitized-name}.md` file in the cache directory via `exportPlanAsMarkdown(plan)`, then presents the iOS share sheet (`UIActivityViewController`) for that file URL using the shared `.shareSheet(item:)` modifier. The user can then save it to Files, AirDrop it, or share it into another app.
  - **Critical**: The share button must actually present a share sheet. Presenting `UIActivityViewController` directly on `connectedScenes.first?.rootViewController` is a known no-op when the first connected scene is inactive — always route through the `.shareSheet(item:)` modifier (see `ShareSheet.swift`, GH #70).
  - If `sourceMarkdown` is null or empty, an "Export Failed" alert is shown instead.
- **Tap favorite heart** → toggles favorite, reloads plan
- **Tap "Start Workout"** → checks for active session → starts workout → navigates to `/workout/active`
  - If active session exists: alert with "Resume Workout" option
  - **Critical**: After tapping "Start Workout", the app MUST navigate to the Active Workout screen (`/workout/active`) and display the workout exercises with their sets. The active workout screen must be fully functional — showing exercise names, set targets (weight, reps, time), and input controls. If the session is created but navigation fails or the active workout screen does not appear, this is a blocking bug.
- **Tap "Edit"** → opens Edit Plan Markdown sheet pre-populated with `sourceMarkdown`. User can edit the markdown text with real-time parse validation (same as import flow). Save updates `sourceMarkdown` and reprocesses the plan. Cancel discards changes.
- **Tap "Reprocess"** → confirmation alert → re-parses plan from original `sourceMarkdown` (no editing)
- **Tap "Edit with AI"** → opens the AI Edit sheet (`ai-edit-sheet`) for this plan. See `spec/services/ai-plan-editing.md` for the engine contract and `spec/flows/ai-plan-editing.md` for the step-by-step flow. The button is shown only when `sourceMarkdown != nil`, the `aiPlanEditing` developer flag is on, and the signed-in user's tier is `pro` or `trial` (or the stub engine is active). When the flag is on but the user is signed out or on `free`, the same slot renders `edit-plan-ai-upsell`, which explains that AI editing is part of LiftMark Pro and, when signed out, offers Sign in. Applying an AI proposal goes through `updatePlanMarkdown` exactly like the markdown editor, so the detail view behind the sheet refreshes on Apply.
- **Tap pencil icon on exercise card** → opens Edit Exercise sheet (same Form/Markdown dual-tab sheet as active workout) pre-populated with the exercise's data. Save updates the exercise within the plan.
  - **Critical (GH #264)**: Persisting an exercise edit MUST NOT regenerate the whole plan from the model. It splices **only the edited exercise's block** back into the plan's `sourceMarkdown` and re-parses that spliced text (`LMWFSourceEditor.replacingExercise` → `updatePlanMarkdown`). Everything the user did not edit — other exercises, section/superset **header levels**, blank lines, comments, and unknown `@metadata` — is preserved verbatim. Regenerating the entire document (the old behavior) flattened every header to `##`, so `## Warmup` / `### Band Side Step` collapsed to two `##` headers, breaking the section nesting and producing a parse error the user then had to hand-repair. An exercise edit must be equivalent to replacing that one section of the source markdown with the user's edited version, at its original header level.
  - Superset edits splice the entire superset block (parent header + all child headers) at their original levels; section-child edits splice just that child's block. The header level(s) come from the source itself, so non-standard nesting (e.g. a superset whose children skip a level) round-trips unchanged.
  - If the edited exercise cannot be located in `sourceMarkdown` (e.g. a legacy plan with no stored markdown), the model change is still persisted but `sourceMarkdown` is left untouched rather than regenerated.
- **Tap YouTube icon** on exercise name → opens YouTube search for that exercise

## Navigation
- `/workout/active` — after starting workout or resuming existing
- Back (via router.back()) — on error

## Error/Empty States
- **Plan not loaded**: LoadingView
- **Load error**: Alert with error message, navigates back on dismiss
- **Export failure**: "Export Failed" alert if `sourceMarkdown` is not available (e.g., plan was not imported from markdown) or the file write fails

## WorkoutDetailView Component Details

### Header
- Plan name (large, bold)
- Favorite toggle (heart icon, red when favorited)
- Optional description text
- Tags as pill badges
- Meta stats row: Exercises count, Total Sets, Units (if set)

### Edit / Reprocess Buttons
- Displayed only when `sourceMarkdown != nil`
- Two half-width buttons side by side in an HStack:
  - **Edit** (`edit-plan-markdown-button`): Opens Edit Plan Markdown sheet
  - **Reprocess** (`reprocess-plan-button`): Shows confirmation alert, then reprocesses from stored markdown
- Both buttons use secondary styling (same as the previous single Reprocess button)
- When the `aiPlanEditing` flag is on, a third full-width row sits beneath them: **Edit with AI** (`edit-plan-ai-button`, sparkles icon, secondary styling) or the `edit-plan-ai-upsell` variant.

### AI Edit Sheet (`ai-edit-sheet`)

Presented with `.sheet` hosted on `WorkoutDetailView` (stable host, see the Settings sign-in sheet note in `settings.md`). The sheet is a **live preview over an edit area**, not a chat transcript (GH #461: the old transcript layout left most of the screen empty). Layout, top to bottom:

1. **Header**: navigation title "Edit with AI", close button (`ai-edit-close`), and a **History** button (`ai-edit-history`, clock icon) that is present once at least one turn has been sent.
2. **Plan preview** (top region, roughly the upper two-thirds, scrolls): the session's working plan rendered as its exercise list — plan name and tags, section headers (same divider style as the detail screen), superset groups, and one row per exercise with the exercise name, equipment, notes, and its sets as LMWF-style lines (`135 lbs x 5 @rest: 90s`). With no proposal pending the container is `ai-edit-preview` and every row is `ai-edit-preview-row-{slug}`.
   - **While a proposal is pending** the preview shows the *proposed* plan with inline diff highlighting and the container is identified as `ai-edit-diff` instead. Highlighted rows carry `ai-edit-diff-row-{slug}` (slug = kind + exercise name, e.g. `added-face-pull`):
     - **added** — success tint, leading `+` marker;
     - **removed** — error tint, leading `−` marker, name and set lines struck through, kept at the position the exercise used to occupy;
     - **changed** — warning tint, leading `~` marker, the previous set lines struck through above the new ones.
     Unchanged rows render normally. Plan-level changes (rename, tags, units, notes) are listed as a caption block above the first section. Uses `Theme` semantic colours only (`success`, `destructive`, `warning`).
   - A plan whose markdown does not parse shows "Preview unavailable" in place of the list.
3. **Status strip** (between preview and edit area, part of the bottom region): exactly one of — the thinking indicator (`ai-edit-thinking`) while a call is in flight; the latest error (`ai-edit-error`, error tint) when the last turn failed; the latest assistant summary plus any parser warnings for the proposed plan ("No changes were made" when the diff is empty); or, before the first turn, the hint "Describe how you'd like to change this plan, or start with a suggestion." Below it, a caption line with the engine label (`ai-edit-engine-label`), the quota label (`ai-edit-quota-label`) and, when Apple offers a limit increase, **Show options** (`ai-edit-quota-options`).
4. **Edit area** (bottom region, fixed, at least the lower third of the sheet; it never collapses — at large Dynamic Type sizes it grows and the preview shrinks and scrolls):
   - **Proposal bar** (only while a proposal is unapplied): **Discard** (`ai-edit-discard`) and **Apply** (`ai-edit-apply`, primary; disabled when the diff is empty). After an Apply, **Undo** (`ai-edit-undo`) appears in its place until the next proposal.
   - **Quick-action chips** (`ai-edit-chip-{slug}`): a horizontally scrolling row, always visible, disabled while thinking or when the engine is unavailable. Tapping a chip sends that instruction.
   - **Privacy caption** (`ai-edit-privacy-footer`): one caption line naming the active engine.
   - **Composer**: text field (`ai-edit-input`, multiline, placeholder "Describe a change…", disabled while thinking or locked), send (`ai-edit-send`, disabled when empty or thinking), cancel (`ai-edit-cancel`, shown only while thinking).

**History** (`ai-edit-history`) presents the transcript as a secondary sheet: one row per turn (`ai-edit-message-{index}`, 0-based) — user instructions right-aligned, assistant summaries left-aligned with a "N changes" caption, errors in the error tint. Turns that were discarded or undone are dimmed and captioned "Discarded" (they are not sent to the engine again, see the service spec). It is read-only; the preview is the surface for the current proposal.

Closing with an unapplied proposal (close button or swipe) asks "Discard the unapplied edit?" (Discard / Keep editing).

### Exercise Cards
- Numbered with section-colored index
- Exercise name (left) with pencil edit icon (`edit-plan-exercise-{exerciseName}`) in the top-right corner (36x36 tap target, `.body` font)
- Equipment type (if set)
- Notes (italic, if present)
- Sets listed with all applicable fields
- YouTube search link at the bottom of the card (below sets), displayed as a centered descriptive link: `Search "Exercise Name" on YouTube` with play.rectangle icon. Hidden when card is collapsed.

#### Set Display Format

Each set row MUST display all data that was parsed from the workout plan. The following fields must be shown when they have values:

| Field | Display Format | Example | Required |
|-------|---------------|---------|----------|
| Set number | Numeric index | "Set 1", "Set 2" | Always |
| Weight | Numeric value + unit | "135 lbs", "60 kg" | When `targetWeight` is set |
| Reps | "x" + count | "x 5", "x 12" | When `targetReps` is set |
| Time | Duration in M:SS | "1:00", "1:30" | When `targetTime` is set |
| RPE | "@RPE" + value | "@RPE 8" | When `targetRpe` is set |
| Rest | Rest duration in M:SS | "1:30 rest" | When `restSeconds` is set |
| Tempo | Tempo notation | "3-0-1-0" | When `tempo` is set |
| Drop set | Badge | "Drop" | When `isDropset` is true |
| Per side | Badge | "/side" | When `isPerSide` is true |

**Critical**: Weight MUST be displayed when it exists in the parsed data. A set row showing only "x 5" when the plan specifies "135 x 5" is a bug — it must show "135 lbs x 5" (or the appropriate unit). The weight is the most important piece of information in a strength training set and must never be silently omitted.

### Section Headers
- Styled divider lines with section name centered between them
- Text uses `fixedSize(horizontal: false, vertical: true)` with `layoutPriority(1)` so the section name gets priority horizontal space and the divider lines flex to fill remaining width
- When the section name wraps to multiple lines, text is centered (`multilineTextAlignment(.center)`)
- Color-coded: warmup (sectionWarmup), cooldown (sectionCooldown), default (primary)

### Supersets
- Purple "SUPERSET" badge
- Multiple exercise names joined with "&"
- Interleaved set display across exercises
- **Single-member supersets**: a superset block that resolves to only one exercise is not a real superset (there is nothing to alternate with). It is rendered as a plain standalone exercise — no SUPERSET badge, no grouped card — exactly as the active workout view renders it. A superset is treated as a real (grouped) superset only when it has 2 or more members (`SupersetGrouping.isRealSuperset`). The validator emits a `SINGLE_MEMBER_SUPERSET` warning so the authoring error is visible in the source.
