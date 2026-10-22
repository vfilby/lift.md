# Plan: LLM plan editing + user tiers

Status: **agreed plan** (decisions recorded in [Decisions](#decisions) at the end).
Date: 2026-10-16.

User story: *As a signed-in user I want to interact with a workout plan to change it,
tweak it, etc. using an LLM.*

This document covers the tier model that gates the feature, the billing/entitlement
plumbing, where the model runs (Apple on-device / Private Cloud Compute vs. Amazon Bedrock),
and the editing feature itself (backend + iOS). Once the decisions are made,
each phase below turns into spec changes in `spec/` (this repo is spec-first) and then
implementation.

**TL;DR:** build one `PlanEditEngine` abstraction with two engines: Apple's
Private Cloud Compute model (free to us, iOS 27, Apple Intelligence devices) as the primary,
and Amazon Nova 2 Lite via our getlift.md backend as the fallback for everyone else. Gate
the feature on a Pro tier.

---

## 1. What already exists

The repo is further along than a from-scratch plan would assume. The design below reuses
all of it.

| Area | State today | Where |
|---|---|---|
| Accounts | Email/password accounts on getlift.md, 1 h access JWT + 1 y rotating refresh token | `validator/src/routes/auth/*`, `spec/services/authentication.md` |
| Tier | `UserTier = 'pro' \| 'trial' \| 'free'` on the user row. New users default to `trial` with `trial_ends_at = +30 d`. **`trial_ends_at` is never enforced** (nothing downgrades an expired trial). | `validator/src/repositories/users.ts` |
| Tier enforcement | Free users get **402** on PAT routes and on `POST /v1/tokens`; trial users capped at N active tokens. iOS shows tier in Settings only. | `validator/src/middleware/pat.ts`, `routes/tokens.ts`, `SettingsAccountSection.swift` |
| Entitlements table | `entitlements` DynamoDB table exists (PK `user_id`, GSI on `stripe_subscription_id`) but has **no repository and no writers**. | `validator/src/infra/tables.ts` |
| Billing | None. No StoreKit, no Stripe code. | — |
| CloudKit sync | Shipped, **on by default for every user**, user's own iCloud private DB, no infrastructure of ours involved. | `CKSyncEngineManager.swift`, `spec/services/cloudkit-sync.md` |
| Server sync | Inbox (agent → server → iOS plans) and outbox (iOS → server → agent, last 20 sessions). Behind the dev flag `workoutInbox`. Not a general sync layer. | `spec/services/workout-inbox.md`, `workout-outbox.md` |
| Plan storage | Raw LMWF markdown is stored per plan (`workout_plans.source_markdown`) and synced. In-app raw markdown editor with live parse validation; per-exercise structured editor that splices one block back into the source. **No full model → markdown serializer.** | `EditPlanMarkdownSheet.swift`, `LMWFSourceEditor.swift`, `WorkoutPlanStore.updatePlanMarkdown` |
| AI today | Generation only, with the **user's own key** (BYOK: Anthropic, OpenAI, Gemini, or self-hosted Ollama, as an ordered fallback list) or "Open in Claude" via clipboard. No editing. | `spec/services/ai-generation.md`, `spec/services/ai-providers.md`, `AIProviderService.swift` |
| Backend | Hono on Lambda (Node 22, 256 MB, **10 s timeout**) behind API Gateway HTTP API + CloudFront, **us-west-2**, CDK. The LMWF parser (`parseWorkout`) is a pure in-process function already used to validate inbox pushes. | `validator/src/app.ts`, `validator/cdk/stack.ts`, `validator/src/parser/index.ts` |
| iOS target | Deployment target **iOS 26.0**, so the Foundation Models framework is available; the PCC model needs `#available(iOS 27, *)`. | `mobile-apps/ios/project.yml` |
| Dev feature flags | Per-device, developer-mode-only toggles (`workoutInbox`, `useBetaApi`). | `spec/services/feature-flags.md` |

---

## 2. Tier model

### Proposed tiers

| | Free | Tier A ("Sync") | Tier B ("Pro") |
|---|---|---|---|
| Local app, HealthKit, Live Activities, import/export | ✅ | ✅ | ✅ |
| CloudKit (iCloud) sync | ✅ | ✅ | ✅ |
| getlift.md server sync for third-party agents: inbox/outbox, PATs, future self-hosted sync server | ❌ | ✅ | ✅ |
| Bring-your-own Anthropic key generation (existing) | ✅ (keep) | ✅ | ✅ |
| LLM plan editing (Apple PCC / on-device / Nova, our key) | ❌ | ❌ | ✅ 20 / day + 10 % grace on the Nova path |
| Trial | 30 days of Tier B on signup (already the default) | | |
| Working name | Free | **Sync** | **Pro** |

Names are placeholders and can change freely while the feature is behind the beta flag.
Prices are configured in App Store Connect and are not recorded in this repo.

Mapping onto the existing enum: rename `pro | trial | free` to **`free | sync | pro`** plus
a separate `trial_ends_at`-driven *effective tier*. A trial user's effective tier is `pro`
until `trial_ends_at`, then `free`. The server computes `effective_tier` once in the auth
middleware and every gate reads that, so "trial" stops being a tier and becomes a state.

### What "cloud sync" means

CloudKit sync is already live for everyone, is the user's own iCloud quota, and runs on no
infrastructure of ours, so it stays free. Tier A's "cloud sync" is the **getlift.md server-side path that
lets third-party agents get data in and out**: inbox/outbox, agent PATs, and the future
full server sync that could later be self-hosted. This is exactly what the 402-on-free
gates already protect.

### Limit semantics (20 / day, 10 % grace, then hard stop)

Applies to the **Nova (metered) path** only; Apple's PCC path has Apple's own per-user
quota and the on-device path is unlimited.

- Counter is per user per **UTC day**, stored in DynamoDB, incremented atomically with a
  conditional write. Reset at 00:00 UTC (shown in the UI in local time).
- Default limit 20, overridable per user via an `ai_daily_limit` attribute on the
  entitlement row (ops/support escape hatch, and how we'd run a higher-limit tier later).
- **Grace:** the hard ceiling is `ceil(limit × 1.1)` = **22** for the default. Requests 21
  and 22 succeed but the response carries `quota.in_grace: true` and the UI shows "Over
  today's limit, 1 extra request left". Request 23 gets `429` with `reset_at`. There is no
  overage billing; the ceiling exists to stop abuse.
- The client is told remaining quota on every response and starts showing it at ≤ 5 remaining.
- Failed requests (model error, parse failure after retries) **do not** consume quota.

---

## 3. Billing and entitlements

### Constraint: Apple in-app purchase

Tier A/B unlock features used **inside the iOS app**, so App Store Review guideline 3.1.1
requires those to be purchasable via StoreKit in-app purchase. Web (Stripe) purchase is
allowed in addition (3.1.3(b) multiplatform), but the app can't steer users to it outside
the US. The existing `stripe_subscription_id` GSI suggests Stripe was the original idea;
it can stay for web signups, but **StoreKit 2 is the required path** for the app.

### Design

- **Source of truth:** the `entitlements` DynamoDB row per user:
  `{ user_id, tier: 'sync'|'pro', source: 'app_store'|'stripe'|'manual', product_id,
  original_transaction_id | stripe_subscription_id, expires_at, status, ai_daily_limit?,
  updated_at }`. Add a GSI on `original_transaction_id`.
- **StoreKit 2 (iOS):** two auto-renewable subscriptions in one group (Sync, Pro; monthly
  + annual). After purchase/restore the app `POST /v1/entitlements/app-store` with the
  signed transaction JWS; the server verifies it (App Store Server API / `app-store-server-library`),
  upserts the entitlement row, and sets `user.tier`. The server also subscribes to **App
  Store Server Notifications V2** (renewal, expiry, refund, grace period) at
  `POST /v1/webhooks/app-store` so tier changes don't depend on the app running.
- **Stripe (web, optional, later):** Checkout + webhook → same entitlement row.
- **Trial expiry:** a daily scheduled Lambda (EventBridge) downgrades users whose
  `trial_ends_at < now` and have no active entitlement. Cheap and fixes the existing gap.
- **`/v1/me`** gains `effective_tier`, `entitlement: { source, expires_at }`, and
  `ai_quota: { limit, used_today, reset_at }`. iOS `AuthenticatedUser` mirrors this and
  the existing profile persistence rule (real profile beats JWT-claims fallback) still applies.
- **iOS gating:** an `EntitlementsStore` (or a computed property on `AuthenticationStore`)
  exposes `can(.aiEditing)`, `can(.serverSync)`. Gated surfaces render an upsell row instead
  of the feature. Server remains the enforcement point for the metered Nova path; the
  client gate is UX (and the only gate for the Apple-hosted engines).
- **Dev flag:** `aiPlanEditing` added to `FeatureFlag` (child of `workoutInbox` since the
  fallback engine needs the account API) so the feature can merge dark.

---

## 4. Where to run the model

Four realistic options. The app's iOS 26 floor makes the Apple ones available today.

| Option | Quality / fit | Reach | Offline | Main risk |
|---|---|---|---|---|
| **A. Apple on-device** (`SystemLanguageModel`, iOS 26+) | ~3 B model (iOS 27: AFM 3 Core / Core Advanced). Fine for simple edits (swap, shorten, add warm-up). **4 K token context** (8 K on newer devices under iOS 27, read `contextSize` at runtime) — far too small to put the LMWF spec in the prompt, so it must work on a compact structured representation via `@Generable` guided generation, not markdown. | Apple Intelligence devices only: iPhone 15 Pro and later, M-series iPad; AI enabled; supported locales. | ✅ | Quality ceiling on multi-constraint rewrites; context budget. |
| **B. Apple Private Cloud Compute** (`PrivateCloudComputeLanguageModel`, **iOS 27**) | Much larger model, **32 K context**, light/moderate/deep reasoning, same `@Generable` + tools API as on-device. Good enough to send the full plan plus a condensed spec. | Same device class as A, iOS 27+, internet required. Per-user **daily quota counted against the user's iCloud account**, raiseable with iCloud+. | ❌ | **Eligibility**: developers with < 2 M lifetime first-time downloads across all apps, by application (fine for us today). Apple's quota number isn't published; Apple could change terms. |
| **C. Cloud via our backend** (Amazon Bedrock, Nova) | Full control of model, prompt, validation; works for any device; stateless proxy. | Every signed-in user. | ❌ | Latency budget (API Gateway 30 s cap); metered usage, so it needs the quota. |
| **D. Bundled open model** (MLX / llama.cpp, 1–4 B Qwen/Gemma/Llama) | Comparable to A at best; 2–4 GB download; battery/thermal; we own the runtime. | Any device with enough RAM, including pre-Apple-Intelligence ones. | ✅ | Not worth it while A exists; only reconsider if non-AI-device reach matters more than the download size. |

Also worth knowing: iOS 27's `LanguageModel` protocol lets third-party providers (e.g.
Anthropic's Claude package) plug into the same session API. That's a nice *client*
abstraction but it still needs an API key, so it doesn't remove the need for a proxy; it
would just let the fallback engine use the same Swift surface as A/B.

### Decided: hybrid, Apple-first, server-fronted Bedrock

Introduce a `PlanEditEngine` protocol on iOS with a single contract:

```swift
protocol PlanEditEngine {
    var availability: EngineAvailability { get }   // .available, .quotaExhausted(resetHint), .unavailable(reason)
    func edit(_ request: PlanEditRequest) async throws -> PlanEditResult   // revised LMWF markdown + summary
}
```

Engine selection, in order (mode `auto`):

1. **`ApplePCCEngine`** when `#available(iOS 27)`, `PrivateCloudComputeLanguageModel().isAvailable`, and quota not reached.
2. **`CloudNovaEngine`** (our backend) otherwise — older devices, non-AI devices, pre-iOS 27,
   PCC quota exhausted, unsupported locale. The server is the only path to Bedrock, so every
   gate (tier, quota, size limits, model choice, kill switch) lives there.
3. **`AppleOnDeviceEngine`** is *optional* in v1: it only earns its place for offline use and
   for cheap "chip" edits. Ship it in Phase 4 once the structured representation exists.

**Developer engine override.** Settings → Feature Flags (developer mode only) gets an
`aiEngineOverride` picker: *Auto / Apple Private Cloud Compute / Apple on-device / LiftMark
cloud*. It forces that engine regardless of availability ranking so each one can be
exercised on a real device; an unavailable forced engine surfaces its real error rather
than falling through. Stored per device like other flags, never synced, hidden outside
developer mode. The Edit with AI sheet shows the active engine name while an override is set.

Why this order: B and C both produce full-quality edits; B is Apple-hosted with Apple's own
per-user quota, so it should absorb most traffic. The on-device model is
the weakest of the three and needs the most new code (structured representation + a
model → markdown serializer the app doesn't have yet), so it shouldn't block v1.

Why the structured path still matters: both Apple engines use guided generation, so the
plan has to round-trip `WorkoutPlan` ↔ markdown. The PCC engine has enough context to accept
markdown in and return markdown out (validated with the existing `MarkdownParser`), so v1 can
start that way and move to structured output when A arrives.

**Tier implication:** the feature is **Pro-only across all engines**: one simple story
("Pro = AI editing") and no "why does my friend's phone get it free" support load.

**Action now:** apply for PCC access on the Apple developer site. It's gated by application
and we don't know the turnaround.

---

## 5. LLM plan editing feature

### User experience (iOS)

- Entry point: **"Edit with AI"** button on the Workout Detail screen (next to the existing
  markdown/exercise editors). Free/Sync users see the same row as an upsell.
- A sheet with a chat-style transcript scoped to **this plan**. First screen offers quick
  chips: *Make it shorter*, *Swap barbell → dumbbell*, *Add a warm-up*, *Progress loads
  +2.5 %*, *I only have 30 min*, plus a free-text field.
- Each turn returns a **revised plan + one-paragraph summary**. The app shows a before/after
  diff (exercise-level: added / removed / changed sets) and **Apply** / **Keep chatting** /
  **Discard**. Apply goes through the existing `updatePlanMarkdown` path, so CloudKit sync,
  exports and everything else just work. Previous markdown is kept in the sheet for a
  one-tap undo.
- Engine indicator is subtle ("On Apple Private Cloud Compute" / "On LiftMark cloud"); quota
  UI differs per engine: Apple's `quotaUsage` for PCC (with Apple's iCloud+ suggestion
  sheet), our `14 of 20 left today` for Nova.
- Nothing is applied automatically. The model never writes to the DB; the user does.

### Shared prompt contract (all engines)

- System/instructions: coach persona + editing rules ("preserve everything the user didn't
  ask to change", "keep units", "never invent history") + condensed LMWF spec + 2–3
  few-shot edits (~5 k tokens). PCC and Nova get the same text; the on-device engine gets a
  ~800-token version plus a `@Generable` schema instead of the spec.
- Dynamic input: compact context (units, equipment, recent-session summary — the block
  `WorkoutGenerationService` already builds), the plan, last ≤ 6 turns, the instruction.
- Output: `{ plan_markdown, summary }`. Every engine's output is parsed with the
  platform parser; on failure one repair turn with the parser errors, then an error.
- Keep the prompt text in one place (`spec/services/ai-plan-editing.md` is the contract;
  the Swift and TS copies are snapshot-tested against it).

### Cloud engine API (`CloudNovaEngine`)

`POST /v1/ai/plan/edit` (session JWT or PAT with a new `ai:edit` scope; effective tier `pro`)

```jsonc
// request
{
  "plan_markdown": "# Push Day\n...",              // ≤ 32 KB
  "instruction": "swap bench for dumbbell press",   // ≤ 2 KB
  "history": [ { "role": "user"|"assistant", "content": "..." } ], // last ≤ 6 turns, ≤ 8 KB
  "context": { "units": "lbs", "equipment": [...], "recent_sessions": "..." } // optional
}
// response 200
{
  "plan_markdown": "# Push Day\n...",   // validated by parseWorkout() server-side
  "summary": "Replaced bench press with dumbbell press, kept the 5x5 scheme.",
  "warnings": [...],
  "quota": { "limit": 20, "remaining": 13, "reset_at": "2026-10-17T00:00:00Z" },
  "model": "amazon.nova-2-lite-v1:0",
  "usage": { "input_tokens": 7412, "output_tokens": 1388 }
}
// 429 { error, quota }  402 { error, upgrade_url }  422 { error: "model output did not parse", attempts: 2 }
```

Stateless server: the client resends the plan and the short history each turn. No
conversation storage, no PII at rest beyond the existing audit log (which records
`ai_plan_edit` with token counts, never content).

### Backend implementation

- New Hono route module `validator/src/routes/ai.ts`; new `validator/src/infra/bedrock.ts`
  using `@aws-sdk/client-bedrock-runtime` **Converse API** (model-agnostic, supports
  system prompt caching and structured tool output). Output requested via a tool/JSON
  schema `{ plan_markdown, summary }` so we don't scrape fences.
- **Prompt caching:** the ~5 k-token system prefix is identical for every call → mark it as
  a cache checkpoint.
- **Validate → retry:** `parseWorkout()` on `plan_markdown`; on errors one repair turn with
  the parser messages; second failure → 422 and no quota consumed.
- **Quota:** `ai_usage` table `{ user_id, day: 'YYYY-MM-DD', count, ttl }`;
  `UpdateItem ADD count 1 WITH ConditionExpression count < :limit`. Conditional failure → 429.
  Decrement on terminal failure.
- **Latency budget:** API Gateway HTTP API caps integration time at **30 s**. Put the AI
  route on a **separate Lambda** (`ai-fn`, 512 MB, 29 s timeout) so the main API keeps its
  10 s timeout and alarms. Nova 2 Lite **without extended thinking**, `maxTokens` 2 000.
  Expected p50 ≈ 6–10 s, p95 ≈ 15–20 s for a ~1.5 k-token plan. If p95 creeps past ~22 s,
  Phase 4 moves to an async job (`POST` returns `job_id`, client polls); the client
  contract above is designed so that swap is additive.
- **Model access/IAM:** `bedrock:InvokeModel` on the `ai-fn` role; enable Nova in both the
  beta and prod accounts (us-west-2; use the `us.`/`global.` cross-region inference profile
  IDs for capacity). Model ID is a Lambda env var so it can change without an app release.
- **Abuse guards:** body size limits above; per-user quota; API Gateway stage throttle
  already exists; optional WAF rate rule on `/v1/ai/*` later. Bedrock Guardrails are
  **not** needed for v1 (output is machine-validated LMWF).
- **Privacy:** Bedrock does not retain or train on inputs; Apple PCC is independently
  verified not to store requests. Add both to the privacy policy and the App Store privacy
  labels ("fitness data sent to our server / Apple for AI features").

### Model choice for the cloud engine

| Model | Why / why not |
|---|---|
| **Nova 2 Lite** (default) | Current-gen instruction following and tool use, 1 M context, prompt caching, fast. Best quality-per-dollar for "edit this structured doc". |
| Nova Lite (v1) / Nova Micro | Smaller models. Worth A/B-ing for trivial chip edits; likely too weak for multi-constraint rewrites. Keep as a configurable fallback. |
| Nova Pro (v1) / Nova 2 Pro | Larger and more expensive; Nova 2 Pro is still preview. Only if Lite quality is unacceptable. |
| Claude Haiku 4.5 (Bedrock or direct) | The existing generation prompt is already tuned for it. A reasonable quality escape hatch, not the default. |

Decided: **Nova 2 Lite** is the default; the others remain reachable through the model-ID
env var.

---

## 6. Phased plan (each phase = spec change + tests first, then code)

### Phase 0 — Decisions (this doc) + apply for PCC access

### Phase 1 — Entitlements and tiers (ships on its own)

Spec: new `spec/services/entitlements.md`; update `authentication.md` (`/v1/me` shape,
effective tier), `screens/settings.md` (Subscription section), `feature-flags.md`
(`aiPlanEditing` flag and `aiEngineOverride` picker), `data-model.md` (persisted profile
fields).

Server: rename tiers (`free|sync|pro`) with a backfill migration; `entitlements`
repository; `effective_tier` in auth middleware; trial-expiry scheduled job; StoreKit
transaction verify endpoint + App Store notifications webhook; `/v1/me` additions;
replace the existing `tier === 'free'` checks with `effectiveTier < required`.
Tests: unit (effective tier matrix, trial expiry), integration (webhook → tier flip),
e2e-beta (sandbox purchase is manual; simulate via the `__test__` route on beta).

iOS: StoreKit 2 products + purchase/restore UI in Settings; `EntitlementsStore`;
upsell rows; `AuthenticatedUser` fields. Tests: unit for gating, YAML E2E with
`--enable-flag` and a stubbed `/v1/me`.

### Phase 2 — Engine abstraction + Apple PCC engine (behind `aiPlanEditing`)

Spec: new `spec/services/ai-plan-editing.md` (engine contract, selection order, prompt
contract, error table, quota semantics per engine); `screens/workout-detail.md` (Edit with
AI entry + sheet), new `flows/ai-plan-editing.md`, `accessibility-ids.md`.

iOS: `PlanEditEngine` protocol, `ApplePCCEngine` (markdown in/out, parser validation, one
repair turn), `PlanEditSession` store, sheet view with transcript, exercise-level diff,
apply via `updatePlanMarkdown`, undo, Apple quota UI. Tests: unit with a fake engine (diff
builder, apply/undo, selection order, availability states), YAML E2E with a stubbed engine
via launch argument. Xcode's "Simulate Apple Foundation Models Availability" scheme option
covers the quota states manually.

This phase is shippable on its own to iOS 27 Apple Intelligence devices.

### Phase 3 — Cloud Nova engine (fallback for everyone else)

Spec: `ai-plan-editing.md` gains the `/v1/ai/plan/edit` API; `lmwf-validator.md`
architecture section notes the second Lambda.

Server: `ai-fn` Lambda + CDK (IAM for Bedrock, env for model ID), Bedrock client, prompt
assembly, parse-validate-repair loop, `ai_usage` quota with grace ceiling, audit event, CloudWatch alarms
(p95 latency, error rate, daily token volume) and an AWS Budgets alarm on Bedrock in both
accounts. Tests: unit with a fake Bedrock client (prompt-assembly snapshot vs. the spec,
quota exhaustion, repair retry, 422 path); integration against DynamoDB Local; one live
smoke test on beta behind the existing `smoke-beta` job using a tiny plan.

iOS: `CloudNovaEngine` over `APIClientProtocol`; our quota UI; engine indicator.

### Phase 4 — Optimisation (as needed)

On-device engine for offline/chip edits (needs `WorkoutPlan → markdown` serializer and a
`@Generable` plan schema); partial-output mode (changed blocks only, spliced via
`LMWFSourceEditor`) to shrink Nova output; async job mode if p95 latency approaches the 30 s gateway limit; Nova
Micro/Lite routing for trivial chips; Stripe web checkout once accounts and the feature
have been beta tested.

---

## Decisions

Recorded 2026-10-16.

| # | Question | Decision |
|---|---|---|
| 1 | CloudKit gating | CloudKit stays free for everyone. Tier A "cloud sync" = getlift.md server path for third-party agents (inbox/outbox, PATs, future self-hosted sync). |
| 2 | Engine topology | Hybrid, Apple PCC first, Nova fallback. Our server fronts Bedrock so all gates live server-side. |
| 3 | Who gets AI editing | Pro only on every engine. Developer-mode engine override so each engine can be tested on a real device. |
| 4 | Names / prices | Working names Sync and Pro. Prices live in App Store Connect, not in this repo. |
| 5 | Nova quota | 20/day, 10 % grace (hard ceiling 22), then hard stop. |
| 6 | Cloud model | Nova 2 Lite. |
| 7 | BYO Anthropic key generation | Stays available on Free. |
| 8 | Stripe web billing | Later, after accounts and the feature are beta tested. |

## Sources

- WWDC26 session 241, What's new in the Foundation Models framework: https://developer.apple.com/videos/play/wwdc2026/241/
- WWDC26 session 319, Build with the new Apple Foundation Model on Private Cloud Compute: https://developer.apple.com/videos/play/wwdc2026/319/
- PCC eligibility discussion: https://mjtsai.com/blog/2026/06/16/apple-foundation-models-in-appleos-27/
