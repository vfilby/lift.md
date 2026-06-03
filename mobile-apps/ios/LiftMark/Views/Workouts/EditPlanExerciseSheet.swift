import SwiftUI

// MARK: - Editable Plan Set Row

struct EditablePlanSetRow: Identifiable {
    let id: String
    var weightText: String
    var repsText: String
    var timeText: String
    var weightUnit: WeightUnit?

    static func from(_ set: PlannedSet) -> EditablePlanSetRow {
        let target = set.entries.first?.target
        return EditablePlanSetRow(
            id: set.id,
            weightText: {
                if let w = target?.weight?.value {
                    return w.formattedWeight
                }
                return ""
            }(),
            repsText: target?.reps.map { "\($0)" } ?? "",
            timeText: target?.time.map { "\($0)" } ?? "",
            weightUnit: target?.weight?.unit
        )
    }
}

// MARK: - Edit Plan Exercise Sheet

struct EditPlanExerciseSheet: View {
    let exercise: PlannedExercise
    let children: [PlannedExercise]
    let onSave: ([PlannedExercise]) -> Void
    @State private var name: String
    @State private var equipmentType: String
    @State private var notes: String
    @State private var editableSets: [EditablePlanSetRow]
    @State private var editMode: Int
    @State private var markdownText: String = ""
    @State private var markdownError: String?
    @Environment(\.dismiss) private var dismiss

    /// Superset parents have no sets and contain children. The form view can't
    /// represent the hierarchy, so editing routes exclusively through markdown.
    private var isSuperset: Bool {
        exercise.groupType == .superset && exercise.sets.isEmpty
    }

