import Foundation
import GRASPCore
import SwiftCrossUI

/// A deck's cards, after the Mac's `DeckDetailView` list: a rail down each
/// row tinted by status, the front and back, and a menu to edit, approve,
/// suspend, move or delete. Filters by status and by text; a click opens
/// the card to edit.
struct CardList: View {
    let library: Library
    let scope: DeckScope
    @State var filter: CardFilter = .all
    @State var text = ""
    /// How many rows are drawn. SwiftCrossUI lays out every row up front,
    /// so a 300-card All Cards shows the first page and grows on request.
    @State var shown = CardList.pageSize
    @State var editing: CardEditorTarget?

    static let pageSize = 50

    var body: some View {
        let cards = library.cards(inDecks: scope.deckIds)
        let matching = cards.filter { filter.includes($0) && matches($0) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SegmentedChoice(options: CardFilter.allCases, selection: filter,
                                label: { "\($0.label) \(cards.filter($0.includes).count)" }) {
                    filter = $0
                    shown = Self.pageSize
                }
                TextField("Filter cards", text: $text)
                    .frame(width: 200.0)
                Spacer()
                Button("+ New Card") {
                    editing = CardEditorTarget(card: nil, deckId: scope.deckIds.first)
                }
                .fixedSize()
            }

            if matching.isEmpty {
                Text(cards.isEmpty ? "No cards in this deck yet." : "No cards match.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
                    .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matching.prefix(shown)), id: \.id) { card in
                        CardRowView(library: library, card: card, scope: scope) {
                            editing = CardEditorTarget(card: card, deckId: nil)
                        }
                    }
                }
                .background(GRASPColor.surface)
                .cornerRadius(10)
                if matching.count > shown {
                    HStack(spacing: 10) {
                        Text("Showing \(shown) of \(matching.count)")
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.textTertiary)
                        Button("Show \(min(Self.pageSize, matching.count - shown)) More") { shown += Self.pageSize }
                            .fixedSize()
                    }
                }
            }
        }
        .onChange(of: scope.id) {
            shown = Self.pageSize
            text = ""
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing {
                CardEditor(library: library, target: editing, deckChoices: deckChoices) { self.editing = nil }
            }
        }
    }

    private func matches(_ card: Card) -> Bool {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = (card.front + " " + card.back).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Where a new card can go: this deck's course's decks.
    private var deckChoices: [Choice] {
        let courseId = library.decks.first { scope.deckIds.contains($0.id) }?.courseId
        return library.decks.filter { $0.courseId == courseId }.map { Choice(id: $0.id, description: $0.name) }
    }
}

enum CardFilter: CaseIterable, Equatable {
    case all, drafts, active, suspended

    var label: String {
        switch self {
        case .all: return "All"
        case .drafts: return "Pending"
        case .active: return "Approved"
        case .suspended: return "Suspended"
        }
    }

    func includes(_ card: Card) -> Bool {
        switch self {
        case .all: return true
        case .drafts: return card.status == .draft
        case .active: return card.status == .active
        case .suspended: return card.status == .suspended
        }
    }
}

