import SwiftUI

/// Settings section that surfaces the user's LMWF account state and the
/// sign-in / sign-out controls. Drops into `SettingsView`'s Form/List as
/// `Section { SettingsAccountSection() } header: { Text("Account") }`.
///
/// Auth is optional — when not signed in, the section explains *why*
/// you'd sign in (push from Claude Code / ChatGPT) and reassures that
/// the app works offline without it.
struct SettingsAccountSection: View {
    @Environment(AuthenticationStore.self) private var authStore
    @Environment(InboxPollerService.self) private var inboxPoller
    @Environment(FeatureFlagsStore.self) private var featureFlags
    @State private var showingLogin = false
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
        .sheet(isPresented: $showingLogin) {
            LoginView()
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
                    .font(.subheadline)
            }
            if inboxPoller.pendingCount > 0 {
                Text("\(inboxPoller.pendingCount) pending")
                    .font(.caption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
            if let err = inboxPoller.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
        .accessibilityIdentifier("account-inbox-status")

        Button {
            Task { await inboxPoller.pollIfAuthenticated() }
        } label: {
            HStack {
                Text("Sync now")
                Spacer()
                if inboxPoller.isPolling {
                    ProgressView()
                }
            }
        }
        .disabled(inboxPoller.isPolling)
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
                    .font(.body)
                    .foregroundStyle(LiftMarkTheme.label)
            }
            if !user.email.isEmpty {
                Text(user.email)
                    .font(.subheadline)
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
            .font(.caption.weight(.semibold))
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
                .font(.subheadline)
                .foregroundStyle(LiftMarkTheme.label)
            Text("Optional — the app works fully offline without an account.")
                .font(.caption)
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
                    .font(.caption.weight(.semibold))
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
