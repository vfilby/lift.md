import SwiftUI

// MARK: - Edit Exercise Set Change

enum EditExerciseSetChange {
    case update(setId: String, weight: Double?, reps: Int?, time: Int?, rest: Int?)
    case add(weight: Double?, unit: WeightUnit?, reps: Int?, time: Int?, rest: Int?)
    case delete(setId: String)
}

// MARK: - Editable Set Row Model

struct EditableSetRow: Identifiable {
    let id: String
    let existingSetId: String?
    var weightText: String
    var repsText: String
    var timeText: String
    /// Rest between sets in seconds. Empty string means "no rest set".
    var restText: String
    var weightUnit: WeightUnit?
    var status: SetStatus

    /// TC-E14: a set with a positive weight but neither reps nor time is
    /// incomplete. The LMWF spec and the validator reject this (a weight needs
    /// reps `x 5` or time `x 60s`), and the Markdown tab already does via the
    /// parser — so the Form tab must reject it too. Bodyweight/reps-only sets
    /// (no weight) are unaffected; weight is the optional part.
    var isWeightOnly: Bool {
        let weight = Double(weightText) ?? 0
        let reps = Int(repsText) ?? 0
        let time = Int(timeText) ?? 0
        return weight > 0 && reps <= 0 && time <= 0
    }

    static func from(_ set: SessionSet) -> EditableSetRow {
        let target = set.entries.first?.target
        return EditableSetRow(
            id: set.id,
            existingSetId: set.id,
            weightText: {
                if let w = target?.weight?.value {
                    return w.formattedWeight
                }
                return ""
            }(),
            repsText: target?.reps.map { "\($0)" } ?? "",
            timeText: target?.time.map { "\($0)" } ?? "",
            restText: set.restSeconds.map { "\($0)" } ?? "",
            weightUnit: target?.weight?.unit,
            status: set.status
        )
    }
}

// MARK: - Edit Exercise Sheet

struct EditExerciseSheet: View {
    let exercise: SessionExercise
    let onSave: (String, String?, String?, [EditExerciseSetChange]) -> Void
    @State private var name: String
    @State private var equipmentType: String
    @State private var notes: String
    @State private var editableSets: [EditableSetRow]
    @State private var editMode: Int = 0
    @State private var markdownText: String = ""
    @State private var validationError: String?
    @Environment(\.dismiss) private var dismiss

