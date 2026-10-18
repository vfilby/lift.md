# AI Plan Editing Service Specification

## Purpose

Let a signed-in Pro user change an existing workout plan by describing the change in plain
language ("swap bench for dumbbell press", "I only have 30 minutes"). An LLM produces a
revised LMWF document; the app shows the user an exercise-level diff; the user applies or
discards it. The model never writes to the database. Applying goes through the same
`updatePlanMarkdown` path as the manual markdown editor, so sync, export, and history all
behave exactly as for a hand edit.

The plan behind this spec is `docs/LLM_PLAN_EDITING_AND_TIERS.md`. This document is the
contract for the first two implementation phases: the iOS engine abstraction with the Apple
engines, and the server-fronted cloud engine.

## Scope and non-goals

- ✅ Edit an existing plan from the Workout Detail screen via a sheet that previews the plan
  live and takes instructions underneath.
- ✅ Three interchangeable engines behind one protocol: Apple Private Cloud Compute, Apple
  on-device, LiftMark cloud (Amazon Bedrock via the getlift.md API).
- ✅ Automatic engine selection with a developer-mode override for device testing.
- ✅ Server-enforced tier gate and daily quota on the cloud engine.
- ❌ Generating a plan from nothing (that is `ai-generation.md`, bring-your-own key).
- ❌ Editing an in-progress session.
- ❌ Server-side conversation storage. Each request is stateless.
- ❌ Billing and StoreKit (Phase 1 of the plan; until it lands, the tier gate uses the
  existing `tier` field from `/v1/me`).

## Gating

The feature is visible only when **all** of:

1. The `aiPlanEditing` developer feature flag is on (see `feature-flags.md`). This gate is
   removed when the feature ships.
2. The plan has non-nil `sourceMarkdown` (same condition as the Edit button).
3. The signed-in user's tier is `pro` or `trial`, **or** the stub engine is active (UI tests).
   A user who is signed out or on `free` sees the same row rendered as an upsell
   (`edit-plan-ai-upsell`) that explains AI editing is part of Pro: signed-out users get a
   "Sign in" action presenting the standard login sheet; signed-in `free` users get an
   informational, non-interactive row until in-app purchase exists (plan doc, Phase 1).
   Server-side, the cloud engine returns 402 for `free` regardless of what the client shows.

## Engines

```swift
enum PlanEditEngineKind: String, CaseIterable, Codable {
    case applePrivateCloud   // FoundationModels PrivateCloudComputeLanguageModel (iOS 27+)
    case appleOnDevice       // FoundationModels SystemLanguageModel (iOS 26+)
    case liftMarkCloud       // POST /v1/ai/plan/edit → Amazon Bedrock
    case stub                // deterministic test double, launch-argument only
}

enum PlanEditEngineAvailability: Equatable {
    case available
    case quotaExhausted(resetAt: Date?)
    case unavailable(reason: String)     // human-readable, shown verbatim in the sheet
}

typealias PlanEditLimitIncreaseAction = @MainActor () -> Void

protocol PlanEditEngine: Sendable {
    var kind: PlanEditEngineKind { get }
    var displayName: String { get }      // "Apple Private Cloud Compute", "Apple on-device", "LiftMark cloud"
    func availability() async -> PlanEditEngineAvailability
    func edit(_ request: PlanEditRequest) async throws -> PlanEditResult
    // Quota affordances so the sheet never imports FoundationModels. Default
    // implementations return false / nil; only the PCC engine overrides them.
    var isApproachingQuotaLimit: Bool { get }
    var limitIncreaseAction: PlanEditLimitIncreaseAction? { get }
}
```

### Request / result

