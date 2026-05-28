import SwiftUI

struct WorkoutsView: View {
    @Environment(WorkoutPlanStore.self) private var planStore
    @Environment(GymStore.self) private var gymStore
    @Environment(EquipmentStore.self) private var equipmentStore
    @Environment(NavigationCoordinator.self) private var navCoordinator
    @Environment(InboxPollerService.self) private var inboxPoller
    @Environment(FeatureFlagsStore.self) private var featureFlags
    @State private var searchText = ""
    @State private var showFavoritesOnly = false
    @State private var showEquipmentFilter = false
    @State private var showFilters = false
    @State private var selectedGymId: String?
    @State private var showImport = false
    @State private var selectedPlanId: String?
    @State private var exportFile: ExportFile?
    @State private var showExportError = false
    @State private var exportErrorMessage = ""

    private var filteredPlans: [WorkoutPlan] {
        planStore.plans.filter { plan in
            let matchesSearch = searchText.isEmpty || plan.name.localizedCaseInsensitiveContains(searchText)
            let matchesFavorite = !showFavoritesOnly || plan.isFavorite
            let matchesEquipment = !showEquipmentFilter || planMatchesEquipment(plan)
            return matchesSearch && matchesFavorite && matchesEquipment
        }
    }

    var body: some View {
        AdaptiveSplitView {
            // iPad sidebar - plan list
            ScrollView {
                LazyVStack(spacing: 0) {
                    if featureFlags.isEnabled(.workoutInbox) {
                        InboxSectionView()
                    }
                    filterToggle
                    if showFilters {
                        filterPanel
                    }
                    if filteredPlans.isEmpty {
                        emptyStateView
                    } else {
                        LazyVStack(spacing: LiftMarkTheme.spacingSM) {
                            ForEach(Array(filteredPlans.enumerated()), id: \.element.id) { index, plan in
                                iPadPlanRow(plan: plan, index: index)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, LiftMarkTheme.spacingSM)
                        .accessibilityIdentifier("workout-list")
                    }
                }
            }
            .refreshable {
                await inboxPoller.pollIfAuthenticated()
            }
        } detail: {
            // iPad detail - plan detail
            if let selectedPlanId {
                WorkoutDetailView(planId: selectedPlanId, isEmbedded: true)
            } else {
                ContentUnavailableView("Select a Plan", systemImage: "doc.on.clipboard", description: Text("Choose a plan from the sidebar."))
            }
        } compact: {
            iPhoneLayout
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workouts-screen")
        .navigationTitle("Plans")
        // The system `.searchable` modifier anchors to the top of the
        // screen and floats over content on pull. We want the modern
        // Mail/Safari pattern: a fixed search field above the tab bar
        // that does not move when the user scrolls. `safeAreaInset`
        // pins our own search bar to the bottom safe area and keeps the
        // scroll content correctly inset above it.
        .safeAreaInset(edge: .bottom) {
            bottomSearchBar
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showImport = true
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "plus")
                        Text("Import")
                    }
                }
            }
            if selectedPlanId != nil {
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
        .sheet(isPresented: $showImport) {
            ImportView()
        }
        .shareSheet(item: $exportFile)
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage)
        }
        .navigationDestination(for: AppDestination.self) { destination in
            switch destination {
            case .workoutDetail(let id):
                WorkoutDetailView(planId: id)
            case .gymDetail(let id):
                GymDetailView(gymId: id)
            default:
                EmptyView()
            }
        }
        .onChange(of: planStore.plans) {
            if let id = selectedPlanId, planStore.getPlan(id: id) == nil {
                selectedPlanId = nil
            }
        }
        .onChange(of: navCoordinator.pendingPlanId) {
            if let id = navCoordinator.pendingPlanId {
                selectedPlanId = id
                navCoordinator.pendingPlanId = nil
            }
        }
        .onAppear {
            if let id = navCoordinator.pendingPlanId {
                selectedPlanId = id
                navCoordinator.pendingPlanId = nil
            }
        }
    }

    @ViewBuilder
    private var iPadPlansList: some View {
        if filteredPlans.isEmpty {
            emptyStateView
        } else {
            ScrollView {
                LazyVStack(spacing: LiftMarkTheme.spacingSM) {
                    ForEach(Array(filteredPlans.enumerated()), id: \.element.id) { index, plan in
                        iPadPlanRow(plan: plan, index: index)
                    }
                }
                .padding(.horizontal)
            }
            .accessibilityIdentifier("workout-list")
        }
    }

    private func iPadPlanRow(plan: WorkoutPlan, index: Int) -> some View {
        Button {
            selectedPlanId = plan.id
        } label: {
            planRowContent(plan: plan)
                .background(selectedPlanId == plan.id ? LiftMarkTheme.primary.opacity(0.12) : LiftMarkTheme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout-card-\(plan.id)")
        .overlay(
            Color.clear
                .accessibilityIdentifier("workout-card-index-\(index)")
        )
        .contextMenu {
            Button {
                planStore.toggleFavorite(id: plan.id)
            } label: {
                Label(plan.isFavorite ? "Unfavorite" : "Favorite", systemImage: plan.isFavorite ? "heart.slash" : "heart")
            }
            Button(role: .destructive) {
                planStore.deletePlan(id: plan.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("delete-\(plan.id)")
        }
    }

    // MARK: - iPhone Layout

    private var iPhoneLayout: some View {
        // Single ScrollView so pull-to-refresh applies to both the Inbox
        // card and the plans list. `.refreshable` here triggers an inbox
        // poll regardless of where the user pulls from.
        ScrollView {
            LazyVStack(spacing: 0) {
                if featureFlags.isEnabled(.workoutInbox) {
                    InboxSectionView()
                }
                filterToggle
                if showFilters {
                    filterPanel
                }
                if filteredPlans.isEmpty {
                    emptyStateView
                } else {
                    LazyVStack(spacing: LiftMarkTheme.spacingSM) {
                        ForEach(Array(filteredPlans.enumerated()), id: \.element.id) { index, plan in
                            planRow(plan: plan, index: index)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, LiftMarkTheme.spacingSM)
                    .accessibilityIdentifier("workout-list")
                }
            }
        }
        .refreshable {
            await inboxPoller.pollIfAuthenticated()
        }
    }

    // MARK: - Bottom Search Bar

    private var bottomSearchBar: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .font(.system(size: 14))
                .accessibilityHidden(true)
            TextField("Search plans", text: $searchText)
                .font(.body)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, LiftMarkTheme.spacingMD)
        .padding(.vertical, LiftMarkTheme.spacingSM)
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(LiftMarkTheme.tertiaryLabel.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, LiftMarkTheme.spacingMD)
        .padding(.bottom, LiftMarkTheme.spacingSM)
        .background(.bar)
        .accessibilityIdentifier("search-input")
    }

    // MARK: - Filter Toggle

    private var filterToggle: some View {
        Button {
            withAnimation { showFilters.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(showFilters ? 90 : 0))
                Text(showFilters ? "Hide Filters" : "Show Filters")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
            }
            .foregroundStyle(LiftMarkTheme.primary)
        }
        .padding(.horizontal)
        .padding(.bottom, LiftMarkTheme.spacingXS)
        .accessibilityIdentifier("filter-toggle")
        .accessibilityLabel(showFilters ? "Hide filters" : "Show filters")
        .accessibilityHint("Toggles filter options for favorites and equipment")
    }

    // MARK: - Filter Panel

    private var filterPanel: some View {
        VStack(spacing: LiftMarkTheme.spacingMD) {
            HStack {
                Text("Favorites Only")
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                Toggle("", isOn: $showFavoritesOnly)
                    .labelsHidden()
            }
            .accessibilityIdentifier("switch-filter-favorites")

            HStack {
                Text("Filter by Equipment")
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                Toggle("", isOn: $showEquipmentFilter)
                    .labelsHidden()
            }
            .accessibilityIdentifier("switch-filter-equipment")
            .onChange(of: showEquipmentFilter) {
                if showEquipmentFilter, let defaultGym = gymStore.gyms.first(where: { $0.isDefault }) {
                    selectedGymId = defaultGym.id
                    equipmentStore.loadEquipment(forGym: defaultGym.id)
                }
            }

            if showEquipmentFilter {
                gymSelectionList
            }
        }
        .padding(.horizontal, LiftMarkTheme.spacingLG)
        .padding(.vertical, LiftMarkTheme.spacingMD)
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        .padding(.horizontal)
        .padding(.bottom, LiftMarkTheme.spacingSM)
    }

    private var gymSelectionList: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
            Text("GYM")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .textCase(.uppercase)

            ForEach(gymStore.gyms) { gym in
                Button {
                    selectedGymId = gym.id
                    equipmentStore.loadEquipment(forGym: gym.id)
                } label: {
                    HStack(spacing: LiftMarkTheme.spacingSM) {
                        ZStack {
                            Circle()
                                .stroke(selectedGymId == gym.id ? LiftMarkTheme.primary : LiftMarkTheme.tertiaryLabel, lineWidth: 2)
                                .frame(width: 20, height: 20)
                            if selectedGymId == gym.id {
                                Circle()
                                    .fill(LiftMarkTheme.primary)
                                    .frame(width: 10, height: 10)
                            }
                        }
                        Text(gym.name)
                            .font(.body)
                            .foregroundStyle(LiftMarkTheme.label)
                    }
                    .padding(.horizontal, LiftMarkTheme.spacingMD)
                    .padding(.vertical, LiftMarkTheme.spacingSM)
                    .background(selectedGymId == gym.id ? LiftMarkTheme.primary.opacity(0.1) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM))
                }
                .accessibilityIdentifier("gym-option-\(gym.id)")
            }
        }
    }

    // MARK: - Plans Content

    @ViewBuilder
    private var plansContent: some View {
        if filteredPlans.isEmpty {
            emptyStateView
        } else {
            plansList
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: LiftMarkTheme.spacingMD) {
            Spacer()
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 48))
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                .accessibilityHidden(true)
            Text(emptyStateTitle)
                .font(.title3)
                .fontWeight(.semibold)
            Text(emptyStateMessage)
                .font(.body)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .multilineTextAlignment(.center)

            if showEquipmentFilter {
                NavigationLink(value: AppDestination.gymDetail(id: selectedGymId ?? "")) {
                    Text("Set Up Equipment")
                        .font(.headline)
                        .padding(.horizontal, LiftMarkTheme.spacingLG)
                        .padding(.vertical, LiftMarkTheme.spacingXS)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("button-setup-equipment")
            } else if planStore.plans.isEmpty {
                Button {
                    showImport = true
                } label: {
                    Text("Import Plan")
                        .font(.headline)
                        .padding(.horizontal, LiftMarkTheme.spacingLG)
                        .padding(.vertical, LiftMarkTheme.spacingXS)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("button-import-empty")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("empty-state")
    }

    private var plansList: some View {
        ScrollView {
            LazyVStack(spacing: LiftMarkTheme.spacingSM) {
                ForEach(Array(filteredPlans.enumerated()), id: \.element.id) { index, plan in
                    planRow(plan: plan, index: index)
                }
            }
            .padding(.horizontal)
        }
        .accessibilityIdentifier("workout-list")
    }

    // MARK: - Plan Row

    private func planRowContent(plan: WorkoutPlan) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: LiftMarkTheme.spacingXS) {
                    Text(plan.name)
                        .font(.headline)
                        .foregroundStyle(LiftMarkTheme.label)
                        .lineLimit(1)
                    if plan.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                            .accessibilityLabel("Favorite")
                    }
                }
                HStack(spacing: LiftMarkTheme.spacingSM) {
                    let exerciseCount = plan.exercises.filter { exercise in
                        !(exercise.groupType == .superset && exercise.sets.isEmpty) &&
                        !(exercise.groupType == .section && exercise.sets.isEmpty)
                    }.count
                    Text("\(exerciseCount) exercises")
                        .font(.subheadline)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    if !plan.tags.isEmpty {
                        Text(plan.tags.prefix(2).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func planRow(plan: WorkoutPlan, index: Int) -> some View {
        NavigationLink(value: AppDestination.workoutDetail(id: plan.id)) {
            planRowContent(plan: plan)
                .background(LiftMarkTheme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout-card-\(plan.id)")
        .overlay(
            Color.clear
                .accessibilityIdentifier("workout-card-index-\(index)")
        )
        .contextMenu {
            Button {
                planStore.toggleFavorite(id: plan.id)
            } label: {
                Label(plan.isFavorite ? "Unfavorite" : "Favorite", systemImage: plan.isFavorite ? "heart.slash" : "heart")
            }
            Button(role: .destructive) {
                planStore.deletePlan(id: plan.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("delete-\(plan.id)")
        }
    }

    private var emptyStateTitle: String {
        if showEquipmentFilter {
            return "No plans available"
        } else if showFavoritesOnly {
            return "No favorites"
        } else if !searchText.isEmpty {
            return "No plans found"
        }
        return "No plans yet"
    }

    private var emptyStateMessage: String {
        if showEquipmentFilter {
            return "All plans require unavailable equipment. Update your gym setup."
        } else if showFavoritesOnly {
            return "No favorite plans yet. Swipe right on a plan to favorite it."
        } else if !searchText.isEmpty {
            return "Try a different search term"
        }
        return "Import your first workout plan to get started"
    }

    private func sharePlan() {
        guard let id = selectedPlanId,
              let plan = planStore.getPlan(id: id) else { return }
        do {
            let url = try WorkoutExportService().exportPlanAsMarkdown(plan)
            exportFile = ExportFile(url: url)
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }

    private func planMatchesEquipment(_ plan: WorkoutPlan) -> Bool {
        let availableEquipment = Set(equipmentStore.equipment.filter(\.isAvailable).map { $0.name.lowercased() })
        guard !availableEquipment.isEmpty else { return true }
        for exercise in plan.exercises {
            if let eq = exercise.equipmentType, !availableEquipment.contains(eq.lowercased()) {
                return false
            }
        }
        return true
    }
}
