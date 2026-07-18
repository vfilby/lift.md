import SwiftUI

enum LiftMarkTheme {
    // MARK: - Colors

    // Tab bar icons — 3:1 minimum for UI components
    static let tabIconDefault = Color(hex: "8E8E93") // 3.3:1 on white, 6.4:1 on black

    #if canImport(UIKit)
    // MARK: Adaptive colors — WCAG AA (4.5:1 normal text on system backgrounds)

    static let tabIconSelected = primary

    static let primary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0, green: 122.0/255, blue: 1, alpha: 1)            // #007AFF — 8.6:1 on black
            : UIColor(red: 0, green: 112.0/255, blue: 224.0/255, alpha: 1)    // #0070E0 — 4.8:1 on white
    })

    static let destructive = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 69.0/255, blue: 58.0/255, alpha: 1)      // #FF453A — 5.5:1 on black
            : UIColor(red: 196.0/255, green: 31.0/255, blue: 31.0/255, alpha: 1) // #C41F1F — 5.9:1 on white
    })

    static let success = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 48.0/255, green: 209.0/255, blue: 88.0/255, alpha: 1) // #30D158 — 10.4:1 on black
            : UIColor(red: 30.0/255, green: 126.0/255, blue: 52.0/255, alpha: 1) // #1E7E34 — 5.4:1 on white
    })

    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 159.0/255, blue: 10.0/255, alpha: 1)     // #FF9F0A — 11.3:1 on black
            : UIColor(red: 196.0/255, green: 81.0/255, blue: 0, alpha: 1)     // #C45100 — 4.9:1 on white
    })

    // MARK: Section accents — WCAG AA on system backgrounds

    static let warmupAccent = warning

    static let cooldownAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 100.0/255, green: 210.0/255, blue: 1, alpha: 1)    // #64D2FF — 11.5:1 on black
            : UIColor(red: 0, green: 119.0/255, blue: 182.0/255, alpha: 1)    // #0077B6 — 4.8:1 on white
    })

    // MARK: Backgrounds
    static let background = Color(.systemBackground)
    static let secondaryBackground = Color(.secondarySystemBackground)
    static let groupedBackground = Color(.systemGroupedBackground)

    // MARK: Text — Apple system semantic colors (adapt via iOS Increase Contrast)
    static let label = Color(.label)
    static let secondaryLabel = Color(.secondaryLabel)
    static let tertiaryLabel = Color(.tertiaryLabel)
    #else
    static let tabIconSelected = Color(hex: "0070E0")
    static let primary = Color(hex: "0070E0")
    static let destructive = Color.red
    static let success = Color.green
    static let warning = Color.orange
    static let warmupAccent = Color.orange
    static let cooldownAccent = Color.cyan

    static let background = Color.white
    static let secondaryBackground = Color.gray.opacity(0.1)
    static let groupedBackground = Color.gray.opacity(0.05)
    static let label = Color.primary
    static let secondaryLabel = Color.secondary
    static let tertiaryLabel = Color.gray
    #endif

    // MARK: - Spacing

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32

    // MARK: - Corner Radius
    //
    // The radius scale governs rectangular surfaces. Two element families are
    // fully rounded instead and do NOT use these tokens: buttons and badges/chips
    // are Capsule() / `.buttonBorderShape(.capsule)`. See spec/visual-spec.md.

    // small chrome: side labels, set-number badge, progress bars, inline info boxes
    static let cornerRadiusXS: CGFloat = 4
    static let cornerRadiusSM: CGFloat = 8   // input fields, small containers
    static let cornerRadiusMD: CGFloat = 12  // cards (the standard card radius), modals
    static let cornerRadiusLG: CGFloat = 16  // large surfaces / full-width banners (e.g. error banner)
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
