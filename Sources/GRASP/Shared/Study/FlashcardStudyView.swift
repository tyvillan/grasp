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
    @FocusState private var isFocused: Bool

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
                        .font(.system(size: 11, weight: .semibold))
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

            ProgressBar(value: min(index, queue.count), total: queue.count, height: 2)
        }
    }

    private var completionView: some View {
        VStack(spacing: 0) {
            Text("Session complete")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(GRASPColor.textPrimary)

            HStack(spacing: 0) {
                tally(understoodCount, "understood", GRASPColor.success)
                Rectangle()
                    .fill(GRASPColor.hairline)
                    .frame(width: 1, height: 32)
                    .padding(.horizontal, 26)
                tally(reviewCount, "to review", GRASPColor.accent)
            }
            .padding(.top, 24)

            Button("Done") { dismiss() }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tally(_ value: Int, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").graspType(.numeral).foregroundStyle(tint)
            Text(label).graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
        }
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
        .contentShape(Rectangle())
        .onTapGesture { isFlipped.toggle() }
    }

    /// Controls group tight against the bottom edge so the canvas above
    /// stays open. The unflipped hint occupies the same height as the
    /// verdict row, so flipping doesn't shift the card underneath.
    private var footer: some View {
        Group {
            if isFlipped {
                HStack(spacing: 10) {
                    markButton("Needs Review", "1", GRASPColor.accent, understood: false)
                    markButton("I Know This", "2", GRASPColor.success, understood: true)
                }
            } else {
                Button {
                    isFlipped = true
                } label: {
                    HStack(spacing: 6) {
                        Text("Reveal answer").graspType(.body)
                        if KeyHints.shown {
                            Text("Space")
                                .graspType(.meta)
                                .foregroundStyle(GRASPColor.textTertiary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(GRASPColor.inset, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                    .foregroundStyle(GRASPColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
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
                        .foregroundStyle(color.opacity(0.7))
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
            isFlipped.toggle()
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
            if understood { understoodCount += 1 } else { reviewCount += 1 }
            focusTimer.countCard()
        }
        index += 1
        isFlipped = false
    }
}

private struct CardQuickEditSheet: View {
    @State var card: Card
    let onSave: (Card) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Card").font(.headline)
            TextEditor(text: $card.front).frame(height: 60).border(.separator)
            TextEditor(text: $card.back).frame(height: 100).border(.separator)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(card)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(card.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || card.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .macSheetFrame(width: 420)
    }
}
