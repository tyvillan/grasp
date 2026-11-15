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
    /// "Practice weakest": a Learn round on these cards.
    var onPractice: ([String]) -> Void = { _ in }
    @State var filter: CardFilter = .all
    /// A weakest note picked on the meter: only its cards are listed.
    @State var noteFilter: String?
    @State var sort: CardSort = .deckOrder
    @State var text = ""
    /// How many rows are drawn. SwiftCrossUI lays out every row up front,
    /// so a 300-card All Cards shows the first page and grows on request.
    @State var shown = CardList.pageSize
    @State var editing: CardEditorTarget?
    /// nil when not selecting; otherwise the cards ticked so far.
    @State var selection: Set<String>?
    @State var confirmingBulkDelete = false

    /// Fifteen a page: about two screens, and each row costs a few views
    /// on every redraw of the page (the Mac shows about eight at once).
    static let pageSize = 15

    var body: some View {
        let cards = library.cards(inDecks: scope.deckIds)
        let levels = library.learnLevels(inDecks: scope.deckIds)
        let notes = library.reviewNotes(inDecks: scope.deckIds)
        let now = Date()
        let matching = sort.apply(cards.filter { card in
            filter.includes(card, levels: levels, now: now) && matches(card)
                && (focus?.contains(card.id) ?? true)
                && (noteFilter == nil || card.materialId == noteFilter)
        })
        let draftCount = cards.filter { $0.status == .draft }.count
        VStack(alignment: .leading, spacing: 16) {
            if let focus {
                HStack(spacing: 10) {
                    Text("Showing the \(focus.count == 1 ? "card" : "\(focus.count) cards") for a key term in the overview.")
                        .font(GRASPFont.body)
                        .foregroundColor(GRASPColor.textSecondary)
                    Spacer()
                    GRASPButton("Show all cards") { self.focus = nil }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
            } else if noteFilter == nil {
                let understanding = library.understanding(inDecks: scope.deckIds)
                UnderstandingPanel(cards: understanding.cards, titles: understanding.titles,
                                   openNote: { id in
                                       noteFilter = id
                                       filter = .all
                                       shown = Self.pageSize
                                   },
                                   practice: onPractice)
            }
            if let noteFilter {
                HStack(spacing: 10) {
                    Text("Showing the cards from \(library.understanding(inDecks: scope.deckIds).titles[noteFilter] ?? "one note").")
                        .font(GRASPFont.body)
                        .foregroundColor(GRASPColor.textSecondary)
                    Spacer()
                    GRASPButton("Show all cards") { self.noteFilter = nil }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
            }
            HStack(spacing: 10) {
                // The Mac's pills: All, Drafts, Due, Understood, with counts.
                // Suspended only appears when a card is suspended.
                let filters = CardFilter.allCases.filter { option in
                    option != .suspended || filter == .suspended || cards.contains { $0.status == .suspended }
                }
                SegmentedChoice(options: filters, selection: filter,
                                label: { option in
                                    "\(option.label) \(cards.filter { option.includes($0, levels: levels, now: now) }.count)"
                                }) {
                    filter = $0
                    shown = Self.pageSize
                }
                Spacer()
                TextField("Filter cards", text: $text)
                    .frame(width: 160.0)
                Picker(of: CardSort.allCases, selection: Binding(get: { sort }, set: { sort = $0 ?? .deckOrder }))
                GRASPButton(selection == nil ? "Select" : "Done") {
                    selection = selection == nil ? [] : nil
                    confirmingBulkDelete = false
                }
                GRASPButton("+ New card") {
                    editing = CardEditorTarget(card: nil, deckId: scope.deckIds.first)
                }
            }

            if draftCount > 0 && filter != .drafts && selection == nil {
                DraftsStrip(count: draftCount, review: {
                    filter = .drafts
                    shown = Self.pageSize
                }, approveAll: { library.approveDrafts(inDecks: scope.deckIds) })
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
                        CardRowView(card: card, state: UnderstandingState.of(level: levels[card.id]),
                                    reviewNote: notes[card.id], now: now,
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
                if matching.count > shown {
                    HStack(spacing: 10) {
                        Text("Showing \(shown) of \(matching.count)")
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.textTertiary)
                        GRASPButton("Show \(min(Self.pageSize, matching.count - shown)) more") { shown += Self.pageSize }
                    }
                }
            }
        }
        .onChange(of: scope.id) {
            shown = Self.pageSize
            text = ""
            selection = nil
            focus = nil
            noteFilter = nil
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

/// The Mac's sort options.
enum CardSort: CaseIterable, Equatable, CustomStringConvertible {
    case deckOrder, alphabetical, dateAdded, dueDate

    var description: String {
        switch self {
        case .deckOrder: return "Deck order"
        case .alphabetical: return "Alphabetical (A to Z)"
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

/// The Mac's filter pills (`DeckDetailView.MasteryFilter`): All, Drafts,
/// Due, Understood. Suspended is Windows' extra pill, shown only when a card
/// is suspended, since the Mac reaches those through its sort menu.
enum CardFilter: CaseIterable, Equatable {
    case all, drafts, due, understood, suspended

    var label: String {
        switch self {
        case .all: return "All"
        case .drafts: return "Drafts"
        case .due: return "Due"
        case .understood: return "Understood"
        case .suspended: return "Suspended"
        }
    }

    func includes(_ card: Card, levels: [String: LearnEngine.Level], now: Date) -> Bool {
        switch self {
        case .all: return true
        case .drafts: return card.status == .draft
        case .due: return card.status == .active && card.due <= now
        case .understood: return card.status == .active && levels[card.id] == .mastered
        case .suspended: return card.status == .suspended
        }
    }
}

/// The Mac's `CardRowStatus.text`: one muted word on the right of a row.
enum CardRowStatus {
    static func text(for card: Card, hasProgress: Bool, now: Date, calendar: Calendar = .current) -> String {
        switch card.status {
        case .draft: return "Draft"
        case .suspended: return "Suspended"
        case .active: break
        }
        if card.reps == 0 && card.lastReview == nil { return hasProgress ? "" : "New" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: card.due)).day ?? 0
        if days < 0 { return "Overdue" }
        if days == 0 { return "Due today" }
        if days < 14 { return "in \(days)d" }
        if days < 60 { return "in \(days / 7)w" }
        return "in \(max(2, days / 30))mo"
    }
}

/// The three understanding pips (recognition, recall, understood), drawn as
/// at most three runs of glyphs rather than three shapes: a row is built for
/// every card on the page, and each shape costs a view. Solid pips take the
/// stage's colour, a self-rated claim is an outline in the secondary tone,
/// and the rest are the strong hairline. No yellow except recall's stage
/// colour, as on the Mac.
struct PipMeter: View {
    let state: UnderstandingState
    var suspended = false

    var body: some View {
        let solid = state.pips.filter { $0 == .solid }.count
        let dotted = state.pips.filter { $0 == .dotted }.count
        let empty = 3 - solid - dotted
        HStack(spacing: 0) {
            if solid > 0 { run(solid, glyph: "\u{25AC}", color: suspended ? GRASPColor.rejected : stageColor) }
            if dotted > 0 { run(dotted, glyph: "\u{25AD}", color: GRASPColor.textSecondary) }
            if empty > 0 { run(empty, glyph: "\u{25AC}", color: GRASPColor.hairlineStrong) }
        }
        .fixedSize()
    }

    private func run(_ count: Int, glyph: String, color: Color) -> some View {
        Text(String(repeating: glyph, count: count))
            .font(Font.system(size: 9))
            .foregroundColor(color)
    }

    /// The Mac's `UnderstandingState.stageColor`.
    private var stageColor: Color {
        switch state.level {
        case .new: return GRASPColor.textTertiary
        case .recognition, .familiar: return GRASPColor.textSecondary
        case .recall: return GRASPColor.accent
        case .mastered: return GRASPColor.success
        }
    }
}

/// One card in the list, as the Mac draws it: pips at the left for an
/// approved card (a 2 pt rail for drafts and suspended ones), the front and
/// back, and one muted status word on the right. Deliberately light: a list
/// page builds every row at once, and a row with its own drop-down menu cost
/// about 30 ms. The actions live in the card's window, a click away.
private struct CardRowView: View {
    let card: Card
    let state: UnderstandingState
    /// A flag on a parser-made draft; shown, never acted on.
    var reviewNote: String?
    let now: Date
    /// nil when not selecting.
    let selected: Bool?
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                if let selected {
                    Text(selected ? "\u{2713}" : " ")
                        .font(Font.system(size: 12, weight: .bold))
                        .foregroundColor(GRASPColor.ink)
                        .frame(width: 18.0, height: 18.0)
                        .background(selected ? GRASPColor.brand : GRASPColor.hairlineStrong)
                        .cornerRadius(9)
                }
                leading.frame(width: 40.0, alignment: .leading).padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    // The sparkle's row only for AI drafts: a container per row
                    // costs on every redraw.
                    if card.origin == .aiGenerated && card.status == .draft {
                        HStack(spacing: 6) {
                            AIGlyph(size: 12)
                            front
                        }
                    } else {
                        front
                    }
                    Text(card.back).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary).lineLimit(2)
                    if let reviewNote {
                        Text(reviewNote).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary).lineLimit(1)
                    }
                }
                Spacer()
                Text(CardRowStatus.text(for: card, hasProgress: state.hasProgress, now: now))
                    .font(GRASPFont.meta)
                    .foregroundColor(card.status == .suspended ? GRASPColor.rejected : GRASPColor.textTertiary)
                    .fixedSize()
            }
            .padding(.vertical, 12)
            HairlineRule()
        }
        .onTapGesture(perform: open)
    }

    private var front: some View {
        Text(card.front).font(Font.system(size: 14.5, weight: .medium)).foregroundColor(GRASPColor.textPrimary)
    }

    @ViewBuilder
    private var leading: some View {
        if card.status == .active {
            PipMeter(state: state)
        } else {
            Rectangle()
                .fill(card.status == .suspended ? GRASPColor.rejected : GRASPColor.hairlineStrong)
                .frame(width: 2.0, height: 34.0)
        }
    }
}

