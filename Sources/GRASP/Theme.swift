import SwiftUI
import AppKit

/// GRASP's palette: warm amber (the "highlighter" running through a real
/// set of lecture notes) as the accent against a black ground, with a
/// muted teal reserved for mastery/success states so it never competes
/// with the amber. Each token is a dynamic `NSColor` so it tracks the
/// system appearance automatically, including live switches -- no
/// environment threading needed at call sites.
///
/// The surfaces form a deliberate elevation ladder rather than a single
/// "card color": `inset` (recessed wells -- progress tracks, fields),
/// `canvas` (the ground), `surface` (a panel resting on it), and
/// `surfaceRaised` (reserved for the one element per screen that should
/// sit forward). Depth comes from those steps, so a 1px stroke is spent
/// only where a real edge exists -- not stamped on every rectangle, which
/// is what flattens a layout into a wall of identical boxes.
enum GRASPColor {
    static let canvas = dynamic(light: 0xF7F6F2, dark: 0x000000)
    static let inset = dynamic(light: 0xEDEBE4, dark: 0x08080B)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x101014)
    static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x191920)

    static let hairline = dynamic(light: 0xE6E3DA, dark: 0x1F1F27)
    static let hairlineStrong = dynamic(light: 0xD3CFC3, dark: 0x2E2E3A)

    static let accent = dynamic(light: 0x9C6208, dark: 0xF2B84B)
    static let accentSoft = dynamic(light: 0xF6E7C9, dark: 0x332B18)
    static let accentMuted = dynamic(light: 0xC79A4A, dark: 0x8A6B2A)
    static let success = dynamic(light: 0x14705E, dark: 0x5FC9B5)
    static let successSoft = dynamic(light: 0xDBEDE8, dark: 0x112824)
    /// A muted terracotta-red, reserved for a card's "Rejected" (suspended)
    /// state -- distinct from `accent` so pending and rejected never read
    /// as the same color at a glance.
    static let rejected = dynamic(light: 0xB2453F, dark: 0xE08A83)
    static let rejectedSoft = dynamic(light: 0xF5DEDA, dark: 0x2E1714)

    static let textPrimary = dynamic(light: 0x1A1B24, dark: 0xEFEEF6)
    static let textSecondary = dynamic(light: 0x5F5E6D, dark: 0x9695A6)
    static let textTertiary = dynamic(light: 0x8C8A97, dark: 0x646374)

    /// Retained under its original name so existing call sites keep
    /// meaning "the default edge" rather than having to pick a weight.
    static var stroke: Color { hairline }
    static var background: Color { canvas }

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

// MARK: - Typography

/// The app's type scale. Sizes are deliberately far apart -- 32 / 17 / 13
/// / 11 rather than four steps clustered around each other -- so hierarchy
/// reads from contrast instead of from weight alone.
///
/// Tracking is the part that stops this looking default-rendered. macOS
/// swaps SF Pro Text for SF Pro Display around 20pt, and Apple's own
/// display-size type is tracked *negative*: at 32pt the default spacing
/// looks loose and unset. Small uppercase labels need the opposite,
/// positive tracking, or the capitals jam together. Each case below
/// carries the tracking its size actually wants.
enum GRASPType {
    /// Dashboard greeting -- the one piece of type per screen that is
    /// allowed to be large.
    case display
    /// A card or section headline.
    case title
    /// A row's primary line.
    case rowTitle
    /// Small uppercase section label. Pair with `.textCase(.uppercase)`.
    case eyebrow
    case body
    /// De-emphasised supporting line under a title.
    case meta
    /// Large figures. Digits are tabular so columns of numbers align and
    /// a counter doesn't jitter as it ticks.
    case numeral
    /// Inline figures inside a stat strip.
    case numeralSmall
    /// Prompt text in a study session -- large, but set at reading weight
    /// rather than a headline's.
    case studyPrompt
    case studyAnswer
    /// Long-form reading prose -- the lesson body. `.body` is a UI label at
    /// 13pt: correct in a row, punishing over a page of paragraphs. 16 with
    /// generous leading is where reading on screen stops feeling like work,
    /// and at the lesson's 680pt measure it lands near 75 characters a line.
    case prose
    /// The lesson's opening question, set a step up from the body and in a
    /// quieter colour -- a standfirst that pulls the reader in, not a
    /// second title competing with the first.
    case lede
    /// The lesson's title. The one large piece of type on the page, and
    /// deliberately a claim rather than a topic, so it gets display sizing
    /// and the negative tracking display sizes want.
    case lessonTitle
    /// A section heading inside the lesson. Headings here are full-sentence
    /// claims, so they're set at a size that holds a sentence without
    /// shouting -- well below the title, well above the body.
    case proseH2
    /// Code, and inline runs of it. One rung below `.prose` on purpose -- a
    /// monospaced face has a wider advance at the same point size, so
    /// matching 16 would make code read as larger than the prose around it.
    case mono
    /// A formula on its own line. Monospaced like `.mono`, but at reading
    /// size: this is content, not an annotation of it.
    case formula

