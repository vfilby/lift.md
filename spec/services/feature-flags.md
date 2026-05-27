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
| `useBetaApi`     | off     | Routes the API base URL to `beta.liftmark.app` instead of the default `liftmark.app`. Off = prod. **Toggling forces a sign-out** because tokens issued by one env aren't valid in the other. |

## Storage

`UserDefaults.standard`, one key per flag: `feature_flag.<rawValue>` (e.g. `feature_flag.workoutInbox`).

- Reads return `defaultValue` when the key is absent.
- Writes invalidate the in-memory `@Observable` store so all observing views recompute.

`FeatureFlagsStore` is a `@MainActor @Observable` exposed via `@Environment`. UI reads via `flags.isEnabled(.workoutInbox)`; writes via `flags.set(.workoutInbox, true)`.

### Special case: `useBetaApi`

Unlike the other flags (which gate UI / poller behavior), `useBetaApi` changes the **HTTP base URL** that `APIClient` talks to. `APIClient` resolves the base URL **per request** by reading `feature_flag.useBetaApi` from UserDefaults — so a flip in Settings takes effect on the next outbound call without restarting the app or rebuilding the client.

Side effect on toggle: every session token (`lmwf_access_jwt`, `lmwf_refresh_token`) and every device-local server-keyed table (`workout_inbox`, `outbox_pending_queue`) was issued/scoped to the *previous* environment. To avoid 401-loops and orphan rows, the Settings row for `useBetaApi` calls `authStore.logout()` immediately after `flags.set(.useBetaApi, ...)`. `logout()` already wipes tokens + inbox + outbox queue.

This is the only flag that's special-cased in the Settings UI; future flags with similar side effects should follow the same pattern (per-flag effect inline at the toggle site, never inside `FeatureFlagsStore` itself).

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

UI tests pass `--enable-flag=workoutInbox` (etc.) as a launch argument to force a flag on without poking UserDefaults. `FeatureFlagsStore` reads launch arguments in its initializer, so the override applies before any view evaluates.
