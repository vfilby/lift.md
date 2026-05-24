import SwiftUI

/// Modal sign-in form for the LMWF account. Used to authenticate the
/// device so workouts pushed from Claude Code / ChatGPT / other tools can
/// land in the inbox. The app is fully usable without signing in — this
/// sheet is only presented when the user explicitly taps Settings →
/// Account → Sign in.
///
/// Password reset and account creation are deferred to the web
/// (beta.liftmark.app) for now, so this view only handles login + the
/// "Resend verification email" remediation path.
struct LoginView: View {
    @Environment(AuthenticationStore.self) private var authStore
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isSubmitting: Bool = false
    @State private var error: AuthError?
    @State private var resendStatus: ResendStatus = .idle

    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case email, password }

    private enum ResendStatus: Equatable {
        case idle
        case sending
        case sent
        case failed(String)
    }

    private static let forgotPasswordURL = URL(string: "https://beta.liftmark.app/account/forgot")!
    private static let signupURL = URL(string: "https://beta.liftmark.app/account/signup")!

    private var canSubmit: Bool {
        !isSubmitting
            && !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .accessibilityIdentifier("login-email")

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await submit() } }
                        .accessibilityIdentifier("login-password")
                }

                if let error {
                    Section {
                        errorView(for: error)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("Sign in")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("login-submit")
                }

                Section {
                    Link("Forgot password?", destination: Self.forgotPasswordURL)
                        .accessibilityIdentifier("login-forgot-password")
                    Link("Create account", destination: Self.signupURL)
                        .accessibilityIdentifier("login-create-account")
                } footer: {
                    Text("Optional — the app works fully offline without an account.")
                }
            }
            .navigationTitle("Sign in")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("login-cancel")
                }
            }
            .onAppear { focusedField = .email }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    // MARK: - Error rendering

    @ViewBuilder
    private func errorView(for error: AuthError) -> some View {
        switch error {
        case .invalidCredentials:
            Text("Invalid email or password")
                .foregroundStyle(LiftMarkTheme.destructive)
                .accessibilityIdentifier("login-error-invalid")
        case .emailNotVerified:
            VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
                Text("Check your email to verify your address.")
                    .foregroundStyle(LiftMarkTheme.destructive)
                resendVerificationControl
            }
            .accessibilityIdentifier("login-error-unverified")
        case .network:
            Text("Couldn't reach LiftMark. Check your connection and try again.")
                .foregroundStyle(LiftMarkTheme.destructive)
                .accessibilityIdentifier("login-error-network")
        case .unknown(let message):
            Text(message ?? "Something went wrong. Try again.")
                .foregroundStyle(LiftMarkTheme.destructive)
                .accessibilityIdentifier("login-error-unknown")
        }
    }

    @ViewBuilder
    private var resendVerificationControl: some View {
        switch resendStatus {
        case .idle:
            Button("Resend email") {
                Task { await resendVerification() }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("login-resend-verification")
        case .sending:
            HStack(spacing: LiftMarkTheme.spacingSM) {
                ProgressView()
                Text("Sending…")
                    .foregroundStyle(.secondary)
            }
        case .sent:
            Text("Verification email sent.")
                .font(.footnote)
                .foregroundStyle(LiftMarkTheme.success)
        case .failed(let message):
            VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(LiftMarkTheme.destructive)
                Button("Try again") {
                    Task { await resendVerification() }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Actions

    private func submit() async {
        guard canSubmit else { return }
        focusedField = nil
        isSubmitting = true
        error = nil
        resendStatus = .idle
        defer { isSubmitting = false }

        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        do {
            _ = try await authStore.login(email: trimmedEmail, password: password)
            dismiss()
        } catch let authError as AuthError {
            error = authError
        } catch {
            self.error = .unknown(error.localizedDescription)
        }
    }

    private func resendVerification() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        guard !trimmedEmail.isEmpty else {
            resendStatus = .failed("Enter your email above first.")
            return
        }
        resendStatus = .sending
        do {
            try await authStore.resendVerificationEmail(for: trimmedEmail)
            resendStatus = .sent
        } catch {
            resendStatus = .failed("Couldn't send verification email. Try again.")
        }
    }
}

#Preview {
    LoginView()
        .environment(AuthenticationStore(api: APIClient(baseURL: nil), tokenStore: TokenStore()))
}