```swift
struct PlanEditTurn: Codable, Equatable { let role: Role; let content: String; enum Role: String, Codable { case user, assistant } }

struct PlanEditContext: Codable, Equatable {
    var units: WeightUnit
    var equipment: [String]              // default gym's equipment names, may be empty
    var recentSessions: String?          // compact history block from WorkoutGenerationService, may be nil
}

struct PlanEditRequest: Equatable {
    let planMarkdown: String             // the current working markdown (see Session)
    let instruction: String
    let history: [PlanEditTurn]          // at most the last 6 turns, oldest first
    let context: PlanEditContext
}

struct PlanEditQuota: Codable, Equatable {
    let limit: Int
    let remaining: Int                   // may be negative while in grace
    let resetAt: Date
    let inGrace: Bool
}

struct PlanEditResult: Equatable {
    let planMarkdown: String             // parses successfully with MarkdownParser
    let summary: String
    let warnings: [String]               // parser warnings for the new markdown
    let engine: PlanEditEngineKind
    let quota: PlanEditQuota?            // cloud engine only
}

enum PlanEditError: Error, Equatable {
    case engineUnavailable(String)
    case quotaExhausted(resetAt: Date?)
    case planTooLarge                    // input would not fit the engine's context budget
    case outputDidNotParse([String])     // after the repair turn
    case subscriptionRequired
    case notSignedIn
    case network
    case model(String)                   // provider error, message is safe to show
    case cancelled
}
```

### Shared behaviour (every engine)

1. **Prompt contract.** System/instructions text is the canonical file
   `spec/data/ai-plan-edit-system-prompt.md` (full) or
   `spec/data/ai-plan-edit-system-prompt-compact.md` (on-device only). Each platform ships a
   verbatim copy (`mobile-apps/ios/LiftMark/Resources/Prompts/`, `validator/src/data/`) and
   has a test that fails if the copy drifts from `spec/data/`.
2. **User message layout**, in this order, each block omitted when empty:

   ```
   # USER CONTEXT
   Units: lbs
   Equipment: barbell, dumbbells, cable
   Recent sessions:
   <compact block>

   # CURRENT PLAN
   <planMarkdown verbatim>

   # CONVERSATION
   user: <turn>
   assistant: <turn>

   # INSTRUCTION
   <instruction>
   ```
3. **Structured output.** Engines request `{ plan_markdown: String, summary: String }` via the
   provider's structured-output mechanism (`@Generable` on Apple, Converse tool use on
   Bedrock). Engines must not scrape code fences; if the model wraps `plan_markdown` in
   fences anyway, strip one outer fence before parsing.
4. **Validate, repair once, then fail.** Parse `plan_markdown` with the platform LMWF parser.
   On failure send exactly one repair turn: the previous output plus the parser error
   messages, asking for a corrected full document. If that also fails, throw
   `.outputDidNotParse(errors)`. Parser **warnings** never trigger a repair; they are
   returned in `PlanEditResult.warnings`.
5. **Empty-change guard.** If the returned markdown equals the input after trimming
   trailing whitespace, the result still succeeds; the sheet shows "No changes were made"
   and disables Apply.
6. **Size limits** on the client before any engine call: `planMarkdown` ≤ 32 KB,
   `instruction` ≤ 2 KB, history ≤ 8 KB total. Over the limit → `.planTooLarge`.

### `ApplePrivateCloudEngine` (`applePrivateCloud`)

