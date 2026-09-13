import SwiftUI
import GRASPCore

/// Decks for one course, chapter-ordered where a chapter exists (auto decks
/// carry `sortIndex` derived from that), else alphabetical. Only ever
/// mounted when the course actually has at least one deck -- `ContentView`
/// renders `CourseEmptyStateView` instead otherwise -- so there is no empty
/// state here, and no course-level actions (New Deck, Add Files, Exams):
/// those live in `ContentView`'s toolbar, since a zero-deck course needs
/// them to work without this view ever mounting, and the collapsible deck-
/// list toggle already established that pattern for course-level chrome.
struct DeckListView: View {
    /// Sentinel sharing `selectedDeckId`'s single-selection binding with
    /// real deck ids, the same trick `ContentView.homeRoute` already uses
    /// for `selectedCourseId` -- a second `String?` that could disagree
    /// with the first would be its own bug to keep in sync.
    static let allCardsId = "__all_cards__"

    @Environment(AppStore.self) private var store
    let courseId: String
    @Binding var selectedDeckId: String?
    @State private var decks: [Deck] = []
    @State private var renamingDeck: Deck?
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

    var body: some View {
        List(selection: $selectedDeckId) {
            AllCardsRow(cardCount: allCardsCounts.cardCount, dueCount: allCardsCounts.dueCount)
                .tag(Self.allCardsId)

            ForEach(decks) { deck in
                let counts = store.deckCounts[deck.id] ?? (0, 0)
                DeckRow(name: deck.name, cardCount: counts.cardCount, dueCount: counts.dueCount)
                    .tag(deck.id)
                    .listRowBackground(
                        dropTargetDeckId == deck.id ? GRASPColor.accentSoft : Color.clear
                    )
                    .contextMenu {
                        DeckContextMenu(
                            deck: deck,
                            onRename: { renamingDeck = deck },
                            onDelete: { beginDelete(deck) }
                        )
                    }
                    .dropDestination(for: CardTransfer.self) { items, _ in
                        guard !items.isEmpty else { return false }
                        try? store.bulkMoveCards(items.map(\.cardId), toDeck: deck.id)
                        return true
                    } isTargeted: { isTargeted in
                        dropTargetDeckId = isTargeted ? deck.id : nil
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .sheet(item: $renamingDeck) { deck in
            DeckRenameSheet(deck: deck, onRenamed: load)
        }
        .sheet(item: $deletingDeck) { deck in
            DeckDeleteSheet(
                deck: deck, cardCount: deletingDeckCardCount,
                siblings: decks.filter { $0.id != deck.id }
            ) { targetId in
                try? store.deleteDeck(deck.id, migrateCardsTo: targetId)
                if selectedDeckId == deck.id { selectedDeckId = targetId }
                load()
            }
        }
        .task(id: courseId) { load() }
        .onChange(of: store.revision) { load() }
    }

    private func load() {
        decks = (try? store.decks(inCourse: courseId)) ?? []
    }

    private func beginDelete(_ deck: Deck) {
        let count = (try? store.deckCardCount(deck.id)) ?? 0
        if count == 0 {
            try? store.deleteDeck(deck.id, migrateCardsTo: nil)
            if selectedDeckId == deck.id { selectedDeckId = nil }
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

/// Card count is set in tabular digits and right-aligned in a fixed slot,
/// so the column of numbers down the list lines up instead of wandering
/// with each deck's name length.
private struct DeckRow: View {
    let name: String
    let cardCount: Int
    let dueCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .graspType(.rowTitle)
                .lineLimit(1)
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
