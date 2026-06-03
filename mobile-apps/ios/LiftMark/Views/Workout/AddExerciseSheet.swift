import SwiftUI

struct AddExerciseSheet: View {
    let onAdd: (String) -> Void
    @State private var markdown = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: LiftMarkTheme.spacingMD) {
                Text("Enter exercise in lift.md format:")
                    .font(.lmSubheadline)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)

                TextEditor(text: $markdown)
                    .font(.lmMono)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM)
                            .stroke(LiftMarkTheme.tertiaryLabel, lineWidth: 1)
                    )

                Text("Example:\n## Bicep Curl [dumbbell]\n- 25 x 12\n- 25 x 10")
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }
            .padding()
            .navigationTitle("Add Exercise")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(markdown)
                        dismiss()
                    }
                    .disabled(markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
