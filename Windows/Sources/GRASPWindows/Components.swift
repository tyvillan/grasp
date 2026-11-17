import Foundation
import SwiftCrossUI

// Shared building blocks, after the Mac's Controls.swift (DESIGN.md "Yellow
// budget", "Patterns"). WinUI has no shadows and no animation here, so depth
// is the surface ladder and a 1 pt hairline: a view gets a border by padding
// 1 pt over a hairline-coloured background.

extension View {
    /// Rounded fill with a 1 pt edge, drawn without extra shape views (each
    /// shape costs about 2.5 ms; modifiers on one view cost almost nothing).
    func edged(fill: Color, edge: Color, radius: Int) -> some View {
        self.background(fill)
            .cornerRadius(radius - 1)
            .padding(1)
            .background(edge)
            .cornerRadius(radius)
    }
}

/// A 1 pt horizontal rule. `Divider` stretches its container, so this is
/// a rectangle with a fixed height.
struct HairlineRule: View {
    var strong = false

    var body: some View {
        Rectangle().fill(strong ? GRASPColor.hairlineStrong : GRASPColor.hairline).frame(height: 1.0)
    }
}

/// A 1 pt vertical rule.
struct HairlineColumn: View {
    var strong = false

    var body: some View {
        Rectangle().fill(strong ? GRASPColor.hairlineStrong : GRASPColor.hairline).frame(width: 1.0)
    }
}

typealias GRASPAction = @MainActor @Sendable () -> Void

/// The glyph that means "AI acts here": generate, rewrite, refine, AI-made
/// drafts and Settings > AI. Used for nothing else, and always `accent`.
struct AIGlyph: View {
    var size = 13.0

    var body: some View {
        Text("\u{2726}")
            .font(Font.system(size: size, weight: .semibold))
            .foregroundColor(GRASPColor.accent)
            .fixedSize()
    }
}

/// GRASP's buttons. `primary` is the screen's one filled yellow button;
/// `secondary` is the outlined pill every other action uses; `destructive` is
/// the same pill in coral. `ai` puts the sparkle before the title (AI actions
/// are outlined, never filled).
struct GRASPButton: View {
    enum Kind { case primary, secondary, destructive }

    let title: String
    var kind: Kind = .secondary
    var ai = false
    let action: @MainActor @Sendable () -> Void

    init(_ title: String, kind: Kind = .secondary, ai: Bool = false,
         action: @escaping @MainActor @Sendable () -> Void) {
        self.title = title
        self.kind = kind
        self.ai = ai
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var label: some View {
        let ink: Color = switch kind {
        case .primary: GRASPColor.ink
        case .secondary: GRASPColor.textPrimary
        case .destructive: GRASPColor.rejected
        }
        return HStack(spacing: 6) {
            if ai { AIGlyph(size: 12) }
            Text(title)
                .font(GRASPFont.button)
                .foregroundColor(ink)
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, kind == .primary ? 22 : 18)
        .padding(.vertical, kind == .primary ? 8 : 6)
        .background(kind == .primary ? GRASPColor.brand : Color.clear)
        // Half the pill's height: WinUI draws a larger radius as a lozenge.
        .cornerRadius(kind == .primary ? 17 : 15)
        .overlay {
            // An outline is a stroked shape: a transparent fill can't be
            // edged by padding over a coloured background.
            if kind != .primary {
                Capsule().inset(by: 0.5).stroke(GRASPColor.hairlineStrong, style: StrokeStyle(width: 1.0))
            }
        }
    }
}

/// One option of a segmented control or a row of filter pills: raised
/// surface and a hairline when selected, never yellow.
struct PillOption: View {
    let text: String
    var count: Int?
    let isSelected: Bool

    /// The selected pill is a raised surface with a hairline; the others
    /// are bare, with a 1 pt margin so every pill is the same size. Edge
    /// layers only where they show (each costs a container on every
    /// screen switch).
    var body: some View {
        if isSelected {
            label.edged(fill: GRASPColor.surfaceRaised, edge: GRASPColor.hairlineStrong, radius: GRASPRadius.inner)
        } else {
            label.padding(1)
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(GRASPFont.rowTitle)
                .foregroundColor(isSelected ? GRASPColor.textPrimary : GRASPColor.textSecondary)
            if let count {
                Text("\(count)")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
        }
        // Otherwise a row squeezes labels to "Mon...".
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

/// A track of pills, the cream segmented control: Cards / Overview, Month /
/// Week / Agenda, and the filter rows.
struct SegmentedChoice<Option: Equatable>: View {
    let options: [Option]
    let selection: Option
    let label: (Option) -> String
    let choose: (Option) -> Void
    var count: ((Option) -> Int?)?

    init(options: [Option], selection: Option, label: @escaping (Option) -> String,
         count: ((Option) -> Int?)? = nil, choose: @escaping (Option) -> Void) {
        self.options = options
        self.selection = selection
        self.label = label
        self.count = count
        self.choose = choose
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                PillOption(text: label(option), count: count?(option), isSelected: option == selection)
                    .onTapGesture { choose(option) }
            }
        }
        .padding(2)
        .edged(fill: GRASPColor.inset, edge: GRASPColor.hairline, radius: GRASPRadius.inner + 2)
        .fixedSize()
    }
}

/// A strip at the top of a list: one rounded `surface` band with a hairline,
/// a leading glyph, one message and at most one action. A failed AI run
/// replaces it with the error and Retry.
struct StatusStrip<Glyph: View>: View {
    let message: String
    var actionTitle: String?
    var action: GRASPAction?
    let glyph: Glyph

