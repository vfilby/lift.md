//  LiftMarkColors.swift
//  LiftMark brand color tokens for SwiftUI.
//
//  Usage:   Color.lmBlue, Color.lmOrange, Color.lmAccent (theme-aware)
//  The semantic roles (lmBg, lmText, lmAccent, …) resolve light/dark
//  automatically via asset-style dynamic colors.

import SwiftUI

public extension Color {

    // MARK: Hex initializer
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8)  & 0xFF) / 255.0,
            blue:  Double( hex        & 0xFF) / 255.0,
            opacity: alpha
        )
    }

    // MARK: Brand
    static let lmBlue       = Color(hex: 0x2D5BFF)   // primary
    static let lmBluePress  = Color(hex: 0x1E45E6)
    static let lmOrange     = Color(hex: 0xFF6A1A)   // energy
    static let lmInk        = Color(hex: 0x0E1116)

    // MARK: Blue scale
    static let lmBlue50  = Color(hex: 0xEEF2FF)
    static let lmBlue100 = Color(hex: 0xDBE3FF)
    static let lmBlue200 = Color(hex: 0xB7C7FF)
    static let lmBlue300 = Color(hex: 0x8AA3FF)
    static let lmBlue400 = Color(hex: 0x5677FF)
    static let lmBlue500 = Color(hex: 0x2D5BFF)
    static let lmBlue600 = Color(hex: 0x1E45E6)
    static let lmBlue700 = Color(hex: 0x1834B4)
    static let lmBlue800 = Color(hex: 0x182E8C)
    static let lmBlue900 = Color(hex: 0x18296E)

    // MARK: Orange scale
    static let lmOrange50  = Color(hex: 0xFFF2EA)
    static let lmOrange100 = Color(hex: 0xFFE0CC)
    static let lmOrange200 = Color(hex: 0xFFBF99)
    static let lmOrange300 = Color(hex: 0xFF9D63)
    static let lmOrange400 = Color(hex: 0xFF8038)
    static let lmOrange500 = Color(hex: 0xFF6A1A)
    static let lmOrange600 = Color(hex: 0xED5305)
    static let lmOrange700 = Color(hex: 0xC44208)
    static let lmOrange800 = Color(hex: 0x9C360F)
    static let lmOrange900 = Color(hex: 0x7E2F12)

    // MARK: Neutral / Slate
    static let lmN0   = Color(hex: 0xFFFFFF)
    static let lmN50  = Color(hex: 0xF6F7F9)
    static let lmN100 = Color(hex: 0xEDEFF3)
    static let lmN200 = Color(hex: 0xDDE1E8)
    static let lmN300 = Color(hex: 0xC2C8D2)
    static let lmN400 = Color(hex: 0x9AA2B0)
    static let lmN500 = Color(hex: 0x6B7382)
    static let lmN600 = Color(hex: 0x4B515E)
    static let lmN700 = Color(hex: 0x333845)
    static let lmN800 = Color(hex: 0x1C2028)
    static let lmN900 = Color(hex: 0x0E1116)

    // MARK: Semantic
    static let lmSuccess = Color(hex: 0x18A957)
    static let lmWarning = Color(hex: 0xF5A524)
    static let lmDanger  = Color(hex: 0xE5484D)
    static let lmInfo    = Color(hex: 0x2D5BFF)

    // MARK: Theme-aware semantic roles
    // Resolves light/dark automatically. Requires UIKit (iOS).
    #if canImport(UIKit)
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { tc in
            tc.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light))
        })
    }
    static let lmBg        = dyn(0xFFFFFF, 0x0E1116)
    static let lmBgSubtle  = dyn(0xF6F7F9, 0x1C2028)
    static let lmSurface   = dyn(0xFFFFFF, 0x1C2028)
    static let lmBorder    = dyn(0xDDE1E8, 0x333845)
    static let lmText      = dyn(0x0E1116, 0xF6F7F9)
    static let lmTextMuted = dyn(0x6B7382, 0x9AA2B0)
    static let lmLink      = dyn(0x1E45E6, 0x8AA3FF)
    static let lmAccent    = dyn(0x2D5BFF, 0x5677FF)
    static let lmCodeBg    = dyn(0xF6F7F9, 0x161A21)
    static let lmCodeText  = dyn(0x1C2028, 0xDDE1E8)
    #endif
}

public extension LinearGradient {
    /// Signature "Energy" gradient — routed through magenta to stay vivid.
    static let lmEnergy = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x2D5BFF), location: 0.00),
            .init(color: Color(hex: 0x5236E8), location: 0.45),
            .init(color: Color(hex: 0xE0357A), location: 0.62),
            .init(color: Color(hex: 0xFF7A1A), location: 1.00),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}
