import SwiftUI

struct WorkoutDetailView: View {
    let planId: String
    var isEmbedded: Bool = false
    @Environment(WorkoutPlanStore.self) private var planStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var showStartConfirm = false
    @State private var showReprocessConfirm = false
    @State private var showEditMarkdown = false
    @State private var navigateToActiveWorkout = false
    @State private var editingPlanExercise: PlannedExercise?
    @State private var exportFile: ExportFile?
    @State private var showExportError = false
    @State private var exportErrorMessage = ""

    private var plan: WorkoutPlan? {
        planStore.getPlan(id: planId)
    }

    /// Group exercises by section (warmup, cooldown, default) then build display items
    private var exerciseSections: [ExerciseDisplaySection] {
        guard let plan else { return [] }
        var sections: [ExerciseDisplaySection] = []
        var currentSectionName: String?
        var currentExercises: [PlannedExercise] = []

        for exercise in plan.exercises {
            let sectionName: String?
            if exercise.groupType == .section {
                sectionName = exercise.groupName
            } else if exercise.parentExerciseId != nil {
                // Children of sections/supersets stay in the current section
                sectionName = currentSectionName
            } else {
                sectionName = nil
            }

            if sectionName != currentSectionName {
                if !currentExercises.isEmpty {
                    sections.append(ExerciseDisplaySection(
                        name: currentSectionName,
                        items: buildPlanDisplayItems(from: currentExercises)
                    ))
                }
                currentSectionName = sectionName
                currentExercises = []
            }
            currentExercises.append(exercise)
        }
        if !currentExercises.isEmpty {
            sections.append(ExerciseDisplaySection(
                name: currentSectionName,
                items: buildPlanDisplayItems(from: currentExercises)
            ))
        }
        return sections
    }

    /// Build display items from a flat list of exercises, grouping supersets
    private func buildPlanDisplayItems(from exercises: [PlannedExercise]) -> [PlanDisplayItem] {
        var items: [PlanDisplayItem] = []
        var processedIds = Set<String>()

        for exercise in exercises {
            if processedIds.contains(exercise.id) { continue }

            if exercise.groupType == .superset && exercise.sets.isEmpty {
                // Superset parent — gather children
                var children: [PlannedExercise] = []
                for child in exercises where child.parentExerciseId == exercise.id {
                    children.append(child)
                    processedIds.insert(child.id)
                }
                processedIds.insert(exercise.id)
                if SupersetGrouping.isRealSuperset(childCount: children.count) {
                    items.append(.superset(parent: exercise, children: children))
                } else {
                    // Single-member superset is not a real superset — render the
                    // lone child as a standalone exercise (no SUPERSET badge),
                    // matching the active workout view.
                    for child in children {
                        items.append(.single(exercise: child))
                    }
                }
            } else if exercise.parentExerciseId != nil {
                // Skip orphan children already handled
                continue
            } else if exercise.groupType == .section && exercise.sets.isEmpty {
                // Section header — gather children. A child that is itself a
                // superset parent must recurse so grandchildren render inside
                // PlanSupersetCard; otherwise the superset parent (no sets)
                // shows as an empty single card and grandchildren are dropped.
                processedIds.insert(exercise.id)
                for child in exercises {
                    guard child.parentExerciseId == exercise.id else { continue }
                    if child.groupType == .superset && child.sets.isEmpty {
                        var grandchildren: [PlannedExercise] = []
                        for grandchild in exercises where grandchild.parentExerciseId == child.id {
                            grandchildren.append(grandchild)
                            processedIds.insert(grandchild.id)
                        }
                        processedIds.insert(child.id)
                        if SupersetGrouping.isRealSuperset(childCount: grandchildren.count) {
                            items.append(.superset(parent: child, children: grandchildren))
                        } else {
                            // Single-member superset inside a section — render the
                            // lone grandchild standalone, matching the active view.
                            for grandchild in grandchildren {
                                items.append(.single(exercise: grandchild))
                            }
                        }
                    } else {
                        items.append(.single(exercise: child))
                        processedIds.insert(child.id)
                    }
                }
            } else {
                items.append(.single(exercise: exercise))
                processedIds.insert(exercise.id)
            }
        }
        return items
    }

    /// Count exercises excluding structural headers (empty section/superset
    /// rows). Shared with the plan list, inbox, and import via `WorkoutPlan`.
    private var exerciseCount: Int {
        plan?.displayExerciseCount ?? 0
    }