    init(_ message: String, actionTitle: String? = nil, action: GRASPAction? = nil,
         @ViewBuilder glyph: () -> Glyph) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.glyph = glyph()
    }

    var body: some View {
        HStack(spacing: 10) {
            glyph
            Text(message)
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textPrimary)
            Spacer()
            if let actionTitle, let action {
                GRASPButton(actionTitle, action: action)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.card)
    }
}

/// The AI strip: the sparkle means AI acts here ("Generating cards from ...",
/// "N new cards", Stop).
struct AIStrip: View {
    let message: String
    var actionTitle: String?
    var action: GRASPAction?

    var body: some View {
        StatusStrip(message, actionTitle: actionTitle, action: action) { AIGlyph(size: 14) }
    }
}

/// An empty state: one action and at most one quiet way out, no filters or
/// counts. The action is the screen's filled yellow button.
struct EmptyState: View {
    let title: String
    var message: String?
    var actionTitle: String?
    var action: GRASPAction?
    var quietTitle: String?
    var quiet: GRASPAction?

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary)
            if let message {
                Text(message)
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
                    .frame(maxWidth: 440.0)
            }
            if let actionTitle, let action {
                GRASPButton(actionTitle, kind: .primary, action: action).padding(.top, 6)
            }
            if let quietTitle, let quiet {
                Text(quietTitle)
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
                    .onTapGesture(perform: quiet)
            }
        }
        .padding(24)
    }
}

/// The floating selection bar: "N selected" and the actions (Approve N,
/// Suspend, Move to, Delete in coral), then a clear control. With no shadow
/// on Windows it is a raised surface with a strong hairline.
struct SelectionBar: View {
    struct Action {
        let title: String
        var kind: GRASPButton.Kind = .secondary
        let run: GRASPAction
    }

    let count: Int
    let actions: [Action]
    let clear: GRASPAction

    var body: some View {
        HStack(spacing: 8) {
            Text("\(count) selected")
                .font(GRASPFont.rowTitle)
                .foregroundColor(GRASPColor.textPrimary)
                .padding(.leading, 6)
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                GRASPButton(action.title, kind: action.kind, action: action.run)
            }
            Text("Clear")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
                .padding(.horizontal, 6)
                .onTapGesture(perform: clear)
        }
        .fixedSize()
        .padding(8)
        .edged(fill: GRASPColor.surfaceRaised, edge: GRASPColor.hairlineStrong, radius: GRASPRadius.card)
    }
}

/// A list row: content, then a hairline under it. `selected` is the raised
/// surface with a 3 pt yellow edge on the left (the sidebar's current-item
/// edge); hover and focus are the OS's.
struct HairlineRow<Content: View>: View {
    var selected = false
    let content: Content

    init(selected: Bool = false, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(selected ? GRASPColor.brand : Color.clear)
                    .frame(width: 3.0)
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .background(selected ? GRASPColor.surfaceRaised : Color.clear)
            HairlineRule()
        }
    }
}

// MARK: - Watching without redrawing

extension View {
    /// `onChange(of:)` hung on a zero-size view behind this one.
    /// SwiftCrossUI's `OnChangeModifier` keeps the last value in an `@State`,
    /// and every write to it (the first when the view appears, then one per
    /// change) lays out and commits everything the modifier wraps again. On
    /// the deck page that was the whole card list or lesson, five to seven
    /// extra passes of 70 to 200 ms after every click. Behind a zero-size
    /// view, that write redraws only the empty view.
    func watch<Value: Equatable>(_ value: Value, perform action: @escaping () -> Void) -> some View {
        background(Color.clear.frame(width: 0.0, height: 0.0).onChange(of: value, perform: action))
    }

    /// `task` the same way: `TaskModifier` stores its task in an `@State`
    /// through an `onChange`, which redraws whatever it wraps.
    func quietTask(_ action: @escaping () async -> Void) -> some View {
        background(Color.clear.frame(width: 0.0, height: 0.0).task(action))
    }
}

extension Binding where Value: Equatable {
    /// The same binding, but a write of the value it already holds is
    /// dropped. WinUI controls report their value back when they are made,
    /// and every `@State` write redraws the view that owns it.
    func changesOnly() -> Binding<Value> {
        Binding(get: { self.wrappedValue }, set: { if $0 != self.wrappedValue { self.wrappedValue = $0 } })
    }
}

