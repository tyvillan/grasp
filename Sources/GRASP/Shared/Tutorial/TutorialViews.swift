import SwiftUI

// MARK: - Marking a real control

extension View {
    /// Tells the tutorial where this real control is, so it can be lit up. It
    /// changes nothing about the control, and does nothing when no tutorial is
    /// running.
    func tutorialTarget(_ target: TutorialTarget) -> some View {
        modifier(TutorialTargetModifier(target: target))
    }
}

extension View {
    /// The same, for a control that is only sometimes one the tutorial points at.
    @ViewBuilder func tutorialTarget(_ target: TutorialTarget?) -> some View {
        if let target { tutorialTarget(target) } else { self }
    }
}

#if os(iOS)
extension View {
    /// Toolbar buttons give no usable position (they report a frame in their
    /// own bar), so on the iPhone the tutorial points at where the trailing
    /// buttons of the navigation bar sit: its right edge, `width` wide, below
    /// the status bar. Put this on the screen's content, not on the button.
    func tutorialTrailingBarTarget(_ target: TutorialTarget, width: CGFloat) -> some View {
        modifier(TutorialTrailingBarModifier(target: target, width: width))
    }
}

private struct TutorialTrailingBarModifier: ViewModifier {
    let target: TutorialTarget
    let width: CGFloat
    @Environment(TutorialFlow.self) private var flow: TutorialFlow?
    @State private var owner = UUID()

    /// The bar's buttons start right under the status bar or Dynamic Island,
    /// whatever the screen's own title does below them.
    private static var statusBarHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow?.safeAreaInsets.top ?? 20
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                let frame = proxy.frame(in: .global)
                return CGRect(x: frame.maxX - 16 - width, y: Self.statusBarHeight, width: width, height: 44)
            } action: { flow?.setFrame($0, for: target, owner: owner) }
            .onDisappear { flow?.clearFrame(for: target, owner: owner) }
    }
}
#endif

private struct TutorialTargetModifier: ViewModifier {
    let target: TutorialTarget
    @Environment(TutorialFlow.self) private var flow: TutorialFlow?
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                flow?.setFrame(frame, for: target, owner: owner)
            }
            .onDisappear { flow?.clearFrame(for: target, owner: owner) }
    }
}

// MARK: - The spotlight

/// The dimmed screen with a rounded hole cut out over the real control.
private nonisolated struct SpotlightShape: Shape {
    var hole: CGRect
    var radius: CGFloat = 12

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(hole.origin.x, hole.origin.y), .init(hole.size.width, hole.size.height)) }
        set {
            hole = CGRect(x: newValue.first.first, y: newValue.first.second,
                          width: newValue.second.first, height: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if !hole.isEmpty {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return path
    }
}

// MARK: - The overlay

/// Dims the window, lights up the real control a step is about, and shows the
/// coach card. Sits over the whole window, above everything else. The dim
/// swallows taps, so nothing behind it can be changed; only on a step that
/// waits for a real tap is the lit area left open, and only for navigation.
struct TutorialOverlay: View {
    @Environment(TutorialFlow.self) private var flow
    @AccessibilityFocusState private var cardFocused: Bool

    var body: some View {
        ZStack {
            if flow.isActive {
                ZStack {
                    dimLayer
                    cardLayer
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.base, value: flow.isActive)
    }

    // MARK: Dim

    private static let ringInset: CGFloat = 6

    private var dimLayer: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let hole = flow.spotlight.map {
                $0.offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: -Self.ringInset, dy: -Self.ringInset)
            }
            let shape = SpotlightShape(hole: hole ?? .zero)
            ZStack {
                shape
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                    // Taps on the dim go nowhere. The lit area is open only
                    // while a step waits for a real tap.
                    .contentShape(shape, eoFill: flow.isWaiting)
                    .onTapGesture {}
                if let hole {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(GRASPColor.textPrimary, lineWidth: 2)
                        .frame(width: hole.width, height: hole.height)
                        .position(x: hole.midX, y: hole.midY)
                        .allowsHitTesting(false)
                }
            }
            .animation(Motion.thumb, value: hole)
            .animation(Motion.base, value: flow.index)
            .onAppear { flow.setViewport(frame) }
            .onChange(of: proxy.size) { _, _ in flow.setViewport(proxy.frame(in: .global)) }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: Coach card

    private static let cardWidth: CGFloat = 360
    private static let margin: CGFloat = 12
    private static let gap: CGFloat = 12
    private static let minCardHeight: CGFloat = 170

    private var cardLayer: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let size = proxy.size
            let hole = flow.spotlight.map {
                $0.offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: -Self.ringInset, dy: -Self.ringInset)
            }
            let placement = Placement.make(hole: hole, in: size)
            ZStack(alignment: .topLeading) {
                Color.clear
                CoachCard(flow: flow, cardFocused: $cardFocused)
                    .frame(width: placement.width, height: placement.height, alignment: placement.alignment)
                    .offset(x: placement.x, y: placement.y)
                    .animation(Motion.thumb, value: placement)
            }
        }
        .padding(Self.margin)
        .onChange(of: flow.index) { _, _ in cardFocused = true }
        .onAppear { cardFocused = true }
    }

    /// Where the card goes: the largest open space beside the lit control,
    /// so the card never covers it. With nothing lit, the middle.
    struct Placement: Equatable {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var alignment: Alignment

        static func make(hole: CGRect?, in size: CGSize) -> Placement {
            // `size` and `hole` are both inside the 12 pt margin.
            let width = min(TutorialOverlay.cardWidth, size.width)
            guard let hole else {
                let height = min(size.height, 460)
                return Placement(x: (size.width - width) / 2, y: (size.height - height) / 2,
                                 width: width, height: height, alignment: .center)
            }
            let gap = TutorialOverlay.gap
            let minH = TutorialOverlay.minCardHeight
            let below = CGRect(x: 0, y: hole.maxY + gap, width: size.width, height: size.height - hole.maxY - gap)
            let above = CGRect(x: 0, y: 0, width: size.width, height: hole.minY - gap)
            let right = CGRect(x: hole.maxX + gap, y: 0, width: size.width - hole.maxX - gap, height: size.height)
            let left = CGRect(x: 0, y: 0, width: hole.minX - gap, height: size.height)

            func fits(_ r: CGRect, minWidth: CGFloat) -> Bool { r.height >= minH && r.width >= minWidth }
            var best: (rect: CGRect, side: Int)?
            func consider(_ r: CGRect, side: Int, minWidth: CGFloat) {
                guard fits(r, minWidth: minWidth) else { return }
                if best == nil || r.width * r.height > best!.rect.width * best!.rect.height { best = (r, side) }
            }
            consider(below, side: 0, minWidth: min(width, 280))
            consider(above, side: 1, minWidth: min(width, 280))
            consider(right, side: 2, minWidth: 280)
            consider(left, side: 3, minWidth: 280)

            guard let (rect, side) = best else {
                // The lit control fills the window; the card sits in the middle.
                let height = min(size.height, 460)
                return Placement(x: (size.width - width) / 2, y: (size.height - height) / 2,
                                 width: width, height: height, alignment: .center)
            }
            let cardWidth = min(width, rect.width)
            switch side {
            case 0, 1:
                let x = min(max(hole.midX - cardWidth / 2, 0), size.width - cardWidth)
                return Placement(x: x, y: rect.minY, width: cardWidth, height: rect.height,
                                 alignment: side == 0 ? .top : .bottom)
            default:
                return Placement(x: side == 2 ? rect.minX : rect.maxX - cardWidth, y: rect.minY,
                                 width: cardWidth, height: rect.height,
                                 alignment: .top)
            }
        }
    }
}

