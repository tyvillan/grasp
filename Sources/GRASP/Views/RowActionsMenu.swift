import SwiftUI

/// A "•••" button for a row, with the same actions as its right-click menu.
/// It is always in the view tree (only its opacity changes with hover), so
/// the pointer arriving doesn't change the row's layout and the hover can't
/// flicker. In `inline` mode it takes its own slot at the row's trailing
/// edge, so it never sits on top of a due count or other badge.
private struct HoverActionsModifier<Actions: View>: ViewModifier {
    @State private var hovering = false
    let inline: Bool
    let alignment: Alignment
    let inset: CGFloat
    @ViewBuilder let actions: () -> Actions

    private var button: some View {
        Menu {
            actions()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(GRASPColor.textSecondary)
                .frame(width: 26, height: 26)
                .background(GRASPColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .help("Actions")
    }

    func body(content: Content) -> some View {
        Group {
            if inline {
                HStack(spacing: 4) {
                    content
                    button
                }
            } else {
                content.overlay(alignment: alignment) { button.padding(inset) }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension View {
    /// Adds a hover "•••" menu and the same menu on right-click. `inline`
    /// puts the button in its own slot beside the row instead of over it.
    func rowActions<Actions: View>(
        inline: Bool = false, alignment: Alignment = .trailing, inset: CGFloat = 0,
        @ViewBuilder _ actions: @escaping () -> Actions
    ) -> some View {
        modifier(HoverActionsModifier(inline: inline, alignment: alignment, inset: inset, actions: actions))
            .contextMenu { actions() }
    }
}
