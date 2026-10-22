import SwiftUI

struct SettingsAISection: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(AIKeyStore.self) private var aiKeyStore
    /// Presented by `SettingsView` (stably mounted), not by these lazy list rows.
    @Binding var editorTarget: AIKeyEditorTarget?

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
            keysHeader
            keyRows
            addKeyButton
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

    // MARK: - AI Provider Keys

    private var keysHeader: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
            Text("AI Provider Keys")
                .font(.lmCaption)
                .foregroundStyle(.secondary)
            if let error = aiKeyStore.lastError {
                Text("Couldn't update keys: \(error.localizedDescription)")
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.destructive)
                    .accessibilityIdentifier("ai-keys-error")
            }
            if aiKeyStore.keys.isEmpty {
                Text("Add a key from Anthropic, OpenAI, Gemini, or a local Ollama server to generate workouts in-app.")
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                    .accessibilityIdentifier("ai-keys-empty")
            } else {
                Text("Generation tries keys top to bottom.")
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
            }
        }
    }

    private var keyRows: some View {
        ForEach(Array(aiKeyStore.keys.enumerated()), id: \.element.id) { index, key in
            Button {
                editorTarget = AIKeyEditorTarget(key: key, isNew: false)
            } label: {
                keyRow(key, index: index)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(index + 1). \(key.provider.displayName), \(key.effectiveModel)")
            .accessibilityValue(statusLabel(key.status))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("ai-key-row-\(index)")
            .contextMenu { keyContextMenu(key, index: index) }
        }
        .onMove { aiKeyStore.move(fromOffsets: $0, toOffset: $1) }
        .onDelete { aiKeyStore.remove(atOffsets: $0) }
    }

    private func keyRow(_ key: AIProviderKey, index: Int) -> some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1). \(key.provider.displayName)")
                    .font(.lmBody)
                Text("\(key.effectiveModel) · \(key.maskedHint)")
                    .font(.lmCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: LiftMarkTheme.spacingXS) {
                Circle()
                    .fill(statusColor(key.status))
                    .frame(width: 8, height: 8)
                Text(statusLabel(key.status))
                    .font(.lmCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func keyContextMenu(_ key: AIProviderKey, index: Int) -> some View {
        if index > 0 {
            Button { aiKeyStore.moveUp(id: key.id) } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .accessibilityIdentifier("ai-key-move-up")
        }
        if index < aiKeyStore.keys.count - 1 {
            Button { aiKeyStore.moveDown(id: key.id) } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .accessibilityIdentifier("ai-key-move-down")
        }
        Button(role: .destructive) { aiKeyStore.remove(id: key.id) } label: {
            Label("Delete", systemImage: "trash")
        }
        .accessibilityIdentifier("ai-key-delete")
    }

    private var addKeyButton: some View {
        Button {
            editorTarget = AIKeyEditorTarget(key: AIProviderKey(provider: .anthropic), isNew: true)
        } label: {
            Label("Add Key", systemImage: "plus.circle")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("add-ai-key-button")
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

    // MARK: - Status Display

    private func statusColor(_ status: AIKeyStatus) -> Color {
        switch status {
        case .verified: return LiftMarkTheme.success
        case .invalid: return LiftMarkTheme.destructive
        case .unverified: return LiftMarkTheme.secondaryLabel
        }
    }

    private func statusLabel(_ status: AIKeyStatus) -> String {
        switch status {
        case .verified: return "Verified"
        case .invalid: return "Invalid"
        case .unverified: return "Not verified"
        }
    }
}
