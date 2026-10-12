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
        // A destructive button keeps the outlined shape but reads in coral.
        let ink = configuration.role == .destructive ? GRASPColor.rejected : GRASPColor.textPrimary
        configuration.label
            .font(.graspUI(size: 13.5, weight: .medium))
            .foregroundStyle(isEnabled ? ink : GRASPColor.textTertiary)
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
                    ink.opacity(isEnabled ? 0.4 : 0.15), lineWidth: 1)
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

/// The glyph for anything the AI does -- buttons, menu items, "Rewrite
/// all". Never used for a non-AI action.
enum AIGlyph {
    static let symbol = "sparkles"
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
    /// A small tracked caption over the items that follow it.
    case header(String)
}

/// A menu drawn as GRASP's outlined pill.
///
/// Not a SwiftUI `Menu`: on the Mac a borderless `Menu` is an
/// `NSPopUpButton` that keeps only its label's text and image, so the pill's
/// padding and border are dropped -- and a `Menu` whose label is empty
/// collapses to a few points wide, which is how the first version of this
/// (an invisible `Menu` laid over a drawn pill) ended up with no click
/// target at all. Instead the whole pill is an ordinary button, and it opens
/// GRASP's own menu panel anchored under itself, drawn in the app's
/// surfaces and type rather than the system menu's.
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
    private static var openPanel: GRASPMenuPanel?
    /// A click on the pill that opened the menu first closes it (the click
    /// lands outside the panel), then reaches the pill; this keeps that
    /// click from reopening it straight away.
    private static var lastClosed: (anchor: ObjectIdentifier, at: Date)?

    /// Closes whichever pill menu is open.
    static func closeOpenMenu() { openPanel?.dismiss() }

    func present(_ items: [PillMenuItem]) {
        if let last = Self.lastClosed, last.anchor == ObjectIdentifier(self),
           Date().timeIntervalSince(last.at) < 0.25 {
            return
        }
        Self.closeOpenMenu()
        guard let view, let window = view.window else { return }
        let id = ObjectIdentifier(self)
        let panel = GRASPMenuPanel(items: items, minWidth: max(view.bounds.width, 210)) {
            Self.openPanel = nil
            Self.lastClosed = (id, Date())
        }
        let anchorRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        panel.show(under: anchorRect, parent: window)
        Self.openPanel = panel
    }
}

/// The floating window a pill menu is drawn in: borderless, above the app,
/// closed by a click anywhere else, Escape, or picking an item. Arrow keys
/// and Return work while it's open, and so do the items' shortcuts.
@MainActor
private final class GRASPMenuPanel: NSPanel {
    private let model: GRASPMenuModel
    private let onClose: () -> Void
    private var monitors: [Any] = []
    private weak var parentWindowRef: NSWindow?

    init(items: [PillMenuItem], minWidth: CGFloat, onClose: @escaping () -> Void) {
        self.onClose = onClose
        model = GRASPMenuModel(items: items)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        model.choose = { [weak self] index in self?.run(index) }
        let host = NSHostingView(rootView: GRASPMenuList(model: model, minWidth: minWidth))
        host.layoutSubtreeIfNeeded()
        contentView = host
        setContentSize(host.fittingSize)
    }

