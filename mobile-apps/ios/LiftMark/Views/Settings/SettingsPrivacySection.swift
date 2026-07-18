import SwiftUI

struct SettingsPrivacySection: View {
    @AppStorage(CrashReporter.crashReportingEnabledKey) private var crashReportingEnabled: Bool = true
    @AppStorage(CrashReporter.includeContentInErrorReportsKey) private var includeContent: Bool = false

    var body: some View {
        Toggle("Send crash and error reports", isOn: Binding(
            get: { crashReportingEnabled },
            set: { newValue in
                crashReportingEnabled = newValue
                CrashReporter.shared.setEnabled(newValue)
            }
        ))
        .accessibilityIdentifier("toggle-crash-reporting")

        Toggle("Include workout content", isOn: $includeContent)
            .disabled(!crashReportingEnabled)
            .accessibilityIdentifier("toggle-include-content")

        Text("Reports help diagnose crashes and sync failures. Content inclusion sends your workout "
            + "text to our error reporter (Sentry) — only enable this to help us debug a parser bug you've hit.")
            .font(.lmFootnote)
            .foregroundStyle(.secondary)
    }
}
