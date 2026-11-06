import SwiftUI

// MARK: - Edit Plan Markdown Sheet

struct EditPlanMarkdownSheet: View {
    let planId: String
    let initialMarkdown: String

    @State private var markdownText = ""
    @State private var parseStatus: LMWFParseStatus?
    @State private var showDiscardConfirm = false
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutPlanStore.self) private var planStore

    private var hasChanges: Bool {
        markdownText != initialMarkdown
    }

    private var canSave: Bool {
        !markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parseStatus?.error == nil
            && hasChanges
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Markdown editor
                TextEditor(text: $markdownText)
                    .font(.lmMono)
                    .padding(LiftMarkTheme.spacingSM)
                    .accessibilityIdentifier("edit-plan-markdown-editor")

                // Parse error / success + warnings, with a Fix button when the
                // parser offered quick fixes (GH #472)
                if let status = parseStatus {
                    LMWFParseStatusView(status: status, idPrefix: "edit-plan-markdown") { fixes in
                        markdownText = LMWFQuickFix.applying(fixes, to: markdownText)
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
                parseStatus = LMWFParseStatus.parse(markdownText)
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

    private func savePlan() {
        planStore.updatePlanMarkdown(id: planId, newMarkdown: markdownText)
        dismiss()
    }
}
