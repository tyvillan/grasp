import SwiftUI

/// A "•••" button that appears at a row's trailing edge while the pointer is
/// over it, offering the same actions as the row's right-click menu. Actions
/// that only existed on right-click were invisible to anyone who didn't
/// know to try it; right-click still works alongside this.
private struct HoverActionsModifier<Actions: View>: ViewModifier {
    @State private var hovering = false
    let alignment: Alignment
    let inset: CGFloat
    @ViewBuilder let actions: () -> Actions

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .overlay(alignment: alignment) {
                if hovering {
                    Menu {
                        actions()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(GRASPColor.textSecondary)
                            .frame(width: 22, height: 20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Actions")
                    .padding(inset)
                }
            }
    }
}

extension View {
    /// Adds a hover "•••" menu and the same menu on right-click.
    func rowActions<Actions: View>(
        alignment: Alignment = .trailing, inset: CGFloat = 0, @ViewBuilder _ actions: @escaping () -> Actions
    ) -> some View {
        modifier(HoverActionsModifier(alignment: alignment, inset: inset, actions: actions))
            .contextMenu { actions() }
    }
}