    /// Opens below `anchor` (screen coordinates), or above it when there
    /// isn't room below -- the profile button sits at the window's foot.
    func show(under anchor: NSRect, parent: NSWindow) {
        parentWindowRef = parent
        appearance = parent.effectiveAppearance
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - 6 - frame.height)
        // A pill near the window's right edge opens its menu leftward,
        // right edges lined up, rather than hanging off the window.
        if origin.x + frame.width > parent.frame.maxX - 8 {
            origin.x = anchor.maxX - frame.width
        }
        if let screen = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - frame.width - 8)
            if origin.y < screen.minY + 8 { origin.y = anchor.maxY + 6 }
        }
        setFrameOrigin(origin)
        parent.addChildWindow(self, ordered: .above)
        orderFront(nil)
        installMonitors()
    }

    func dismiss() {
        guard isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        parentWindowRef?.removeChildWindow(self)
        orderOut(nil)
        close()
        onClose()
    }

    private func run(_ index: Int) {
        guard case .action(_, _, _, _, let disabled, _, _, let perform) = model.items[index], !disabled else { return }
        dismiss()
        perform()
    }

    private func installMonitors() {
        let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self { self.dismiss() }
            return event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        // Another app coming forward, or the window going away.
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        monitors = [mouse, keys, outside].compactMap { $0 }
    }

    /// True when the key was the menu's to handle.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: dismiss(); return true                       // Escape
        case 125: model.move(1); return true                  // Down
        case 126: model.move(-1); return true                 // Up
        case 36, 76:                                          // Return, Enter
            if let index = model.highlighted { run(index) }
            return true
        default: break
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        for (index, item) in model.items.enumerated() {
            if case .action(_, _, _, _, _, _, let shortcut?, _) = item,
               shortcut.key.lowercased() == key,
               mods.intersection([.command, .shift, .option, .control]) == shortcut.modifiers {
                run(index)
                return true
            }
        }
        return false
    }
}

@MainActor @Observable
private final class GRASPMenuModel {
    let items: [PillMenuItem]
    var highlighted: Int?
    var choose: (Int) -> Void = { _ in }

    init(items: [PillMenuItem]) { self.items = items }

    private func isEnabledAction(_ index: Int) -> Bool {
        if case .action(_, _, _, _, let disabled, _, _, _) = items[index] { return !disabled }
        return false
    }

    func move(_ step: Int) {
        let candidates = items.indices.filter(isEnabledAction)
        guard !candidates.isEmpty else { return }
        guard let current = highlighted, let at = candidates.firstIndex(of: current) else {
            highlighted = step > 0 ? candidates.first : candidates.last
            return
        }
        highlighted = candidates[(at + step + candidates.count) % candidates.count]
    }
}

/// The menu itself: GRASP's raised surface, rows that light up with the
/// yellow edge the sidebar uses, AI items with the yellow sparkle and
/// destructive ones in coral.
private struct GRASPMenuList: View {
    @Bindable var model: GRASPMenuModel
    let minWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// Taller than this, the list scrolls -- a course picker can hold a
    /// dozen terms.
    private static let maxHeight: CGFloat = 440

    private var estimatedHeight: CGFloat {
        model.items.reduce(12) { total, item in
            switch item {
            case .divider: total + 10
            case .header: total + 22
            case .action: total + 29
            }
        }
    }

    var body: some View {
        Group {
            if estimatedHeight > Self.maxHeight {
                ScrollViewReader { proxy in
                    ScrollView { rows.padding(5) }
                        .frame(height: Self.maxHeight)
                        .onAppear { if let checked = checkedIndex { proxy.scrollTo(checked, anchor: .center) } }
                }
            } else {
                rows.padding(5)
            }
        }
        .frame(minWidth: minWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(GRASPColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(GRASPColor.hairlineStrong, lineWidth: 1)
        )
        .padding(1)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(Motion.choose(Motion.snappy, reduceMotion: reduceMotion)) { appeared = true } }
    }

