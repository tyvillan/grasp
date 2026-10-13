import SwiftUI
import GRASPCore

/// A flashcard session over one deck's due queue. Deliberately just two
/// outcomes per card -- "Needs Review" or "I Know This" -- rather than
/// FSRS's four-grade scale: FSRS still schedules the due date under the
/// hood (`AppStore.markCard` maps the two options to Again/Good), but the
/// user-facing decision and the mastery label shared with Learn mode and
/// test filtering are both binary. Keyboard-first: space flips, 1/2 mark,
/// arrows move without marking (for a quick look-ahead/back), E edits the
/// current card, S suspends it, Esc ends the session early. Every mark
/// writes to the database immediately, so quitting mid-session loses
/// nothing already marked.
struct FlashcardStudyView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deckIds: [String]
    let deckName: String
    /// Set by a deck page: the finish screen offers one follow-on (Learn
    /// the cards you missed, or a test) and hands the choice back here
    /// after the session has closed. Nil elsewhere, which shows no button.
    var onNextStep: ((StudyNextStep) -> Void)? = nil

    @State private var queue: [Card] = []
    @State private var index = 0
    @State private var isFlipped = false
    @State private var reviewCount = 0
    @State private var understoodCount = 0
    @State private var editingCard: Card?
    /// Cards already graded this session. Arrowing back onto one shows it
    /// again but doesn't grade it a second time -- that was a second FSRS
    /// review and a second history row for one look at the card.
    @State private var markedIds: Set<String> = []
    /// Cards marked Needs Review this session, for "Learn the N you missed".
    @State private var missedIds: Set<String> = []
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The card's turn during a flip: it rotates edge-on, the answer
    /// appears, and it turns back -- the question stays on the same face.
    @State private var flipAngle: Double = 0
    /// A brief yellow flash of the progress bar after "I Know This".
    @State private var progressFlash = false

    @AppStorage("focusWorkMinutes") private var workMinutes = 25
    @AppStorage("focusBreakMinutes") private var breakMinutes = 5
    @AppStorage("focusCardTarget") private var cardTarget = 20
    @State private var focusTimer = FocusTimerModel(workMinutes: 25, breakMinutes: 5, cardTarget: 20)

    var body: some View {
        VStack(spacing: 0) {
            header
            // Below the header rather than above it: the deck and the
            // queue's progress are what the session is, the timer is a
            // tool running alongside it.
            if !queue.isEmpty && index < queue.count {
                FocusTimerBar(model: focusTimer)
            }
            if queue.isEmpty {
                ContentUnavailableView(
                    "Nothing due", systemImage: "checkmark.circle",
                    description: Text("No cards in \(deckName) are due for review right now.")
                )
                .frame(maxHeight: .infinity)
            } else if index >= queue.count {
                completionView
            } else {
                cardView(queue[index])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        }
        .background(GRASPColor.canvas)
        .macWindowFrame(minWidth: 620, minHeight: 520)
        .dimsWindowBehind()
        .task {
            queue = (try? store.dueCards(inDecks: deckIds)) ?? []
            isFocused = true
            focusTimer.workMinutes = workMinutes
            focusTimer.breakMinutes = breakMinutes
            focusTimer.cardTarget = cardTarget
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress { handleKeyPress($0) }
        // The timer bar disappears once the queue is finished (it's
        // gated on `index < queue.count` above), but the model itself
        // keeps running unless told to stop -- without this, a work or
        // break interval can still elapse behind the completion screen,
        // beeping with no bar left to acknowledge it from.
        .onChange(of: index) {
            if index >= queue.count { focusTimer.pause() }
        }
        .sheet(item: $editingCard) { card in
            CardQuickEditSheet(card: card) { updated in
                try? store.updateCard(updated)
                // The stored card, not the sheet's copy: the copy predates any
                // grading done since it opened.
                if index < queue.count, let fresh = try? store.card(updated.id) {
                    queue[index] = fresh
                }
            }
        }
    }

    /// Deck name and position on one line, with the queue's progress drawn
    /// as a hairline directly beneath -- the bar doubles as the rule
    /// separating the chrome from the card canvas, instead of stacking a
    /// separate progress row and a `Divider()` on top of each other.
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.graspUI(size: 11, weight: .semibold))
                        .foregroundStyle(GRASPColor.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(GRASPColor.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .help("End session (Esc)")

                VStack(alignment: .leading, spacing: 1) {
                    Text(deckName)
                        .graspType(.title)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .lineLimit(1)
                    Text("Flashcards")
                        .graspType(.meta)
                        .textCase(.uppercase)
                        .tracking(0.7)
                        .foregroundStyle(GRASPColor.textTertiary)
                }

                Spacer(minLength: 12)

                Text("\(min(index, queue.count)) / \(queue.count)")
                    .graspType(.numeralSmall)
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            ProgressBar(value: min(index, queue.count), total: queue.count, height: progressFlash ? 4 : 2)
                .brightness(progressFlash ? 0.15 : 0)
                .animation(Motion.snappy, value: progressFlash)
        }
    }

    private var completionView: some View {
        SessionCompleteView(
            understood: understoodCount, toReview: reviewCount,
            goalLine: goalLine, nextStep: nextStep,
            onNextStep: { step in
                onNextStep?(step)
                dismiss()
            }
        ) { dismiss() }
    }

    /// Progress to today's goal from the Settings daily goal, counted from
    /// the reviews already saved. Nothing when no goal is set.
    private var goalLine: String? {
        let goal = UserDefaults.standard.object(forKey: "dailyCardGoal") as? Int ?? 20
        guard goal > 0 else { return nil }
        let done = store.studyStreak().reviewsToday
        return done >= goal ? "Daily goal reached" : "\(goal - done) more to reach today's goal of \(goal)"
    }

    /// One follow-on, only where the deck page can act on it.
    private var nextStep: StudyNextStep? {
        guard onNextStep != nil else { return nil }
        if !missedIds.isEmpty { return .learnMissed(missedIds) }
        if (try? store.deckMastery(deckIds: deckIds))?.total ?? 0 > 0 { return .test }
        return nil
    }

    /// The card gets the whole canvas. Front and back share one surface --
    /// flipping reveals the answer *below* the prompt rather than swapping
    /// the face, so the question stays readable while the answer is judged,
    /// which is what the two-verdict decision actually needs.
    @ViewBuilder
    private func cardView(_ card: Card) -> some View {
        VStack(spacing: 0) {
            Text(card.front)
                .graspType(.studyPrompt)
                .foregroundStyle(GRASPColor.textPrimary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 560)

            if isFlipped {
                Rectangle()
                    .fill(GRASPColor.hairlineStrong)
                    .frame(width: 40, height: 1)
                    .padding(.vertical, 24)

                Text(card.back)
                    .graspType(.studyAnswer)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560)
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(GRASPColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(GRASPColor.hairline, lineWidth: 1)
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
        )
        .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .contentShape(Rectangle())
        .onTapGesture { flip() }
    }

    /// Reveal (or hide) the answer. Revealing is a quick half-turn of the
    /// card, about 220ms in all; under Reduce Motion it's a plain fade.
    private func flip() {
        guard !isFlipped else {
            isFlipped = false
            return
        }
        if reduceMotion {
            withAnimation(Motion.fade) { isFlipped = true }
            return
        }
        withAnimation(.easeIn(duration: 0.11)) { flipAngle = 90 } completion: {
            isFlipped = true
            flipAngle = -90
            withAnimation(.easeOut(duration: 0.11)) { flipAngle = 0 }
        }
    }

    /// Controls group tight against the bottom edge so the canvas above
    /// stays open. The unflipped hint occupies the same height as the
    /// verdict row, so flipping doesn't shift the card underneath.
    private var footer: some View {
        Group {
            if isFlipped {
                HStack(spacing: 10) {
                    markButton("Needs Review", "1", GRASPColor.rejected, understood: false)
                    markButton("I Know This", "2", GRASPColor.success, understood: true)
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
            } else {
                Button {
                    flip()
                } label: {
                    HStack(spacing: 6) {
                        Text("Reveal answer").graspType(.body).fontWeight(.semibold)
                        if KeyHints.shown {
                            Text("Space")
                                .graspType(.meta)
                                .foregroundStyle(GRASPColor.ink)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(GRASPColor.ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                    // The one yellow control on this screen: revealing is
                    // the main action until the answer is up.
                    .foregroundStyle(GRASPColor.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(GRASPColor.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reveal answer")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .animation(Motion.choose(Motion.bouncy, reduceMotion: reduceMotion), value: isFlipped)
        .sensoryFeedback(.impact(weight: .light), trigger: index)
    }

    private func markButton(_ title: String, _ key: String, _ color: Color, understood: Bool) -> some View {
        Button {
            submitMastery(understood)
        } label: {
            HStack(spacing: 7) {
                Text(title)
                if KeyHints.shown {
                    Text(key)
                        .graspType(.meta)
                        // Full-strength text: the dimmed key hint fell under
                        // 4.5:1 on its tinted background.
                        .foregroundStyle(GRASPColor.textSecondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        }
        .buttonStyle(GRASPVerdictButton(tint: color))
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard index < queue.count else { return .ignored }
        switch press.key {
        case .space:
            flip()
            return .handled
        case .leftArrow:
            if index > 0 { index -= 1; isFlipped = false }
            return .handled
        case .rightArrow:
            if index < queue.count - 1 { index += 1; isFlipped = false }
            return .handled
        case .escape:
            dismiss()
            return .handled
        default:
            break
        }
        if isFlipped {
            switch press.characters {
            case "1":
                submitMastery(false)
                return .handled
            case "2":
                submitMastery(true)
                return .handled
            default:
                break
            }
        }
        switch press.characters {
        case "e":
            editingCard = queue[index]
            return .handled
        case "s":
            try? store.setCardStatus(queue[index].id, status: .suspended)
            queue.remove(at: index)
            // `index` didn't change, so the onChange that pauses the timer at
            // the end of the queue never fires for the last card.
            if index >= queue.count { focusTimer.pause() }
            return .handled
        default:
            return .ignored
        }
    }

    private func submitMastery(_ understood: Bool) {
        guard index < queue.count else { return }
        let cardId = queue[index].id
        if markedIds.insert(cardId).inserted {
            try? store.markCard(cardId, understood: understood, source: "flashcards")
            if understood { understoodCount += 1 } else { reviewCount += 1; missedIds.insert(cardId) }
            focusTimer.countCard()
        }
        if understood {
            progressFlash = true
            Task { try? await Task.sleep(for: .milliseconds(260)); progressFlash = false }
        }
        index += 1
        isFlipped = false
        flipAngle = 0
    }
}

private struct CardQuickEditSheet: View {
    @State var card: Card
    let onSave: (Card) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GRASPSheet(eyebrow: "Card", title: "Edit card", width: 480) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Front")
                    TextEditor(text: $card.front).graspEditorChrome(minHeight: 56)
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Back")
                    TextEditor(text: $card.back).graspEditorChrome(minHeight: 110)
                }
            }
        } footer: {
            Button("Cancel") { dismiss() }
            Button("Save") {
                onSave(card)
                dismiss()
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(card.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || card.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// What the study finish screen can lead to next.
enum StudyNextStep: Equatable {
    case learnMissed(Set<String>)
    case test

    var title: String {
        switch self {
        case .learnMissed(let ids): return ids.count == 1 ? "Learn the 1 you missed" : "Learn the \(ids.count) you missed"
        case .test: return "Take a test"
        }
    }
}

/// The end of a session: the two tallies count up from zero and a few
/// yellow squares drift in. Under 1.5s; a click skips straight to the
/// final numbers, and Reduce Motion shows them at once.
struct SessionCompleteView: View {
    let understood: Int
    let toReview: Int
    var goalLine: String? = nil
    var nextStep: StudyNextStep? = nil
    var onNextStep: ((StudyNextStep) -> Void)? = nil
    let onDone: () -> Void
    @State private var shownUnderstood = 0
    @State private var shownReview = 0
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<7, id: \.self) { i in
                    BrandDot(size: CGFloat(6 + (i % 3) * 3))
                        .rotationEffect(.degrees(drift ? Double(i) * 37 : 0))
                        .offset(x: CGFloat(i - 3) * 70, y: drift ? CGFloat((i % 2 == 0 ? -1 : 1) * (90 + i * 6)) : 0)
                        .opacity(drift ? 0.0 : 0.9)
                        .allowsHitTesting(false)
                }
            }
            VStack(spacing: 0) {
                SectionLabel("Session complete")
                Text(understood + toReview == 1 ? "1 card done" : "\(understood + toReview) cards done")
                    .font(.graspDisplay(34))
                    .tracking(-0.6)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .padding(.top, 10)

                HStack(spacing: 0) {
                    tally(shownUnderstood, "understood", GRASPColor.success)
                    Rectangle()
                        .fill(GRASPColor.hairline)
                        .frame(width: 1, height: 40)
                        .padding(.horizontal, 30)
                    tally(shownReview, "to review", GRASPColor.accent)
                }
                .padding(.top, 26)

                if let goalLine {
                    Text(goalLine)
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .padding(.top, 20)
                }

                // Done is the screen's one filled button; the follow-on is
                // outlined beside it.
                HStack(spacing: 12) {
                    if let nextStep, let onNextStep {
                        Button(nextStep.title) { onNextStep(nextStep) }
                            .buttonStyle(GRASPQuietButton())
                    }
                    Button("Done", action: onDone)
                        .buttonStyle(GRASPProminentButton())
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, goalLine == nil ? 32 : 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        .onAppear {
            if reduceMotion { skip(); return }
            withAnimation(.easeOut(duration: 1.2)) { drift = true }
            withAnimation(Motion.settle.delay(0.15)) {
                shownUnderstood = understood
                shownReview = toReview
            }
        }
    }

    private func skip() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            shownUnderstood = understood
            shownReview = toReview
            drift = true
        }
    }

    private func tally(_ value: Int, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.graspDisplay(44))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .foregroundStyle(tint)
            Text(label).graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
        }
    }
}
