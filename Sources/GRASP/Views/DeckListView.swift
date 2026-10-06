import SwiftUI
import GRASPCore

/// A user-chosen display order for `DeckListView`'s list -- separate from
/// `AppStore.decks(inCourse:)`'s own DB-level ordering (`sortIndex`,
/// `chapter`, `name`), which `.deckOrder` here just passes through
/// unchanged. One global preference (`@AppStorage`, like
/// `isDeckListCollapsed`) rather than per-course, since "how I like my
/// decks arranged" is a habit, not something that varies course to course.
private enum DeckSortOption: String, CaseIterable, Identifiable {
    case deckOrder, alphabetical, dateAdded, mostDue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deckOrder: return "Default (Deck Order)"
        case .alphabetical: return "Alphabetical (A–Z)"
        case .dateAdded: return "Date Added"
        case .mostDue: return "Most Due First"
        }
    }
}

/// Decks for one course, chapter-ordered where a chapter exists (auto decks
/// carry `sortIndex` derived from that), else alphabetical. Only ever
/// mounted when the course actually has at least one deck -- `ContentView`
/// renders `CourseEmptyStateView` instead otherwise, which carries its own
/// "New Deck…" button so a zero-deck course can still get its first deck
/// without this view ever mounting. `New Deck` doesn't need that guarantee, so it lives in `header` below,
/// beside the list it actually populates -- collapsing the deck-list pane
/// hides it along with everything else in the pane, same as any other
/// deck-list-scoped control.
struct DeckListView: View {
    /// Sentinel sharing `selectedDeckId`'s single-selection binding with
    /// real deck ids, the same trick `ContentView.homeRoute` already uses
    /// for `selectedCourseId` -- a second `String?` that could disagree
    /// with the first would be its own bug to keep in sync.
    static let allCardsId = "__all_cards__"

    /// An exam's study page shares the same selection, one row per exam
    /// that has a study guide: `examRowPrefix` + the exam's event id.
    static let examRowPrefix = "__exam__:"
    static func examRowId(_ examEventId: String) -> String { examRowPrefix + examEventId }
    static func examEventId(fromRow id: String) -> String? {
        id.hasPrefix(examRowPrefix) ? String(id.dropFirst(examRowPrefix.count)) : nil
    }

    @Environment(AppStore.self) private var store
    let courseId: String
    @Binding var selectedDeckId: String?
    let onNewDeck: () -> Void
    let onAddStudyGuide: () -> Void
    @AppStorage("deckSortOption") private var sortOption: DeckSortOption = .deckOrder
    @State private var decks: [Deck] = []
    @State private var kickers: [String: String] = [:]
    @State private var exams: [CalendarEvent] = []
    @State private var renamingDeck: Deck?
    @State private var settingLectureDateFor: Deck?
    @State private var deletingDeck: Deck?
    @State private var deletingDeckCardCount = 0
    @State private var dropTargetDeckId: String?

    /// Summed from `store.deckCounts`, the same per-deck counts every real
    /// row already reads -- free of any extra query, and it updates the
    /// instant a card is added, removed, or moved between decks because
    /// `deckCounts` itself is recomputed on every `store.reload()`.
    private var allCardsCounts: (cardCount: Int, dueCount: Int) {
        decks.reduce((0, 0)) { total, deck in
            let counts = store.deckCounts[deck.id] ?? (0, 0)
            return (total.0 + counts.cardCount, total.1 + counts.dueCount)
        }
    }

