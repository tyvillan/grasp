import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The one primary action on a screen: a yellow pill with ink text. Lifts
/// 2pt and brightens on hover, presses to 0.97. Every other button is a
/// `GRASPQuietButton` (an outlined pill) -- one filled yellow button per
/// screen is what keeps it loud.
struct GRASPProminentButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Defaults to the brand yellow -- pass `.success` (or any other tint)
    /// for a same-shape button that needs to read as a different verdict.
    var tint: Color = GRASPColor.brand
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let lifted = isHovering && isEnabled && !configuration.isPressed && !reduceMotion
        configuration.label
            .font(.graspUI(size: 13.5, weight: .semibold))
            .foregroundStyle(isEnabled ? GRASPColor.ink : GRASPColor.textTertiary)
            .padding(.horizontal, 18)
            .frame(minHeight: 30)
            .background(Capsule().fill(isEnabled ? tint : GRASPColor.surface))
            .overlay(Capsule().strokeBorder(isEnabled ? .clear : GRASPColor.hairline, lineWidth: 1))
            .brightness(lifted ? 0.05 : 0)
            .offset(y: lifted ? -2 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(Motion.snappy, value: isHovering)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// The default button: an outlined pill, cream text, a 40% cream edge. On
/// hover a raised fill sweeps in from the left.
struct GRASPQuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.graspUI(size: 13.5, weight: .medium))
            .foregroundStyle(isEnabled ? GRASPColor.textPrimary : GRASPColor.textTertiary)
            .padding(.horizontal, 16)
            .frame(minHeight: 30)
            .background(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(GRASPColor.surfaceRaised)
                        .frame(width: isHovering && isEnabled ? geo.size.width : (reduceMotion ? geo.size.width : 0))
                        .opacity(isHovering && isEnabled ? 1 : 0)
                }
            }
            .overlay(
                Capsule().strokeBorder(
                    GRASPColor.textPrimary.opacity(isEnabled ? 0.4 : 0.15), lineWidth: 1)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { isHovering = $0 }
            .animation(Motion.sweep, value: isHovering)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Used for the two mastery verdicts in a study session, where the choice
/// itself is the screen's main interaction and deserves more presence than
/// a standard push button.
struct GRASPVerdictButton: ButtonStyle {
    let tint: Color
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.graspUI(size: 13, weight: .semibold))
            .tracking(-0.1)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovering ? tint.opacity(0.16) : tint.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(tint.opacity(isHovering ? 0.55 : 0.3), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

/// A small tinted label -- a card's status, a note's "Out of date".
struct PreviewChip: View {
    let text: String
    let tint: Color
    let tintSoft: Color
    var icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon).font(.graspUI(size: 8))
            }
            Text(text)
        }
        .graspType(.meta)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(tintSoft, in: Capsule())
    }
}

/// The label that opens a section -- GRASP's one recurring typographic
/// signature: a 6pt yellow square (the brand dot), then the name in small
/// tracked capitals.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            BrandDot(size: 6)
            Text(text)
                .graspType(.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(GRASPColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The small yellow square from the wordmark.
struct BrandDot: View {
    var size: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
            .fill(GRASPColor.brand)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A course's color dot (sidebar and calendar only -- never Home).
struct CourseDot: View {
    let color: Color?
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color ?? GRASPColor.hairlineStrong)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A GRASP card: the panel fill, a 14pt radius and a hairline edge. No
    /// shadow -- depth comes from the surface steps.
    func graspCard(padding: CGFloat = GRASPSpace.xl, fill: Color = GRASPColor.surface) -> some View {
        self
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous)
                    .strokeBorder(GRASPColor.hairline, lineWidth: 1)
            )
    }
}

/// Initials-in-a-circle avatar, reused by the picker and this menu so
/// switching profiles doesn't change what "you" look like in the UI.
struct Avatar: View {
    let name: String
    var size: CGFloat = 32
    var fontSize: CGFloat = 13

