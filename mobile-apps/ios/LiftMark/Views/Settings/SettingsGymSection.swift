import SwiftUI

struct SettingsGymSection: View {
    @Environment(GymStore.self) private var gymStore

    var body: some View {
        ForEach(gymStore.gyms) { gym in
            NavigationLink(value: AppDestination.gymDetail(id: gym.id)) {
                HStack {
                    Image(systemName: gym.isDefault ? "star.fill" : "star")
                        .foregroundStyle(gym.isDefault ? LiftMarkTheme.warning : LiftMarkTheme.secondaryLabel)
                    Text(gym.name)
                    Spacer()
                    if gym.isDefault {
                        Text("Default")
                            .font(.lmCaption)
                            .fontWeight(.semibold)
                            .foregroundStyle(LiftMarkTheme.warning)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(LiftMarkTheme.warning.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .accessibilityIdentifier("gym-item")
        }

        Button {
            gymStore.createGym(name: "New Gym")
        } label: {
            Label("Add Gym", systemImage: "plus")
        }
        .accessibilityIdentifier("add-gym-button")
    }
}
