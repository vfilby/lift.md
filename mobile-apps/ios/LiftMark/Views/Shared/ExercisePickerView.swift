import SwiftUI

struct ExercisePickerView: View {
    @State private var searchText = ""
    @State private var historyExercises: [String] = []
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    private let commonExercises = [
        "Back Squat", "Deadlift", "Bench Press", "Overhead Press",
        "Barbell Row", "Pull-Up", "Dip", "Leg Press",
        "Romanian Deadlift", "Front Squat", "Incline Bench Press",
        "Lat Pulldown", "Cable Row", "Leg Curl", "Leg Extension",
        "Lateral Raise", "Bicep Curl", "Tricep Pushdown"
    ]

    /// Merged list: common exercises + any history exercises not already in the common list.
    private var allExercises: [String] {
        let commonSet = Set(commonExercises.map { $0.lowercased() })
        let extras = historyExercises.filter { !commonSet.contains($0.lowercased()) }
        return commonExercises + extras.sorted()
    }

    private var filteredExercises: [String] {
        if searchText.isEmpty { return allExercises }
        return allExercises.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var hasExactMatch: Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredExercises.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .accessibilityIdentifier("exercise-picker-cancel")

                Spacer()

                Text("Choose Exercise")
                    .font(.lmHeadline)

                Spacer()
            }
            .padding()

            // Search
            TextField("Search exercises...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .accessibilityIdentifier("exercise-picker-search")

            // List
            List {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasExactMatch {
                    Button {
                        onSelect(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    } label: {
                        Label(
                            "Add \"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\"",
                            systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("exercise-picker-free-entry")
                }

                ForEach(filteredExercises, id: \.self) { name in
                    Button(name) {
                        onSelect(name)
                        dismiss()
                    }
                    .accessibilityIdentifier("exercise-option-\(name)")
                }
            }
            .listStyle(.plain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exercise-picker-modal")
        .onAppear {
            do {
                historyExercises = try ExerciseHistoryRepository().getAllExerciseNamesNormalized()
            } catch {
                // Silently fall back to common exercises only
            }
        }
    }
}
