import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// GRASP's palette: black and yellow are the brand, everything else is
/// secondary. A near-black stage with warm cream text (never pure white on
/// pure black), one loud yellow used sparingly -- the primary button, the
/// selection, focus, the streak, progress and the single most important
/// number on a screen -- and hairlines instead of shadows.
///
/// Light mode is the same brand turned over: a warm cream page with ink
/// text. Yellow stays the fill of the primary button and the selection in
/// both, but yellow *text* on cream is unreadable, so `accent` (the text
/// and icon tone) darkens to gold there while `brand` (the fill) does not.
///
/// The surfaces form an elevation ladder rather than a single "card color":
/// `inset` (recessed wells -- progress tracks, fields), `canvas` (the
/// ground), `surface` (a panel resting on it), and `surfaceRaised` (hover
/// and selected). Depth comes from those steps, not shadows. Each token is
/// a dynamic platform color, so it tracks the appearance live.
enum GRASPColor {
    static let canvas = dynamic(light: 0xF7F4E3, dark: 0x0E100F)
    static let inset = dynamic(light: 0xEEEAD4, dark: 0x0A0B0A)
    /// The brief's `panel`: cards, sidebar, nested surfaces.
    static let surface = dynamic(light: 0xFFFDF3, dark: 0x171917)
    /// The brief's `panelRaised`: hover and selected surfaces.
    static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x1F221F)

    static let hairline = dynamic(light: 0xE2DDC4, dark: 0x2C2E2A)
    static let hairlineStrong = dynamic(light: 0xCFC9AC, dark: 0x3B3E38)

    /// Yellow as a fill: the primary button, the selection bar, progress,
    /// the brand dot. The same in both modes; whatever sits on it is `ink`.
    static let brand = Color(hex: "FFD43B")
    /// Text and icons placed on `brand`.
    static let ink = Color(hex: "0E100F")
    /// Yellow as text or an icon on the page. Gold in light mode, where
    /// the brand yellow on cream would fail contrast.
    static let accent = dynamic(light: 0x7A5900, dark: 0xFFD43B)
    static let accentSoft = dynamic(light: 0xFFF0B0, dark: 0x2E2912)
    static let accentMuted = dynamic(light: 0xB08A1A, dark: 0xA08A35)
    static let success = dynamic(light: 0x14705E, dark: 0x5FC9B5)
    static let successSoft = dynamic(light: 0xDBEDE8, dark: 0x112824)
    /// A muted terracotta-red, reserved for a card's "Rejected" (suspended)
    /// state -- distinct from `accent` so pending and rejected never read
    /// as the same color at a glance.
    static let rejected = dynamic(light: 0xB2453F, dark: 0xE08A83)
    static let rejectedSoft = dynamic(light: 0xF5DEDA, dark: 0x2E1714)

    /// The brief's `cream` (dark) and ink (light).
    static let textPrimary = dynamic(light: 0x14160F, dark: 0xFFFCE1)
    static let textSecondary = dynamic(light: 0x4A4A3E, dark: 0xB9B7A5)
    /// The brief's `muted`. Never lighter than this for text: it is the
    /// floor that still clears 4.5:1 on the canvas.
    static let textTertiary = dynamic(light: 0x6A695B, dark: 0x8C8C7E)

    /// Retained under its original name so existing call sites keep
    /// meaning "the default edge" rather than having to pick a weight.
    static var stroke: Color { hairline }
    static var background: Color { canvas }

    /// A color that switches with light and dark mode, on either platform.
    ///
    /// `nonisolated`, closure included: SwiftUI resolves colors on its
    /// render thread, not the main actor. With the app's default main-actor
    /// isolation the provider carried a runtime check that the thread was
    /// main, and the first off-main redraw -- the Google sign-in sheet on
    /// iPhone -- tripped it and crashed the app.
    nonisolated static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        Color(NSColor(name: nil) { @Sendable appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #else
        Color(UIColor { @Sendable traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

/// Course colors: secondary to the brand, one hue per course in the current
/// term, never yellow. Shown on the sidebar dot and on Calendar events --
/// never on Home. Each has a darker light-mode twin so a course-colored
/// label stays readable on cream.
enum CoursePalette {
    struct Slot: Identifiable, Equatable {
        let name: String
        /// What's stored in `Course.colorHex`: the dark-mode value.
        let hex: String
        let light: UInt32
        var id: String { hex }
        var color: Color { GRASPColor.dynamic(light: light, dark: UInt32(hex, radix: 16) ?? 0) }
    }

    static let slots: [Slot] = [
        Slot(name: "Blue", hex: "4CC9F0", light: 0x0A7EA8),
        Slot(name: "Mint", hex: "4FE0B6", light: 0x0E8F6C),
        Slot(name: "Lilac", hex: "9D95FF", light: 0x5B50D6),
        Slot(name: "Pink", hex: "FF8FD0", light: 0xC2338A),
        Slot(name: "Coral", hex: "FF7A59", light: 0xC9431F),
        Slot(name: "Lime", hex: "B6F36A", light: 0x4F7F10),
    ]

    /// A stored hex as a color: a palette slot gets its light-mode twin,
    /// anything older (the previous swatches) is drawn as stored.
    static func color(hex: String) -> Color {
        let upper = hex.uppercased()
        return slots.first { $0.hex == upper }?.color ?? Color(hex: hex)
    }
}

extension Color {
    /// Six-digit RRGGBB, as stored in `course.colorHex`.
    nonisolated init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

#if os(macOS)
private typealias PlatformColor = NSColor
#else
private typealias PlatformColor = UIColor
#endif

private extension PlatformColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Fonts

/// The two bundled families (both SIL OFL, licenses beside the files in
/// `Shared/Fonts`): Bricolage Grotesque for display type, Instrument Sans for
/// everything people read and click. Registered once, in-process, the first
/// time any GRASP font is asked for. If registration fails -- a dev build run
/// straight from `swift run`, where the files aren't in the bundle -- every
/// helper falls back to the system font rather than to nothing.
enum GRASPFonts {
    nonisolated static let displaySemiBold = "BricolageGrotesque-24ptSemiBold"
    nonisolated static let displayExtraBold = "BricolageGrotesque-72ptExtraBold"
    nonisolated static let bodyRegular = "InstrumentSans-Regular"
    nonisolated static let bodyMedium = "InstrumentSans-Medium"
    nonisolated static let bodySemiBold = "InstrumentSans-SemiBold"
    nonisolated static let bodyBold = "InstrumentSans-Bold"

    /// Whether the bundled fonts are usable. Lazily computed, thread-safe.
    nonisolated static let available: Bool = register()

    nonisolated private static func register() -> Bool {
        let bundle = Bundle.main
        let urls = (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
            + (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
        for url in urls {
            // Already registered (a second window, a relaunch in-process)
            // is fine; the check below is what decides.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let probe = CTFontCreateWithName(bodyRegular as CFString, 12, nil)
        return (CTFontCopyPostScriptName(probe) as String) == bodyRegular
    }
}

extension Font {
    /// Display type: Bricolage Grotesque. `heavy` is the 800 cut used for
    /// heroes and titles; otherwise the 600.
    static func graspDisplay(_ size: CGFloat, heavy: Bool = true) -> Font {
        guard GRASPFonts.available else { return .system(size: size, weight: heavy ? .heavy : .semibold) }
        return .custom(heavy ? GRASPFonts.displayExtraBold : GRASPFonts.displaySemiBold, fixedSize: size)
    }

    /// UI and reading type: Instrument Sans at the nearest bundled weight.
    static func graspUI(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard GRASPFonts.available else { return .system(size: size, weight: weight) }
        let name: String
        switch weight {
        case .ultraLight, .thin, .light, .regular: name = GRASPFonts.bodyRegular
        case .medium: name = GRASPFonts.bodyMedium
        case .semibold: name = GRASPFonts.bodySemiBold
        default: name = GRASPFonts.bodyBold
        }
        return .custom(name, fixedSize: size)
    }

    // The system text styles, mapped onto the GRASP families so a view that
    // asked for "a caption" gets GRASP's caption rather than SF Pro's.
    static var graspLargeTitle: Font { graspDisplay(30) }
    static var graspTitle: Font { graspDisplay(22) }
    static var graspTitle2: Font { graspDisplay(18) }
    static var graspTitle3: Font { graspDisplay(16, heavy: false) }
    static var graspHeadline: Font { graspUI(size: 14, weight: .semibold) }
    static var graspSubheadline: Font { graspUI(size: 13) }
    static var graspBody: Font { graspUI(size: 14) }
    static var graspCallout: Font { graspUI(size: 13.5) }
    static var graspFootnote: Font { graspUI(size: 12) }
    static var graspCaption: Font { graspUI(size: 12) }
    static var graspCaption2: Font { graspUI(size: 11) }
}

// MARK: - Typography

/// The app's type scale. Display type (Bricolage) carries the screen and
/// section titles and the big numbers; Instrument Sans carries everything
/// people read and click. Body sits at 14-15, captions at 12-13: this is a
/// dense working app, not a marketing page.
///
/// Tracking: display sizes go negative (about -0.02em), the small uppercase
/// eyebrow goes positive (+0.08em) so its capitals don't jam together.
enum GRASPType {
    /// A screen title -- the one piece of type per screen that is allowed
    /// to be large.
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
    /// Long-form reading prose -- the lesson body. 16 with generous leading
    /// is where reading on screen stops feeling like work.
    case prose
    /// The lesson's opening question, a step up from the body and in a
    /// quieter colour -- a standfirst, not a second title.
    case lede
    /// The lesson's title: display type, a claim rather than a topic.
    case lessonTitle
    /// A section heading inside the lesson.
    case proseH2
    /// Code, and inline runs of it. One rung below `.prose` on purpose -- a
    /// monospaced face has a wider advance at the same point size.
    case mono
    /// A formula on its own line. Monospaced like `.mono`, but at reading
    /// size: this is content, not an annotation of it.
    case formula

    var font: Font {
        switch self {
        case .display: return .graspDisplay(36)
        case .title: return .graspDisplay(18, heavy: false)
        case .rowTitle: return .graspUI(size: 14, weight: .medium)
        case .eyebrow: return .graspUI(size: 12, weight: .semibold)
        case .body: return .graspUI(size: 14)
        case .meta: return .graspUI(size: 12.5)
        case .numeral: return .graspDisplay(30).monospacedDigit()
        case .numeralSmall: return .graspDisplay(17, heavy: false).monospacedDigit()
        case .studyPrompt: return .graspUI(size: 26)
        case .studyAnswer: return .graspUI(size: 17)
        case .prose: return .graspUI(size: 16)
        case .lede: return .graspUI(size: 19)
        case .lessonTitle: return .graspDisplay(32)
        case .proseH2: return .graspDisplay(22, heavy: false)
        case .mono: return .system(size: 14, weight: .regular, design: .monospaced)
        case .formula: return .system(size: 16, weight: .regular, design: .monospaced)
        }
    }

    var tracking: CGFloat {
        switch self {
        case .display: return -0.72
        case .title: return -0.2
        case .rowTitle: return 0
        case .eyebrow: return 0.96
        case .body: return 0
        case .meta: return 0.05
        case .numeral: return -0.6
        case .numeralSmall: return -0.2
        case .studyPrompt: return -0.4
        case .studyAnswer: return -0.1
        case .prose: return 0
        case .lede: return -0.2
        case .lessonTitle: return -0.64
        case .proseH2: return -0.4
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
        .graspDisplay(size, heavy: size >= 20)
    }

    static func graspNumber(_ size: CGFloat) -> Font {
        .graspDisplay(size, heavy: size >= 20).monospacedDigit()
    }

    /// Companion to the two above, for the `AttributedString` run
    /// attributes the inline markdown renderer sets by hand -- a per-run
    /// attribute can't reach the `graspType` view modifier.
    static func graspMono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

// MARK: - Spacing and shape

/// A 4pt grid. The common gaps are 8, 12, 16, 24 and 32; sections sit
/// 32-40 apart.
enum GRASPSpace {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let section: CGFloat = 40
}

enum GRASPRadius {
    /// Cards and panels.
    static let card: CGFloat = 14
    /// Inner wells and rows inside a card.
    static let inner: CGFloat = 10
}

// MARK: - Motion

/// Every duration and curve in one place. Three durations and two curves,
/// nothing longer than `glideDuration`, nothing that overshoots, nothing
/// that blocks input (every animation is state-driven and interruptible).
///
/// - `quick` 0.12 s: press, hover colour and fill, focus.
/// - `base` 0.20 s: cross-fades, status words, flip halves, strips.
/// - `glide` 0.32 s: entrances, slides, thumbs, expand and collapse, fills.
/// - `out` (decelerate) for things that arrive or open; `inOut` for things
///   that move between two places.
///
/// Reduce Motion (the system setting, or `-GRASPForceReduceMotion 1` at
/// launch): positional motion becomes an opacity change at `quick`;
/// opacity-only changes (cross-fades, count-ups) become instant. The tokens
/// below already do that, so a view that uses them needs no check of its own.
enum Motion {
    // MARK: Reduce Motion

    /// True under the system's Reduce Motion, or when the debug launch flag
    /// `-GRASPForceReduceMotion 1` is set.
    static var isReduced: Bool {
        if UserDefaults.standard.bool(forKey: "GRASPForceReduceMotion") { return true }
        #if os(macOS)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        return UIAccessibility.isReduceMotionEnabled
        #endif
    }

    // MARK: Durations and curves

    static let quickDuration = 0.12
    static let baseDuration = 0.20
    static let glideDuration = 0.32

    /// Decelerates into place: arrivals, openings.
    static func out(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0.0, 0.0, 1.0, duration: duration)
    }
    /// Eases both ends: moving between two places, state swaps.
    static func inOut(_ duration: Double) -> Animation {
        .timingCurve(0.4, 0.0, 0.2, 1.0, duration: duration)
    }
    /// No animation at all.
    static let instant = Animation.linear(duration: 0)

    // MARK: Tokens

    /// 0.12 s: a press, a hover, focus. Already as short as Reduce Motion asks.
    static var quick: Animation { out(quickDuration) }
    /// 0.20 s cross-fade; instant under Reduce Motion (opacity-only).
    static var base: Animation { isReduced ? instant : out(baseDuration) }
    /// 0.32 s arrival; a plain `quick` fade under Reduce Motion.
    static var glide: Animation { isReduced ? quick : out(glideDuration) }
    /// 0.32 s move between two places; `quick` under Reduce Motion.
    static var glideInOut: Animation { isReduced ? quick : inOut(glideDuration) }

    // MARK: Names used across the app (all map to the tokens above)

    /// A number rolling to its value: `glide`, and instant under Reduce
    /// Motion (an opacity-only change).
    static var countUp: Animation { isReduced ? instant : out(glideDuration) }

    /// The 190 pt Home numeral rolling to its value: `base`-length, because the
    /// digit morph blurs and a longer roll is still soft after `glide`.
    /// Instant under Reduce Motion.
    static var numeral: Animation { isReduced ? instant : out(baseDuration) }

    /// A thumb or bar that travels between two places (matched geometry):
    /// `glideInOut`, and no travel at all under Reduce Motion.
    static var thumb: Animation { isReduced ? instant : inOut(glideDuration) }

    /// A selection moving, a thumb, a hover: `glideInOut`.
    static var snappy: Animation { glideInOut }
    /// Panels and cards arriving: `glide`.
    static var settle: Animation { glide }
    /// Small icons: `glide`, without the overshoot it used to have.
    static var bouncy: Animation { glide }
    /// Cross-fade: `base`.
    static var fade: Animation { base }
    /// The pressed state of a button: `quick`.
    static var press: Animation { quick }
    /// The fill sweeping across an outlined pill on hover: `base`.
    static var sweep: Animation { isReduced ? quick : out(baseDuration) }
    /// A progress bar filling: `glide`.
    static var fill: Animation { glide }
    /// The card flip's two halves are `baseDuration / 2` each.
    static var flip: Animation { base }
    /// Two things that swap places (a status word and the actions that
    /// replace it): the outgoing one fades out in the first half of `base`
    /// and is gone before the incoming one starts, so both are never visible.
    /// Instant under Reduce Motion.
    static var swapOut: Animation { isReduced ? instant : out(baseDuration / 2) }
    static var swapIn: Animation {
        isReduced ? instant : out(baseDuration / 2).delay(baseDuration / 2)
    }
    /// Gap between items in a staggered reveal (capped by callers).
    static let stagger: Double = 0.05

    /// `animation`, or a `quick` change when Reduce Motion is on.
    static func choose(_ animation: Animation, reduceMotion: Bool) -> Animation {
        (reduceMotion || isReduced) ? quick : animation
    }

    // MARK: Transitions

    /// Arrives from `edge` by a short offset while fading in; just a fade
    /// under Reduce Motion.
    static func slide(from edge: Edge, distance: CGFloat = 12) -> AnyTransition {
        guard !isReduced else { return .opacity }
        switch edge {
        case .top: return .opacity.combined(with: .offset(y: -distance))
        case .bottom: return .opacity.combined(with: .offset(y: distance))
        case .leading: return .opacity.combined(with: .offset(x: -distance))
        case .trailing: return .opacity.combined(with: .offset(x: distance))
        }
    }
}

extension View {
    /// A reveal on first appearance: slides up a few points and fades in,
    /// `index` steps after the first. Just a fade under Reduce Motion.
    func revealOnAppear(index: Int = 0, distance: CGFloat = 8) -> some View {
        modifier(RevealOnAppear(index: index, distance: distance))
    }
}

private struct RevealOnAppear: ViewModifier {
    let index: Int
    let distance: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        let reduced = Motion.isReduced
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduced ? 0 : distance)
            .onAppear {
                // The stagger is capped so a long page never waits on its
                // last row.
                let delay = min(Double(index) * Motion.stagger, 0.25)
                withAnimation(Motion.glide.delay(reduced ? 0 : delay)) { shown = true }
            }
    }
}

extension View {
    /// A menu drawn as a bare icon. macOS needs the borderless style for
    /// that; on iOS a `Menu` with an icon label already looks like one.
    @ViewBuilder
    func borderlessMenu() -> some View {
        #if os(macOS)
        self.menuStyle(.borderlessButton)
        #else
        self
        #endif
    }
}

/// Puts text on the clipboard.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension View {
    /// A minimum window size -- on the Mac, where these screens open as
    /// sheets that would otherwise shrink to fit. On iPhone a screen is
    /// the width of the phone, and a desktop minimum only pushed its edges
    /// off the sides.
    @ViewBuilder
    func macWindowFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }

    /// A study sheet that grows with the window on the Mac: it opens at the
    /// size of the page behind it (macOS 15+) and follows the window when it
    /// is resized, with a floor so nothing gets cramped.
    @ViewBuilder
    func adaptiveStudySheet(minWidth: CGFloat = 680, minHeight: CGFloat = 560) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            self.frame(minWidth: minWidth, idealWidth: 1000, maxWidth: .infinity,
                       minHeight: minHeight, idealHeight: 820, maxHeight: .infinity)
                .presentationSizing(.page)
        } else {
            self.frame(minWidth: minWidth, idealWidth: 1000, maxWidth: .infinity,
                       minHeight: minHeight, idealHeight: 820, maxHeight: .infinity)
        }
        #else
        self
        #endif
    }

    /// A fixed sheet size on the Mac; the full width available on iPhone.
    @ViewBuilder
    func macSheetFrame(width: CGFloat, height: CGFloat? = nil) -> some View {
        #if os(macOS)
        self.frame(width: width, height: height)
        #else
        self.frame(maxWidth: .infinity)
        #endif
    }
}

/// Whether to label buttons with their keyboard shortcuts. A Mac always
/// has a keyboard; on a phone the hint is noise for a key that isn't there.
enum KeyHints {
    #if os(macOS)
    static let shown = true
    #else
    static let shown = false
    #endif
}