    var font: Font {
        switch self {
        case .display: return .system(size: 32, weight: .bold)
        case .title: return .system(size: 17, weight: .semibold)
        case .rowTitle: return .system(size: 13, weight: .medium)
        case .eyebrow: return .system(size: 11, weight: .semibold)
        case .body: return .system(size: 13, weight: .regular)
        case .meta: return .system(size: 11, weight: .regular)
        case .numeral: return .system(size: 28, weight: .semibold).monospacedDigit()
        case .numeralSmall: return .system(size: 15, weight: .semibold).monospacedDigit()
        case .studyPrompt: return .system(size: 26, weight: .regular)
        case .studyAnswer: return .system(size: 17, weight: .regular)
        case .prose: return .system(size: 16, weight: .regular)
        case .lede: return .system(size: 19, weight: .regular)
        case .lessonTitle: return .system(size: 30, weight: .bold)
        case .proseH2: return .system(size: 21, weight: .semibold)
        case .mono: return .system(size: 14, weight: .regular, design: .monospaced)
        case .formula: return .system(size: 16, weight: .regular, design: .monospaced)
        }
    }

    var tracking: CGFloat {
        switch self {
        case .display: return -0.7
        case .title: return -0.25
        case .rowTitle: return -0.05
        case .eyebrow: return 0.7
        case .body: return 0
        case .meta: return 0.1
        case .numeral: return -0.8
        case .numeralSmall: return -0.2
        case .studyPrompt: return -0.4
        case .studyAnswer: return -0.1
        // 16pt sits inside SF Pro Text's optically-correct range, so there
        // is nothing to correct -- same reasoning as `.body`.
        case .prose: return 0
        case .lede: return -0.2
        // Display sizes track negative, per this scale's own rule; 30 sits
        // just under `.display`'s 32 and borrows most of its tracking.
        case .lessonTitle: return -0.6
        case .proseH2: return -0.35
        // A monospaced face's advances are already fixed; tracking one only
        // breaks the grid that makes it readable.
        case .mono, .formula: return 0
        }
    }

    /// Extra leading for the styles that carry multi-line text. Single-line
    /// labels get none, so rows stay on their intended heights.
    var lineSpacing: CGFloat {
        switch self {
        case .studyPrompt: return 6
        case .studyAnswer, .body: return 2
        // A reading column wants more air than either -- the eye has to
        // find the start of the next line unaided.
        case .prose: return 7
        case .lede: return 6
        case .lessonTitle: return 2
        case .proseH2: return 2
        // Formulas wrap badly; the extra leading stops a wrapped one
        // reading as two separate formulas.
        case .formula: return 6
        case .mono: return 4
        default: return 0
        }
    }
}

extension View {
    func graspType(_ style: GRASPType) -> some View {
        font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }
}

extension Font {
    /// Kept for call sites that need a bare `Font` (menus, `Text`
    /// concatenation) where the view modifier isn't reachable.
    static func graspHeading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func graspNumber(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold).monospacedDigit()
    }

    /// Companion to the two above, for the `AttributedString` run
    /// attributes the inline markdown renderer sets by hand -- a per-run
    /// attribute can't reach the `graspType` view modifier.
    static func graspMono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}
