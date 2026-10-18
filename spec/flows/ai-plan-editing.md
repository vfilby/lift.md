# AI Plan Editing Flow

Service contract: `spec/services/ai-plan-editing.md`. Screen: `spec/screens/workout-detail.md`.

## Preconditions

- `aiPlanEditing` developer flag is on.
- The plan has `sourceMarkdown`.
- The user is signed in with tier `pro` or `trial` (or the stub engine is active).

## Flow

1. User opens a plan and taps **Edit with AI** (`edit-plan-ai-button`).
2. The sheet opens as a conversation: an empty transcript with the opening hint above the
   edit controls (chips + composer). `PlanEditEngineSelector` picks an engine (stub →
   override → Apple Private Cloud Compute → LiftMark cloud). The header caption shows the
   engine's display name (`ai-edit-engine-label`) and, once known, quota
   (`ai-edit-quota-label`).
   - If no engine is available the transcript shows the reason (`ai-edit-error`) and the
     input and chips are disabled. The user can close the sheet.
3. Quick-action chips (`ai-edit-chip-{slug}`) are always visible above the composer:
   *Make it shorter*, *Swap barbell for dumbbells*, *Add a warm-up*, *Progress loads 2.5%*,
   *I only have 30 min*. Tapping a chip sends that instruction.
4. User types an instruction (`ai-edit-input`) and taps send (`ai-edit-send`). The
   instruction appears as a user turn in the transcript.
   - Input and chips are disabled and a thinking row (`ai-edit-thinking`) trails the
     transcript while the call runs. A cancel button (`ai-edit-cancel`) aborts it.
5. On success an assistant turn is appended: the summary and a compact inline diff
   (`ai-edit-diff`; rows `ai-edit-diff-row-{slug}`; unchanged exercises collapsed to a
   count), and the proposal bar appears: **Apply** (`ai-edit-apply`), **Discard**
   (`ai-edit-discard`).
   - If the diff is empty, the turn says "No changes were made" and Apply is disabled.
   - Parser warnings for the new plan are listed under the diff.
6. **Hold the diff** to open the full preview (`ai-edit-preview-full`): the whole proposed
   plan with the same highlighting, unchanged rows included. **Done**
   (`ai-edit-preview-done`) returns to the conversation. Any earlier turn's diff can be
   held the same way (`ai-edit-diff-previous`).
7. The user may:
   - **Apply**: the plan is persisted via `updatePlanMarkdown`. The detail view behind the
     sheet updates. **Undo** (`ai-edit-undo`) takes the proposal bar's place; it restores
     the previously persisted markdown. The sheet stays open and the transcript is kept.
   - **Keep editing**: send another instruction; it edits the current proposal, not the
     original, so edits chain. Each new turn's diff is relative to the last applied (or
     original) plan.
   - **Discard**: drops the proposal; the discarded turns stay in the transcript, dimmed and
     captioned "Discarded", and the next instruction edits the last applied (or original)
     plan.
8. On failure the error is appended to the transcript (`ai-edit-error`) with the copy from
   the service spec. The input is re-enabled except for `quotaExhausted` and
   `subscriptionRequired`, which disable it until the sheet is reopened.
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
