import SwiftUI

/// Sheet payload: the key being edited (or a fresh draft) and whether it's new.
struct AIKeyEditorTarget: Identifiable {
    let key: AIProviderKey
    let isNew: Bool
    var id: String { key.id }
}

/// Add/Edit sheet for one BYOK provider key. Saving runs an offline format check,
/// then the provider's free list-models call — never a token-spending request.
/// See spec/screens/settings.md "AI Provider Keys (BYOK)".
struct AIKeyEditorSheet: View {
    let original: AIProviderKey
    let isNew: Bool

    @Environment(AIKeyStore.self) private var aiKeyStore
    @Environment(\.dismiss) private var dismiss

    @State private var provider: AIProvider
    @State private var apiKey: String
    @State private var model: String
    @State private var baseURL: String
    @State private var showKey = false
    @State private var isVerifying = false
    @State private var errorMessage: String?
    @State private var availableModels: [String] = []
    /// In-flight verification; cancelled when the sheet goes away so an
    /// abandoned (or just-deleted) key is never saved behind the user's back.
    @State private var verifyTask: Task<Void, Never>?

    init(original: AIProviderKey, isNew: Bool) {
        self.original = original
        self.isNew = isNew
        _provider = State(initialValue: original.provider)
        _apiKey = State(initialValue: original.apiKey)
        _model = State(initialValue: original.model)
        _baseURL = State(initialValue: original.baseURL ?? AIProvider.defaultOllamaBaseURL)
    }

    private var draft: AIProviderKey {
        AIProviderKey(
            id: original.id,
            provider: provider,
            apiKey: apiKey,
            model: model,
            baseURL: provider == .ollama ? baseURL : nil,
            status: .unverified
        )
    }

    private var canSave: Bool {
        guard !isVerifying else { return false }
        return provider == .ollama ? !draft.baseURL.isNilOrEmpty : !draft.apiKey.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $provider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.pickerLabel).tag(provider)
                        }
                    }
                    .accessibilityIdentifier("picker-ai-provider")
                }
                credentialSection
                modelSection
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.destructive)
                            .accessibilityIdentifier("ai-key-error")
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete Key", role: .destructive) {
                            verifyTask?.cancel()
                            aiKeyStore.remove(id: original.id)
                            dismiss()
                        }
                        .accessibilityIdentifier("button-delete-ai-key")
                    }
                }
            }
            .navigationTitle(isNew ? "Add Key" : "Edit Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        verifyTask?.cancel()
                        dismiss()
                    }
                        .accessibilityIdentifier("button-cancel-ai-key")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isVerifying {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("button-save-ai-key")
                }
            }
            .onChange(of: provider) { _, _ in
                // Never carry a secret or model id over to a different provider
                // (e.g. an OpenAI key sent as a Bearer token to a LAN Ollama host).
                verifyTask?.cancel()
                isVerifying = false
                apiKey = ""
                model = ""
                errorMessage = nil
                availableModels = []
            }
            .onDisappear { verifyTask?.cancel() }
            .task {
                if !isNew { await loadModels(showErrors: false) }
            }
        }
        .accessibilityIdentifier("ai-key-sheet")
    }

    // MARK: - Sections

    @ViewBuilder
    private var credentialSection: some View {
        if provider == .ollama {
            Section {
                TextField("Server URL", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("input-ai-base-url")
                keyField
            } header: {
                Text("Server")
            } footer: {
                Text("Run Ollama with OLLAMA_HOST=0.0.0.0 and enter this computer's LAN address.")
            }
        } else {
            Section("API Key") {
                keyField
            }
        }
    }

    private var keyField: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            Group {
                if showKey {
                    TextField(provider.keyPlaceholder, text: $apiKey)
                } else {
                    SecureField(provider.keyPlaceholder, text: $apiKey)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("input-ai-api-key")

            Button {
                showKey.toggle()
            } label: {
                Image(systemName: showKey ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showKey ? "Hide key" : "Show key")
            .accessibilityIdentifier("toggle-api-key-visibility")
        }
    }

    private var modelSection: some View {
        Section("Model") {
            HStack(spacing: LiftMarkTheme.spacingSM) {
                TextField(provider.defaultModel, text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("input-ai-model")
                if availableModels.isEmpty {
                    Button("Load models") {
                        verifyTask = Task { await loadModels(showErrors: true) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isVerifying || draft.formatError != nil)
                    .accessibilityIdentifier("button-load-ai-models")
                } else {
                    Menu {
                        ForEach(availableModels, id: \.self) { id in
                            Button(id) { model = id }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Choose model")
                    .accessibilityIdentifier("menu-ai-model")
                }
            }
        }
    }

    // MARK: - Actions

    private func loadModels(showErrors: Bool) async {
        let candidate = draft
        guard candidate.formatError == nil else { return }
        isVerifying = true
        let result = await AIProviderService.shared.verify(candidate)
        // Drop results for a draft the user has since changed or abandoned.
        guard !Task.isCancelled, candidate.provider == provider else { return }
        isVerifying = false
        availableModels = result.models
        if showErrors { errorMessage = result.message }
    }

    private func save() {
        let candidate = draft
        if let formatError = candidate.formatError {
            errorMessage = formatError
            return
        }
        errorMessage = nil
        isVerifying = true
        verifyTask = Task {
            let result = await AIProviderService.shared.verify(candidate)
            guard !Task.isCancelled else { return }
            isVerifying = false
            if !result.models.isEmpty { availableModels = result.models }

            if result.status == .invalid {
                errorMessage = result.message
                return
            }
            if result.status == .verified,
               let modelError = candidate.modelAvailabilityError(installed: result.models) {
                errorMessage = modelError
                return
            }
            var saved = candidate
            saved.status = result.status
            do {
                try aiKeyStore.save(saved)
                dismiss()
            } catch {
                errorMessage = "Couldn't save the key: \(error.localizedDescription)"
            }
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
