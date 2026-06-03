import SwiftUI

// MARK: - LiftMark Brand Typography
//
// Brand fonts (bundled in Resources/Fonts, registered via UIAppFonts):
//   • Space Grotesk  — display / titles / wordmark   (Bold, Medium)
//   • Inter          — body / UI                      (Regular, SemiBold)
//   • JetBrains Mono — code / monospaced              (Medium)
//
// Each token mirrors a SwiftUI `Font.TextStyle` and is built with
// `Font.custom(_:size:relativeTo:)` so it still scales with Dynamic Type.
// Base sizes match Apple's default (Large) metrics for each text style, so
// swapping `.font(.body)` → `.font(.lmBody)` keeps layout proportions.
//
// NOTE: Space Grotesk's PostScript names are `SpaceGroteskLight-*` (the family
// was cut from a Light master) — using the file stem silently falls back to
// the system font, so the exact PostScript names are required here.

enum BrandFontName {
    static let interRegular = "Inter-Regular"
    static let interSemiBold = "Inter-SemiBold"
    static let spaceGroteskBold = "SpaceGroteskLight-Bold"
    static let spaceGroteskMedium = "SpaceGroteskLight-Medium"
    static let jetBrainsMonoMedium = "JetBrainsMono-Medium"
}

extension Font {
    // Display / titles — Space Grotesk
    static let lmLargeTitle = Font.custom(BrandFontName.spaceGroteskBold, size: 34, relativeTo: .largeTitle)
    static let lmTitle = Font.custom(BrandFontName.spaceGroteskBold, size: 28, relativeTo: .title)
    static let lmTitle2 = Font.custom(BrandFontName.spaceGroteskMedium, size: 22, relativeTo: .title2)
    static let lmTitle3 = Font.custom(BrandFontName.spaceGroteskMedium, size: 20, relativeTo: .title3)

    // UI emphasis — Inter SemiBold
    static let lmHeadline = Font.custom(BrandFontName.interSemiBold, size: 17, relativeTo: .headline)

    // Body / UI — Inter Regular
    static let lmBody = Font.custom(BrandFontName.interRegular, size: 17, relativeTo: .body)
    static let lmCallout = Font.custom(BrandFontName.interRegular, size: 16, relativeTo: .callout)
    static let lmSubheadline = Font.custom(BrandFontName.interRegular, size: 15, relativeTo: .subheadline)
    static let lmFootnote = Font.custom(BrandFontName.interRegular, size: 13, relativeTo: .footnote)
    static let lmCaption = Font.custom(BrandFontName.interRegular, size: 12, relativeTo: .caption)
    static let lmCaption2 = Font.custom(BrandFontName.interRegular, size: 11, relativeTo: .caption2)

    // Code / monospaced — JetBrains Mono (size matches `.system(.body)` = 17pt)
    static let lmMono = Font.custom(BrandFontName.jetBrainsMonoMedium, size: 17, relativeTo: .body)

    /// Monospaced brand font at an explicit size, scaled relative to a text style.
    static func lmMono(size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        Font.custom(BrandFontName.jetBrainsMonoMedium, size: size, relativeTo: textStyle)
    }

    /// Display brand font (Space Grotesk Bold) at an explicit size — for hero
    /// numerics / titles that were laid out against a specific point size.
    static func lmDisplay(size: CGFloat, relativeTo textStyle: Font.TextStyle = .title) -> Font {
        Font.custom(BrandFontName.spaceGroteskBold, size: size, relativeTo: textStyle)
    }
}
