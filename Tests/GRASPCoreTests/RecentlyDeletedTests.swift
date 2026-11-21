import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Recently deleted")
struct RecentlyDeletedTests {
    private func setup() async throws -> (GRASPDatabase, courseId: String) {
        let db = try GRASPDatabase.inMemory()
        let courseId: String = try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Micro")
            try course.insert(conn)
            return course.id
        }
        return (db, courseId)
    }

    private func deck(_ db: GRASPDatabase, _ courseId: String, _ name: String) async throws -> String {
        try await db.queue.write { conn in
            let deck = Deck(courseId: courseId, name: name)
            try deck.insert(conn)
            return deck.id
        }
    }

    private func card(_ db: GRASPDatabase, _ deckId: String, _ front: String) async throws -> String {
        try await db.queue.write { conn in
            let card = Card(materialId: nil, front: front, back: "A", origin: .manual, status: .active)
            try card.insert(conn)
            try DeckCard(deckId: deckId, cardId: card.id).insert(conn)
            return card.id
        }
    }

    @Test("a deleted card is listed with its deck and comes back with its place and history")
    func cardRoundTrip() async throws {
        let (db, courseId) = try await setup()
        let deckId = try await deck(db, courseId, "Week 1")
        let keep = try await card(db, deckId, "Keep")
        let gone = try await card(db, deckId, "Gone")
        try await db.queue.write { try CardActions.delete([gone], db: $0) }

        let listed = try await db.queue.read { try CardActions.recentlyDeleted(db: $0) }
        #expect(listed.map(\.card.id) == [gone])
        #expect(listed.first?.deckName == "Week 1")

        let restored = try await db.queue.write { try CardActions.restore([gone, keep], db: $0) }
        #expect(restored == 1)
        let live = try await db.queue.read { try Card.filter(Column("deletedAt") == nil).fetchCount($0) }
        #expect(live == 2)
        let inDeck = try await db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM deckCard WHERE deckId = ?", arguments: [deckId])
        }
        #expect(inDeck == 2)
    }

    @Test("a deleted deck comes back with the cards that went with it")
    func deckRoundTrip() async throws {
        let (db, courseId) = try await setup()
        let deckId = try await deck(db, courseId, "Week 2")
        let a = try await card(db, deckId, "A")
        let b = try await card(db, deckId, "B")
        try await db.queue.write { try LibraryActions.deleteDeck(deckId, migrateCardsTo: nil, db: $0) }

        let decks = try await db.queue.read { try LibraryActions.recentlyDeletedDecks(db: $0) }
        #expect(decks.map(\.id) == [deckId])
        #expect(decks.first?.cardCount == 2)

        let count = try await db.queue.write { try LibraryActions.restoreDeck(deckId, db: $0) }
        #expect(count == 2)
        try await db.queue.read { conn in
            #expect(try Deck.fetchOne(conn, key: deckId)?.deletedAt == nil)
            #expect(try Card.fetchOne(conn, key: a)?.deletedAt == nil)
            #expect(try Card.fetchOne(conn, key: b)?.deletedAt == nil)
            let members = try String.fetchAll(conn, sql: "SELECT cardId FROM deckCard WHERE deckId = ?", arguments: [deckId])
            #expect(Set(members) == Set([a, b]))
        }
    }

    @Test("a deck deleted by moving its cards comes back empty; the cards stay where they went")
    func migratedDeck() async throws {
        let (db, courseId) = try await setup()
        let source = try await deck(db, courseId, "Old")
        let target = try await deck(db, courseId, "New")
        let moved = try await card(db, source, "Moved")
        try await db.queue.write { try LibraryActions.deleteDeck(source, migrateCardsTo: target, db: $0) }
        let count = try await db.queue.write { try LibraryActions.restoreDeck(source, db: $0) }
        #expect(count == 0)
        try await db.queue.read { conn in
            let inSource = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM deckCard WHERE deckId = ?", arguments: [source])
            let inTarget = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM deckCard WHERE deckId = ? AND cardId = ?", arguments: [target, moved])
            #expect(inSource == 0)
            #expect(inTarget == 1)
        }
    }
}