/// The Mac's drafts strip: how many drafts wait, a way to see them, and
/// approving them all at once.
private struct DraftsStrip: View {
    let count: Int
    let review: GRASPAction
    let approveAll: GRASPAction

    var body: some View {
        HStack(spacing: 12) {
            Text("\u{2750}").font(Font.system(size: 14)).foregroundColor(GRASPColor.textTertiary)
            Text("\(count) draft\(count == 1 ? "" : "s") to review")
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textSecondary)
            Spacer()
            GRASPButton("Approve all", action: approveAll)
            GRASPButton("Review drafts", action: review)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.card)
    }
}

/// The deck page's understanding block, after the Mac's
/// `UnderstandingSummary`: a bar of the deck's cards by stage, its count
/// line, the five weakest notes (a tap shows that note's cards) and an
/// outlined "Practice weakest" that starts a Learn round on up to eight of
/// them.
struct UnderstandingPanel: View {
    let cards: [DeckUnderstanding.Card]
    let titles: [String: String]
    let openNote: (String?) -> Void
    let practice: ([String]) -> Void

    /// The last real width the reader saw. SwiftCrossUI also runs a reader
    /// at width 0 and infinity; those passes reuse it (see CalendarScreen).
    private static var lastWidth = 900.0

    var body: some View {
        let distribution = DeckUnderstanding.distribution(of: cards)
        if distribution.total > 0 {
            let weakest = DeckUnderstanding.weakestNotes(of: cards)
            let practiceIds = DeckUnderstanding.practiceCards(of: cards)
            // One reader for the whole panel, so every bar spans it: a reader
            // per bar laid each out three times, and a width taken from the
            // window fed back into the window's size and grew it. A reader
            // inside a ScrollView needs a height, so it's worked out from the
            // rows (bar, count line, the notes heading, 40 pt a note, the
            // button).
            let notesHeight: Double = weakest.isEmpty ? 0 : 20 + 50 * Double(weakest.count)
            let buttonHeight: Double = practiceIds.isEmpty ? 0 : 46
            let height: Double = 37 + notesHeight + buttonHeight
            GeometryReader { proxy in
                let barWidth = Self.width(proxy.size.width)
                content(distribution: distribution, weakest: weakest, practiceIds: practiceIds, barWidth: barWidth)
            }
            .frame(height: height)
            .padding(16)
            .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.card)
        }
    }

    private static func width(_ proposed: Double) -> Double {
        if proposed.isFinite && proposed > 0 { lastWidth = Double(proposed) }
        return lastWidth
    }

    private func content(distribution: DeckUnderstanding.Distribution, weakest: [DeckUnderstanding.NoteGroup],
                         practiceIds: [String], barWidth: Double) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                UnderstandingBar(distribution: distribution, width: barWidth, height: 10.0)
                Text(distribution.line)
                    .font(Font.system(size: 12.5))
                    .foregroundColor(GRASPColor.textSecondary)
                if !weakest.isEmpty {
                    Text("Weakest notes")
                        .font(GRASPFont.eyebrow)
                        .foregroundColor(GRASPColor.textTertiary)
                        .padding(.top, 4)
                    ForEach(weakest, id: \.id) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Text(group.materialId.flatMap { titles[$0] } ?? "Other")
                                    .font(Font.system(size: 13.5, weight: .medium))
                                    .foregroundColor(GRASPColor.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text(group.summary)
                                    .font(Font.system(size: 12))
                                    .foregroundColor(GRASPColor.textTertiary)
                                    .fixedSize()
                            }
                            UnderstandingBar(distribution: group.distribution, width: barWidth, height: 6.0)
                        }
                        .padding(.vertical, 5)
                        .onTapGesture { openNote(group.materialId) }
                    }
                }
                if !practiceIds.isEmpty {
                    GRASPButton("Practice weakest") { practice(practiceIds) }
                        .padding(.top, 4)
                }
            }
    }
}

