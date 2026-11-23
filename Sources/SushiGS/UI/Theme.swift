import AppKit
import Observation
import SwiftUI

/// One accent color in three shades. Light and dark mode follow macOS.
struct Theme: Identifiable, Hashable {
    struct Shades: Hashable {
        let light: UInt32
        let base: UInt32
        let deep: UInt32
    }

    let id: String
    let name: String
    let shades: Shades?
    var darkText = false

    var tint: Color? { shades.map { Color(hex: $0.base) } }
    var accent: Color { tint ?? .accentColor }
    var accentText: Color { shades.map { Color(light: $0.deep, dark: $0.light) } ?? .accentColor }
    var onAccent: Color { darkText ? Color(hex: 0x16161C) : .white }

    static let tamagoGold = Theme(
        id: "tamago",
        name: "Tamago Gold",
        shades: .init(light: 0xFBBF24, base: 0xC97A00, deep: 0x8F5300),
        darkText: false
    )

    static let all: [Theme] = [
        Theme(id: "system", name: "System", shades: nil),
        tamagoGold,
        Theme(id: "blue", name: "Blue", shades: .init(light: 0x7CC0FF, base: 0x0A84FF, deep: 0x0064D2)),
        Theme(id: "teal", name: "Teal", shades: .init(light: 0x8BE9F5, base: 0x06B6D4, deep: 0x0E7490), darkText: true),
        Theme(id: "mint", name: "Mint", shades: .init(light: 0x8EEBC4, base: 0x2BC48A, deep: 0x0F7A55), darkText: true),
        Theme(id: "orange", name: "Orange", shades: .init(light: 0xFFB87A, base: 0xF97316, deep: 0xC2410C)),
        Theme(id: "indigo", name: "Indigo", shades: .init(light: 0xA5ADFF, base: 0x5E6AD2, deep: 0x4650B8)),
        Theme(id: "pink", name: "Pink", shades: .init(light: 0xFF9CCB, base: 0xE84A93, deep: 0xC0306F)),
        Theme(id: "graphite", name: "Graphite", shades: .init(light: 0xC7C7CC, base: 0x7C7C84, deep: 0x55555C)),
    ]
}

@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    static let defaultID = "system"
    /// Warm Tamago Gold brand accent when the Mac's system accent is Multicolor.
    static let brand: Theme? = Theme.tamagoGold

    var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: "appearance.accent") }
    }

    private(set) var macIsMulticolor = ThemeStore.readMulticolor()

    var theme: Theme {
        let chosen = Theme.all.first { $0.id == themeID } ?? Theme.all[0]
        if chosen.id == "system", macIsMulticolor, let brand = Self.brand {
            return Theme(id: "system", name: "System (Tamago Gold)", shades: brand.shades, darkText: brand.darkText)
        }
        return chosen
    }

    private init() {
        themeID = ProcessInfo.processInfo.environment["APP_ACCENT"]
            ?? UserDefaults.standard.string(forKey: "appearance.accent") ?? Self.defaultID
        NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.macIsMulticolor = ThemeStore.readMulticolor() }
        }
    }

    private static func readMulticolor() -> Bool {
        UserDefaults.standard.object(forKey: "AppleAccentColor") == nil
    }
}

enum Palette {
    static var accent: Color { ThemeStore.shared.theme.accent }
    static var accentText: Color { ThemeStore.shared.theme.accentText }
    static var onAccent: Color { ThemeStore.shared.theme.onAccent }
}

extension View {
    func themed() -> some View {
        modifier(Themed())
    }
}

private struct Themed: ViewModifier {
    private var store = ThemeStore.shared

    func body(content: Content) -> some View {
        content.tint(store.theme.tint)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    init(light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ]) {
            case .darkAqua: NSColor(hex: dark)
            case .accessibilityHighContrastAqua: NSColor(hex: highContrastLight ?? light)
            case .accessibilityHighContrastDarkAqua: NSColor(hex: highContrastDark ?? dark)
            default: NSColor(hex: light)
            }
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
