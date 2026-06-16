import SwiftUI

/// App-level banner shown when a previously signed-in session has lapsed and
/// there are completed workouts stranded in the outbox because the device needs
/// to re-authenticate. This is the user-facing half of the GH #143 fix: a
/// completed workout must never silently fail to sync without a recovery
/// affordance.
///
/// Visible when ALL of:
///   - `outboxPusher.pendingCount > 0`
///   - `authStore.sessionExpired` — the *last known* session lapsed (a 401 on
///     refresh). It is deliberately keyed off `sessionExpired`, NOT
///     `!isAuthenticated`: a user who has **never** signed in is not in a broken
///     state (their workouts queue locally and drain when they choose to sign
///     in), so the nag must not appear for them. `sessionExpired` is only set by
///     the refresh-failure path and reset on login/logout/successful refresh, so
///     it is exactly "was signed in, now needs re-auth". (GH #143 follow-up.)
///   - no workout is currently active
///   - the user hasn't dismissed it this launch
///
/// It is suppressed while a workout session is in progress (GH #194 follow-up):
/// the banner is mounted as a top `safeAreaInset` over the whole tab view, and
/// the active-workout screen draws its own header (with the Finish button) into
/// that same top region — so a visible banner overlaps and intercepts taps on
/// Finish. A sync nag for *past* workouts also shouldn't crowd a live session.
/// It returns automatically once the workout ends.
///
/// It is **dismissable** (trailing ✕): the banner must never permanently obscure
/// the app. If the lapsed-session user can't immediately sign back in (e.g. a
/// login/server hiccup), they can clear it and keep using the app. Dismissal is
/// in-memory only and re-arms when `pendingCount` increases (a freshly completed
/// workout is a new reason to nag) or on the next launch.
///
/// Tapping the banner body presents `LoginView`. A successful login resets
/// `sessionExpired` and flushes the outbox, which drains the queue and dismisses
/// the banner.
struct AuthSyncBannerView: View {
    @Environment(AuthenticationStore.self) private var authStore
    @Environment(OutboxPusherService.self) private var outboxPusher
    @Environment(SessionStore.self) private var sessionStore

    @State private var showingLogin = false
    /// User dismissed the banner this launch. Re-armed when `pendingCount` grows
    /// (see `onChange` below) and reset on relaunch (in-memory `@State`).
    @State private var dismissed = false
    /// Last `pendingCount` we observed, to detect *increases* for re-arming.
    @State private var lastPendingCount = 0

    /// Pure visibility decision, extracted so it can be unit-tested without a
    /// SwiftUI host. The view's `shouldShow` forwards to this.
    static func shouldShow(
        pendingCount: Int,
        sessionExpired: Bool,
        hasActiveSession: Bool,
        dismissed: Bool
    ) -> Bool {
        pendingCount > 0
            && sessionExpired
            && !hasActiveSession
            && !dismissed
    }

    private var shouldShow: Bool {
        Self.shouldShow(
            pendingCount: outboxPusher.pendingCount,
            sessionExpired: authStore.sessionExpired,
            hasActiveSession: sessionStore.activeSession != nil,
            dismissed: dismissed
        )
    }

    private var message: String {
        let count = outboxPusher.pendingCount
        let noun = count == 1 ? "workout" : "workouts"
        return "\(count) \(noun) waiting to sync — sign in to upload."
    }

    var body: some View {
        // The `.sheet` modifier is hoisted onto a *stably-mounted* container
        // (this VStack always exists) rather than the conditionally-rendered
        // banner button. When the sheet hung off the `if shouldShow` branch, the
        // first "Sign in" tap toggled `showingLogin` *and* the presenting view
        // lived inside a structurally unstable `if` — SwiftUI tore down and
        // re-established the branch on the ensuing re-render, dropping the
        // in-flight sheet presentation. You had to tap a second time for it to
        // stick. Keeping the presenter mounted for the banner's lifetime makes
        // the modal appear on the FIRST tap. An empty VStack collapses to zero
        // height, so the top `safeAreaInset` still reserves no space when the
        // banner is hidden, and grows to fit it when shown.
        VStack(spacing: 0) {
            if shouldShow {
                bannerButton
            }
        }
        .sheet(isPresented: $showingLogin) {
            LoginView()
        }
        .onChange(of: outboxPusher.pendingCount) { _, newCount in
            // A newly completed (and freshly stranded) workout is a new reason
            // to nag, so re-arm a previously dismissed banner when the queue
            // grows. A shrinking/equal count (e.g. a drain) leaves dismissal as-is.
            if newCount > lastPendingCount {
                dismissed = false
            }
            lastPendingCount = newCount
        }
    }

    private var bannerButton: some View {
        HStack(spacing: 0) {
            Button {
                showingLogin = true
            } label: {
                HStack(spacing: LiftMarkTheme.spacingSM) {
                    Image(systemName: "exclamationmark.icloud.fill")
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.lmSubheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Spacer(minLength: LiftMarkTheme.spacingSM)
                    Text("Sign in")
                        .font(.lmSubheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.right")
                        .font(.lmCaption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                // Fill the row *minus* the rigid dismiss button, so the content
                // (and the dismiss ✕) never overflow the screen edge. Without
                // this the long message holds its intrinsic width and pushes the
                // trailing ✕ partly off-screen.
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
            .accessibilityHint("Opens sign-in to upload your completed workouts")
            .accessibilityIdentifier("auth-sync-banner")

            Button {
                dismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.lmSubheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    // A rigid 44×44 tap target keeps the trailing ✕ hittable and
                    // stops the flexible sign-in label from starving its frame.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityHint("Hides the sync reminder until your next completed workout")
            .accessibilityIdentifier("auth-sync-banner-dismiss")
        }
        .padding(.leading, LiftMarkTheme.spacingMD)
        .padding(.trailing, LiftMarkTheme.spacingSM)
        .padding(.vertical, LiftMarkTheme.spacingSM)
        .frame(maxWidth: .infinity)
        .background(LiftMarkTheme.warning)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#Preview {
    let auth = AuthenticationStore(api: APIClient(baseURL: nil), tokenStore: TokenStore())
    let pusher = OutboxPusherService(authStore: auth, apiClient: APIClient(baseURL: nil))
    return AuthSyncBannerView()
        .environment(auth)
        .environment(pusher)
        .environment(SessionStore())
}
