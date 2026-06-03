import SwiftUI

// MARK: - Edit Parse Result

struct EditParseResult {
    let name: String
    let exerciseCount: Int
    let setCount: Int
    let warnings: [String]
}

// MARK: - Edit Plan Markdown Sheet

struct EditPlanMarkdownSheet: View {
    let planId: String
    let initialMarkdown: String

    @State private var markdownText = ""
    @State private var parseResult: EditParseResult?
    @State private var parseError: String?
    @State private var showDiscardConfirm = false
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutPlanStore.self) private var planStore

    private var hasChanges: Bool {
        markdownText != initialMarkdown
    }

    private var canSave: Bool {
        !markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parseError == nil && hasChanges
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Markdown editor
                TextEditor(text: $markdownText)
                    .font(.lmMono)
                    .padding(LiftMarkTheme.spacingSM)
                    .accessibilityIdentifier("edit-plan-markdown-editor")

                // Parse error
                if let error = parseError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(LiftMarkTheme.destructive)
                        Text(error)
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.destructive)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, LiftMarkTheme.spacingSM)
                    .background(LiftMarkTheme.destructive.opacity(0.1))
                }

                // Parse success
                if let result = parseResult {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LiftMarkTheme.success)
                        Text("\(result.name) - \(result.exerciseCount) exercises, \(result.setCount) sets")
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.success)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, LiftMarkTheme.spacingSM)
                    .background(LiftMarkTheme.success.opacity(0.1))

                    if !result.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(result.warnings, id: \.self) { warning in
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.lmCaption2)
                                        .foregroundStyle(LiftMarkTheme.warning)
                                    Text(warning)
                                        .font(.lmCaption2)
                                        .foregroundStyle(LiftMarkTheme.warning)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, LiftMarkTheme.spacingXS)
                    }
                }
            }
            .navigationTitle("Edit Plan")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges {
                            showDiscardConfirm = true
                        } else {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("edit-plan-cancel-button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePlan()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("edit-plan-save-button")
                }
            }
            .onChange(of: markdownText) {
                parseMarkdown()
            }
            .alert("Discard Changes?", isPresented: $showDiscardConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) {
                    dismiss()
                }
            } message: {
                Text("You have unsaved changes that will be lost.")
            }
        }
        .accessibilityIdentifier("edit-plan-markdown-sheet")
        .onAppear {
            markdownText = initialMarkdown
        }
    }

    private func parseMarkdown() {
        let trimmed = markdownText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parseResult = nil
            parseError = nil
            return
        }

        let result = MarkdownParser.parseWorkout(trimmed)

        if !result.errors.isEmpty {
            parseError = result.errors.first ?? "Parse error"
            parseResult = nil
        } else {
            parseError = nil
            parseResult = EditParseResult(
                name: result.data?.name ?? "Untitled",
                exerciseCount: result.data?.exercises.count ?? 0,
                setCount: result.data?.exercises.reduce(0) { $0 + $1.sets.count } ?? 0,
                warnings: result.warnings
            )
        }
    }

    private func savePlan() {
        planStore.updatePlanMarkdown(id: planId, newMarkdown: markdownText)
        dismiss()
    }
}
