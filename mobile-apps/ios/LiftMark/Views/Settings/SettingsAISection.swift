import SwiftUI

struct SettingsAISection: View {
    @Environment(SettingsStore.self) private var settingsStore
    @State private var showApiKey = false
    @State private var apiKeyText = ""
    @FocusState private var apiKeyFocused: Bool

    var body: some View {
        Group {
            if let settings = settingsStore.settings {
                content(settings: settings)
            }
        }
    }

    @ViewBuilder
    private func content(settings: UserSettings) -> some View {
        Group {
            togglesGroup
            customPromptGroup(settings: settings)
            apiKeyGroup
            apiKeyStatusBadge(status: settings.anthropicApiKeyStatus)
        }
    }

    private var togglesGroup: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            Text("Include in AI prompt")
                .font(.lmCaption)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                Toggle("lift.md format pointer", isOn: toggleBinding(\.aiPromptIncludeFormatPointer))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toggle-ai-include-format-pointer")
                Divider()
                Toggle("Recent workouts", isOn: toggleBinding(\.aiPromptIncludeRecentWorkouts))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toggle-ai-include-recent-workouts")
                Divider()
                Toggle("Progression", isOn: toggleBinding(\.aiPromptIncludeProgression))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toggle-ai-include-progression")
                Divider()
                Toggle("Gym equipment", isOn: toggleBinding(\.aiPromptIncludeEquipment))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toggle-ai-include-equipment")
            }
        }
    }

    private func customPromptGroup(settings: UserSettings) -> some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            Text("Custom Prompt")
                .font(.lmCaption)
                .foregroundStyle(.secondary)
            TextField("Additional instructions for AI...", text: Binding(
                get: { settings.customPromptAddition ?? "" },
                set: { newValue in
                    var updated = settings
                    updated.customPromptAddition = newValue.isEmpty ? nil : newValue
                    settingsStore.updateSettings(updated)
                }
            ), axis: .vertical)
            .lineLimit(2...4)
            .accessibilityIdentifier("input-custom-prompt")
        }
    }

    private var apiKeyGroup: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            Text("API Key")
                .font(.lmCaption)
                .foregroundStyle(.secondary)
            HStack(spacing: LiftMarkTheme.spacingSM) {
                if showApiKey {
                    TextField("API Key", text: $apiKeyText)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .focused($apiKeyFocused)
                } else {
                    SecureField("Anthropic API Key", text: $apiKeyText)
                        .focused($apiKeyFocused)
                }
                Button {
                    let wasFocused = apiKeyFocused
                    showApiKey.toggle()
                    if wasFocused {
                        DispatchQueue.main.async { apiKeyFocused = true }
                    }
                } label: {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("toggle-api-key-visibility")

                Button {
                    saveApiKey()
                } label: {
                    Text("Save")
                        .font(.lmSubheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(LiftMarkTheme.primary)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("save-api-key-button")

                Button {
                    removeApiKey()
                } label: {
                    Text("Remove")
                        .font(.lmSubheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .overlay(
                            Capsule()
                                .stroke(LiftMarkTheme.destructive, lineWidth: 1.5)
                        )
                        .foregroundStyle(LiftMarkTheme.destructive)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("remove-api-key-button")
            }
        }
        .accessibilityIdentifier("input-api-key")
    }

    @ViewBuilder
    private func apiKeyStatusBadge(status: ApiKeyStatus?) -> some View {
        if let status {
            HStack {
                Circle()
                    .fill(apiKeyStatusColor(status))
                    .frame(width: 8, height: 8)
                Text(apiKeyStatusLabel(status))
                    .font(.lmCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Toggle Binding

    private func toggleBinding(_ keyPath: WritableKeyPath<UserSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings?[keyPath: keyPath] ?? true },
            set: { newValue in
                guard var updated = settingsStore.settings else { return }
                updated[keyPath: keyPath] = newValue
                settingsStore.updateSettings(updated)
            }
        )
    }

    // MARK: - API Key Actions

    private func saveApiKey() {
        let trimmed = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try SecureStorage.storeApiKey(trimmed)
            guard var updated = settingsStore.settings else { return }
            updated.anthropicApiKeyStatus = .verified
            settingsStore.updateSettings(updated)
        } catch {
            guard var updated = settingsStore.settings else { return }
            updated.anthropicApiKeyStatus = .invalid
            settingsStore.updateSettings(updated)
        }
    }

    private func removeApiKey() {
        try? SecureStorage.removeApiKey()
        apiKeyText = ""
        guard var updated = settingsStore.settings else { return }
        updated.anthropicApiKeyStatus = .notSet
        settingsStore.updateSettings(updated)
    }

    private func apiKeyStatusColor(_ status: ApiKeyStatus) -> Color {
        switch status {
        case .verified: return LiftMarkTheme.success
        case .invalid: return LiftMarkTheme.destructive
        case .notSet: return LiftMarkTheme.secondaryLabel
        }
    }

    private func apiKeyStatusLabel(_ status: ApiKeyStatus) -> String {
        switch status {
        case .verified: return "Verified"
        case .invalid: return "Invalid"
        case .notSet: return "Not Set"
        }
    }
}