    /// A dropdown marks its current choice with a check; the list opens
    /// scrolled to it.
    private var checkedIndex: Int? {
        model.items.indices.first { index in
            if case .action(_, "checkmark", _, _, _, _, _, _) = model.items[index] { return true }
            return false
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                switch item {
                case .divider:
                    Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                        .padding(.vertical, 4).padding(.horizontal, 6)
                case .header(let title):
                    Text(title)
                        .graspType(.eyebrow)
                        .textCase(.uppercase)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, index == 0 ? 4 : 2)
                        .padding(.bottom, 3)
                case .action(let title, let systemImage, let ai, let destructive, let disabled, let help, let shortcut, _):
                    row(index: index, title: title, systemImage: systemImage, ai: ai, destructive: destructive,
                        disabled: disabled, help: help, shortcut: shortcut)
                    .id(index)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private func row(index: Int, title: String, systemImage: String?, ai: Bool, destructive: Bool,
                     disabled: Bool, help: String?, shortcut: (key: String, modifiers: NSEvent.ModifierFlags)?) -> some View {
        let lit = model.highlighted == index && !disabled
        let ink = destructive ? GRASPColor.rejected : GRASPColor.textPrimary
        return HStack(spacing: 9) {
            // A ZStack, not a Group: an item with no icon still keeps the
            // column, so every title lines up.
            ZStack {
                if ai {
                    Image(systemName: AIGlyph.symbol).foregroundStyle(GRASPColor.accent)
                } else if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(destructive ? GRASPColor.rejected : GRASPColor.textSecondary)
                }
            }
            .font(.graspUI(size: 12, weight: .medium))
            .frame(width: 16)
            Text(title)
                .font(.graspUI(size: 13, weight: .medium))
                .foregroundStyle(ink)
                .lineLimit(1)
            Spacer(minLength: GRASPSpace.l)
            if let shortcut {
                Text(Self.symbols(shortcut.modifiers) + shortcut.key.uppercased())
                    .font(.graspUI(size: 12))
                    .foregroundStyle(GRASPColor.textTertiary)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: 28)
        .background {
            if lit {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(destructive ? GRASPColor.rejectedSoft : GRASPColor.accentSoft)
                    .overlay(alignment: .leading) {
                        Capsule().fill(destructive ? GRASPColor.rejected : GRASPColor.brand)
                            .frame(width: 3, height: 14)
                            .padding(.leading, 3)
                    }
            }
        }
        .opacity(disabled ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.highlighted = disabled ? nil : index }
            else if model.highlighted == index { model.highlighted = nil }
        }
        .onTapGesture { if !disabled { model.choose(index) } }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !disabled { model.choose(index) } }
    }

    private static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }
}

/// A small "⋯" square for a row in a popup or list, opening GRASP's menu
/// panel.
struct IconMenu: View {
    var systemImage = "ellipsis"
    var help = "Actions"
    let items: () -> [PillMenuItem]
    @State private var anchor = MenuAnchor()
    @State private var hovering = false

    var body: some View {
        Button {
            anchor.present(items())
        } label: {
            Image(systemName: systemImage)
                .font(.graspUI(size: 12, weight: .bold))
                .foregroundStyle(hovering ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                .frame(width: 26, height: 26)
                .background(hovering ? GRASPColor.surfaceRaised : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A pick-one field for popups: shows the choice in GRASP's field look and
/// opens GRASP's menu panel, with a check by the current choice. Replaces
/// the system pop-up button, whose menu is drawn by macOS.
struct GRASPDropdown<Value: Hashable>: View {
    struct Group {
        var title: String?
        var options: [(value: Value, label: String)]
    }

    @Binding var selection: Value
    let groups: [Group]
    var placeholder = "Choose…"
    @State private var anchor = MenuAnchor()
    @State private var hovering = false

    init(selection: Binding<Value>, options: [(value: Value, label: String)], placeholder: String = "Choose…") {
        _selection = selection
        groups = [Group(title: nil, options: options)]
        self.placeholder = placeholder
    }

    init(selection: Binding<Value>, groups: [Group], placeholder: String = "Choose…") {
        _selection = selection
        self.groups = groups
        self.placeholder = placeholder
    }

    private var currentLabel: String? {
        groups.lazy.flatMap(\.options).first { $0.value == selection }?.label
    }

    var body: some View {
        Button {
            anchor.present(items)
        } label: {
            HStack(spacing: 8) {
                Text(currentLabel ?? placeholder)
                    .foregroundStyle(currentLabel == nil ? GRASPColor.textTertiary : GRASPColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.graspUI(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? GRASPColor.accent : GRASPColor.textTertiary)
            }
            .graspFieldChrome(focused: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .onHover { hovering = $0 }
        .accessibilityValue(currentLabel ?? placeholder)
    }

    private var items: [PillMenuItem] {
        var items: [PillMenuItem] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { items.append(.divider) }
            if let title = group.title { items.append(.header(title)) }
            for option in group.options {
                let value = option.value
                items.append(.action(option.label, systemImage: value == selection ? "checkmark" : nil) {
                    selection = value
                })
            }
        }
        return items
    }
}

/// The anchor a custom button opens a GRASP menu under.
struct MenuAnchorHost: View {
    let anchor: MenuAnchor
    var body: some View { MenuAnchorView(anchor: anchor) }
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