    init(exercise: SessionExercise, onSave: @escaping (String, String?, String?, [EditExerciseSetChange]) -> Void) {
        self.exercise = exercise
        self.onSave = onSave
        self._name = State(initialValue: exercise.exerciseName)
        self._equipmentType = State(initialValue: exercise.equipmentType ?? "")
        self._notes = State(initialValue: exercise.notes ?? "")
        self._editableSets = State(initialValue: exercise.sets.map { EditableSetRow.from($0) })
        self._markdownText = State(initialValue: Self.generateMarkdown(from: exercise))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $editMode) {
                    Text("Form").tag(0)
                    Text("Markdown").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                .accessibilityIdentifier("edit-exercise-mode-picker")

                if editMode == 0 {
                    formView
                } else {
                    markdownView
                }
            }
            .navigationTitle("Edit Exercise")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("edit-exercise-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveExercise()
                    }
                    .accessibilityIdentifier("edit-exercise-save")
                }
            }
            .onChange(of: editMode) { _, newValue in
                if newValue == 1 {
                    markdownText = generateMarkdownFromForm()
                    validationError = nil
                } else {
                    parseMarkdownIntoForm()
                }
            }
        }
    }

    private var formView: some View {
        Form {
            if let error = validationError {
                Section {
                    Text(error)
                        .font(.lmCaption)
                        .foregroundStyle(LiftMarkTheme.destructive)
                        .accessibilityIdentifier("edit-exercise-form-error")
                }
            }

            Section("Exercise") {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("edit-exercise-name")
                TextField("Equipment", text: $equipmentType)
                    .accessibilityIdentifier("edit-exercise-equipment")
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 60)
                    .accessibilityIdentifier("edit-exercise-notes")
            }

            Section {
                ForEach(Array(editableSets.enumerated()), id: \.element.id) { index, setRow in
                    VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
                        HStack(spacing: LiftMarkTheme.spacingSM) {
                            Text("Set \(index + 1)")
                                .font(.lmSubheadline)
                                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                                .frame(width: 45, alignment: .leading)

                            TextField("Wt", text: $editableSets[index].weightText)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 65)
                                .accessibilityIdentifier("edit-set-weight-\(index)")

                            Text("x")
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)

                            TextField("Reps", text: $editableSets[index].repsText)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .accessibilityIdentifier("edit-set-reps-\(index)")

                            if !setRow.timeText.isEmpty {
                                TextField("Time", text: $editableSets[index].timeText)
                                    #if os(iOS)
                                    .keyboardType(.numberPad)
                                    #endif
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 50)
                                    .accessibilityIdentifier("edit-set-time-\(index)")
                                Text("s")
                                    .font(.lmCaption)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }

                            Spacer()

                            if setRow.status != .pending {
                                Text(setRow.status.rawValue)
                                    .font(.lmCaption2)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                        }

                        HStack(spacing: LiftMarkTheme.spacingSM) {
                            Text("Rest")
                                .font(.lmCaption)
                                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                                .frame(width: 45, alignment: .leading)
                            TextField("Rest", text: $editableSets[index].restText, prompt: Text("none"))
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 65)
                                .accessibilityIdentifier("edit-set-rest-\(index)")
                            Text("s")
                                .font(.lmCaption)
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            Spacer()
                        }
                    }
                }
                .onDelete(perform: deleteSets)
                .onMove(perform: moveSets)

                Button {
                    addSet()
                } label: {
                    Label("Add Set", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("edit-exercise-add-set")
            } header: {
                Text("Sets")
            }
        }
        .accessibilityIdentifier("edit-exercise-form")
    }

    private var markdownView: some View {
        VStack(spacing: LiftMarkTheme.spacingSM) {
            if let error = validationError {
                Text(error)
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.destructive)
                    .padding(.horizontal)
            }

            TextEditor(text: $markdownText)
                .font(.lmMono)
                .padding(.horizontal)
                .accessibilityIdentifier("edit-exercise-markdown")

            Text("lift.md format: ## Name [equipment]\n> notes\n- weight x reps")
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("edit-exercise-markdown-view")
    }

    private func addSet() {
        let lastSet = editableSets.last
        let newSet = EditableSetRow(
            id: UUID().uuidString,
            existingSetId: nil,
            weightText: lastSet?.weightText ?? "",
            repsText: lastSet?.repsText ?? "",
            timeText: lastSet?.timeText ?? "",
            restText: lastSet?.restText ?? "",
            weightUnit: lastSet?.weightUnit,
            status: .pending
        )
        editableSets.append(newSet)
    }

    private func deleteSets(at offsets: IndexSet) {
        editableSets.remove(atOffsets: offsets)
    }

    private func moveSets(from source: IndexSet, to destination: Int) {
        editableSets.move(fromOffsets: source, toOffset: destination)
    }

    private func saveExercise() {
        // When in markdown mode, parse into local variables directly.
        // We cannot rely on @State updates from parseMarkdownIntoForm() because
        // SwiftUI batches state changes — they won't be visible until next render.
        var saveName = name
        var saveNotes = notes
        var saveEquipment = equipmentType
        var saveSets = editableSets

        if editMode == 1 {
            let wrappedMarkdown = "# Workout\n\(markdownText)"
            let result = MarkdownParser.parseWorkout(wrappedMarkdown)
            guard let plan = result.data, let parsedExercise = plan.exercises.first else {
                validationError = result.errors.first ?? "Failed to parse markdown"
                return
            }
            validationError = nil

            saveName = parsedExercise.exerciseName
            saveEquipment = parsedExercise.equipmentType ?? ""
            saveNotes = parsedExercise.notes ?? ""
            let newSets = editableSetRows(from: parsedExercise)
            saveSets = newSets

            // Also update @State for UI consistency
            name = saveName
            equipmentType = saveEquipment
            notes = saveNotes
            editableSets = newSets
        }

        // TC-E14: reject weight-only sets (weight but no reps and no time) so
        // the Form tab matches the Markdown tab / validator / spec. The
        // Markdown path is already parser-validated above, but checking
        // uniformly here keeps the rule in one place.
        if let badIndex = saveSets.firstIndex(where: { $0.isWeightOnly }) {
            let content = formatSetLine(saveSets[badIndex])
            validationError = "Set \(badIndex + 1) — Incomplete set: \"\(content)\". "
                + "Weight with unit requires reps (x 5) or time (x 60s)"
            return
        }
        validationError = nil

        var changes: [EditExerciseSetChange] = []
        let originalSetIds = Set(exercise.sets.map { $0.id })
        let currentSetIds = Set(saveSets.compactMap { $0.existingSetId })

        for originalId in originalSetIds where !currentSetIds.contains(originalId) {
            changes.append(.delete(setId: originalId))
        }

        for setRow in saveSets {
            let weight = Double(setRow.weightText)
            let reps = Int(setRow.repsText)
            let time = Int(setRow.timeText)
            let rest: Int? = {
                guard let r = Int(setRow.restText), r > 0 else { return nil }
                return r
            }()

            if let existingId = setRow.existingSetId {
                changes.append(.update(setId: existingId, weight: weight, reps: reps, time: time, rest: rest))
            } else {
                changes.append(.add(weight: weight, unit: setRow.weightUnit, reps: reps, time: time, rest: rest))
            }
        }

        onSave(
            saveName,
            saveNotes.isEmpty ? nil : saveNotes,
            saveEquipment.isEmpty ? nil : saveEquipment,
            changes
        )
        dismiss()
    }

    private func generateMarkdownFromForm() -> String {
        var lines: [String] = []
        lines.append("## \(name)")
        if !equipmentType.isEmpty {
            lines.append("@type: \(equipmentType)")
        }
        if !notes.isEmpty {
            lines.append(notes)
        }
        for setRow in editableSets {
            lines.append("- \(formatSetLine(setRow))")
        }
        return lines.joined(separator: "\n")
    }

    private func formatSetLine(_ setRow: EditableSetRow) -> String {
        var parts: [String] = []
        if !setRow.weightText.isEmpty {
            parts.append(setRow.weightText)
            if let unit = setRow.weightUnit {
                parts.append(unit.rawValue)
            }
        }
        if !setRow.repsText.isEmpty {
            parts.append("x \(setRow.repsText)")
        }
        if !setRow.timeText.isEmpty {
            parts.append("\(setRow.timeText)s")
        }
        var line = parts.isEmpty ? "x 1" : parts.joined(separator: " ")
        if let rest = Int(setRow.restText), rest > 0 {
            line += " @rest: \(rest)s"
        }
        return line
    }

    static func generateMarkdown(from exercise: SessionExercise) -> String {
        var lines: [String] = []
        lines.append("## \(exercise.exerciseName)")
        if let equip = exercise.equipmentType, !equip.isEmpty {
            lines.append("@type: \(equip)")
        }
        if let notes = exercise.notes, !notes.isEmpty {
            lines.append(notes)
        }
        for set in exercise.sets {
            let target = set.entries.first?.target
            var parts: [String] = []
            if let w = target?.weight?.value {
                let wStr = w.formattedWeight
                parts.append(wStr)
                if let unit = target?.weight?.unit {
                    parts.append(unit.rawValue)
                }
            }
            if let r = target?.reps {
                parts.append("x \(r)")
            }
            if let t = target?.time {
                parts.append("\(t)s")
            }
            var line = parts.joined(separator: " ")
            if let rest = set.restSeconds, rest > 0 {
                line += " @rest: \(rest)s"
            }
            lines.append("- \(line)")
        }
        return lines.joined(separator: "\n")
    }

    private func parseMarkdownIntoForm() {
        let wrappedMarkdown = "# Workout\n\(markdownText)"
        let result = MarkdownParser.parseWorkout(wrappedMarkdown)
        guard let plan = result.data, let parsedExercise = plan.exercises.first else {
            validationError = result.errors.first ?? "Failed to parse markdown"
            return
        }
        validationError = nil
        name = parsedExercise.exerciseName
        equipmentType = parsedExercise.equipmentType ?? ""
        notes = parsedExercise.notes ?? ""
        editableSets = editableSetRows(from: parsedExercise)
    }

    /// Build `EditableSetRow`s from a parsed exercise, preserving existing set IDs and
    /// status by position so that edits update the same session sets instead of
    /// replacing them wholesale.
    private func editableSetRows(from parsedExercise: PlannedExercise) -> [EditableSetRow] {
        var rows: [EditableSetRow] = []
        for (i, parsedSet) in parsedExercise.sets.enumerated() {
            let existingId: String? = i < exercise.sets.count ? exercise.sets[i].id : nil
            let existingStatus: SetStatus = i < exercise.sets.count ? exercise.sets[i].status : .pending
            let parsedTarget = parsedSet.entries.first?.target
            let weightStr: String
            if let w = parsedTarget?.weight?.value {
                weightStr = w.formattedWeight
            } else {
                weightStr = ""
            }
            rows.append(EditableSetRow(
                id: existingId ?? UUID().uuidString,
                existingSetId: existingId,
                weightText: weightStr,
                repsText: parsedTarget?.reps.map { "\($0)" } ?? "",
                timeText: parsedTarget?.time.map { "\($0)" } ?? "",
                restText: parsedSet.restSeconds.map { "\($0)" } ?? "",
                weightUnit: parsedTarget?.weight?.unit,
                status: existingStatus
            ))
        }
        return rows
    }
}
