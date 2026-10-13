import Testing
import Foundation
import GRDB
import GRASPCore
@testable import GRASP

@Suite("Deck page counts")
struct DeckCardCountsTests {
    private func card(_ status: CardStatus, due: Date = Date(timeIntervalSinceNow: 86_400),
                      origin: CardOrigin = .parser) -> Card {
        Card(materialId: nil, front: UUID().uuidString, back: "b", origin: origin, status: status, due: due)
    }

    /// A deck of 10: four drafts, one suspended, five approved (two due,
    /// one understood).
    private func deck() -> (cards: [Card], levels: [String: LearnEngine.Level]) {
        let past = Date(timeIntervalSinceNow: -3_600)
        let cards = [
            card(.draft), card(.draft), card(.draft), card(.draft),
            card(.suspended),
            card(.active, due: past), card(.active, due: past), card(.active), card(.active), card(.active),
        ]
        return (cards, [cards[9].id: .mastered])
    }

    @Test("Each figure counts its own kind of card")
    func figures() {
        let (cards, levels) = deck()
        let counts = DeckCardCounts.make(cards: cards, levels: levels)
        #expect(counts.all == 10)
        #expect(counts.drafts == 4)
        #expect(counts.active == 5)
        #expect(counts.suspended == 1)
        #expect(counts.due == 2)
        #expect(counts.understood == 1)
        #expect(counts.inDeckList == 9)
    }

    @Test("A batch still sliding in is in no count until it has all landed")
    func heldBatch() {
        var (cards, levels) = deck()
        let before = DeckCardCounts.make(cards: cards, levels: levels)
        let arrivals = (0..<3).map { _ in card(.draft, origin: .aiGenerated) }
        cards += arrivals
        let held = Set(arrivals.map(\.id))

        // Mid-batch: the page's counts have not moved and the strip says 0 new.
        #expect(DeckCardCounts.make(cards: cards, levels: levels, held: held) == before)
        #expect(DeckCardCounts.newCount(recent: arrivals.map(\.id), held: held) == 0)

        // Landed: every count moves by the same three.
        let after = DeckCardCounts.make(cards: cards, levels: levels)
        #expect(after.all == before.all + 3)
        #expect(after.drafts == before.drafts + 3)
        #expect(DeckCardCounts.newCount(recent: arrivals.map(\.id), held: []) == 3)
    }

    @Test("Strip, pills and deck list agree after every batch of a run")
    func agreeAcrossARun() async throws {
        let database = try GRASPDatabase.inMemory()
        let (deckId, courseId) = try await database.queue.write { db -> (String, String) in
            let course = Course(semesterId: nil, name: "Course")
            try course.insert(db)
            let deck = Deck(courseId: course.id, name: "Deck")
            try deck.insert(db)
            return (deck.id, course.id)
        }
        _ = courseId
        var recent: [String] = []
        for batchSize in [2, 5, 1, 3] {
            // Cards land in the database...
            let batch = (0..<batchSize).map { _ in card(.draft, origin: .aiGenerated) }
            try await database.queue.write { db in
                for (index, card) in batch.enumerated() {
                    try card.insert(db)
                    try DeckCard(deckId: deckId, cardId: card.id, sortIndex: index).insert(db)
                }
            }
            recent = batch.map(\.id) + recent
            // ...the page reads them, holding the batch while rows slide in.
            let loaded = try await database.queue.read { try CardActions.cards(inDecks: [deckId], db: $0) }
            let held = Set(batch.map(\.id))
            let midBatch = DeckCardCounts.make(cards: loaded, levels: [:], held: held)
            #expect(midBatch.all == recent.count - batch.count)
            #expect(DeckCardCounts.newCount(recent: recent, held: held) == recent.count - batch.count)

            // Batch on screen: the page's figures and the deck list's own
            // count (the same query the sidebar reads) are the same number.
            let settled = DeckCardCounts.make(cards: loaded, levels: [:])
            let listCounts = try await database.queue.read { db -> Int in
                let decks = try Deck.fetchAll(db)
                return try AppStore.deckCounts(for: decks, db)[deckId]?.cardCount ?? -1
            }
            #expect(settled.all == recent.count)
            #expect(settled.drafts == recent.count)
            #expect(settled.inDeckList == listCounts)
            #expect(DeckCardCounts.newCount(recent: recent, held: []) == settled.all)
        }
    }
}
