import SwiftUI

/// The 60pt bar across the top of the window, above both the sidebar and
/// the content. On the left, over the sidebar, the GRASP wordmark -- which
/// is also the Home button. On the right, the window's few global actions.
/// The traffic lights sit in its top-left corner (the window's title bar is
/// hidden), and dragging its empty space moves the window.
struct TopBar<Trailing: View>: View {
    static var height: CGFloat { 60 }

    let sidebarWidth: CGFloat
    let showsSidebar: Bool
    let onHome: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    @State private var wordmarkActive = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                // Room for the traffic lights.
                Color.clear.frame(width: 78)
                Wordmark(isActive: $wordmarkActive, action: onHome)
                Spacer(minLength: 0)
            }
            .frame(width: showsSidebar ? sidebarWidth : 78 + 120, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(showsSidebar ? GRASPColor.surface : GRASPColor.canvas)

            if showsSidebar {
                Rectangle().fill(GRASPColor.hairline).frame(width: 1)
            }

            // The acronym slides out here, into the bar's empty space, and
            // never over the sidebar or a control.
            AcronymReveal(isShown: wordmarkActive)
                .padding(.leading, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .clipped()

            HStack(spacing: 6) { trailing() }
                .padding(.trailing, 16)
        }
        .frame(height: Self.height)
        .background(GRASPColor.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
        .windowDraggable()
    }
}

/// The yellow square and "GRASP". On hover or keyboard focus the square
/// turns 90° and grows a little, the letters spread, and the acronym slides
/// out along the bar (`AcronymReveal`). Clicking goes Home.
private struct Wordmark: View {
    @Binding var isActive: Bool
    let action: () -> Void
    @FocusState private var focused: Bool
    @State private var hovering = false
    private var reduceMotion: Bool { Motion.isReduced }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(GRASPColor.brand)
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(isActive && !reduceMotion ? 90 : 0))
                    .scaleEffect(isActive && !reduceMotion ? 1.12 : 1)
                    .opacity(isActive && reduceMotion ? 0.75 : 1)
                Text("GRASP")
                    .font(.graspDisplay(22))
                    .tracking(isActive ? 22 * 0.07 : 0)
                    .foregroundStyle(GRASPColor.textPrimary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(GRASPColor.brand, lineWidth: 2)
                    .padding(-2)
            }
        }
        .focusEffectDisabled()
        .onHover { hovering = $0; update() }
        .onChange(of: focused) { update() }
        .animation(Motion.choose(Motion.bouncy, reduceMotion: reduceMotion), value: isActive)
        .accessibilityLabel("GRASP: Gather Resources, Apply, Study, Perform. Go to Home")
        .help("Home")
    }

    private func update() { isActive = hovering || focused }
}

/// G Gather · R Resources · A Apply · S Study · P Perform, each a yellow
/// display initial and the word, sliding in from the left 50ms apart.
private struct AcronymReveal: View {
    let isShown: Bool
    private var reduceMotion: Bool { Motion.isReduced }

    private static let words = ["Gather", "Resources", "Apply", "Study", "Perform"]

    var body: some View {
        HStack(spacing: 22) {
            ForEach(Array(Self.words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 5) {
                    Text(String(word.prefix(1)))
                        .font(.graspDisplay(19))
                        .foregroundStyle(GRASPColor.accent)
                    Text(word)
                        .font(.graspUI(size: 14, weight: .medium))
                        .foregroundStyle(GRASPColor.textPrimary)
                }
                .fixedSize()
                .opacity(isShown ? 1 : 0)
                .offset(x: isShown || reduceMotion ? 0 : -24)
                .animation(
                    Motion.choose(Motion.snappy, reduceMotion: reduceMotion)
                        .delay(isShown ? Double(index) * Motion.stagger : 0),
                    value: isShown
                )
            }
        }
        .accessibilityHidden(true)
    }
}

/// A plain icon button for the top bar.
struct TopBarButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.graspUI(size: 14, weight: .medium))
                .foregroundStyle(hovering ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(hovering ? GRASPColor.surfaceRaised : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

extension View {
    /// Dragging this view's empty space moves the window (macOS 15+).
    @ViewBuilder
    func windowDraggable() -> some View {
        if #available(macOS 15.0, *) {
            self.gesture(WindowDragGesture())
        } else {
            self
        }
    }
}
