import Foundation
import GRASPCore
import SwiftCrossUI

/// A deck's cards, after the Mac's `DeckDetailView` list: a rail down each
/// row tinted by status, and the front and back. Filters by status, by
/// mastery and by text, and sorts like the Mac; a click opens the card to
/// edit, approve, suspend, move or delete. "Select" picks several cards for
/// one action -- the Mac's Cmd/Shift-click, which SwiftCrossUI can't see.
struct CardList: View {
    let library: Library
    let scope: DeckScope
    /// Cards opened from an overview's key term; nil shows the whole deck.
    @Binding var focus: Set<String>?
    @State var filter: CardFilter = .all
    @State var mastery: MasteryFilter = .all
    @State var sort: CardSort = .deckOrder
    @State var text = ""
    /// How many rows are drawn. SwiftCrossUI lays out every row up front,
    /// so a 300-card All Cards shows the first page and grows on request.
    @State var shown = CardList.pageSize
    @State var editing: CardEditorTarget?
    /// nil when not selecting; otherwise the cards ticked so far.
    @State var selection: Set<String>?
    @State var confirmingBulkDelete = false

    static let pageSize = 25

    var body: some View {
        let cards = library.cards(inDecks: scope.deckIds)
        let levels = library.learnLevels(inDecks: scope.deckIds)
        let matching = sort.apply(cards.filter {
            filter.includes($0) && mastery.includes($0, levels: levels) && matches($0)
                && (focus?.contains($0.id) ?? true)
        })
        VStack(alignment: .leading, spacing: 12) {
            if let focus {
                HStack(spacing: 10) {
                    Text("Showing the \(focus.count == 1 ? "card" : "\(focus.count) cards") for a key term in the overview.")
                        .font(GRASPFont.body)
                        .foregroundColor(GRASPColor.textSecondary)
                    Spacer()
                    Button("Show All Cards") { self.focus = nil }.fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(GRASPColor.successSoft)
                .cornerRadius(8)
            }
            HStack(spacing: 10) {
                SegmentedChoice(options: CardFilter.allCases, selection: filter,
                                label: { "\($0.label) \(cards.filter($0.includes).count)" }) {
                    filter = $0
                    shown = Self.pageSize
                }
                TextField("Filter cards", text: $text)
                    .frame(width: 180.0)
                Spacer()
                Button(selection == nil ? "Select" : "Done Selecting") {
                    selection = selection == nil ? [] : nil
                    confirmingBulkDelete = false
                }
                .fixedSize()
                Button("+ New Card") {
                    editing = CardEditorTarget(card: nil, deckId: scope.deckIds.first)
                }
                .fixedSize()
            }
            HStack(spacing: 10) {
                // Only approved cards have a Learn level to filter on.
                if cards.contains(where: { $0.status == .active }) {
                    SegmentedChoice(options: MasteryFilter.allCases, selection: mastery, label: \.label) {
                        mastery = $0
                        shown = Self.pageSize
                    }
                }
                Spacer()
                Text("Sort").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary).fixedSize()
                Picker(of: CardSort.allCases, selection: Binding(get: { sort }, set: { sort = $0 ?? .deckOrder }))
            }

            if let selection {
                selectionBar(selection, visible: matching)
            }

            if matching.isEmpty {
                Text(cards.isEmpty ? "No cards in this deck yet." : "No cards match.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
                    .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matching.prefix(shown)), id: \.id) { card in
                        CardRowView(card: card, understood: levels[card.id] == .mastered,
                                    selected: selection.map { $0.contains(card.id) }) {
                            if var picked = selection {
                                if picked.contains(card.id) { picked.remove(card.id) } else { picked.insert(card.id) }
                                selection = picked
                            } else {
                                editing = CardEditorTarget(card: card, deckId: nil)
                            }
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
            selection = nil
            focus = nil
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing {
                CardEditor(library: library, target: editing, deckChoices: deckChoices, moveTargets: moveTargets) { self.editing = nil }
            }
        }
    }

    /// The Mac's selection bar: how many are ticked, and what to do to them.
    /// Acts on cards in the list's order, so moved cards keep it.
    private func selectionBar(_ picked: Set<String>, visible: [Card]) -> some View {
        let ordered = visible.map(\.id).filter(picked.contains)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(picked.count) selected").font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary).fixedSize()
                QuietLink(title: "Select All \(visible.count)") { selection = Set(visible.map(\.id)) }
                QuietLink(title: "Deselect All") { selection = [] }
                Spacer()
                if !picked.isEmpty {
                    Button("Approve") { library.setStatus(ordered, to: .active); selection = [] }.fixedSize()
                    Button("Suspend") { library.setStatus(ordered, to: .suspended); selection = [] }.fixedSize()
                    if !moveTargets.isEmpty {
                        Picker(of: moveTargets, selection: Binding(get: { nil }, set: { choice in
                            if let id = choice?.id { library.moveCards(ordered, toDeck: id); selection = [] }
                        }))
                    }
                    Button("Delete…") { confirmingBulkDelete = true }.fixedSize()
                }
            }
            if confirmingBulkDelete && !picked.isEmpty {
                HStack(spacing: 8) {
                    Text("Delete \(picked.count) card\(picked.count == 1 ? "" : "s")? Review history is kept, but they leave this deck.")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.rejected)
                    Spacer()
                    Button("Delete") {
                        library.deleteCards(ordered)
                        selection = []
                        confirmingBulkDelete = false
                    }
                    .fixedSize()
                    Button("Keep") { confirmingBulkDelete = false }.fixedSize()
                }
            }
        }
        .padding(12)
        .background(GRASPColor.inset)
        .cornerRadius(8)
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