- Requires `#available(iOS 27, *)`; on iOS 26 the engine is constructible but reports
  `.unavailable("Apple Private Cloud Compute requires iOS 27.")`. The implementation is
  also wrapped in `#if canImport(FoundationModels, _version: 2.0)` (the iOS 27 SDK's module
  version): a build made with an older SDK compiles a stand-in that always reports
  `.unavailable("Apple Private Cloud Compute needs a build made with the iOS 27 SDK.")`, so
  CI on Xcode 26 and local Xcode 27 builds share one source tree. GitHub's macOS runners do
  not yet ship Xcode 27; until they do, TestFlight builds from CI cannot use PCC. `availability()` maps
  `PrivateCloudComputeLanguageModel.availability`: `.available` → `.available`;
  `.unavailable(reason)` → `.unavailable` with a reason string per case. The iOS 27 SDK
  defines only `deviceNotEligible` and `systemNotReady` for PCC (the "Apple Intelligence not
  enabled" and "model not ready" cases exist on the on-device model only); unknown future
  cases map to a generic "unavailable" string. If `quotaUsage.isLimitReached` →
  `.quotaExhausted(resetAt: quotaUsage.resetDate)`.
- One `LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions:)` per
  `edit` call (stateless; the repair turn reuses the same session so the model sees its own
  prior output).
- `respond(to:generating: PlanEditResponse.self, options:, contextOptions:)` with
  `ContextOptions(reasoningLevel: .light)` and `GenerationOptions(maximumResponseTokens: 4000)`.
- Error mapping: context-size errors → `.planTooLarge`; rate limiting → `.quotaExhausted`;
  guardrail violation / unsupported locale → `.model(message)`; cancellation → `.cancelled`.
- Quota UI: when `quotaUsage.status` is `.belowLimit` and `isApproachingLimit`, the sheet
  shows "Nearing Apple's daily limit"; when a `limitIncreaseSuggestion` exists after
  `.quotaExhausted`, the sheet offers a "Show options" button that calls `suggestion.show()`.

### `AppleOnDeviceEngine` (`appleOnDevice`)

- Requires iOS 26 (`SystemLanguageModel.default`). Availability mapping as above (no quota).
- Uses the **compact** prompt. Before calling, computes
  `tokenCount(for: instructions) + tokenCount(for: prompt) + 1200` and compares to the
  model's `contextSize`; if it does not fit → `.planTooLarge` without calling the model.
  (1200 is the reserved output budget; on-device plans must be short.) `tokenCount(for:)`
  and `contextSize` are iOS 26.4 APIs; on 26.0–26.3 the engine estimates tokens as
  UTF-8 bytes / 4 against a 4096 context.
- Same structured output, validate, and repair behaviour. `maximumResponseTokens` = 1200.
- Offline capable. No quota.

### `LiftMarkCloudEngine` (`liftMarkCloud`)

- Requires a signed-in session (`AuthenticationStore.isAuthenticated`), otherwise
  `.unavailable("Sign in to use LiftMark cloud")` and `edit` throws `.notSignedIn`.
- `edit` calls `POST /v1/ai/plan/edit` through `authStore.withAuthorizedRequest` (same
  pattern as `InboxPollerService`), body = the request above in snake_case JSON.
- Response mapping: 200 → `PlanEditResult` (the server already validated the markdown, the
  client parses it again anyway to populate the diff); 402 → `.subscriptionRequired`;
  429 → `.quotaExhausted(resetAt: nil)` — `APIError.server` carries only the error message,
  not the 429 body, so the sheet falls back to the `reset_at` of the last cached
  `PlanEditQuota` for its copy; 413 → `.planTooLarge`; 422 → `.outputDidNotParse`;
  5xx/504 → `.model(message)`; transport failure → `.network`.
- `availability()` is `.available` whenever signed in; quota state is only known after a
  call, and the last `PlanEditQuota` is cached in the session for the header label.

### `StubPlanEditEngine` (`stub`)

Test double, active only when the app is launched with `--ai-engine-stub`. Deterministic:

- `availability()` → `.available`.
- `edit` appends an exercise `## Face Pull` with sets `- x 15` ×3 to the end of the plan and
  returns summary "Added Face Pull (stub)." If the instruction contains `fail` it throws
  `.model("Stub failure")`; if it contains `quota` it throws `.quotaExhausted(resetAt: nil)`.
- While the stub is active the tier gate is satisfied regardless of auth state.

## Engine selection

`PlanEditEngineSelector.select(override:, isSignedIn:) async -> any PlanEditEngine`:

1. If `--ai-engine-stub` is present → `stub`.
2. If a developer override is set (see below) → that engine, **even if unavailable**; its
   real availability error is surfaced so the developer sees what a user on that path would.
3. Otherwise, first of these whose `availability()` is `.available`:
   `applePrivateCloud` → `liftMarkCloud`.
4. If none is available, the sheet opens in the unavailable state showing the reason from
   the last engine tried (`liftMarkCloud`).

`appleOnDevice` is never auto-selected in this phase; it is reachable only through the
override. (It joins the auto order once the structured plan representation exists; see the
plan doc, Phase 4.)

### Developer override

`AIEngineOverride` is a developer setting, not a `FeatureFlag` (flags are booleans):

```swift
enum AIEngineOverride: String, CaseIterable { case auto, applePrivateCloud, appleOnDevice, liftMarkCloud }
```

- Stored in `UserDefaults` under `feature_flag.aiEngineOverride`, default `auto`, never
  synced, read through `FeatureFlagsStore.engineOverride`.
- Rendered as a `Picker` row (`ai-engine-override-picker`) nested under the `aiPlanEditing`
  flag row in the developer Feature Flags section, visible only while that flag is on.
  Turning the flag off resets the override to `auto`.
- Launch argument `--ai-engine-override=<rawValue>` sets it for UI tests.

## Session (`PlanEditSession`)

`@MainActor @Observable final class PlanEditSession` owns one sheet's state:

| Property | Meaning |
|---|---|
| `planId`, `originalMarkdown` | The plan being edited and its markdown when the sheet opened. |
| `workingMarkdown` | What the next instruction edits. Starts as `originalMarkdown`; becomes the proposal after each successful turn ("keep chatting" chains edits). |
| `appliedMarkdown` | Markdown last persisted via Apply; `nil` until the first Apply. |
| `messages: [PlanEditMessage]` | Transcript: `.user(text)`, `.assistant(summary, diff, warnings)`, `.error(PlanEditError)`. Each carries `isDiscarded`; discarded messages are kept for History but never sent to the engine. |
| `pendingProposal: (markdown, diff)?` | The latest unapplied result, drives the Apply/Discard bar. |
| `engine`, `availability`, `quota` | For the header labels. |
| `isThinking` | True while an `edit` call is in flight; input is disabled. |
| `workingPlan` | `workingMarkdown` parsed (`nil` when it does not parse); feeds the live preview. |

Operations:

- `send(instruction)`: appends the user message, builds the request from `workingMarkdown`
  and the last 6 *live* turns, calls the engine, then either sets `pendingProposal` + `workingMarkdown`
  and appends the assistant message, or appends an error message. Failed turns do not change
  `workingMarkdown`. The proposal's diff is always taken against `appliedMarkdown ??
  originalMarkdown` (what is persisted), not the previous proposal, so a chained edit's
  preview highlights everything Apply would change.
- `apply()`: `planStore.updatePlanMarkdown(id:newMarkdown:)` with the proposal; records
  `appliedMarkdown`; clears `pendingProposal`; the turns since the previous Apply become
  committed. The sheet stays open so the user can keep editing.
- `undo()`: available after an Apply; re-applies the markdown that was persisted before the
  most recent Apply (one level, matching the plan doc's "one-tap undo"). Uses the same store
  path. The turns of the undone Apply (and anything sent since) are marked discarded.
- `discard()`: drops `pendingProposal`, resets `workingMarkdown` to `appliedMarkdown ??
  originalMarkdown`, and marks the turns of the discarded proposal as discarded: the user
  instruction and its assistant reply, plus any chained turns since the last Apply.
- `cancel()`: cancels the in-flight task; the sheet shows "Cancelled" as an error message.

**History sent to the engine (GH #464).** The `history` of a request contains only turns
whose proposal was applied or that belong to the current pending chain. Discarded turns are
excluded, otherwise the `# CONVERSATION` block still says "user: make it shorter / assistant:
Cut sets to 3…" after a Discard and the model re-applies the discarded intent even though
`# CURRENT PLAN` is the reverted markdown. Error turns were never sent. The History sheet
still lists discarded turns, captioned "Discarded", so the user can see why they did not
carry over.

## Diff (`PlanDiffBuilder`)

`PlanDiffBuilder.diff(before: WorkoutPlan, after: WorkoutPlan) -> PlanDiff`

- Exercises are matched by trimmed, case-insensitive name within the same parent (superset
  or section). Unmatched in `before` → `.removed`; unmatched in `after` → `.added`; matched
  with a different set list, notes, equipment type, or rest → `.changed(before:after:)`;
  otherwise `.unchanged`.
- A set list comparison uses the sets' LMWF text rendering so `135 x 5` and `135 lbs x 5`
  under `@units: lbs` compare equal.
- Plan-level changes (name, tags, units, workout notes) are reported as `PlanDiff.headerChanges: [String]`.
- `PlanDiff.isEmpty` is true when every entry is `.unchanged` and there are no header changes.

- Each `PlanDiffExercise` also records its enclosing `section` and whether its immediate
  parent is a superset (`parentKind`), so the sheet can rebuild the plan's section/superset
  structure from the entry list alone. `entries` is ordered like the *after* plan with removed
  exercises flushed at the position they used to occupy.

The sheet renders the diff *inline in the plan preview* (`PlanEditPreview`, built from
`PlanDiff.entries`): every exercise is a row; added rows are success-tinted with a `+`
marker, removed rows error-tinted with a `−` marker and struck through, changed rows
warning-tinted with a `~` marker and the previous set lines struck through above the new
ones. Unchanged rows render without highlighting. With no proposal pending the same preview
is built from `PlanDiffBuilder.unchangedEntries(of:)` for the working plan.

## Cloud API

`POST /v1/ai/plan/edit` on the getlift.md API. Session JWT or PAT with scope `ai:edit`.

### Request

```jsonc
{
  "plan_markdown": "# Push Day\n...",              // required, ≤ 32 768 bytes
  "instruction": "swap bench for dumbbell press",   // required, ≤ 2 048 bytes
  "history": [ { "role": "user", "content": "..." }, { "role": "assistant", "content": "..." } ], // optional, ≤ 6 turns, ≤ 8 192 bytes total
  "context": {                                      // optional
    "units": "lbs",                                 // "lbs" | "kg"
    "equipment": ["barbell", "dumbbells"],          // ≤ 50 strings, each ≤ 64 bytes
    "recent_sessions": "..."                        // ≤ 8 192 bytes
  }
}
```

### Responses

| Status | Body | When |
|---|---|---|
| 200 | `{ plan_markdown, summary, warnings: [string], attempts: 1 \| 2, quota: { limit, remaining, reset_at, in_grace }, model: string, usage: { input_tokens, output_tokens } }` | Success. `plan_markdown` has passed `parseWorkout()`. `attempts` is 2 when the repair turn was needed; `usage` sums both turns. |
| 400 | `{ error }` | Missing/invalid fields, bad JSON. |
| 401 | `{ error }` | No/invalid auth (from `auth` middleware). |
| 402 | `{ error: "Subscription required", upgrade_url }` | `tier === 'free'`. Same shape as `/v1/tokens`. |
| 403 | `{ error }` | PAT without `ai:edit` scope. |
| 413 | `{ error }` | Any size limit exceeded. |
| 422 | `{ error: "Model output did not parse", attempts: 2, parse_errors: [string] }` | Validate + repair both failed. Quota **not** consumed. |
| 429 | `{ error: "Daily AI limit reached", quota: {...} }` | Hard ceiling hit. |
| 502 | `{ error }` | Bedrock error (throttled, model unavailable). Quota not consumed. |
| 504 | `{ error }` | Model call exceeded the Lambda budget. Quota not consumed. |

`Retry-After` is set on 429 (seconds until `reset_at`) and 502.

### Quota

- Table `ai_usage`: PK `user_id` (S), SK `day` (S, `YYYY-MM-DD` UTC), attributes `count`
  (N), `ttl` (N, epoch seconds, 7 days after `day`). Added to `tables.ts` so CDK and DDB
  Local create it.
- `limit` = `entitlements.ai_daily_limit` if present, else `AI_DAILY_LIMIT` env (default
  **20**). `ceiling = ceil(limit * 1.1)` (22 for the default).
- Reserve before calling the model: `UpdateItem ADD count 1` with
  `ConditionExpression: attribute_not_exists(count) OR count < :ceiling`. Conditional
  failure → 429 with `remaining: 0`, no model call.
- Release on terminal failure (422, 502, 504): `UpdateItem ADD count -1`. Best effort; a
  failed release is logged, never surfaced.
- Response `quota.remaining = limit - count` (negative while in grace),
  `in_grace = count > limit`, `reset_at` = next 00:00 UTC.
- `trial` users share the same limit as `pro`.

### Server implementation

- Separate Lambda **`ai-fn`** (same bundle source, entry `src/handler-ai.ts`, Hono app in
  `src/ai-app.ts` mounting only `/v1/ai/*` plus `/version`), 512 MB, **29 s** timeout. API
  Gateway routes `/v1/ai/{proxy+}` to it; everything else stays on the validator function
  with its 10 s timeout and alarms. Its own log group, error alarm, and p95 alarm (threshold
  20 s).
- IAM: `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` on the configured
  model ARN and its cross-region inference profile. Env: `AI_MODEL_ID` (default
  `us.amazon.nova-2-lite-v1:0`), `AI_DAILY_LIMIT`, `AI_MAX_OUTPUT_TOKENS` (default 4000),
  `AI_MODEL_TIMEOUT_MS` (default 24000).
- `src/infra/bedrock.ts` wraps `@aws-sdk/client-bedrock-runtime` `ConverseCommand`:
  system = full prompt file with a `cachePoint` block after it; `toolConfig` with one tool
  `submit_plan_edit` whose input schema is `{ plan_markdown: string, summary: string }` and
  `toolChoice: { tool: { name: "submit_plan_edit" } }`; `inferenceConfig.maxTokens` from env,
  `temperature: 0.2`. The client is injected so tests use a fake.
- Route flow: auth → tier check → body validation → quota reserve → build messages → model
  call → extract tool input → `parseWorkout()` → on error one repair turn (assistant tool
  use + tool result with the errors, asking for a corrected document) → on second failure
  release quota, 422 → audit `ai_plan_edit` `{ user_id, model, input_tokens, output_tokens,
  attempts, status }` (never content) → 200.
- PAT scope `ai:edit` is added to `ALLOWED_SCOPES` in `routes/tokens.ts`.
- An AWS Budgets alarm on Bedrock spend is created per environment by CDK; its threshold is
  a CDK context value, not committed (`--context aiBudgetUsd=<usd>`, optional
  `aiBudgetEmail=<address>` for the 80 % actual / 100 % forecast notifications; no budget
  resource is created when `aiBudgetUsd` is absent).
- The validator's prompt copy is refreshed with `make sync-prompt` (run automatically by
  `make bundle`); the Lambda bundle ships it as `dist/data/ai-plan-edit-system-prompt.md`
  and reads it at runtime.
