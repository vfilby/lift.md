import SwiftUI

/// A theme picker styled like iOS Settings > Display & Brightness.
/// Shows three phone mockup thumbnails (Light, Dark, Auto) with a
/// checkmark under the selected option.
struct AppearancePicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        HStack(spacing: 16) {
            ForEach(AppTheme.allCases, id: \.self) { theme in
                Button {
                    selection = theme
                } label: {
                    VStack(spacing: 8) {
                        ThemeThumbnail(theme: theme, isSelected: selection == theme)
                        Text(theme.displayName)
                            .font(.lmCaption)
                            .foregroundStyle(selection == theme ? LiftMarkTheme.primary : LiftMarkTheme.secondaryLabel)
                        Image(systemName: selection == theme ? "checkmark.circle.fill" : "circle")
                            .font(.lmTitle3)
                            .foregroundStyle(selection == theme ? LiftMarkTheme.primary : LiftMarkTheme.tertiaryLabel)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("theme-option-\(theme.rawValue)")
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Theme Thumbnail

private struct ThemeThumbnail: View {
    let theme: AppTheme
    let isSelected: Bool

    private var backgroundColor: Color {
        switch theme {
        case .light: return Color(white: 0.95)
        case .dark: return Color(white: 0.15)
        case .auto: return Color(white: 0.95) // left half light
        }
    }

    var body: some View {
        ZStack {
            if theme == .auto {
                // Split light/dark
                HStack(spacing: 0) {
                    lightPhoneContent
                        .frame(maxWidth: .infinity)
                        .background(Color(white: 0.95))
                    darkPhoneContent
                        .frame(maxWidth: .infinity)
                        .background(Color(white: 0.15))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Group {
                    if theme == .light {
                        lightPhoneContent
                    } else {
                        darkPhoneContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(width: 72, height: 100)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? LiftMarkTheme.primary : Color.gray.opacity(0.3), lineWidth: isSelected ? 2.5 : 1)
        )
    }

    // MARK: - Phone Content

    private var lightPhoneContent: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 8)
            // Simulated content lines
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray.opacity(0.25))
                .frame(height: 6)
                .padding(.horizontal, 6)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray.opacity(0.18))
                .frame(height: 6)
                .padding(.horizontal, 6)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray.opacity(0.12))
                .frame(height: 6)
                .padding(.horizontal, 10)
            Spacer(minLength: 8)
            // Bottom tab bar
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var darkPhoneContent: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 8)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.2))
                .frame(height: 6)
                .padding(.horizontal, 6)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.15))
                .frame(height: 6)
                .padding(.horizontal, 6)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.1))
                .frame(height: 6)
                .padding(.horizontal, 10)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

// MARK: - AppTheme Display Name

private extension AppTheme {
    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .auto: return "Automatic"
        }
    }
}