    /// `decks` itself always stays in the DB's own order -- re-derived
    /// fresh from `sortOption` on every render instead of re-sorted in
    /// place, so switching the option back to `.deckOrder` doesn't need to
    /// remember or re-fetch anything.
    private var sortedDecks: [Deck] {
        switch sortOption {
        case .deckOrder:
            return decks
        case .alphabetical:
            return decks.sorted { NaturalOrder.isOrdered($0.name, before: $1.name) }
        case .dateAdded:
            return decks.sorted { $0.createdAt < $1.createdAt }
        case .mostDue:
            return decks.sorted { (store.deckCounts[$0.id]?.dueCount ?? 0) > (store.deckCounts[$1.id]?.dueCount ?? 0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List(selection: $selectedDeckId) {
                AllCardsRow(cardCount: allCardsCounts.cardCount, dueCount: allCardsCounts.dueCount)
                    .tag(Self.allCardsId)
                ForEach(exams) { exam in
                    ExamRow(exam: exam)
                        .tag(Self.examRowId(exam.id))
                }

                ForEach(sortedDecks) { deck in
                    let counts = store.deckCounts[deck.id] ?? (0, 0)
                    DeckRow(name: deck.name, kicker: kickers[deck.id],
                            cardCount: counts.cardCount, dueCount: counts.dueCount)
                        .tag(deck.id)
                        .listRowBackground(
                            dropTargetDeckId == deck.id ? GRASPColor.accentSoft : Color.clear
                        )
                        .rowActions(inline: true) {
                            DeckContextMenu(
                                deck: deck,
                                onRename: { renamingDeck = deck },
                                onSetLectureDate: { settingLectureDateFor = deck },
                                onDelete: { beginDelete(deck) }
                            )
                        }
                        .dropDestination(for: CardTransfer.self) { items, _ in
                            guard !items.isEmpty else { return false }
                            try? store.bulkMoveCards(items.flatMap(\.cardIds), toDeck: deck.id)
                            return true
                        } isTargeted: { isTargeted in
                            dropTargetDeckId = isTargeted ? deck.id : nil
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .sheet(item: $renamingDeck) { deck in
            DeckRenameSheet(deck: deck, onRenamed: load)
        }
        .sheet(item: $settingLectureDateFor) { deck in
            DeckLectureDateSheet(deck: deck, onSaved: load)
        }
        .sheet(item: $deletingDeck) { deck in
            DeckDeleteSheet(
                deck: deck, cardCount: deletingDeckCardCount,
                siblings: decks.filter { $0.id != deck.id }
            ) { targetId in
                try? store.deleteDeck(deck.id, migrateCardsTo: targetId)
                // Land on where the cards went, or "All Cards" -- never on
                // nothing, which left an empty pane.
                if selectedDeckId == deck.id { selectedDeckId = targetId ?? Self.allCardsId }
                load()
            }
        }
        .task(id: courseId) { load() }
        .onChange(of: store.revision) { load() }
    }

    /// "Decks" label plus the sort and create actions -- the common macOS
    /// sidebar header shape, and the one place `New Deck` lives now that
    /// it's no longer duplicated in the main window toolbar.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Decks")
                .graspType(.eyebrow)
                .foregroundStyle(GRASPColor.textSecondary)
            Spacer(minLength: 4)
            Menu {
                Picker("Sort Decks", selection: $sortOption) {
                    ForEach(DeckSortOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort decks: \(sortOption.label)")
            Button(action: onAddStudyGuide) {
                Label("Add Guide", systemImage: "graduationcap")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Add a study guide for an exam in this course")
            Button(action: onNewDeck) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(GRASPColor.accent)
            }
            .buttonStyle(.plain)
            .help("Create a new deck in this course")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func load() {
        decks = (try? store.decks(inCourse: courseId)) ?? []
        kickers = store.deckKickers(for: decks)
        exams = store.guidedExams(courseId: courseId)
    }

    private func beginDelete(_ deck: Deck) {
        let count = (try? store.deckCardCount(deck.id)) ?? 0
        if count == 0 {
            try? store.deleteDeck(deck.id, migrateCardsTo: nil)
            if selectedDeckId == deck.id { selectedDeckId = Self.allCardsId }
            load()
        } else {
            deletingDeckCardCount = count
            deletingDeck = deck
        }
    }
}

/// The "master category" pinned above every real deck: an icon and bold
/// name mark it as a different kind of row (an aggregate, not a category
/// someone made), while the count columns line up with `DeckRow`'s so the
/// list still reads as one column of numbers, not two competing styles.
private struct AllCardsRow: View {
    let cardCount: Int
    let dueCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 11))
                .foregroundStyle(GRASPColor.accent)
            Text("All Cards")
                .graspType(.rowTitle)
                .fontWeight(.semibold)
            Spacer(minLength: 4)
            if dueCount > 0 {
                Text("\(dueCount)")
                    .font(.system(size: 10, weight: .bold)).monospacedDigit()
                    .foregroundStyle(GRASPColor.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(GRASPColor.accentSoft, in: Capsule())
            }
            Text("\(cardCount)")
                .graspType(.meta)
                .monospacedDigit()
                .foregroundStyle(GRASPColor.textTertiary)
                .frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

/// An exam with a study guide, pinned under All Cards: what to study for
/// next, with how soon it is.
private struct ExamRow: View {
    let exam: CalendarEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 11))
                .foregroundStyle(GRASPColor.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(exam.title)
                    .graspType(.rowTitle)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("\(exam.startsAt.formatted(.dateTime.month(.abbreviated).day())) · \(exam.countdownText())")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Card count is set in tabular digits and right-aligned in a fixed slot,
/// so the column of numbers down the list lines up instead of wandering
/// with each deck's name length.
private struct DeckRow: View {
    let name: String
    let kicker: String?
    let cardCount: Int
    let dueCount: Int

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if let kicker {
                    Text(kicker)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GRASPColor.accent)
                }
                Text(name)
                    .graspType(.rowTitle)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if dueCount > 0 {
                Text("\(dueCount)")
                    .font(.system(size: 10, weight: .bold)).monospacedDigit()
                    .foregroundStyle(GRASPColor.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(GRASPColor.accentSoft, in: Capsule())
            }
            Text("\(cardCount)")
                .graspType(.meta)
                .monospacedDigit()
                .foregroundStyle(GRASPColor.textTertiary)
                .frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