    /// Global exercise index (1-based) for numbering, excluding structural headers
    private func globalExerciseIndex(for exercise: PlannedExercise) -> Int {
        guard let plan else { return 1 }
        var index = 0
        for ex in plan.exercises {
            if ex.isStructuralHeader { continue }
            index += 1
            if ex.id == exercise.id { return index }
        }
        return 1
    }

    var body: some View {
        Group {
            if let plan {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                            // Header card
                            headerCard(plan: plan)

                            // Stats grid
                            HStack(spacing: LiftMarkTheme.spacingSM) {
                                WorkoutStatCard(
                                    value: "\(exerciseCount)",
                                    label: "Exercises"
                                )
                                WorkoutStatCard(
                                    value: "\(plan.plannedSetCount)",
                                    label: "Sets"
                                )
                                WorkoutStatCard(
                                    value: plan.defaultWeightUnit?.rawValue.uppercased() ?? "—",
                                    label: "Units"
                                )
                            }

                            // Edit & Reprocess buttons
                            if plan.sourceMarkdown != nil {
                                editReprocessButtons
                            }

                            // Exercises heading
                            Text("Exercises")
                                .font(.lmCallout)
                                .fontWeight(.semibold)
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)

                            // Exercises by section
                            ForEach(Array(exerciseSections.enumerated()), id: \.offset) { _, section in
                                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
                                    // Section header divider
                                    if let sectionName = section.name {
                                        WorkoutSectionHeader(name: sectionName)
                                    }

                                    // Exercises and superset groups
                                    ForEach(section.items) { item in
                                        switch item {
                                        case .single(let exercise):
                                            PlanExerciseCard(
                                                exercise: exercise,
                                                sectionName: section.name,
                                                exerciseIndex: globalExerciseIndex(for: exercise),
                                                onEdit: { editingPlanExercise = exercise }
                                            )
                                        case .superset(let parent, let children):
                                            PlanSupersetCard(
                                                parent: parent,
                                                children: children,
                                                sectionName: section.name,
                                                exerciseIndex: { globalExerciseIndex(for: $0) },
                                                onEditChild: { editingPlanExercise = $0 },
                                                onEdit: { editingPlanExercise = parent }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                    .accessibilityIdentifier("workout-detail-view")

                    Divider()

                    // Start Workout Button — pinned to bottom
                    startWorkoutButton
                }
            } else {
                VStack {
                    ProgressView()
                    Text("Loading...")
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("workout-detail-loading")
            }
        }
        .navigationTitle(isEmbedded ? "" : (plan?.name ?? "Workout Details"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(isEmbedded ? .inline : .large)
        #endif
        .toolbar {
            if plan != nil && !isEmbedded {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        sharePlan()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("share-plan-button")
                }
            }
        }
        .navigationDestination(isPresented: $navigateToActiveWorkout) {
            ActiveWorkoutView()
        }
        .shareSheet(item: $exportFile)
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage)
        }
        .onAppear {
            if plan == nil && !isEmbedded {
                dismiss()
            }
        }
        .alert("Replace Active Workout?", isPresented: $showStartConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) {
                sessionStore.cancelSession()
                startWorkout()
            }
        } message: {
            Text("You have an active workout in progress. Starting a new one will discard it.")
        }
        .alert("Reprocess from Markdown?", isPresented: $showReprocessConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reprocess", role: .destructive) {
                reprocessPlan()
            }
        } message: {
            Text("This will re-parse the plan from its original markdown. Any manual changes will be lost.")
        }
        .sheet(isPresented: $showEditMarkdown) {
            if let plan {
                EditPlanMarkdownSheet(planId: plan.id, initialMarkdown: plan.sourceMarkdown ?? "")
            }
        }
        .sheet(item: $editingPlanExercise) { exercise in
            let supersetChildren = (plan?.exercises.filter { $0.parentExerciseId == exercise.id }) ?? []
            EditPlanExerciseSheet(exercise: exercise, children: supersetChildren) { updatedExercises in
                guard var currentPlan = plan, !updatedExercises.isEmpty else { return }
                if updatedExercises.count == 1 {
                    if let idx = currentPlan.exercises.firstIndex(where: { $0.id == exercise.id }) {
                        currentPlan.exercises[idx] = updatedExercises[0]
                    }
                } else {
                    // Superset: replace parent + all old children with the new
                    // parent + new children, then renumber orderIndex so the
                    // section's exercises stay sequential.
                    let oldChildIds = Set(currentPlan.exercises.filter { $0.parentExerciseId == exercise.id }.map { $0.id })
                    currentPlan.exercises.removeAll { oldChildIds.contains($0.id) }
                    if let parentIdx = currentPlan.exercises.firstIndex(where: { $0.id == exercise.id }) {
                        currentPlan.exercises[parentIdx] = updatedExercises[0]
                        let newChildren = Array(updatedExercises.dropFirst())
                        currentPlan.exercises.insert(contentsOf: newChildren, at: parentIdx + 1)
                    }
                    for i in 0..<currentPlan.exercises.count {
                        currentPlan.exercises[i].orderIndex = i
                    }
                }
                // Persist the edit by splicing only this exercise's block back
                // into the original markdown, preserving every other block's
                // header level and formatting. Regenerating the whole document
                // flattened all headers to `##` (GH #264). When the plan has no
                // stored markdown, or the block can't be located, fall back to a
                // plain model update and leave `sourceMarkdown` untouched.
                if let source = currentPlan.sourceMarkdown,
                   let spliced = LMWFSourceEditor.replacingExercise(
                    orderIndex: exercise.orderIndex,
                    in: source,
                    with: updatedExercises
                   ) {
                    planStore.updatePlanMarkdown(id: currentPlan.id, newMarkdown: spliced)
                } else {
                    planStore.updatePlan(currentPlan)
                }
            }
        }
    }