/// The window's width as the root reader last saw it, for the few places
/// that change shape when the window is narrow (the Cards toolbar). Read in
/// a body; the reader re-creates the content on every resize, so bodies see
/// the new width.
enum WindowLayout {
    nonisolated(unsafe) private(set) static var width = 1700.0

    /// Under this the Cards toolbar takes two rows (its one row needs about
    /// 1,400 pt of window beside the sidebar and deck column).
    static let narrowBelow = 1440.0
    static var isNarrow: Bool { width < narrowBelow }

    static func note(width: Double) {
        if width.isFinite && width > 0 { self.width = width }
    }
}

/// The detail pane's width for a `GeometryReader` pass. SwiftCrossUI runs a
/// reader at width 0 and infinity before the real width, and a wrong guess
/// sticks: the content's nodes keep the layout they made for it, since the
/// real pass offers them the same size. The window's width less the sidebar
/// is the pane's real width, so the first visit after launch (the calendar
/// used to fall back to 1400, about 26 pt narrow) and a resized window both
/// start right.
enum PaneWidth {
    private static var lastWidth: Double?

    static func width(_ proposed: Double) -> Double {
        if proposed.isFinite && proposed > 0 {
            lastWidth = Double(proposed)
            return Double(proposed)
        }
        #if os(Windows)
        if let client = WindowIcon.clientWidth(), client > Sidebar.width + 1 { return client - Sidebar.width - 1 }
        #endif
        return lastWidth ?? 1400
    }
}

// MARK: - Sheets

/// The Mac's `GRASPSheet`, as the Library page's sheets draw it: a yellow
/// square eyebrow, a heavy title (with the sparkle for AI), a muted line,
/// the content, then the buttons on the right. One yellow button at most.
struct GRASPSheet<Content: View, Footer: View>: View {
    let eyebrow: String
    let title: String
    var message: String?
    var ai = false
    var width = 520.0
    /// What Return does: the sheet's yellow button. Nil when it has none.
    var confirm: (() -> Void)?
    var multiline = false
    let content: Content
    let footer: Footer

    init(eyebrow: String, title: String, message: String? = nil, ai: Bool = false, width: Double = 520,
         confirm: (() -> Void)? = nil, multiline: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.eyebrow = eyebrow
        self.title = title
        self.message = message
        self.ai = ai
        self.width = width
        self.confirm = confirm
        self.multiline = multiline
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(eyebrow)
            HStack(spacing: 8) {
                if ai { AIGlyph(size: 16) }
                Text(title)
                    .font(Font.system(size: 22, weight: .heavy))
                    .foregroundColor(GRASPColor.textPrimary)
            }
            if let message {
                Text(message)
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            content
            if let confirm {
                HStack(spacing: 8) { footer }.returnConfirms(multiline: multiline, confirm)
            } else {
                HStack(spacing: 8) { footer }
            }
        }
        .padding(24)
        .frame(width: width)
        .background(GRASPColor.canvas)
    }
}

// MARK: - Return in a sheet

extension View {
    /// Return presses this sheet's one yellow button (`confirm`), as the
    /// Mac's `.keyboardShortcut(.defaultAction)`. Put it on any view inside
    /// the sheet; it holds while the sheet is up. A sheet with a multi-line
    /// text box passes `multiline`, so Return types a new line there and
    /// Ctrl+Return confirms. Escape needs nothing: WinUI's dialog closes itself.
    func returnConfirms(multiline: Bool = false, _ confirm: @escaping () -> Void) -> some View {
        background(ReturnRegistrar(multiline: multiline, confirm: confirm))
    }
}

private struct ReturnRegistrar: View {
    let multiline: Bool
    let confirm: () -> Void
    @State var id = UUID().uuidString

    var body: some View {
        Color.clear
            .frame(width: 0.0, height: 0.0)
            #if os(Windows)
            .onAppear { KeyCommands.pushSheet(.init(id: id, confirm: confirm, multiline: multiline)) }
            .onDisappear { KeyCommands.popSheet(id) }
            #endif
    }
}

/// A small label above a field in a sheet.
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(GRASPFont.eyebrow)
            .foregroundColor(GRASPColor.textTertiary)
    }
}

/// A tick box: a rounded square that fills yellow with an ink check, as in
/// the Mac's popups.
struct TickBox: View {
    let isOn: Bool
    var round = false

    var body: some View {
        Text(isOn ? "\u{2713}" : " ")
            .font(Font.system(size: 12, weight: .bold))
            .foregroundColor(GRASPColor.ink)
            .frame(width: 18.0, height: 18.0)
            .background(isOn ? GRASPColor.brand : GRASPColor.hairlineStrong)
            .cornerRadius(round ? 9 : 5)
    }
}
