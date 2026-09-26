import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Study modes")
struct StudyModesTests {
    /// One deck of eight active cards and one draft.
    private func makeDeck() async throws -> (GRASPDatabase, deckId: String, cards: [String]) {
        let db = try GRASPDatabase.inMemory()
        let ids = try await db.queue.write { conn -> (String, [String]) in
            let course = Course(semesterId: nil, name: "Biology")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Cells")
            try deck.insert(conn)
            var cardIds: [String] = []
            let pairs = [("Mitochondria", "Makes ATP"), ("Ribosome", "Builds proteins"), ("Nucleus", "Holds DNA"),
                         ("Golgi", "Packages proteins"), ("Lysosome", "Digests waste"), ("Vacuole", "Stores water"),
                         ("Chloroplast", "Photosynthesis"), ("Membrane", "Controls entry"), ("Draft", "Not approved")]
            for (index, (front, back)) in pairs.enumerated() {
                let card = Card(materialId: nil, front: front, back: back, origin: .manual,
                                status: front == "Draft" ? .draft : .active)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: index).insert(conn)
                cardIds.append(card.id)
            }
            return (deck.id, cardIds)
        }
        return (db, ids.0, ids.1)
    }

    @Test("I Know This masters a card and schedules it; Needs Review resets it")
    func mark() async throws {
        let (db, deckId, cards) = try await makeDeck()
        try await db.queue.write { db in
            try Study.mark(cards[0], understood: true, db: db)
            try Study.mark(cards[1], understood: false, db: db)
        }
        let levels = try await db.queue.read { try Study.learnLevels(forDecks: [deckId], db: $0) }
        #expect(levels[cards[0]] == .mastered)
        #expect(levels[cards[1]] == .new)
        let mastery = try await db.queue.read { try Study.mastery(forDecks: [deckId], db: $0) }
        #expect(mastery.mastered == 1)
        #expect(mastery.total == 8)
        let logs = try await db.queue.read { try Review.fetchCount($0) }
        #expect(logs == 2)
    }

    @Test("a Learn round asks only active cards, and a right answer climbs the ladder")
    func learnRound() async throws {
        let (db, deckId, cards) = try await makeDeck()
        let round = try await db.queue.read { var rng2 = SystemRandomNumberGenerator(); return try Study.learnRound(forDecks: [deckId], using: &rng2, db: $0) }
        #expect(!round.isEmpty)
        #expect(round.count <= LearnEngine.roundSize)
        #expect(!round.contains { $0.cardId == cards[8] })

        try await db.queue.write { try Study.recordLearnAnswer(cardId: cards[2], wasCorrect: true, db: $0) }
        let level = try await db.queue.read { try Study.learnLevels(forDecks: [deckId], db: $0)[cards[2]] }
        #expect(level != .new)
    }

    @Test("a test writes one item per question, scores on finish, and re-schedules misses")
    func testFlow() async throws {
        let (db, deckId, _) = try await makeDeck()
        let config = TestBuilder.Config(questionCount: 5, allowMultipleChoice: true, allowWritten: true,
                                        allowTrueFalse: true, shuffle: true, timeLimitSeconds: nil, excludeMastered: false)
        let (attemptId, questions) = try await db.queue.write { var rng2 = SystemRandomNumberGenerator()
            return try Study.startTest(deckIds: [deckId], config: config, using: &rng2, db: $0)
        }
        #expect(questions.count == 5)
        #expect(try await db.queue.read { try TestItem.filter(Column("attemptId") == attemptId).fetchCount($0) } == 5)

        try await db.queue.write { db in
            for index in questions.indices {
                try Study.submitTestAnswer(attemptId: attemptId, ordinal: index, given: "x", isCorrect: index < 3, db: db)
            }
        }
        let score = try await db.queue.write { try Study.finishTest(attemptId: attemptId, db: $0) }
        #expect(score.correct == 3)
        #expect(score.total == 5)
        let misses = try await db.queue.read { try Review.filter(Column("source") == "test").fetchCount($0) }
        #expect(misses == questions.suffix(2).filter { $0.cardId != nil }.count)

        try await db.queue.write {
            try Study.overrideTestItemCorrect(attemptId: attemptId, ordinal: 4, cardId: questions[4].cardId, db: $0)
        }
        let attempt = try #require(try await db.queue.read { try TestAttempt.fetchOne($0, key: attemptId) })
        #expect(attempt.scoreNumerator == 4)
    }

    @Test("a test with every card excluded writes nothing")
    func emptyTest() async throws {
        let (db, deckId, cards) = try await makeDeck()
        try await db.queue.write { db in
            for card in cards.prefix(8) { try Study.mark(card, understood: true, db: db) }
        }
        let config = TestBuilder.Config(questionCount: 5, allowMultipleChoice: true, allowWritten: true,
                                        allowTrueFalse: true, shuffle: false, timeLimitSeconds: nil, excludeMastered: true)
        let result = try await db.queue.write { var rng2 = SystemRandomNumberGenerator(); return try Study.startTest(deckIds: [deckId], config: config, using: &rng2, db: $0) }
        #expect(result.attemptId.isEmpty)
        #expect(try await db.queue.read { try TestAttempt.fetchCount($0) } == 0)
    }
}
