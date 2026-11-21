import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Sharing a deck")
struct DeckShareTests {
    private func library() async throws -> (GRASPDatabase, deckId: String, otherCourse: String) {
        let db = try GRASPDatabase.inMemory()
        let ids: (String, String) = try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Micro")
            try course.insert(conn)
            let other = Course(semesterId: nil, name: "Other")
            try other.insert(conn)
            let deck = Deck(courseId: course.id, name: "Week 3")
            try deck.insert(conn)
            var position = 0
            func add(_ front: String, _ back: String, status: CardStatus, deleted: Bool = false) throws {
                let card = Card(materialId: nil, front: front, back: back, origin: .manual, status: status,
                                deletedAt: deleted ? Date() : nil)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: position).insert(conn)
                position += 1
            }
            try add("Opportunity cost", "The best alternative given up", status: .active)
            try add("Sunk cost", "A cost already spent and gone", status: .active)
            try add("Draft card", "Not reviewed", status: .draft)
            try add("Deleted card", "Gone", status: .active, deleted: true)
            return (deck.id, other.id)
        }
        return (db, ids.0, ids.1)
    }

    @Test("a deck packs its approved cards only, and round-trips through a file")
    func exportRoundTrip() async throws {
        let (db, deckId, _) = try await library()
        let shared = try await db.queue.read { try DeckShare.export(deckId: deckId, includeQuestions: false, db: $0) }
        #expect(shared.name == "Week 3")
        #expect(shared.courseName == "Micro")
        #expect(shared.cards.map(\.front) == ["Opportunity cost", "Sunk cost"])
        let decoded = try DeckShare.decode(try DeckShare.encode(shared))
        #expect(decoded.cards == shared.cards)
    }

    @Test("a file that is not a deck, or is from a newer GRASP, is refused")
    func refuses() throws {
        #expect(throws: DeckShare.ShareError.notADeckFile) { try DeckShare.decode(Data("{\"hello\": 1}".utf8)) }
        #expect(throws: DeckShare.ShareError.notADeckFile) { try DeckShare.decode(Data("not json".utf8)) }
        let future = SharedDeck(format: SharedDeck.format, version: 99, name: "x", courseName: nil,
                                exportedAt: Date(), cards: [], questions: [])
        #expect(throws: DeckShare.ShareError.newerVersion) { try DeckShare.decode(try DeckShare.encode(future)) }
    }

    @Test("importing makes a new deck of approved cards, and importing again skips what is already there")
    func importing() async throws {
        let (db, deckId, other) = try await library()
        let shared = try await db.queue.read { try DeckShare.export(deckId: deckId, includeQuestions: false, db: $0) }
        let first = try await db.queue.write { try DeckShare.importDeck(shared, intoCourse: other, db: $0) }
        #expect(first.cardsAdded == 2 && first.duplicatesSkipped == 0)
        let second = try await db.queue.write { try DeckShare.importDeck(shared, intoCourse: other, db: $0) }
        #expect(second.cardsAdded == 0 && second.duplicatesSkipped == 2)
        try await db.queue.read { conn in
            let deck = try #require(try Deck.fetchOne(conn, key: first.deckId))
            #expect(deck.courseId == other && deck.name == "Week 3")
            let cards = try Card.fetchAll(conn, sql: """
                SELECT card.* FROM card JOIN deckCard ON deckCard.cardId = card.id WHERE deckCard.deckId = ?
                """, arguments: [first.deckId])
            #expect(cards.count == 2)
            #expect(cards.allSatisfy { $0.status == .active && $0.reps == 0 })
        }
    }

    @Test("importing into a course that is gone fails cleanly")
    func missingCourse() async throws {
        let (db, deckId, _) = try await library()
        let shared = try await db.queue.read { try DeckShare.export(deckId: deckId, includeQuestions: false, db: $0) }
        await #expect(throws: DeckShare.ShareError.courseMissing) {
            try await db.queue.write { try DeckShare.importDeck(shared, intoCourse: "nope", db: $0) }
        }
    }

    @Test("the printable document is a table of fronts and backs")
    func printable() {
        let shared = SharedDeck(format: SharedDeck.format, version: 1, name: "Week 3", courseName: "Micro",
                                exportedAt: Date(), cards: [.init(front: "A", back: "B", hasMath: false)], questions: [])
        let document = DeckShare.document(for: shared)
        #expect(document.title == "Week 3")
        #expect(document.subtitle == "Micro · 1 card")
        #expect(document.blocks == [.table(rows: [["Front", "Back"], ["A", "B"]], bar: nil)])
    }
}