- For local dev and the Vitest suite the main validator app also mounts `/v1/ai` so the
  route is reachable on `npm run dev`; in production only `ai-fn` serves it.

## iOS UI (summary; details in `screens/workout-detail.md`)

- Entry: `edit-plan-ai-button` ("Edit with AI") in the Edit/Reprocess row of Workout Detail.
- Sheet `ai-edit-sheet`: a header caption with engine and quota labels, a scrolling transcript
  (user turns, assistant turns with a compact inline diff, errors, thinking row; discarded
  turns dimmed), and the edit controls beneath it (Apply/Discard bar when a proposal exists
  or Undo after an Apply, always-visible quick-action chips, privacy caption, text field +
  send). Holding an inline diff opens a read-only full preview of that turn's proposed plan
  with the same highlighting (`ai-edit-preview-full`).
- All strings describing engines or quota come from the engine (`displayName`) or the
  `PlanEditQuota`, never hard-coded per engine in the view.

## Errors (user-facing copy)

| `PlanEditError` | Copy |
|---|---|
| `engineUnavailable(reason)` | reason verbatim |
| `quotaExhausted(resetAt)` | "Daily AI limit reached. Resets at {time}." (or without the time) |
| `planTooLarge` | "This plan is too long for the selected AI engine." |
| `outputDidNotParse` | "The AI's edit couldn't be read as a valid plan. Try rephrasing." |
| `subscriptionRequired` | "AI editing is part of LiftMark Pro." |
| `notSignedIn` | "Sign in to use LiftMark cloud." |
| `network` | "Couldn't reach LiftMark. Check your connection." |
| `model(message)` | message verbatim |
| `cancelled` | "Cancelled." |

