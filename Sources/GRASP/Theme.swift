import SwiftUI
import AppKit

/// GRASP's palette: warm amber (the "highlighter" running through a real
/// set of lecture notes) as the accent against a deep indigo-navy ground,
/// with a muted teal reserved for mastery/success states so it never
/// competes with the amber accent. Each token is a dynamic `NSColor` so it
/// tracks the system appearance automatically, including live switches --
/// no environment threading needed at call sites.
enum GRASPColor {
    static let background = dynamic(light: 0xF7F6F2, dark: 0x121218)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1C1D28)
    static let surfaceRaised = dynamic(light: 0xFBFAF7, dark: 0x24263A)
    static let accent = dynamic(light: 0xB9791A, dark: 0xF2B84B)
    static let accentSoft = dynamic(light: 0xF3E4C8, dark: 0x3A3220)
    static let success = dynamic(light: 0x1E7A68, dark: 0x5FC9B5)
    static let successSoft = dynamic(light: 0xDCEEEA, dark: 0x1D3430)
    static let textPrimary = dynamic(light: 0x1C1D28, dark: 0xEDEDF5)
    static let textSecondary = dynamic(light: 0x6B6B7D, dark: 0x9797AC)
    static let stroke = dynamic(light: 0xE4E1D8, dark: 0x2E3040)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Font {
    static func graspHeading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    static func graspNumber(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}
