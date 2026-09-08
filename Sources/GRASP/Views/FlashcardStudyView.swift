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
            Divider()
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
        .frame(minWidth: 520, minHeight: 420)
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

    private var header: some View {
        HStack {
            Button("Close") { dismiss() }
            Spacer()
            Text(deckName).font(.headline)
            Spacer()
            Text("\(min(index, queue.count))/\(queue.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding()
    }

    private var completionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "party.popper").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Session complete").font(.title2.bold())
            Text("\(understoodCount) you know, \(reviewCount) marked for review.")
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func cardView(_ card: Card) -> some View {
        VStack(spacing: 16) {
            Text(card.front)
                .font(.title.weight(.medium))
                .multilineTextAlignment(.center)
            if isFlipped {
                Divider().frame(width: 200)
                Text(card.back)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { isFlipped.toggle() }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if isFlipped {
                HStack(spacing: 12) {
                    markButton("Needs Review", "1", .red, understood: false)
                    markButton("I Know This", "2", GRASPColor.success, understood: true)
                }
            } else {
                Text("Space to flip").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func markButton(_ title: String, _ key: String, _ color: Color, understood: Bool) -> some View {
        Button {
            submitMastery(understood)
        } label: {
            VStack(spacing: 2) {
                Text(title)
                Text(key).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(color)
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
