import SwiftUI

/// Editor for workout-level (session) notes.
///
/// Used in three places, all with the same contract:
/// - Active workout (mid-session) — accessible via a persistent header button.
/// - Workout summary (finish screen) — prompted after finish, pre-filled with
///   any in-progress notes.
/// - History detail — edit later, as many times as the user wants.
///
/// Plain free text, no tags or structured fields, per issue #91.
struct SessionNotesSheet: View {
    let initialNotes: String?
    let onSave: (String?) -> Void
    let title: String

    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    init(initialNotes: String?, title: String = "Workout Notes", onSave: @escaping (String?) -> Void) {
        self.initialNotes = initialNotes
        self.title = title
        self.onSave = onSave
        self._text = State(initialValue: initialNotes ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: LiftMarkTheme.spacingSM) {
                Text("Capture how this workout felt — energy, form cues, soreness, "
                    + "anything worth remembering. Plain text.")
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $text)
                    .focused($isFocused)
                    .font(.lmBody)
                    .frame(minHeight: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM)
                            .stroke(LiftMarkTheme.tertiaryLabel, lineWidth: 1)
                    )
                    .accessibilityIdentifier("session-notes-editor")

                Spacer()
            }
            .padding()
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("session-notes-cancel-button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                    .accessibilityIdentifier("session-notes-save-button")
                }
            }
            .onAppear { isFocused = true }
        }
    }
}
