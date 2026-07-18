import SwiftUI

// MARK: - Plan Row Content

/// Shared label for a plan row — used by both the iPhone NavigationLink row
/// and the iPad selection-button row in `WorkoutsView`.
struct WorkoutPlanRowContent: View {
    let plan: WorkoutPlan

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: LiftMarkTheme.spacingXS) {
                    Text(plan.name)
                        .font(.lmHeadline)
                        .foregroundStyle(LiftMarkTheme.label)
                        .lineLimit(1)
                    if plan.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.lmCaption)
                            .foregroundStyle(.pink)
                            .accessibilityLabel("Favorite")
                    }
                }
                HStack(spacing: LiftMarkTheme.spacingSM) {
                    Text("\(plan.displayExerciseCount) exercises")
                        .font(.lmSubheadline)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    if !plan.tags.isEmpty {
                        Text(plan.tags.prefix(2).joined(separator: ", "))
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

// MARK: - Filter Panel

/// Favorites/equipment filter controls plus the gym picker shown when the
/// equipment filter is enabled.
struct WorkoutsFilterPanel: View {
    @Binding var showFavoritesOnly: Bool
    @Binding var showEquipmentFilter: Bool
    @Binding var selectedGymId: String?
    @Environment(GymStore.self) private var gymStore
    @Environment(EquipmentStore.self) private var equipmentStore

    var body: some View {
        VStack(spacing: LiftMarkTheme.spacingMD) {
            HStack {
                Text("Favorites Only")
                    .font(.lmBody)
                    .fontWeight(.medium)
                Spacer()
                Toggle("", isOn: $showFavoritesOnly)
                    .labelsHidden()
            }
            .accessibilityIdentifier("switch-filter-favorites")

            HStack {
                Text("Filter by Equipment")
                    .font(.lmBody)
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
                .font(.lmCaption)
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
                                .stroke(
                                    selectedGymId == gym.id ? LiftMarkTheme.primary : LiftMarkTheme.tertiaryLabel,
                                    lineWidth: 2)
                                .frame(width: 20, height: 20)
                            if selectedGymId == gym.id {
                                Circle()
                                    .fill(LiftMarkTheme.primary)
                                    .frame(width: 10, height: 10)
                            }
                        }
                        Text(gym.name)
                            .font(.lmBody)
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
}

// MARK: - Bottom Search Bar

/// Fixed search field pinned above the tab bar (Mail/Safari pattern).
struct WorkoutsBottomSearchBar: View {
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .font(.system(size: 14))
                .accessibilityHidden(true)
            TextField("Search plans", text: $searchText)
                .font(.lmBody)
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
}

// MARK: - Empty State

/// Empty state shown when the (filtered) plan list has nothing to display.
struct WorkoutsEmptyStateView: View {
    let showEquipmentFilter: Bool
    let showFavoritesOnly: Bool
    let searchText: String
    let selectedGymId: String?
    let hasNoPlans: Bool
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: LiftMarkTheme.spacingMD) {
            Spacer()
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 48))
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                .accessibilityHidden(true)
            Text(emptyStateTitle)
                .font(.lmTitle3)
                .fontWeight(.semibold)
            Text(emptyStateMessage)
                .font(.lmBody)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .multilineTextAlignment(.center)

            if showEquipmentFilter {
                NavigationLink(value: AppDestination.gymDetail(id: selectedGymId ?? "")) {
                    Text("Set Up Equipment")
                        .font(.lmHeadline)
                        .padding(.horizontal, LiftMarkTheme.spacingLG)
                        .padding(.vertical, LiftMarkTheme.spacingXS)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("button-setup-equipment")
            } else if hasNoPlans {
                Button {
                    onImport()
                } label: {
                    Text("Import Plan")
                        .font(.lmHeadline)
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
}
