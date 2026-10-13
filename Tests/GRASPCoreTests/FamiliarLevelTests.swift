import Foundation
import Testing
import GRDB
@testable import GRASPCore

/// "I Know This" in Study is a self-rating: it makes a card `familiar`
/// (level 4), which Learn asks once. Only a right answer there masters it.
@Suite("Familiar level")
struct FamiliarLevelTests {
    private func makeDeck(cards count: Int = 6) throws -> (db: GRASPDatabase, deckId: String, cardIds: [String]) {
        let db = try GRASPDatabase.inMemory()
        return try db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Course")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Deck")
            try deck.insert(conn)
            var ids: [String] = []
            for index in 0..<count {
                let card = Card(materialId: nil, front: "Term \(index)", back: "Definition \(index) of the term",
                                origin: .manual, status: .active)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: index).insert(conn)
                ids.append(card.id)
            }
            return (db, deck.id, ids)
        }
    }

    @Test("a right answer on a familiar card makes it mastered; a miss sends it to recognition")
    func advanceFromFamiliar() {
        let right = LearnEngine.advance(level: .familiar, consecutiveCorrect: 0, wasCorrect: true)
        #expect(right.level == .mastered)
        #expect(right.consecutiveCorrect == 1)
        let miss = LearnEngine.advance(level: .familiar, consecutiveCorrect: 0, wasCorrect: false)
        #expect(miss.level == .recognition)
        #expect(miss.consecutiveCorrect == 0)
    }

    @Test("Learn asks a familiar card once, as a typed answer, and a deck of only familiar cards is still a round")
    func learnAsksFamiliar() {
        let candidates = (0..<5).map {
            LearnEngine.Candidate(cardId: "c\($0)", front: "Term \($0)", back: "Definition \($0)", level: .familiar)
        }
        var rng = SystemRandomNumberGenerator()
        let round = LearnEngine.buildRound(from: candidates, using: &rng)
        #expect(round.count == 5)
        #expect(round.allSatisfy { $0.type == .written })
    }

    @Test("Study's I Know This writes familiar and the understood count does not move")
    func studyMarkIsFamiliar() async throws {
        let (db, deckId, cards) = try makeDeck()
        try await db.queue.write { try Study.mark(cards[0], understood: true, db: $0) }
        let row = try await db.queue.read { try LearnState.fetchOne($0, key: cards[0]) }
        #expect(row?.level == 4)
        let mastery = try await db.queue.read { try Study.mastery(forDecks: [deckId], db: $0) }
        #expect(mastery.mastered == 0)
        #expect(mastery.total == 6)
    }

    @Test("answering a familiar card right in Learn masters it")
    func learnMastersFamiliar() async throws {
        let (db, deckId, cards) = try makeDeck()
        try await db.queue.write { try Study.mark(cards[0], understood: true, db: $0) }
        try await db.queue.write { try Study.recordLearnAnswer(cardId: cards[0], wasCorrect: true, db: $0) }
        let levels = try await db.queue.read { try Study.learnLevels(forDecks: [deckId], db: $0) }
        #expect(levels[cards[0]] == .mastered)
    }

    @Test("a level this build doesn't know reads as new, so an older client just tests the card")
    func unknownLevelReadsAsNew() async throws {
        #expect(LearnEngine.Level(rawValue: 5) == nil)
        let (db, deckId, cards) = try makeDeck()
        try await db.queue.write { try LearnState(cardId: cards[0], level: 99).save($0) }
        let levels = try await db.queue.read { try Study.learnLevels(forDecks: [deckId], db: $0) }
        #expect(levels[cards[0]] == .new)
    }

    @Test("cards already mastered stay mastered, row for row, after other cards are rated")
    func existingMasteredUnchanged() async throws {
        let (db, deckId, cards) = try makeDeck()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.queue.write { conn in
            try LearnState(cardId: cards[0], level: 3, consecutiveCorrect: 5, lastSeenAt: stamp).save(conn)
            try LearnState(cardId: cards[1], level: 3, consecutiveCorrect: 1, lastSeenAt: stamp).save(conn)
        }
        try await db.queue.write { conn in
            try Study.mark(cards[2], understood: true, db: conn)
            try Study.mark(cards[3], understood: false, db: conn)
            // Rating a card Learn already proved does not demote it.
            try Study.mark(cards[1], understood: true, db: conn)
        }
        let rows = try await db.queue.read { conn in
            try LearnState.filter([cards[0], cards[1]].contains(Column("cardId"))).fetchAll(conn)
        }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.cardId, $0) })
        #expect(byId[cards[0]]?.level == 3)
        #expect(byId[cards[0]]?.consecutiveCorrect == 5)
        #expect(byId[cards[0]]?.lastSeenAt == stamp)
        #expect(byId[cards[1]]?.level == 3)
        #expect(byId[cards[1]]?.consecutiveCorrect == 1)
        let mastery = try await db.queue.read { try Study.mastery(forDecks: [deckId], db: $0) }
        #expect(mastery.mastered == 2)
    }

    @Test("a familiar level survives a sync round trip unchanged, and so does a mastered one")
    func syncRoundTrip() async throws {
        let server = SyncEngineTests.MemoryServer()
        let mac = try GRASPDatabase.inMemory()
        let macEngine = SyncEngine(database: mac)
        let ids: [String] = try await mac.queue.write { conn in
            var ids: [String] = []
            let course = Course(semesterId: nil, name: "Matrix Theory")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Lecture 1")
            try deck.insert(conn)
            for index in 0..<2 {
                let card = Card(materialId: nil, front: "F\(index)", back: "B\(index)", origin: .manual, status: .active)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
                ids.append(card.id)
            }
            try LearnState(cardId: ids[0], level: 4).insert(conn)
            try LearnState(cardId: ids[1], level: 3, consecutiveCorrect: 4).insert(conn)
            return ids
        }
        try macEngine.enable(accountUserId: "user-1", uploadExisting: true)
        try await macEngine.sync(using: server)

        let other = try GRASPDatabase.inMemory()
        let otherEngine = SyncEngine(database: other)
        try otherEngine.enable(accountUserId: "user-1", uploadExisting: false)
        try await otherEngine.sync(using: server)
        let rows = try await other.queue.read { try LearnState.fetchAll($0) }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.cardId, $0) })
        #expect(byId[ids[0]]?.level == 4)
        #expect(byId[ids[1]]?.level == 3)
        #expect(byId[ids[1]]?.consecutiveCorrect == 4)
    }
}