/// The deck's cards as one bar, left to right: understood (green), recall
/// (yellow), recognition (light), self-rated (dim), and the not-asked rest
/// as the track. Drawn at a given width rather than in a GeometryReader:
/// a reader lays its content out three times, and the deck page shows a
/// bar per deck and per weak note.
struct UnderstandingBar: View {
    let distribution: DeckUnderstanding.Distribution
    let width: Double
    var height = 10.0

    var body: some View {
        let total = Double(max(distribution.total, 1))
        let part = { (count: Int) -> Double in (width * Double(count) / total).rounded() }
        HStack(spacing: 0) {
                if distribution.solid > 0 { Rectangle().fill(GRASPColor.success).frame(width: part(distribution.solid), height: height) }
                if distribution.recall > 0 { Rectangle().fill(GRASPColor.accent).frame(width: part(distribution.recall), height: height) }
                if distribution.recognition > 0 {
                    Rectangle().fill(GRASPColor.textSecondary).frame(width: part(distribution.recognition), height: height)
                }
                if distribution.selfRated > 0 {
                    Rectangle().fill(GRASPColor.textTertiary).frame(width: part(distribution.selfRated), height: height)
                }
                Spacer()
        }
        .frame(width: width, height: height)
        .background(GRASPColor.inset)
        .cornerRadius(Int(height / 2))
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
                    let note = library.note(materialId)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if let kicker = note?.kicker {
                                Text(kicker).font(GRASPFont.eyebrow).foregroundColor(GRASPColor.accent)
                            }
                            if let title = note?.title {
                                Text(title).font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textPrimary)
                            }
                            Text(note?.text ?? "This card's note isn't in the library.")
                                .font(GRASPFont.body)
                                .foregroundColor(GRASPColor.textSecondary)
                        }
                        .frame(maxWidth: 440.0, alignment: .leading)
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
