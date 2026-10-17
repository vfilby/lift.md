# AI Plan Editing Flow

Service contract: `spec/services/ai-plan-editing.md`. Screen: `spec/screens/workout-detail.md`.

## Preconditions

- `aiPlanEditing` developer flag is on.
- The plan has `sourceMarkdown`.
- The user is signed in with tier `pro` or `trial` (or the stub engine is active).

## Flow

1. User opens a plan and taps **Edit with AI** (`edit-plan-ai-button`).
2. The sheet opens showing the current plan as a live preview (`ai-edit-preview`) in its
   upper region and the edit area (chips + composer) in its lower region.
   `PlanEditEngineSelector` picks an engine (stub → override → Apple Private Cloud Compute →
   LiftMark cloud). The status strip's caption shows the engine's display name
   (`ai-edit-engine-label`) and, once known, quota (`ai-edit-quota-label`).
   - If no engine is available the status strip shows the reason (`ai-edit-error`) and the
     input and chips are disabled. The user can close the sheet.
3. Quick-action chips (`ai-edit-chip-{slug}`) are always visible above the composer:
   *Make it shorter*, *Swap barbell for dumbbells*, *Add a warm-up*, *Progress loads 2.5%*,
   *I only have 30 min*. Tapping a chip sends that instruction.
4. User types an instruction (`ai-edit-input`) and taps send (`ai-edit-send`).
   - Input and chips are disabled and the status strip shows the thinking indicator
     (`ai-edit-thinking`) while the call runs. A cancel button (`ai-edit-cancel`) aborts it.
5. On success the preview switches to the proposed plan with inline diff highlighting
   (container `ai-edit-diff`; rows `ai-edit-diff-row-{slug}`), the status strip shows the
   assistant's summary, and the proposal bar appears: **Apply** (`ai-edit-apply`), **Discard**
   (`ai-edit-discard`).
   - If the diff is empty, the status strip says "No changes were made" and Apply is disabled.
   - Parser warnings for the new plan are listed under the summary.
6. The user may:
   - **Apply**: the plan is persisted via `updatePlanMarkdown`. The detail view behind the
     sheet updates. The preview loses its highlighting (it now shows the applied plan) and
     **Undo** (`ai-edit-undo`) takes the proposal bar's place; it restores the previously
     persisted markdown. The sheet stays open.
   - **Keep editing**: send another instruction; it edits the current proposal, not the
     original, so edits chain. The preview keeps highlighting relative to the last applied
     (or original) plan.
   - **Discard**: drops the proposal; the preview returns to the last applied (or original)
     plan and the next instruction edits that.
7. On failure the status strip shows the error (`ai-edit-error`) with the copy from the
   service spec; the preview is unchanged. The input is re-enabled except for
   `quotaExhausted` and `subscriptionRequired`, which disable it until the sheet is reopened.
8. Earlier turns stay reachable through **History** (`ai-edit-history`), a read-only list of
   the transcript (`ai-edit-message-{index}`).
9. Closing the sheet (`ai-edit-close`) with an unapplied proposal asks "Discard the
   unapplied edit?" (Discard / Keep editing).

## Engine-specific notes

- **Apple Private Cloud Compute**: when Apple reports the quota is near its limit the status
  caption shows "Nearing Apple's daily limit". When the limit is reached and Apple offers a limit
  increase, a **Show options** button (`ai-edit-quota-options`) presents Apple's sheet.
- **LiftMark cloud**: the quota label reads "N of M left today"; while in grace it reads
  "Over today's limit · N extra left"; at the ceiling the error copy includes the reset time.
- **Apple on-device**: reachable only via the developer override. Long plans fail fast with
  "This plan is too long for the selected AI engine."

## Developer override flow

1. Enable developer mode (7 taps on the version row), enable `aiPlanEditing`.
2. The **AI engine** picker appears under the flag. Choose an engine.
3. Open any plan's Edit with AI sheet: the engine label shows the forced engine and the
   availability error, if any, is shown instead of silently falling through.
