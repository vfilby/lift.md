import SwiftUI

/// Settings section that surfaces the user's LMWF account state and the
/// sign-in / sign-out controls. Drops into `SettingsView`'s Form/List as
/// `Section { SettingsAccountSection() } header: { Text("Account") }`.
///
/// Auth is optional — when not signed in, the section explains *why*
/// you'd sign in (push from Claude Code / ChatGPT) and reassures that
/// the app works offline without it.
///
/// The `LoginView` sheet is deliberately **not** presented from this view.
/// This body is a transparent `Group` that swaps between the signed-in and
/// signed-out branches, so a `.sheet` hung off it attaches to whichever
/// branch is currently rendered; a re-render during launch settling tears
/// that branch down mid-presentation and drops the sheet, forcing a second
/// tap (GH #279 — same instability documented in `AuthSyncBannerView`). The
/// presenter therefore lives in `SettingsView`, whose settings-loaded body
/// is stably mounted across auth re-renders, and the Sign in button flips
/// the `showingLogin` binding it owns. See `spec/screens/settings.md`.
struct SettingsAccountSection: View {
    @Environment(AuthenticationStore.self) private var authStore
    @Environment(InboxPollerService.self) private var inboxPoller
    @Environment(OutboxPusherService.self) private var outboxPusher
    @Environment(FeatureFlagsStore.self) private var featureFlags
    /// Owned by `SettingsView` so the `.sheet` is hosted on a stably-mounted
    /// view (GH #279). Flipped `true` by the Sign in button below.
    @Binding var showingLogin: Bool
    @State private var isSigningOut = false

    var body: some View {
        Group {
            if let user = authStore.currentUser {
                signedInContent(user: user)
                if featureFlags.isEnabled(.workoutInbox) {
                    inboxStatusContent
                }
            } else {
                signedOutContent
            }
        }
    }

    // MARK: - Inbox status

    /// Minimal inbox surface inside the Account section. Surfaces poll
    /// freshness, pending backlog (if any), and an explicit "Sync now" so
    /// users have a manual lever when they just pushed a workout from a
    /// third-party tool and don't want to wait for a foreground transition.
    @ViewBuilder
    private var inboxStatusContent: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
            HStack {
                Text("Last synced")
                    .foregroundStyle(LiftMarkTheme.label)
                Spacer()
                Text(lastSyncedLabel)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .font(.lmSubheadline)
            }
            if inboxPoller.pendingCount > 0 {
                Text("\(inboxPoller.pendingCount) pending")
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
            if let err = inboxPoller.lastError {
                Text(err)
                    .font(.lmCaption)
                    .foregroundStyle(Color.red)
            }
        }
        .accessibilityIdentifier("account-inbox-status")

        Button {
            // A manual "Sync now" must move data in BOTH directions: poll the
            // inbox AND flush the outbox. `force: true` bypasses the per-item
            // retry backoff so completed workouts parked behind `next_attempt_
            // after` push immediately — the backoff timer is an automatic-flush
            // concern, not a manual-sync one. See spec/services/workout-outbox.md.
            Task {
                async let poll: Void = inboxPoller.pollIfAuthenticated()
                async let flush: Void = outboxPusher.flushIfAuthenticated(force: true)
                _ = await (poll, flush)
            }
        } label: {
            HStack {
                Text("Sync now")
                Spacer()
                if inboxPoller.isPolling || outboxPusher.isFlushing {
                    ProgressView()
                }
            }
        }
        .disabled(inboxPoller.isPolling || outboxPusher.isFlushing)
        .accessibilityIdentifier("account-inbox-sync-now")
    }

    private var lastSyncedLabel: String {
        guard let date = inboxPoller.lastSyncedAt else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Signed in

    @ViewBuilder
    private func signedInContent(user: AuthenticatedUser) -> some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
            if !user.displayName.isEmpty {
                Text(user.displayName)
                    .font(.lmBody)
                    .foregroundStyle(LiftMarkTheme.label)
            }
            if !user.email.isEmpty {
                Text(user.email)
                    .font(.lmSubheadline)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
        }
        .accessibilityIdentifier("account-identity")

        HStack {
            Text("Plan")
                .foregroundStyle(LiftMarkTheme.label)
            Spacer()
            tierBadge(for: user)
        }
        .accessibilityIdentifier("account-tier-row")

        Button(role: .destructive) {
            Task { await signOut() }
        } label: {
            HStack {
                Text("Sign out")
                Spacer()
                if isSigningOut {
                    ProgressView()
                }
            }
        }
        .disabled(isSigningOut)
        .accessibilityIdentifier("account-sign-out")
    }

    @ViewBuilder
    private func tierBadge(for user: AuthenticatedUser) -> some View {
        let (label, color) = tierLabelAndColor(for: user)
        Text(label)
            .font(.lmCaption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .accessibilityIdentifier("account-tier-badge")
    }

    private func tierLabelAndColor(for user: AuthenticatedUser) -> (String, Color) {
        switch user.tier {
        case .pro:
            return ("Pro", LiftMarkTheme.primary)
        case .trial:
            if let endsAt = user.trialEndsAt {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d"
                return ("Trial (ends \(formatter.string(from: endsAt)))", LiftMarkTheme.warning)
            }
            return ("Trial", LiftMarkTheme.warning)
        case .free:
            return ("Free", LiftMarkTheme.secondaryLabel)
        }
    }

    // MARK: - Signed out

    @ViewBuilder
    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
            Text("Sign in to receive workouts pushed from Claude Code, ChatGPT, or other tools.")
                .font(.lmSubheadline)
                .foregroundStyle(LiftMarkTheme.label)
            Text("Optional — the app works fully offline without an account.")
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
        }
        .padding(.vertical, LiftMarkTheme.spacingXS)
        .accessibilityIdentifier("account-signed-out-copy")

        Button {
            showingLogin = true
        } label: {
            HStack {
                Text("Sign in")
                    .fontWeight(.semibold)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.lmCaption.weight(.semibold))
                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
            }
        }
        .accessibilityIdentifier("account-sign-in")
    }

    // MARK: - Actions

    private func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        await authStore.logout()
    }
}
