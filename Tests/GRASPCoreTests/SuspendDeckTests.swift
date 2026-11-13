import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Suspend a deck")
struct SuspendDeckTests {
    private struct Fixture {
        var db: GRASPDatabase
        var deck: String
        var other: String
        var cards: [String: String]   // name to id
    }

    private func make() async throws -> Fixture {
        let db = try GRASPDatabase.inMemory()
        return try await db.queue.write { conn -> Fixture in
            let course = Course(semesterId: nil, name: "C"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "D"); try deck.insert(conn)
            let other = Deck(courseId: course.id, name: "Other"); try other.insert(conn)
            var ids: [String: String] = [:]
            func add(_ name: String, _ status: CardStatus, in deck: Deck, deleted: Bool = false) throws {
                var card = Card(materialId: nil, front: name, back: "b", origin: .manual, status: status,
                                due: Date(timeIntervalSince1970: 1_000))
                if deleted { card.deletedAt = Date() }
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
                ids[name] = card.id
            }
            try add("a1", .active, in: deck)
            try add("a2", .active, in: deck)
            try add("draft", .draft, in: deck)
            try add("held", .suspended, in: deck)
            try add("gone", .active, in: deck, deleted: true)
            try add("elsewhere", .active, in: other)
            try LearnState(cardId: ids["a1"]!, level: 3, consecutiveCorrect: 4, lastSeenAt: Date()).save(conn)
            return Fixture(db: db, deck: deck.id, other: other.id, cards: ids)
        }
    }

    private func status(_ f: Fixture, _ name: String) async throws -> String {
        try await f.db.queue.read { try String.fetchOne($0, sql: "SELECT status FROM card WHERE id = ?", arguments: [f.cards[name]!]) ?? "" }
    }

    @Test("every active card goes back to a draft, and the count says how many")
    func suspends() async throws {
        let f = try await make()
        let moved = try await f.db.queue.write { try CardActions.suspendDeck([f.deck], db: $0) }
        #expect(moved == 2)
        #expect(try await status(f, "a1") == "draft")
        #expect(try await status(f, "a2") == "draft")
    }

    @Test("drafts, suspended, deleted and other decks' cards are left alone")
    func leavesTheRest() async throws {
        let f = try await make()
        try await f.db.queue.write { try CardActions.suspendDeck([f.deck], db: $0) }
        #expect(try await status(f, "draft") == "draft")
        #expect(try await status(f, "held") == "suspended")
        #expect(try await status(f, "elsewhere") == "active")
        let goneStatus = try await status(f, "gone")
        #expect(goneStatus == "active")
    }

    @Test("progress and due dates are kept, and approving brings the cards straight back")
    func reversible() async throws {
        let f = try await make()
        try await f.db.queue.write { try CardActions.suspendDeck([f.deck], db: $0) }
        let kept = try await f.db.queue.read { db -> (Int, Date) in
            let level = try LearnState.fetchOne(db, key: f.cards["a1"]!)?.level ?? -1
            let due = try Card.fetchOne(db, key: f.cards["a1"]!)!.due
            return (level, due)
        }
        #expect(kept.0 == 3)
        #expect(kept.1 == Date(timeIntervalSince1970: 1_000))
        // Reactivating the deck brings the cards straight back.
        try await f.db.queue.write { try CardActions.reactivateDeck([f.deck], db: $0) }
        #expect(try await status(f, "a1") == "active")
        #expect(try await status(f, "a2") == "active")
    }

    @Test("reactivating treats drafts and suspended cards the same, and leaves deleted ones deleted")
    func reactivateBoth() async throws {
        let f = try await make()
        try await f.db.queue.write { try CardActions.suspendDeck([f.deck], db: $0) }
        let moved = try await f.db.queue.write { try CardActions.reactivateDeck([f.deck], db: $0) }
        // a1, a2 (suspended just now), the original draft and the held card.
        #expect(moved == 4)
        #expect(try await status(f, "draft") == "active")
        #expect(try await status(f, "held") == "active")
        #expect(try await status(f, "elsewhere") == "active")
        let gone = try await f.db.queue.read { try Card.fetchOne($0, key: f.cards["gone"]!)?.deletedAt }
        #expect(gone != nil)
        let none = try await f.db.queue.write { try CardActions.reactivateDeck([], db: $0) }
        #expect(none == 0)
    }

    @Test("a suspended deck gives Study, Learn and Tests nothing to ask")
    func nothingToStudy() async throws {
        let f = try await make()
        try await f.db.queue.write { try CardActions.suspendDeck([f.deck], db: $0) }
        let due = try await f.db.queue.read { try Study.dueCards(inDecks: [f.deck], db: $0) }
        let candidates = try await f.db.queue.read { try Study.learnCandidates(forDecks: [f.deck], db: $0) }
        #expect(due.isEmpty)
        #expect(candidates.isEmpty)
    }

    @Test("an empty selection or a deck with no active cards moves nothing")
    func noop() async throws {
        let f = try await make()
        let none = try await f.db.queue.write { try CardActions.suspendDeck([], db: $0) }
        #expect(none == 0)
        try await f.db.queue.write { try CardActions.suspendDeck([f.deck], db: $0) }
        let again = try await f.db.queue.write { try CardActions.suspendDeck([f.deck], db: $0) }
        #expect(again == 0)
    }
}
