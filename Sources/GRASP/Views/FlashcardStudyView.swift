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
    let deckId: String
    let deckName: String

    @State private var queue: [Card] = []
    @State private var index = 0
    @State private var isFlipped = false
    @State private var reviewCount = 0
    @State private var understoodCount = 0
    @State private var editingCard: Card?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
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
        .frame(minWidth: 620, minHeight: 520)
        .task {
            queue = (try? store.dueCards(inDeck: deckId)) ?? []
            isFocused = true
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress { handleKeyPress($0) }
        .sheet(item: $editingCard) { card in
            CardQuickEditSheet(card: card) { updated in
                try? store.updateCard(updated)
                if index < queue.count { queue[index] = updated }
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
                        Text("Space")
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.textTertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(GRASPColor.inset, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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
                Text(key)
                    .graspType(.meta)
                    .foregroundStyle(color.opacity(0.7))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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
            return .handled
        default:
            return .ignored
        }
    }

    private func submitMastery(_ understood: Bool) {
        guard index < queue.count else { return }
        try? store.markCard(queue[index].id, understood: understood, source: "flashcards")
        if understood { understoodCount += 1 } else { reviewCount += 1 }
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
                    var saved = card
                    saved.origin = .manual
                    saved.updatedAt = Date()
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