    // MARK: - Header Card

    @ViewBuilder
    private func headerCard(plan: WorkoutPlan) -> some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            // Plan name + favorite
            HStack(alignment: .top) {
                Text(plan.name)
                    .font(.lmTitle2)
                    .fontWeight(.bold)

                Spacer()

                Button {
                    planStore.toggleFavorite(id: planId)
                } label: {
                    Image(systemName: plan.isFavorite ? "heart.fill" : "heart")
                        .font(.lmTitle3)
                        .foregroundStyle(plan.isFavorite ? .red : LiftMarkTheme.tertiaryLabel)
                        .frame(width: 36, height: 36)
                }
                .accessibilityIdentifier("favorite-button-detail")
            }

            // Description
            if let description = plan.description, !description.isEmpty {
                Text(description)
                    .font(.lmBody)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }

            // Tags
            if !plan.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(plan.tags, id: \.self) { tag in
                        Text(tag.lowercased())
                            .font(.lmCaption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(LiftMarkTheme.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(LiftMarkTheme.primary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding()
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
    }

    // MARK: - Edit & Reprocess Buttons

    private var editReprocessButtons: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            Button {
                showEditMarkdown = true
            } label: {
                Label("Edit", systemImage: "pencil.line")
                    .font(.lmSubheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LiftMarkTheme.spacingSM)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(LiftMarkTheme.primary)
            .accessibilityIdentifier("edit-plan-markdown-button")

            Button {
                showReprocessConfirm = true
            } label: {
                Label("Reprocess", systemImage: "arrow.clockwise")
                    .font(.lmSubheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LiftMarkTheme.spacingSM)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(LiftMarkTheme.primary)
            .accessibilityIdentifier("reprocess-plan-button")
        }
    }

    // MARK: - Start Workout Button

    private var startWorkoutButton: some View {
        Button {
            if sessionStore.activeSession != nil {
                showStartConfirm = true
            } else {
                startWorkout()
            }
        } label: {
            Text(sessionStore.activeSession != nil ? "Replace Active Workout" : "Start Workout")
                .font(.lmHeadline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(LiftMarkTheme.primary)
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
        .accessibilityIdentifier("start-workout-button")
        .padding(.horizontal)
        .padding(.vertical, LiftMarkTheme.spacingSM)
        .background(LiftMarkTheme.background)
    }

    // MARK: - Helpers

    private func startWorkout() {
        guard let plan else { return }
        let session = sessionStore.startSession(from: plan)
        if session != nil {
            navigateToActiveWorkout = true
        }
    }

    private func sharePlan() {
        guard let plan else { return }
        do {
            let url = try WorkoutExportService().exportPlanAsMarkdown(plan)
            exportFile = ExportFile(url: url)
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }

    private func reprocessPlan() {
        guard let plan, let markdown = plan.sourceMarkdown else { return }
        planStore.reprocessPlan(id: plan.id, fromMarkdown: markdown)
    }

}
