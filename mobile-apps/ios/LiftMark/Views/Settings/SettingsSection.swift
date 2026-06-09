import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case workout = "Workout Settings"
    case gyms = "Gyms"
    case integrations = "Integrations"
    case ai = "AI Assistance"
    case data = "Data Management"
    case privacy = "Privacy"
    case developer = "Developer"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .workout: return "figure.strengthtraining.traditional"
        case .gyms: return "building.2"
        case .integrations: return "link"
        case .ai: return "brain"
        case .data: return "externaldrive"
        case .privacy: return "hand.raised"
        case .developer: return "hammer"
        case .about: return "info.circle"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: return .blue
        case .appearance: return .purple
        case .workout: return .orange
        case .gyms: return .blue
        case .integrations: return .green
        case .ai: return .pink
        case .data: return .gray
        case .privacy: return .indigo
        case .developer: return .yellow
        case .about: return .secondary
        }
    }

    static func visibleSections(settings: UserSettings, forIPad: Bool = false) -> [SettingsSection] {
        let allSections = SettingsSection.allCases
        let filtered: [SettingsSection]

        if forIPad {
            // iPad: use .general instead of separate .appearance/.integrations
            filtered = allSections.filter { $0 != .appearance && $0 != .integrations }
        } else {
            // iPhone: use .appearance/.integrations, skip .general
            filtered = allSections.filter { $0 != .general }
        }

        // Developer visibility follows the easter-egg toggle in every build
        // configuration so the confirmation alert ("now visible"/"hidden")
        // never lies — see spec/screens/settings.md.
        return filtered.filter { $0 != .developer || settings.developerModeEnabled }
    }
}

// MARK: - Settings Nav Row

struct SettingsNavRow: View {
    let section: SettingsSection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: section.icon)
                .font(.lmBody)
                .foregroundStyle(section.iconColor)
                .frame(width: 28, height: 28)
                .background(section.iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusXS))
            Text(section.rawValue)
                .font(.lmBody)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? LiftMarkTheme.primary.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM))
        .contentShape(Rectangle())
    }
}
