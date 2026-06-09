import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Interactive AI prompt builder. The user writes an intent, picks a gym, toggles
/// which context blocks to include, and sees the live prompt update as they go.
/// On successful generation, returns the LMWF markdown to the caller via `onGenerated`.
struct GeneratePromptView: View {
    var onGenerated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(GymStore.self) private var gymStore

    @State private var intent: String = ""
    @State private var selectedGymId: String?
    @State private var equipment: [GymEquipment] = []
    @State private var recentWorkouts: String = ""
    @State private var progression: String = ""
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var showPreview: Bool = true

    private var settings: UserSettings? { settingsStore.settings }
    private var selectedGym: Gym? {
        gymStore.gyms.first { $0.id == selectedGymId } ?? gymStore.gyms.first { $0.isDefault } ?? gymStore.gyms.first
    }

    private var canGenerate: Bool {
        settings?.anthropicApiKeyStatus == .verified
            && !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                    intentSection
                    gymSection
                    togglesSection
                    previewSection
                    if let error = generationError {
                        Text(error)
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.destructive)
                    }
                }
                .padding()
            }
            .navigationTitle("Build with AI")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("button-cancel")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        copyPrompt()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityIdentifier("button-copy-prompt")

                    if settings?.anthropicApiKeyStatus == .verified {
                        Button {
                            generate()
                        } label: {
                            if isGenerating {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Generate", systemImage: "sparkles")
                            }
                        }
                        .disabled(!canGenerate)
                        .accessibilityIdentifier("button-generate")
                    }
                }
            }
            .onAppear {
                if gymStore.gyms.isEmpty { gymStore.loadGyms() }
                if selectedGymId == nil { selectedGymId = selectedGym?.id }
                loadEquipment()
                loadHistory()
            }
            .onChange(of: selectedGymId) { _, _ in loadEquipment() }
        }
    }

    // MARK: - Sections

    private var intentSection: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            Text("What do you want to train?")
                .font(.lmCaption)
                .foregroundStyle(.secondary)
            TextEditor(text: $intent)
                .font(.lmBody)
                .frame(minHeight: 80)
                .padding(LiftMarkTheme.spacingSM)
                .background(LiftMarkTheme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM))
                .overlay(alignment: .topLeading) {
                    if intent.isEmpty {
                        Text("e.g. heavy push day, 45 minutes, focus on bench")
                            .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                            .padding(LiftMarkTheme.spacingSM + 4)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("input-intent")
        }
    }

    private var gymSection: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            HStack {
                Text("Gym")
                    .font(.lmCaption)
                    .foregroundStyle(.secondary)
                Spacer()
                if gymStore.gyms.isEmpty {
                    Text("No gyms — using default equipment")
                        .font(.lmCaption)
                        .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                } else {
                    Picker("Gym", selection: Binding(
                        get: { selectedGymId ?? selectedGym?.id ?? "" },
                        set: { selectedGymId = $0 }
                    )) {
                        ForEach(gymStore.gyms.filter { !$0.isDeleted }, id: \.id) { gym in
                            Text(gym.name).tag(gym.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("picker-gym")
                }
            }

            if settings?.aiPromptIncludeEquipment == true, !equipment.isEmpty {
                let available = equipment.filter { $0.isAvailable }.map(\.name)
                Text(available.isEmpty ? "(no equipment marked available)" : available.joined(separator: ", "))
                    .font(.lmCaption2)
                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
            }
        }
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            Text("Include in prompt")
                .font(.lmCaption)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                Toggle("lift.md format pointer", isOn: toggle(\.aiPromptIncludeFormatPointer))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toggle-ai-include-format-pointer")
                Divider()
                Toggle("Recent workouts", isOn: toggle(\.aiPromptIncludeRecentWorkouts))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toggle-ai-include-recent-workouts")
                Divider()
                Toggle("Progression", isOn: toggle(\.aiPromptIncludeProgression))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toggle-ai-include-progression")
                Divider()
                Toggle("Gym equipment", isOn: toggle(\.aiPromptIncludeEquipment))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toggle-ai-include-equipment")
            }
        }
    }

    private var previewSection: some View {
        DisclosureGroup(isExpanded: $showPreview) {
            ScrollView {
                Text(builtPrompt)
                    .font(.lmMono(size: 12, relativeTo: .caption))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(LiftMarkTheme.spacingSM)
            }
            .frame(maxHeight: 360)
            .background(LiftMarkTheme.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM))
            .accessibilityIdentifier("prompt-preview")
        } label: {
            Text("Prompt preview")
                .font(.lmCaption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Prompt Building

    private var builtPrompt: String {
        let s = settings
        let context = WorkoutGenerationContext(
            defaultWeightUnit: s?.defaultWeightUnit ?? .lbs,
            customPromptAddition: s?.customPromptAddition,
            recentWorkouts: recentWorkouts,
            progression: progression,
            availableEquipment: equipment.filter { $0.isAvailable }.map(\.name),
            currentGym: selectedGym?.name,
            toggles: AIPromptToggles(
                includeFormatPointer: s?.aiPromptIncludeFormatPointer ?? true,
                includeRecentWorkouts: s?.aiPromptIncludeRecentWorkouts ?? true,
                includeProgression: s?.aiPromptIncludeProgression ?? true,
                includeEquipment: s?.aiPromptIncludeEquipment ?? true
            )
        )
        let params = WorkoutGenerationParams(
            intent: intent.isEmpty ? nil : intent
        )
        return WorkoutGenerationService.buildWorkoutGenerationPrompt(context: context, params: params)
    }

    // MARK: - Actions

    private func copyPrompt() {
        #if canImport(UIKit)
        UIPasteboard.general.string = builtPrompt
        #endif
    }

    private func generate() {
        guard let apiKey = SecureStorage.getApiKey() else {
            generationError = "API key missing. Add one in Settings."
            return
        }
        let prompt = builtPrompt
        isGenerating = true
        generationError = nil
        Task {
            let result = await AnthropicService.shared.generateWorkout(apiKey: apiKey, prompt: prompt)
            await MainActor.run {
                isGenerating = false
                if let markdown = result.workout {
                    onGenerated(markdown)
                    dismiss()
                } else {
                    generationError = result.error?.message ?? "Generation failed"
                }
            }
        }
    }

    private func loadEquipment() {
        guard let gymId = selectedGymId ?? selectedGym?.id else {
            equipment = []
            return
        }
        let store = EquipmentStore()
        store.loadEquipment(forGym: gymId)
        equipment = store.equipment
    }

    private func loadHistory() {
        let service = WorkoutHistoryService()
        recentWorkouts = (try? service.generateWorkoutHistoryContext(recentCount: 5)) ?? ""
        progression = (try? service.generateProgressionContext(topN: 5)) ?? ""
    }

    // MARK: - Toggle binding

    private func toggle(_ keyPath: WritableKeyPath<UserSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings?[keyPath: keyPath] ?? true },
            set: { newValue in
                guard var updated = settingsStore.settings else { return }
                updated[keyPath: keyPath] = newValue
                settingsStore.updateSettings(updated)
            }
        )
    }
}