// MARK: - The card

private struct CoachCard: View {
    let flow: TutorialFlow
    var cardFocused: AccessibilityFocusState<Bool>.Binding

    var body: some View {
        let step = flow.current
        ViewThatFits(in: .vertical) {
            card(step)
            ScrollView { card(step) }
                .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(flow.progressLabel). \(step.title). \(step.body)")
        .accessibilityFocused(cardFocused)
        .id(step.id)
        .transition(.opacity)
        .animation(Motion.base, value: step.id)
        .background { shortcuts }
    }

    private func card(_ step: TutorialStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(flow.progressLabel)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .monospacedDigit()

            if flow.isFallback {
                illustration(step)
            }

            Text(step.title)
                .graspType(.title)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(step.body)
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let ai = step.aiLine {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: AIGlyph.symbol)
                        .font(.graspUI(size: 12, weight: .semibold))
                        .foregroundStyle(GRASPColor.accent)
                        .accessibilityHidden(true)
                    Text(ai)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if flow.isFallback {
                Text(step.fallbackNote)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let prompt = flow.waitPrompt {
                Text(prompt)
                    .graspType(.rowTitle)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttons
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous).strokeBorder(GRASPColor.hairlineStrong))
    }

    /// The real icon for a control that is not on screen yet.
    private func illustration(_ step: TutorialStep) -> some View {
        Image(systemName: step.symbol)
            .font(.graspUI(size: 20, weight: .medium))
            .foregroundStyle(GRASPColor.textSecondary)
            .frame(width: 44, height: 44)
            .background(GRASPColor.inset, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous).strokeBorder(GRASPColor.hairline))
            .accessibilityHidden(true)
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { skipButton; Spacer(minLength: 8); backButton; nextButton }
            VStack(alignment: .leading, spacing: 8) {
                nextButton
                HStack(spacing: 8) { skipButton; backButton }
            }
        }
    }

    @ViewBuilder private var skipButton: some View {
        if !flow.isLast {
            Button("Skip") { flow.skip() }
                .buttonStyle(GRASPQuietButton())
                #if os(macOS)
                .keyboardShortcut(.cancelAction)
                #endif
        }
    }

    @ViewBuilder private var backButton: some View {
        if !flow.isFirst {
            Button("Back") { flow.back() }
                .buttonStyle(GRASPQuietButton())
        }
    }

    /// Hidden while a step waits for a real tap. The yellow primary.
    @ViewBuilder private var nextButton: some View {
        if !flow.isWaiting {
            Button(flow.isFirst ? "Start" : flow.isLast ? "Done" : "Next") { flow.next() }
                .buttonStyle(GRASPProminentButton())
                #if os(macOS)
                .keyboardShortcut(.defaultAction)
                #endif
        }
    }

    /// Mac: Right arrow is Next, Left arrow is Back, and Escape (on Skip)
    /// is Skip.
    @ViewBuilder private var shortcuts: some View {
        #if os(macOS)
        ZStack {
            Button("Next") { flow.next() }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Back") { flow.back() }.keyboardShortcut(.leftArrow, modifiers: [])
            if flow.isLast {
                Button("Done") { flow.skip() }.keyboardShortcut(.cancelAction)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        #endif
    }
}