    var body: some View {
        ZStack {
            Circle().fill(GRASPColor.brand)
            Text(initials)
                .font(.graspUI(size: fontSize, weight: .bold))
                .foregroundStyle(GRASPColor.ink)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// "‹ Study guides" above a page opened from a list, where there is no
/// navigation stack to supply a back button.
struct BackBar: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.graspUI(size: 11, weight: .semibold))
                        .offset(x: hovering ? -3 : 0)
                    Text(title)
                }
                .font(.graspUI(size: 13, weight: .medium))
                .foregroundStyle(hovering ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .onHover { hovering = $0 }
            .animation(Motion.snappy, value: hovering)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(alignment: .bottom) { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
    }
}

#if os(macOS)
/// One entry in a `PillMenu`.
enum PillMenuItem {
    /// `ai` marks an action the AI performs: it gets the yellow sparkle,
    /// the one glyph GRASP uses for AI everywhere. `shortcut` is shown beside
    /// the item (and works while the menu is open); the view registers the
    /// same shortcut for when it isn't.
    case action(_ title: String, systemImage: String? = nil, ai: Bool = false, destructive: Bool = false,
                disabled: Bool = false, help: String? = nil,
                shortcut: (key: String, modifiers: NSEvent.ModifierFlags)? = nil, perform: () -> Void)
    case divider
}

/// The glyph for anything the AI does -- buttons, menu items, "Rewrite
/// all". Never used for a non-AI action.
enum AIGlyph {
    static let symbol = "sparkles"
}

/// A menu drawn as GRASP's outlined pill.
///
/// Not a SwiftUI `Menu`: on the Mac a borderless `Menu` is an
/// `NSPopUpButton` that keeps only its label's text and image, so the pill's
/// padding and border are dropped -- and a `Menu` whose label is empty
/// collapses to a few points wide, which is how the first version of this
/// (an invisible `Menu` laid over a drawn pill) ended up with no click
/// target at all. Instead the whole pill is an ordinary button, and it opens
/// a native `NSMenu` anchored under itself. That also lets a destructive
/// item be drawn in coral, which a SwiftUI menu can't do.
struct PillMenu: View {
    let title: String
    var systemImage: String? = nil
    var isBusy = false
    /// False for the icon-only "⋯" pill; the title is still its
    /// accessibility label.
    var showsTitle = true
    let items: () -> [PillMenuItem]
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.present(items())
        } label: {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.graspUI(size: 11, weight: showsTitle ? .medium : .bold))
                }
                if showsTitle {
                    Text(title)
                    Image(systemName: "chevron.down").font(.graspUI(size: 9, weight: .semibold))
                }
            }
        }
        .buttonStyle(GRASPQuietButton())
        .background(MenuAnchorView(anchor: anchor))
        .help(showsTitle ? "" : title)
        .accessibilityLabel("\(title) menu")
        .accessibilityAddTraits(.isButton)
    }
}

/// Holds the AppKit view the menu opens under.
@MainActor
final class MenuAnchor {
    fileprivate weak var view: NSView?
    /// The menu on screen, if any, so a view change can close it.
    private static weak var openMenu: NSMenu?

    /// Closes whichever pill menu is open.
    static func closeOpenMenu() { openMenu?.cancelTracking() }

    func present(_ items: [PillMenuItem]) {
        guard let view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var handlers: [MenuHandler] = []
        for item in items {
            switch item {
            case .divider:
                menu.addItem(.separator())
            case .action(let title, let systemImage, let ai, let destructive, let disabled, let help, let shortcut, let perform):
                let handler = MenuHandler(perform)
                handlers.append(handler)
                let menuItem = NSMenuItem(title: title, action: #selector(MenuHandler.run), keyEquivalent: "")
                menuItem.target = handler
                menuItem.isEnabled = !disabled
                menuItem.toolTip = help
                if let shortcut {
                    menuItem.keyEquivalent = shortcut.key.lowercased()
                    menuItem.keyEquivalentModifierMask = shortcut.modifiers
                }
                if ai {
                    menuItem.image = NSImage(systemSymbolName: AIGlyph.symbol, accessibilityDescription: "AI")?
                        .withSymbolConfiguration(.init(paletteColors: [NSColor(GRASPColor.accent)]))
                } else if let systemImage {
                    menuItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
                }
                if destructive {
                    let coral = NSColor(GRASPColor.rejected)
                    menuItem.attributedTitle = NSAttributedString(
                        string: title, attributes: [.foregroundColor: disabled ? coral.withAlphaComponent(0.4) : coral,
                                                    .font: NSFont.menuFont(ofSize: 0)])
                    menuItem.image = menuItem.image?.withSymbolConfiguration(.init(paletteColors: [coral]))
                }
                menu.addItem(menuItem)
            }
        }
        // Keeps the handlers alive while the menu is open; `popUp` returns
        // only once it closes, after any chosen item has run.
        MenuAnchor.openMenu = menu
        withExtendedLifetime(handlers) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
    }
}

private final class MenuHandler: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc func run() { perform() }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    /// Flipped, so "below the pill" is +y like the rest of SwiftUI.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