## Privacy

Plan markdown, the instruction, equipment names, and the compact recent-session block are
sent to the selected engine. Apple engines: processed on device or on Apple's Private Cloud
Compute, not stored. LiftMark cloud: processed by Amazon Bedrock in our AWS account, not
stored or used for training; the server logs token counts only. The sheet shows a one-line
caption naming the active engine under the quick-action chips. It gains a link to the
privacy policy once a privacy page exists (none does today).

## Testing

### iOS unit (`LiftMarkTests`)

- `PlanEditEngineSelectorTests`: stub wins; override forces an unavailable engine; auto
  order PCC → cloud; none available → last reason.
- `PlanDiffBuilderTests`: added / removed / changed / unchanged; superset-scoped matching;
  unit-normalised set equality; header changes; `isEmpty`.
- `PlanEditSessionTests` with a `FakePlanEditEngine`: send success chains `workingMarkdown`;
  send failure leaves it; apply persists through a fake `WorkoutPlanStore`; undo restores;
  discard resets; history is capped at 6 turns; cancel; discard then send: engine request
  history omits the discarded turns and `planMarkdown` is the reverted plan; undo then send:
  history omits the undone turns; apply then send: history still includes the applied turns;
  an assistant turn records the proposed markdown it describes.
- `PlanEditPromptTests`: user-message layout snapshot; bundled prompt files equal
  `spec/data/*.md` (read via `#filePath`).