/// One card in the list.
private struct CardRowView: View {
    let library: Library
    let card: Card
    let scope: DeckScope
    let open: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // The Mac's rail: pending amber, suspended rose, approved a
                // muted gold -- so a long list can be scanned for what
                // still needs a look without reading a word.
                Rectangle().fill(railTint).frame(width: 2.0, height: 34.0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.front)
                        .font(GRASPFont.rowTitle)
                        .foregroundColor(GRASPColor.textPrimary)
                    Text(card.back)
                        .font(GRASPFont.body)
                        .foregroundColor(GRASPColor.textSecondary)
                        .lineLimit(3)
                }
                .onTapGesture(perform: open)
                Spacer()
                badges
                actions
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
        }
    }

    private var railTint: Color {
        switch card.status {
        case .draft: return GRASPColor.accent
        case .suspended: return GRASPColor.rejected
        case .active: return GRASPColor.accentMuted
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 6) {
            if card.status == .draft {
                Chip(text: "Pending", tint: GRASPColor.accent, soft: GRASPColor.accentSoft)
            } else if card.status == .suspended {
                Chip(text: "Suspended", tint: GRASPColor.rejected, soft: GRASPColor.rejectedSoft)
            }
            if card.isContextRefined {
                Chip(text: "AI refined", tint: GRASPColor.success, soft: GRASPColor.successSoft)
            }
            if card.origin == .aiGenerated {
                Chip(text: "AI", tint: GRASPColor.accent, soft: GRASPColor.accentSoft)
            }
        }
    }

    private var actions: some View {
        Menu("•••") {
            Button("Edit…") { open() }
            if card.status == .draft {
                Button("Approve") { library.setStatus([card.id], to: .active) }
            }
            Button(card.status == .suspended ? "Reactivate" : "Suspend") {
                library.setStatus([card.id], to: card.status == .suspended ? .active : .suspended)
            }
            if card.isContextRefined {
                Button("Revert AI Refinement") { library.revertContextRefinement(card.id) }
            }
            let targets = moveTargets
            if !targets.isEmpty {
                Menu("Move to") {
                    ForEach(targets, id: \.id) { deck in
                        Button(deck.name) { library.moveCards([card.id], toDeck: deck.id) }
                    }
                }
            }
            Button("Delete") { library.deleteCards([card.id]) }
        }
        .fixedSize()
    }

    /// The course's other decks. From All Cards every deck is a target;
    /// moving a card into the deck it's already in does nothing.
    private var moveTargets: [DeckRow] {
        let courseId = library.decks.first { scope.deckIds.contains($0.id) }?.courseId
        return library.decks.filter { $0.courseId == courseId && !(scope.deckIds.count == 1 && scope.deckIds[0] == $0.id) }
    }
}

// MARK: - Editing

struct CardEditorTarget {
    /// nil for a new card.
    let card: Card?
    /// Where a new card goes.
    let deckId: String?
}

/// Front and back of one card, or a new one, after the Mac's
/// `CardEditSheet` / `CardCreateSheet`.
struct CardEditor: View {
    let library: Library
    let target: CardEditorTarget
    let deckChoices: [Choice]
    let close: () -> Void

    @State var front: String
    @State var back: String
    @State var deckId: String?
    @State var confirmingDelete = false

    init(library: Library, target: CardEditorTarget, deckChoices: [Choice], close: @escaping () -> Void) {
        self.library = library
        self.target = target
        self.deckChoices = deckChoices
        self.close = close
        _front = State(wrappedValue: target.card?.front ?? "")
        _back = State(wrappedValue: target.card?.back ?? "")
        _deckId = State(wrappedValue: target.deckId ?? deckChoices.first?.id)
    }

    private var isNew: Bool { target.card == nil }
    private var canSave: Bool {
        !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isNew || deckId != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Card" : "Edit Card")
                .font(Font.system(size: 18, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
            if isNew && deckChoices.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Deck")
                    Picker(of: deckChoices, selection: Binding(
                        get: { deckChoices.first { $0.id == deckId } },
                        set: { deckId = $0?.id }
                    ))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Front")
                TextEditor(text: $front).frame(height: 70.0)
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Back")
                TextEditor(text: $back).frame(height: 130.0)
            }
            if let card = target.card, card.origin == .parser {
                Text("Edited cards stay as you wrote them when the note is imported again.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            if confirmingDelete {
                HStack(spacing: 8) {
                    Text("Delete this card? Its review history is kept.")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.rejected)
                    Spacer()
                    Button("Delete") {
                        if let card = target.card { library.deleteCards([card.id]) }
                        close()
                    }
                    .fixedSize()
                    Button("Keep") { confirmingDelete = false }.fixedSize()
                }
            } else {
                HStack(spacing: 8) {
                    if !isNew {
                        Button("Delete…") { confirmingDelete = true }.fixedSize()
                    }
                    Spacer()
                    Button("Cancel") { close() }.fixedSize()
                    Button(isNew ? "Add Card" : "Save") { save() }
                        .disabled(!canSave)
                        .fixedSize()
                }
            }
        }
        .padding(24)
        .frame(width: 500.0)
        .background(GRASPColor.canvas)
    }

    private func save() {
        if let card = target.card {
            library.editCard(card.id, front: front, back: back)
        } else if let deckId {
            library.createCard(front: front, back: back, deckId: deckId)
        }
        close()
    }
}