    init(exercise: PlannedExercise, children: [PlannedExercise] = [], onSave: @escaping ([PlannedExercise]) -> Void) {
        self.exercise = exercise
        self.children = children
        self.onSave = onSave
        self._name = State(initialValue: exercise.exerciseName)
        self._equipmentType = State(initialValue: exercise.equipmentType ?? "")
        self._notes = State(initialValue: exercise.notes ?? "")
        self._editableSets = State(initialValue: exercise.sets.map { EditablePlanSetRow.from($0) })
        let isSupersetParent = exercise.groupType == .superset && exercise.sets.isEmpty
        self._editMode = State(initialValue: isSupersetParent ? 1 : 0)
        let initialMarkdown = isSupersetParent
            ? Self.generateSupersetMarkdown(parent: exercise, children: children)
            : Self.generateMarkdown(from: exercise)
        self._markdownText = State(initialValue: initialMarkdown)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !isSuperset {
                    Picker("Mode", selection: $editMode) {
                        Text("Form").tag(0)
                        Text("Markdown").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    .accessibilityIdentifier("edit-plan-exercise-mode-picker")
                } else {
                    Text("Edit superset block — children are nested under #### headings")
                        .font(.lmCaption)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, LiftMarkTheme.spacingSM)
                }

                if isSuperset || editMode == 1 {
                    markdownView
                } else {
                    formView
                }
            }
            .navigationTitle("Edit Exercise")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("edit-plan-exercise-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveExercise()
                    }
                    .accessibilityIdentifier("edit-plan-exercise-save")
                }
            }
            .onChange(of: editMode) { _, newValue in
                if newValue == 1 {
                    markdownText = generateMarkdownFromForm()
                    markdownError = nil
                } else {
                    parseMarkdownIntoForm()
                }
            }
        }
    }

    private var formView: some View {
        Form {
            Section("Exercise") {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("edit-plan-exercise-name")
                TextField("Equipment", text: $equipmentType)
                    .accessibilityIdentifier("edit-plan-exercise-equipment")
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 60)
                    .accessibilityIdentifier("edit-plan-exercise-notes")
            }

            Section {
                ForEach(Array(editableSets.enumerated()), id: \.element.id) { index, setRow in
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
                            .accessibilityIdentifier("edit-plan-set-weight-\(index)")

                        Text("x")
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)

                        TextField("Reps", text: $editableSets[index].repsText)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                            .accessibilityIdentifier("edit-plan-set-reps-\(index)")

                        TextField("Time", text: $editableSets[index].timeText)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                            .accessibilityIdentifier("edit-plan-set-time-\(index)")
                        Text("s")
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)

                        Spacer()
                    }
                }
                .onDelete(perform: deleteSets)
                .onMove(perform: moveSets)

                Button {
                    addSet()
                } label: {
                    Label("Add Set", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("edit-plan-exercise-add-set")
            } header: {
                Text("Sets")
            }
        }
        .accessibilityIdentifier("edit-plan-exercise-form")
    }

    private var markdownView: some View {
        VStack(spacing: LiftMarkTheme.spacingSM) {
            if let error = markdownError {
                Text(error)
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.destructive)
                    .padding(.horizontal)
            }

            TextEditor(text: $markdownText)
                .font(.lmMono)
                .padding(.horizontal)
                .accessibilityIdentifier("edit-plan-exercise-markdown")

            Text("lift.md format: ## Name [equipment]\n> notes\n- weight x reps")
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("edit-plan-exercise-markdown-view")
    }

    private func addSet() {
        let lastSet = editableSets.last
        let newSet = EditablePlanSetRow(
            id: UUID().uuidString,
            weightText: lastSet?.weightText ?? "",
            repsText: lastSet?.repsText ?? "",
            timeText: lastSet?.timeText ?? "",
            weightUnit: lastSet?.weightUnit
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
        if isSuperset {
            saveSupersetFromMarkdown()
            return
        }

        var saveName = name
        var saveNotes = notes
        var saveEquipment = equipmentType
        var saveSets = editableSets

        if editMode == 1 {
            let wrappedMarkdown = "# Workout\n\(markdownText)"
            let result = MarkdownParser.parseWorkout(wrappedMarkdown)
            guard let plan = result.data, let parsedExercise = plan.exercises.first else {
                markdownError = result.errors.first ?? "Failed to parse markdown"
                return
            }
            markdownError = nil

            saveName = parsedExercise.exerciseName
            saveEquipment = parsedExercise.equipmentType ?? ""
            saveNotes = parsedExercise.notes ?? ""

            var newSets: [EditablePlanSetRow] = []
            for (i, parsedSet) in parsedExercise.sets.enumerated() {
                let existingId: String? = i < exercise.sets.count ? exercise.sets[i].id : nil
                let parsedTarget = parsedSet.entries.first?.target
                let weightVal = parsedTarget?.weight?.value
                let weightStr: String = weightVal.map {
                    $0.formattedWeight
                } ?? ""
                newSets.append(EditablePlanSetRow(
                    id: existingId ?? UUID().uuidString,
                    weightText: weightStr,
                    repsText: parsedTarget?.reps.map { "\($0)" } ?? "",
                    timeText: parsedTarget?.time.map { "\($0)" } ?? "",
                    weightUnit: parsedTarget?.weight?.unit
                ))
            }
            saveSets = newSets

            name = saveName
            equipmentType = saveEquipment
            notes = saveNotes
            editableSets = newSets
        }

        // Build the updated PlannedExercise
        var updatedExercise = exercise
        updatedExercise.exerciseName = saveName
        updatedExercise.equipmentType = saveEquipment.isEmpty ? nil : saveEquipment
        updatedExercise.notes = saveNotes.isEmpty ? nil : saveNotes

        var newPlannedSets: [PlannedSet] = []
        for (index, setRow) in saveSets.enumerated() {
            let weight = Double(setRow.weightText)
            let reps = Int(setRow.repsText)
            let time = Int(setRow.timeText)
            // Preserve existing set if possible, otherwise create new
            let existingSet: PlannedSet? = index < exercise.sets.count && setRow.id == exercise.sets[index].id
                ? exercise.sets[index] : nil

            var plannedSet = existingSet ?? PlannedSet(
                id: setRow.id,
                plannedExerciseId: exercise.id,
                orderIndex: index
            )
            plannedSet.orderIndex = index
            plannedSet.targetWeight = weight
            plannedSet.targetWeightUnit = setRow.weightUnit ?? existingSet?.targetWeightUnit
            plannedSet.targetReps = reps
            plannedSet.targetTime = time
            newPlannedSets.append(plannedSet)
        }
        updatedExercise.sets = newPlannedSets

        onSave([updatedExercise])
        dismiss()
    }

    /// Parse the user's superset markdown and emit the parent + all children as
    /// a single replacement set. Wraps the input as a workout/section so the
    /// parser interprets `### name` as a superset header (when name contains
    /// "superset") and nested `#### child` headings as superset children.
    private func saveSupersetFromMarkdown() {
        let wrappedMarkdown = "# Workout\n## Main\n\(markdownText)"
        let result = MarkdownParser.parseWorkout(wrappedMarkdown)
        guard let plan = result.data else {
            markdownError = result.errors.first ?? "Failed to parse markdown"
            return
        }
        guard let parsedParent = plan.exercises.first(where: { $0.groupType == .superset && $0.sets.isEmpty }) else {
            markdownError = "Couldn't find a superset header — make sure the first line starts with '### Superset:'"
            return
        }
        let parsedChildren = plan.exercises.filter { $0.parentExerciseId == parsedParent.id }
        guard !parsedChildren.isEmpty else {
            markdownError = "Superset needs at least one child exercise (nested under ####)"
            return
        }

        // Preserve the original parent's ID, section parentage, ordering, and
        // groupName so existing references in the plan stay stable. Children
        // get re-linked to that preserved parent ID.
        var finalParent = parsedParent
        finalParent.id = exercise.id
        finalParent.parentExerciseId = exercise.parentExerciseId
        finalParent.orderIndex = exercise.orderIndex
        finalParent.groupType = .superset
        finalParent.groupName = exercise.groupName

        let finalChildren = parsedChildren.map { child -> PlannedExercise in
            var c = child
            c.parentExerciseId = finalParent.id
            c.groupType = .superset
            c.groupName = finalParent.groupName
            return c
        }

        markdownError = nil
        onSave([finalParent] + finalChildren)
        dismiss()
    }

    /// Build a `### Superset:\n#### child\n…` block with each child's notes
    /// and sets, suitable for round-tripping through the parser.
    private static func generateSupersetMarkdown(parent: PlannedExercise, children: [PlannedExercise]) -> String {
        var lines: [String] = []
        lines.append("### \(parent.exerciseName)")
        if let notes = parent.notes, !notes.isEmpty {
            lines.append(notes)
        }
        for child in children {
            lines.append("")
            lines.append("#### \(child.exerciseName)")
            if let equip = child.equipmentType, !equip.isEmpty {
                lines.append("@type: \(equip)")
            }
            if let notes = child.notes, !notes.isEmpty {
                lines.append(notes)
            }
            for set in child.sets {
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
                lines.append("- \(parts.joined(separator: " "))")
            }
        }
        return lines.joined(separator: "\n")
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

    private func formatSetLine(_ setRow: EditablePlanSetRow) -> String {
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
        return parts.isEmpty ? "x 1" : parts.joined(separator: " ")
    }

    static func generateMarkdown(from exercise: PlannedExercise) -> String {
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
            lines.append("- \(parts.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    private func parseMarkdownIntoForm() {
        let wrappedMarkdown = "# Workout\n\(markdownText)"
        let result = MarkdownParser.parseWorkout(wrappedMarkdown)
        guard let plan = result.data, let parsedExercise = plan.exercises.first else {
            markdownError = result.errors.first ?? "Failed to parse markdown"
            return
        }
        markdownError = nil
        name = parsedExercise.exerciseName
        equipmentType = parsedExercise.equipmentType ?? ""
        notes = parsedExercise.notes ?? ""

        var newSets: [EditablePlanSetRow] = []
        for (i, parsedSet) in parsedExercise.sets.enumerated() {
            let existingId: String? = i < exercise.sets.count ? exercise.sets[i].id : nil
            let parsedTarget = parsedSet.entries.first?.target
            let weightVal = parsedTarget?.weight?.value
            let weightStr: String = weightVal.map {
                $0.formattedWeight
            } ?? ""
            newSets.append(EditablePlanSetRow(
                id: existingId ?? UUID().uuidString,
                weightText: weightStr,
                repsText: parsedTarget?.reps.map { "\($0)" } ?? "",
                timeText: parsedTarget?.time.map { "\($0)" } ?? "",
                weightUnit: parsedTarget?.weight?.unit
            ))
        }
        editableSets = newSets
    }
}
