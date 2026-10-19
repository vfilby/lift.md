import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ImportView: View {
    var initialContent: String = ""

    @State private var markdownText = ""
    @State private var parseStatus: LMWFParseStatus?
    @State private var showImportSuccess = false
    @State private var importedPlanName = ""
    @State private var showDiscardConfirm = false
    @State private var showGeneratePrompt = false
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutPlanStore.self) private var planStore
    @Environment(SettingsStore.self) private var settingsStore

    private var canImport: Bool {
        !markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parseStatus?.error == nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Action buttons
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LiftMarkTheme.spacingSM) {
                        Button {
                            pasteFromClipboard()
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                                .font(.lmSubheadline)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("button-paste")

                        Button {
                            showGeneratePrompt = true
                        } label: {
                            Label("Build with AI", systemImage: "sparkles")
                                .font(.lmSubheadline)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("button-build-with-ai")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, LiftMarkTheme.spacingSM)
                }

                Divider()

                // Markdown input
                TextEditor(text: $markdownText)
                    .font(.lmMono)
                    .padding(LiftMarkTheme.spacingSM)
                    .accessibilityIdentifier("input-markdown")
                    .overlay(
                        Group {
                            if markdownText.isEmpty {
                                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
                                    Text("Paste your workout in lift.md format:")
                                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                                    Text("""
                                    # Push Day
                                    @tags: strength, upper
                                    @units: lbs

                                    ## Bench Press [barbell]
                                    - 135 x 5
                                    - 185 x 5
                                    - 225 x 5
                                    """)
                                    .font(.lmMono(size: 12, relativeTo: .caption))
                                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                                }
                                .padding(LiftMarkTheme.spacingMD)
                                .allowsHitTesting(false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                        }
                    )

                // Parse error / success + warnings, with a Fix button when the
                // parser offered quick fixes (GH #472)
                if let status = parseStatus {
                    LMWFParseStatusView(status: status, idPrefix: "import-markdown") { fixes in
                        markdownText = LMWFQuickFix.applying(fixes, to: markdownText)
                    }
                }
            }
            .navigationTitle("Import Workout")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            dismiss()
                        } else {
                            showDiscardConfirm = true
                        }
                    }
                    .accessibilityIdentifier("button-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importWorkout()
                    }
                    .disabled(!canImport)
                    .accessibilityIdentifier("button-import")
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
            .alert("Workout Imported", isPresented: $showImportSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("\(importedPlanName) has been imported successfully.")
            }
            .sheet(isPresented: $showGeneratePrompt) {
                GeneratePromptView { markdown in
                    markdownText = markdown
                }
            }
        }
        .accessibilityIdentifier("import-modal")
        .onAppear {
            if !initialContent.isEmpty {
                markdownText = initialContent
            }
        }
    }

    // MARK: - Actions

    private func pasteFromClipboard() {
        #if canImport(UIKit)
        if let text = UIPasteboard.general.string {
            markdownText = text
        }
        #endif
    }

    private func importWorkout() {
        let result = MarkdownParser.parseWorkout(markdownText)
        guard var plan = result.data else { return }
        plan.sourceMarkdown = markdownText
        planStore.createPlan(plan)
        importedPlanName = plan.name
        showImportSuccess = true
    }

}