- `LiftMarkCloudEngineTests` with a fake `APIClientProtocol`: status → error mapping, quota
  decode, not-signed-in.
- `StubPlanEditEngineTests`: deterministic output, `fail`, `quota`.
- `PlanEditPresentationTests`: tier gate, quota captions, chip slugs, preview row slugs,
  markers and parents, the "N exercises unchanged" caption, the inline diff
  (`PlanEditInlineDiff`: changed rows only in diff order, unchanged count, header changes,
  `isEmpty`), which transcript row carries `ai-edit-diff` (`latestAssistantIndex`), and
  `PlanEditPreview` building — section/superset grouping from entries, removed rows kept in
  place, the full preview built from an assistant turn's proposed markdown (nil for other
  turns or unparseable markdown).

### iOS E2E (`e2e-spec/scenarios/ai-plan-edit.yaml`)

Launch with `--enable-flag=workoutInbox --enable-flag=aiPlanEditing --ai-engine-stub`.
Import a plan, open detail, tap `edit-plan-ai-button`, type "add face pulls" into
`ai-edit-input`, tap `ai-edit-send`, wait for `ai-edit-apply`, assert the inline diff shows
"Face Pull" as an added row (`ai-edit-diff-row-added-face-pull`), long-press `ai-edit-diff`,
wait for `ai-edit-preview-full`, assert an unchanged row of the fixture is listed
(`ai-edit-preview-row-bench-press`), tap `ai-edit-preview-done`, assert the full preview is
gone, tap Apply, close the sheet, assert the detail view now lists "Face Pull". Second test:
instruction "fail" shows `ai-edit-error`.

### Validator (`validator/tests/ai.test.ts`, Vitest)

With a fake Bedrock client and DDB Local:

- 401 without auth; 402 for `free`; 403 for PAT without `ai:edit`.
- 400/413 body validation.
- Happy path returns parsed markdown, quota decrements, audit entry recorded without content.
- Repair turn: first output invalid, second valid → 200 with `attempts: 2`.
- Both invalid → 422 and quota released.
- Ceiling: 23rd request in a day → 429 with `Retry-After`; 21st and 22nd succeed with `in_grace`.
- Per-user `ai_daily_limit` override respected.
- Bedrock throttling → 502, quota released.
- Prompt drift: `src/data/ai-plan-edit-system-prompt.md` equals `spec/data/`.

### Beta smoke

`smoke-beta` gains one live call with a three-line plan and the instruction "add one
warm-up set", asserting 200 and that the response parses. Skipped when `AI_SMOKE=0`.
