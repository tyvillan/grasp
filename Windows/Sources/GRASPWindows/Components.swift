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