    /// Where a card can move: the course's other decks. From All Cards
    /// every deck is a target; moving a card into its own deck does nothing.
    private var moveTargets: [Choice] {
        deckChoices.filter { !(scope.deckIds.count == 1 && scope.deckIds[0] == $0.id) }
    }
}

/// The Mac's mastery filter: understood means Learn level "mastered".
enum MasteryFilter: CaseIterable, Equatable {
    case all, needsReview, understood

    var label: String {
        switch self {
        case .all: return "All"
        case .needsReview: return "Needs Review"
        case .understood: return "Understood"
        }
    }

    func includes(_ card: Card, levels: [String: LearnEngine.Level]) -> Bool {
        switch self {
        case .all: return true
        case .needsReview: return card.status == .active && levels[card.id] != .mastered
        case .understood: return card.status == .active && levels[card.id] == .mastered
        }
    }
}

/// The Mac's sort options.
enum CardSort: CaseIterable, Equatable, CustomStringConvertible {
    case deckOrder, alphabetical, dateAdded, dueDate

    var description: String {
        switch self {
        case .deckOrder: return "Deck order"
        case .alphabetical: return "Alphabetical (A–Z)"
        case .dateAdded: return "Date added"
        case .dueDate: return "Due date"
        }
    }

    func apply(_ cards: [Card]) -> [Card] {
        switch self {
        case .deckOrder: return cards
        case .alphabetical: return cards.sorted { $0.front.localizedStandardCompare($1.front) == .orderedAscending }
        case .dateAdded: return cards.sorted { $0.createdAt < $1.createdAt }
        case .dueDate: return cards.sorted { $0.due < $1.due }
        }
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

/// One card in the list. Deliberately light: a list page builds every row
/// at once, and a row with its own drop-down menu and badge views cost
/// about 30 ms each, so a 50-card page took well over a second to open.
/// The actions live in the card's window instead, a click away.
private struct CardRowView: View {
    let card: Card
    let understood: Bool
    /// nil when not selecting.
    let selected: Bool?
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // The Mac's rail: pending amber, suspended rose, approved a
                // muted gold -- so a long list can be scanned for what
                // still needs a look without reading a word.
                if let selected {
                    Text(selected ? "✓" : " ")
                        .font(Font.system(size: 12, weight: .bold))
                        .foregroundColor(GRASPColor.canvas)
                        .frame(width: 18.0, height: 18.0)
                        .background(selected ? GRASPColor.accent : GRASPColor.hairlineStrong)
                        .cornerRadius(4)
                }
                Rectangle().fill(railTint).frame(width: 2.0, height: 34.0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.front).font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textPrimary)
                    Text(card.back).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary).lineLimit(2)
                }
                Spacer()
                if let label = statusLabel {
                    Text(label).font(GRASPFont.badge).foregroundColor(railTint).fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
        }
        .onTapGesture(perform: open)
    }

    private var railTint: Color {
        switch card.status {
        case .draft: return GRASPColor.accent
        case .suspended: return GRASPColor.rejected
        case .active: return understood ? GRASPColor.success : GRASPColor.accentMuted
        }
    }

    private var statusLabel: String? {
        var parts: [String] = []
        if card.status == .draft { parts.append("PENDING") }
        if card.status == .suspended { parts.append("SUSPENDED") }
        if card.isContextRefined { parts.append("AI REFINED") }
        if card.origin == .aiGenerated { parts.append("AI") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
    let moveTargets: [Choice]
    let close: () -> Void

    @State var front: String
    @State var back: String
    @State var deckId: String?
    @State var confirmingDelete = false
    @State var showingNote = false

    init(library: Library, target: CardEditorTarget, deckChoices: [Choice], moveTargets: [Choice],
         close: @escaping () -> Void) {
        self.library = library
        self.target = target
        self.deckChoices = deckChoices
        self.moveTargets = moveTargets
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
            // The Mac's "View Source Note", shown in place: a sheet can't
            // open another sheet on Windows.
            if let materialId = target.card?.materialId {
                QuietLink(title: showingNote ? "Hide Source Note ▴" : "Show Source Note ▾") { showingNote.toggle() }
                if showingNote {
                    ScrollView {
                        Text(library.note(materialId)?.text ?? "This card's note isn't in the library.")
                            .font(GRASPFont.body)
                            .foregroundColor(GRASPColor.textSecondary)
                            .frame(maxWidth: 440.0)
                    }
                    .frame(height: 180.0)
                    .padding(10)
                    .background(GRASPColor.surface)
                    .cornerRadius(6)
                }
            }
            if let card = target.card, card.origin == .parser {
                Text("Edited cards stay as you wrote them when the note is imported again.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            if let card = target.card {
                CardActionsBar(library: library, card: card, moveTargets: moveTargets, close: close)
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

/// What you can do to a card besides editing its text, each applied at once
/// and closing the window: approve or suspend, move to another deck, revert
/// an AI rewrite.
private struct CardActionsBar: View {
    let library: Library
    let card: Card
    let moveTargets: [Choice]
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if card.status == .draft {
                Button("Approve") { apply { library.setStatus([card.id], to: .active) } }.fixedSize()
            }
            Button(card.status == .suspended ? "Reactivate" : "Suspend") {
                apply { library.setStatus([card.id], to: card.status == .suspended ? .active : .suspended) }
            }
            .fixedSize()
            if card.isContextRefined {
                Button("Revert AI Rewrite") { apply { library.revertContextRefinement(card.id) } }.fixedSize()
            }
            // Any card from a note, approved or not: a clumsy or off-topic
            // card can need a second look long after it was approved.
            if card.materialId != nil {
                Button("Refine with AI") {
                    apply { library.refineCardWithAI(card.id, courseId: library.courseId(ofCard: card.id)) }
                }
                .fixedSize()
            }
            Spacer()
            if !moveTargets.isEmpty {
                Text("Move to").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary).fixedSize()
                Picker(of: moveTargets, selection: Binding(
                    get: { nil },
                    set: { choice in
                        if let id = choice?.id { apply { library.moveCards([card.id], toDeck: id) } }
                    }
                ))
            }
        }
    }

    private func apply(_ action: () -> Void) {
        action()
        close()
    }
}
