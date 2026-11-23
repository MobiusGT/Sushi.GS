import SwiftUI

enum Radius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
}

enum Surfaces {
    static let card = Color.primary.opacity(0.035)
    static let cardHover = Color.primary.opacity(0.06)
    static let dropZone = Color.primary.opacity(0.025)
    static let hairline = Color.primary.opacity(0.10)

    static let statusSuccess = Color(light: 0x15803D, dark: 0x4ADE80, highContrastLight: 0x14532D, highContrastDark: 0x86EFAC)
    static let statusWarning = Color(light: 0xB45309, dark: 0xFBBF24, highContrastLight: 0x78350F, highContrastDark: 0xFDE68A)
    static let statusError = Color(light: 0xB91C1C, dark: 0xF87171, highContrastLight: 0x7F1D1D, highContrastDark: 0xFCA5A5)
    static let statusRunning = Color(light: 0x0369A1, dark: 0x38BDF8, highContrastLight: 0x0C4A6E, highContrastDark: 0x7DD3FC)

    static let warningBannerFill = Color(light: 0xFEF3C7, dark: 0x3B2A0A, highContrastLight: 0xFDE68A, highContrastDark: 0x4C350A)
    static let warningBannerBorder = Color(light: 0xD97706, dark: 0xD97706, highContrastLight: 0x92400E, highContrastDark: 0xF59E0B)
    static let errorBannerFill = Color(light: 0xFEE2E2, dark: 0x3F1316, highContrastLight: 0xFECACA, highContrastDark: 0x52161B)
    static let errorBannerBorder = Color(light: 0xDC2626, dark: 0xEF4444, highContrastLight: 0x991B1B, highContrastDark: 0xF87171)
}

enum Motion {
    static func quick(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.14)
    }

    static func ui(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }
}
