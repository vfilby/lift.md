# Feature Flags Service Specification

## Purpose

Lightweight runtime flag system for gating in-development features. Lets us merge incomplete or experimental UI/services into the main branch without exposing them to general testers until we flip the switch.

These are **developer-facing toggles**, not user-facing preferences. They live in Settings only when developer mode is enabled, default to off, and are not synced across devices.

## Scope and non-goals

- ✅ Toggle features on/off per device.
- ✅ Discoverable list — adding a flag = adding one enum case + one row in Settings.
- ✅ Persisted across launches.
- ❌ Not a remote-config system (no server fetch, no A/B targeting).
- ❌ Not for user-facing preferences — those still belong in `user_settings`.
- ❌ Not synced across devices (deliberate — different devices may be testing different states).

## Flag registry

Defined in `mobile-apps/ios/LiftMark/Models/FeatureFlag.swift` as a String-rawValue enum so each case is its own UserDefaults key. Adding a new flag means:

1. Add a `case` to `FeatureFlag`.
2. Add it to `FeatureFlag.allCases` (automatic via `CaseIterable`).
3. Provide a human-readable `title` and `summary` for the Settings row.
4. Decide its default in `defaultValue` (almost always `false`).

Current flags:

| Flag             | Default | Gates                                                                  |
|------------------|---------|------------------------------------------------------------------------|
| `workoutInbox`   | off     | Home inbox card, Plans Inbox section, `InboxPollerService` networking. |
| `useBetaApi`     | off     | Routes the API base URL to the beta environment instead of prod. Off = prod. **Toggling forces a sign-out** because tokens issued by one env aren't valid in the other. **Child of `workoutInbox`** (see below). |
| `aiPlanEditing`  | off     | "Edit with AI" on Workout Detail and the AI Edit sheet (`spec/services/ai-plan-editing.md`). **Child of `workoutInbox`** — the LiftMark cloud engine needs the account API. Turning it off resets the AI engine override to `auto`. |

## Flag hierarchy (parent/child)

A flag may declare a `parent` (`FeatureFlag.parent`). A child flag only makes sense in the context of its parent:

- It is **hidden** in the Settings list until the parent is enabled, and renders **nested/indented** beneath the parent.
- Disabling the parent **cascades** the child off, running the child's toggle side effects (e.g. `useBetaApi`'s sign-out) so a hidden child can never keep silently affecting behavior.

Current hierarchy:

- `useBetaApi` is a child of `workoutInbox` — the beta environment only serves the account + sync API, which the inbox drives.
- `aiPlanEditing` is a child of `workoutInbox` — its cloud engine talks to the same account API. There's no reason to switch environments unless the inbox is in use.

`FeatureFlag.topLevelCases` are the roots the Settings list iterates; each root's `children` render beneath it.

## Storage

`UserDefaults.standard`, one key per flag: `feature_flag.<rawValue>` (e.g. `feature_flag.workoutInbox`).

- Reads return `defaultValue` when the key is absent.
- Writes invalidate the in-memory `@Observable` store so all observing views recompute.

`FeatureFlagsStore` is a `@MainActor @Observable` exposed via `@Environment`. UI reads via `flags.isEnabled(.workoutInbox)`; writes via `flags.set(.workoutInbox, true)`.

### Special case: `useBetaApi`

Unlike the other flags (which gate UI / poller behavior), `useBetaApi` changes the **HTTP base URL** that `APIClient` talks to. `APIClient` resolves the base URL **per request** by reading `feature_flag.useBetaApi` from UserDefaults — so a flip in Settings takes effect on the next outbound call without restarting the app or rebuilding the client.

Side effect on toggle: every session token (`lmwf_access_jwt`, `lmwf_refresh_token`) and every device-local server-keyed table (`workout_inbox`, `outbox_pending_queue`) was issued/scoped to the *previous* environment. To avoid 401-loops and orphan rows, the Settings row for `useBetaApi` calls `authStore.logout()` immediately after `flags.set(.useBetaApi, ...)`. `logout()` already wipes tokens + inbox + outbox queue.

This is the only flag that's special-cased in the Settings UI; future flags with similar side effects should follow the same pattern (per-flag effect inline at the toggle site, never inside `FeatureFlagsStore` itself).

### Developer setting: AI engine override

`aiPlanEditing` has one companion developer *setting* that is not a boolean flag: `AIEngineOverride` (`auto | applePrivateCloud | appleOnDevice | liftMarkCloud`). It is stored in `UserDefaults` under `feature_flag.aiEngineOverride` (default `auto`), exposed as `FeatureFlagsStore.engineOverride`, and rendered as a `Picker` row (`ai-engine-override-picker`, title "AI engine") nested beneath the `aiPlanEditing` row only while that flag is on. Disabling `aiPlanEditing` resets it to `auto` (side effect at the toggle site, like `useBetaApi`). Launch argument `--ai-engine-override=<rawValue>` sets it for UI tests; `--ai-engine-stub` selects the stub engine regardless of the override. This is the one sanctioned exception to "flags are toggles": it exists purely so each AI engine can be exercised on a real device, and it is removed with the flag.

## Gating pattern

For each gated surface:

- **UI**: wrap in `if flags.isEnabled(.flagName) { ... }`. Use `@Environment(FeatureFlagsStore.self) private var flags`.
- **Services**: early-return from any entry point that initiates work for the flagged feature. Don't gate the service's construction — keeping the service alive simplifies wiring; idle services cost nothing.
- **Persistence wipes** (e.g., logout cleanup): always run, regardless of flag state. Cleanup is cheap and the flag may have been on previously.

## Settings UI

`SettingsView` shows a **Feature Flags** section *only* when `user_settings.developer_mode_enabled` is true. Each flag renders as a single `Toggle` row with title + summary text. Toggling flips the store synchronously.

The section is intentionally minimal — flags are dev affordances, not configuration screens. A flag that grows configuration knobs has outgrown this system and should move to either `user_settings` (if user-facing) or its own settings sub-screen.

## Lifecycle hygiene

When a flag has been on by default in shipped builds for one full release cycle without issues, **remove it** — both the enum case and the gating sites. Flags are temporary; the build accumulates cruft if old flags linger as no-op toggles.

## Testing

UI tests pass `--enable-flag=workoutInbox` (etc.) as a launch argument to force a flag on without poking UserDefaults. The AI engine override is set the same way with `--ai-engine-override=<rawValue>`. `FeatureFlagsStore` reads launch arguments in its initializer, so the override applies before any view evaluates.
