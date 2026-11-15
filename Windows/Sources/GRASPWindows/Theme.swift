import Foundation
import SwiftCrossUI

/// GRASP's palette: the same tokens as the Mac's `GRASPColor`
/// (`Sources/GRASP/Shared/Theme.swift`, listed in DESIGN.md "Colour"). Yellow
/// is a fill (`brand`) or, as text, `accent` (gold on cream in light mode).
/// Depth is the surface ladder `inset` < `canvas` < `surface` < `surfaceRaised`
/// and 1 pt hairlines, never shadows. Keep the hex values in step with the Mac's.
enum GRASPColor {
    static let canvas = adaptive(light: 0xF7F4E3, dark: 0x0E100F)
    static let inset = adaptive(light: 0xEEEAD4, dark: 0x0A0B0A)
    static let surface = adaptive(light: 0xFFFDF3, dark: 0x171917)
    static let surfaceRaised = adaptive(light: 0xFFFFFF, dark: 0x1F221F)
    /// The Mac's sidebar is a `surface` panel.
    static let sidebar = surface

    static let hairline = adaptive(light: 0xE2DDC4, dark: 0x2C2E2A)
    static let hairlineStrong = adaptive(light: 0xCFC9AC, dark: 0x3B3E38)

    /// Yellow as a fill, and the text that sits on it.
    static let brand = Color(rgb: 0xFFD43B)
    static let ink = Color(rgb: 0x0E100F)
    /// Yellow as text or an icon.
    static let accent = adaptive(light: 0x7A5900, dark: 0xFFD43B)
    static let accentSoft = adaptive(light: 0xFFF0B0, dark: 0x2E2912)
    static let accentMuted = adaptive(light: 0xB08A1A, dark: 0xA08A35)
    static let success = adaptive(light: 0x14705E, dark: 0x5FC9B5)
    static let successSoft = adaptive(light: 0xDBEDE8, dark: 0x112824)
    static let rejected = adaptive(light: 0xB2453F, dark: 0xE08A83)
    static let rejectedSoft = adaptive(light: 0xF5DEDA, dark: 0x2E1714)

    /// Cream on dark, ink on light.
    static let textPrimary = adaptive(light: 0x14160F, dark: 0xFFFCE1)
    static let textSecondary = adaptive(light: 0x4A4A3E, dark: 0xB9B7A5)
    /// Meta and status words. Never lighter (4.5:1 floor).
    static let textTertiary = adaptive(light: 0x6A695B, dark: 0x8C8C7E)

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

    /// A stored hex at a given opacity: a course colour as a soft fill.
    init(hex: String, opacity: Double) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let rgb = UInt32(digits, radix: 16) ?? 0
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: opacity)
    }
}

/// Corner radii and the 4 pt grid (DESIGN.md "Shape and depth").
enum GRASPRadius {
    /// Cards, strips and sheets.
    static let card = 14
    /// Rows and wells.
    static let inner = 10
    /// A pill: larger than half of any control's height.
    static let pill = 40
}

enum GRASPSpace {
    static let xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0, huge = 40.0
}

/// The Mac's type scale (`GRASPType`, DESIGN.md "Type"). Segoe UI stands in
/// for Bricolage Grotesque and Instrument Sans until the bundled families can
/// be loaded (see Windows/PATCHES.md); sizes and weights are the Mac's, minus
/// tracking, which WinUI text doesn't take.
enum GRASPFont {
    static let display = Font.system(size: 36, weight: .heavy)
    static let lessonTitle = Font.system(size: 32, weight: .heavy)
    static let numeral = Font.system(size: 30, weight: .heavy)
    static let proseH2 = Font.system(size: 22, weight: .semibold)
    static let title = Font.system(size: 18, weight: .semibold)
    static let studyPrompt = Font.system(size: 26)
    static let lede = Font.system(size: 19)
    static let prose = Font.system(size: 16)
    static let body = Font.system(size: 14)
    static let rowTitle = Font.system(size: 14, weight: .medium)
    static let meta = Font.system(size: 12.5)
    static let eyebrow = Font.system(size: 12, weight: .semibold)
    /// A due count inside its pill.
    static let badge = Font.system(size: 11, weight: .bold)
    static let button = Font.system(size: 13.5, weight: .semibold)
}

/// The small yellow rounded square from the wordmark.
struct BrandDot: View {
    var size = 6.0

    var body: some View {
        Rectangle().fill(GRASPColor.brand).frame(width: size, height: size).cornerRadius(1)
    }
}

/// A small label over a group of rows: a brand dot, then the words in
/// tracked-capitals style ("FALL 2026", "DECKS").
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            BrandDot()
            Text(text.uppercased())
                .font(GRASPFont.eyebrow)
                .foregroundColor(GRASPColor.textSecondary)
                .lineLimit(1)
        }
    }
}

/// The due-count pill the Mac shows beside decks and courses: muted words
/// on a hairline-edged well, with the number in `accent`.
struct DueBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(GRASPFont.badge)
            .foregroundColor(GRASPColor.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(GRASPColor.accentSoft)
            .cornerRadius(9)
    }
}
