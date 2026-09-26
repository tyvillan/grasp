import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Card actions")
struct CardActionsTests {
    /// A course with two decks: "Week 1" holding three parser cards from a
    /// note about photosynthesis, "Week 2" empty.
    private func makeLibrary() async throws -> (GRASPDatabase, week1: String, week2: String, cards: [String], material: String) {
        let db = try GRASPDatabase.inMemory()
        let ids = try await db.queue.write { conn -> (String, String, [String], String) in
            let course = Course(semesterId: nil, name: "Biology")
            try course.insert(conn)
            let week1 = Deck(courseId: course.id, name: "Week 1")
            try week1.insert(conn)
            let week2 = Deck(courseId: course.id, name: "Week 2")
            try week2.insert(conn)
            let material = Material(courseId: course.id, relativePath: "/v/photo.md", kind: .markdown,
                                    contentHash: "h", title: "Photosynthesis")
            try material.insert(conn)
            let text = "Chlorophyll absorbs light in the thylakoid membrane. The Calvin cycle fixes carbon."
            try NoteText(materialId: material.id, raw: text, reflowed: text, wordCount: 13, hasMath: false).insert(conn)
            var cardIds: [String] = []
            for (index, (front, back)) in [("Chlorophyll", "Absorbs light"), ("Calvin cycle", "Fixes carbon"),
                                           ("Stroma", "Fluid around the thylakoids")].enumerated() {
                let card = Card(materialId: material.id, front: front, back: back, origin: .parser, status: .draft)
                try card.insert(conn)
                try DeckCard(deckId: week1.id, cardId: card.id, sortIndex: index).insert(conn)
                cardIds.append(card.id)
            }
            return (week1.id, week2.id, cardIds, material.id)
        }
        return (db, ids.0, ids.1, ids.2, ids.3)
    }

    @Test("cards come back in deck order, without deleted ones")
    func listing() async throws {
        let (db, week1, _, cards, _) = try await makeLibrary()
        try await db.queue.write { try CardActions.delete([cards[1]], db: $0) }
        let listed = try await db.queue.read { try CardActions.cards(inDecks: [week1], db: $0) }
        #expect(listed.map(\.id) == [cards[0], cards[2]])
    }

    @Test("editing changes only the text, trims it, and makes a parser card manual")
    func edit() async throws {
        let (db, _, _, cards, _) = try await makeLibrary()
        let changed = try await db.queue.write {
            try CardActions.updateText(cardId: cards[0], front: "  Chlorophyll a ", back: "Absorbs red and blue light", db: $0)
        }
        #expect(changed)
        let card = try #require(try await db.queue.read { try Card.fetchOne($0, key: cards[0]) })
        #expect(card.front == "Chlorophyll a")
        #expect(card.back == "Absorbs red and blue light")
        #expect(card.origin == .manual)
        #expect(card.status == .draft)

        let unchanged = try await db.queue.write {
            try CardActions.updateText(cardId: cards[0], front: "Chlorophyll a", back: "Absorbs red and blue light", db: $0)
        }
        #expect(!unchanged)
        let blank = try await db.queue.write { try CardActions.updateText(cardId: cards[0], front: " ", back: "x", db: $0) }
        #expect(!blank)
    }

    @Test("status changes and deletes apply to every card given")
    func statusAndDelete() async throws {
        let (db, week1, _, cards, _) = try await makeLibrary()
        try await db.queue.write { try CardActions.setStatus([cards[0], cards[1]], to: .suspended, db: $0) }
        let statuses = try await db.queue.read { db in try cards.map { try Card.fetchOne(db, key: $0)!.status } }
        #expect(statuses == [.suspended, .suspended, .draft])
        try await db.queue.write { try CardActions.delete(cards, db: $0) }
        let left = try await db.queue.read { try CardActions.cards(inDecks: [week1], db: $0) }
        #expect(left.isEmpty)
    }

    @Test("moving puts cards at the end of the target and leaves ones already there alone")
    func move() async throws {
        let (db, week1, week2, cards, _) = try await makeLibrary()
        try await db.queue.write { try CardActions.move([cards[2], cards[0]], toDeck: week2, db: $0) }
        let (one, two) = try await db.queue.read { db in
            (try CardActions.cards(inDecks: [week1], db: db).map(\.id), try CardActions.cards(inDecks: [week2], db: db).map(\.id))
        }
        #expect(one == [cards[1]])
        #expect(two == [cards[2], cards[0]])
        try await db.queue.write { try CardActions.move([cards[2]], toDeck: week2, db: $0) }
        let again = try await db.queue.read { try CardActions.cards(inDecks: [week2], db: $0).map(\.id) }
        #expect(again == [cards[2], cards[0]])
    }

    @Test("a hand-typed card is active and joins the end of its deck")
    func createManual() async throws {
        let (db, week1, _, _, _) = try await makeLibrary()
        let id = try await db.queue.write { try CardActions.createManual(front: " Light reactions ", back: "Make ATP", deckId: week1, db: $0) }
        let listed = try await db.queue.read { try CardActions.cards(inDecks: [week1], db: $0) }
        #expect(listed.last?.id == id)
        #expect(listed.last?.front == "Light reactions")
        #expect(listed.last?.status == .active)
        #expect(listed.last?.origin == .manual)
    }

    @Test("note search finds words by prefix and survives FTS keywords")
    func noteSearch() async throws {
        let (db, _, _, _, material) = try await makeLibrary()
        let hits = try await db.queue.read { try CardActions.searchNotes("thylak", db: $0) }
        #expect(hits.map(\.materialId) == [material])
        #expect(hits.first?.snippet.contains("\u{2}") == true)
        let keywords = try await db.queue.read { try CardActions.searchNotes("Calvin AND cycle", db: $0) }
        #expect(keywords.isEmpty)
        let none = try await db.queue.read { try CardActions.searchNotes("!!!", db: $0) }
        #expect(none.isEmpty)
    }

    @Test("card search needs every word, on either side, ignoring case")
    func cardSearch() async throws {
        let (db, week1, _, cards, _) = try await makeLibrary()
        let hits = try await db.queue.read { try CardActions.searchCards("fixes CALVIN", db: $0) }
        #expect(hits.map(\.card.id) == [cards[1]])
        #expect(hits.first?.deckId == week1)
        try await db.queue.write { try CardActions.delete([cards[1]], db: $0) }
        let gone = try await db.queue.read { try CardActions.searchCards("calvin", db: $0) }
        #expect(gone.isEmpty)
    }
}
