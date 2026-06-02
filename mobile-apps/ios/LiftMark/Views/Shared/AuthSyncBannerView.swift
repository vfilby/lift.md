import SwiftUI

/// App-level banner shown when there are completed workouts that can't sync
/// because the device needs to (re-)authenticate. This is the user-facing half
/// of the GH #143 fix: a completed workout must never silently fail to sync
/// without a recovery affordance.
///
/// Visible when:
///   `outboxPusher.pendingCount > 0 && (!authStore.isAuthenticated || authStore.sessionExpired)`
///   — **and** no workout is currently active.
///
/// It is suppressed while a workout session is in progress (GH #194 follow-up):
/// the banner is mounted as a top `safeAreaInset` over the whole tab view, and
/// the active-workout screen draws its own header (with the Finish button) into
/// that same top region — so a visible banner overlaps and intercepts taps on
/// Finish. A sync nag for *past* workouts also shouldn't crowd a live session.
/// It returns automatically once the workout ends.
///
/// Tapping it presents `LoginView`. A successful login resets `sessionExpired`
/// and flushes the outbox, which drains the queue and dismisses the banner.
struct AuthSyncBannerView: View {
    @Environment(AuthenticationStore.self) private var authStore
    @Environment(OutboxPusherService.self) private var outboxPusher
    @Environment(SessionStore.self) private var sessionStore

    @State private var showingLogin = false

    private var shouldShow: Bool {
        outboxPusher.pendingCount > 0
            && (!authStore.isAuthenticated || authStore.sessionExpired)
            && sessionStore.activeSession == nil
    }

    private var message: String {
        let count = outboxPusher.pendingCount
        let noun = count == 1 ? "workout" : "workouts"
        return "\(count) \(noun) waiting to sync — sign in to upload."
    }

    var body: some View {
        if shouldShow {
            Button {
                showingLogin = true
            } label: {
                HStack(spacing: LiftMarkTheme.spacingSM) {
                    Image(systemName: "exclamationmark.icloud.fill")
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Spacer(minLength: LiftMarkTheme.spacingSM)
                    Text("Sign in")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, LiftMarkTheme.spacingMD)
                .padding(.vertical, LiftMarkTheme.spacingSM + 2)
                .frame(maxWidth: .infinity)
                .background(LiftMarkTheme.warning)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
            .accessibilityHint("Opens sign-in to upload your completed workouts")
            .accessibilityIdentifier("auth-sync-banner")
            .sheet(isPresented: $showingLogin) {
                LoginView()
            }
        }
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
