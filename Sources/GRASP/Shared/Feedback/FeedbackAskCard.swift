import SwiftUI

/// The small card for a soft ask: one line, and three ways out. It sits at
/// the edge of the screen and never blocks anything. All three buttons are
/// outlined: the screen's one yellow button stays where it was.
struct FeedbackAskCard: View {
    let ask: FeedbackAsk
    let onSend: () -> Void
    let onNotNow: () -> Void
    let onNever: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ask.message)
                .graspType(.body)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { sendButton; notNowButton; neverButton }
                // A narrow screen: the third choice goes on its own line.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { sendButton; notNowButton }
                    neverButton
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous).strokeBorder(GRASPColor.hairlineStrong))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ask.message)
    }

    private var sendButton: some View { Button("Send feedback", action: onSend).buttonStyle(GRASPQuietButton()) }
    private var notNowButton: some View { Button("Not now", action: onNotNow).buttonStyle(GRASPQuietButton()) }
    private var neverButton: some View { Button("Don't ask again", action: onNever).buttonStyle(GRASPQuietButton()) }
}

/// Puts the soft ask on screen when one is due, and runs the sheet. Applied
/// once, at the root of each app.
private struct FeedbackAskHost: ViewModifier {
    @Environment(AppStore.self) private var store
    private let asks = FeedbackAsks.shared
    private let service = FeedbackService.shared

    private var busy: Bool { store.presentedStudySheets > 0 || store.tutorial.isActive }

    private func evaluate() {
        asks.showIfDue(busy: busy, sheetShowing: FeedbackLauncher.isSheetShowing || service.isPresenting)
    }

    private var card: some View {
        Group {
            if let ask = asks.showing {
                FeedbackAskCard(
                    ask: ask,
                    onSend: { asks.dismiss(); service.isPresenting = true },
                    onNotNow: { withAnimation(Motion.fade) { asks.dismiss() } },
                    onNever: { withAnimation(Motion.fade) { asks.neverAskAgain() } }
                )
                .padding(16)
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: asks.showing != nil)
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .overlay(alignment: .bottomTrailing) { card }
            .modifier(triggers)
        #else
        content
            .safeAreaInset(edge: .bottom, spacing: 0) { card }
            .modifier(triggers)
        #endif
    }

    private var triggers: some ViewModifier { FeedbackAskTriggers(evaluate: evaluate, busy: busy) }
}

private struct FeedbackAskTriggers: ViewModifier {
    let evaluate: () -> Void
    let busy: Bool

    func body(content: Content) -> some View {
        content
            .task { evaluate() }
            .onChange(of: busy) { _, _ in evaluate() }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in evaluate() }
            #else
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in evaluate() }
            #endif
    }
}

extension View {
    /// Shows the soft feedback ask when one is due.
    func feedbackAskHost() -> some View { modifier(FeedbackAskHost()) }

    /// Presents the Send feedback sheet.
    func feedbackSheet() -> some View {
        sheet(isPresented: Binding(
            get: { FeedbackService.shared.isPresenting },
            set: { FeedbackService.shared.isPresenting = $0 }
        )) { SendFeedbackSheet() }
    }
}
