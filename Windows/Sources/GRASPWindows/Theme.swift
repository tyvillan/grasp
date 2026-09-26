import Foundation
import SwiftCrossUI

/// GRASP's palette, the same tokens as the Mac's `GRASPColor`
/// (`Sources/GRASP/Shared/Theme.swift`): warm amber as the accent against a
/// black ground, teal for mastery, and an elevation ladder of surfaces
/// (`inset` < `canvas` < `surface` < `surfaceRaised`). Keep the hex values
/// in step with the Mac's.
enum GRASPColor {
    static let canvas = adaptive(light: 0xF7F6F2, dark: 0x000000)
    static let inset = adaptive(light: 0xEDEBE4, dark: 0x08080B)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x101014)
    static let surfaceRaised = adaptive(light: 0xFFFFFF, dark: 0x191920)
    /// The Mac's sidebar is translucent material tinted toward `canvas`.
    /// WinUI has no material here, so this is its flat equivalent: a step
    /// lighter than the deck column, which is a step lighter than the canvas.
    static let sidebar = adaptive(light: 0xEFEDE7, dark: 0x16161B)

    static let hairline = adaptive(light: 0xE6E3DA, dark: 0x1F1F27)
    static let hairlineStrong = adaptive(light: 0xD3CFC3, dark: 0x2E2E3A)

    static let accent = adaptive(light: 0x9C6208, dark: 0xF2B84B)
    static let accentSoft = adaptive(light: 0xF6E7C9, dark: 0x332B18)
    static let accentMuted = adaptive(light: 0xC79A4A, dark: 0x8A6B2A)
    static let success = adaptive(light: 0x14705E, dark: 0x5FC9B5)
    static let successSoft = adaptive(light: 0xDBEDE8, dark: 0x112824)
    static let rejected = adaptive(light: 0xB2453F, dark: 0xE08A83)
    static let rejectedSoft = adaptive(light: 0xF5DEDA, dark: 0x2E1714)

    static let textPrimary = adaptive(light: 0x1A1B24, dark: 0xEFEEF6)
    static let textSecondary = adaptive(light: 0x5F5E6D, dark: 0x9695A6)
    static let textTertiary = adaptive(light: 0x8C8A97, dark: 0x646374)

    /// The lesson figures' two line colours (the Mac's `FigurePalette`).
    static let figureBlue = adaptive(light: 0x2F6FD0, dark: 0x58C4DD)
    static let figureAmber = adaptive(light: 0xC47A0B, dark: 0xF2B84B)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        .adaptive(light: Color(rgb: light), dark: Color(rgb: dark))
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    /// Six-digit RRGGBB, as stored in `course.colorHex` (a leading `#` is
    /// allowed). Matches the Mac's `Color(hex:)`.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        self.init(rgb: UInt32(digits, radix: 16) ?? 0)
    }
}

/// The Mac's type scale (`GRASPType`), minus tracking, which WinUI text
/// doesn't take.
enum GRASPFont {
    static let display = Font.system(size: 32, weight: .bold)
    static let title = Font.system(size: 17, weight: .semibold)
    static let rowTitle = Font.system(size: 13, weight: .medium)
    static let eyebrow = Font.system(size: 11, weight: .semibold)
    static let body = Font.system(size: 13)
    static let meta = Font.system(size: 11)
    static let numeral = Font.system(size: 28, weight: .semibold)
    static let badge = Font.system(size: 10, weight: .bold)
}

/// A small uppercase label over a group of rows ("FALL 2026", "DECKS").
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(GRASPFont.eyebrow)
            .foregroundColor(GRASPColor.textTertiary)
    }
}

/// The amber due-count pill the Mac shows beside decks and courses.
struct DueBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(GRASPFont.badge)
            .foregroundColor(GRASPColor.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(GRASPColor.accentSoft)
            .cornerRadius(8)
    }
}
