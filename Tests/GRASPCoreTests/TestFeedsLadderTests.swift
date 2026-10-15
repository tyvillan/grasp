import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Test answers feed the understanding ladder")
struct TestFeedsLadderTests {
    private struct Fixture {
        var db: GRASPDatabase
        var attempt: String
        var card: String
        var ai: String
    }

    private func make(level: LearnEngine.Level? = nil, run: Int = 0, items: Int = 4) async throws -> Fixture {
        let db = try GRASPDatabase.inMemory()
        return try await db.queue.write { conn -> Fixture in
            let course = Course(semesterId: nil, name: "C"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "D"); try deck.insert(conn)
            let card = Card(materialId: nil, front: "f", back: "b", origin: .manual, status: .active)
            try card.insert(conn)
            try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            if let level {
                try LearnState(cardId: card.id, level: level.rawValue, consecutiveCorrect: run, lastSeenAt: Date()).save(conn)
            }
            let attempt = TestAttempt(deckId: deck.id, configJSON: "{}")
            try attempt.insert(conn)
            for ordinal in 0..<items {
                try TestItem(attemptId: attempt.id, cardId: card.id, ordinal: ordinal, questionType: "written",
                             promptText: "q\(ordinal)").insert(conn)
            }
            // One AI-written question with no card.
            try TestItem(attemptId: attempt.id, cardId: nil, ordinal: 99, questionType: "written", promptText: "ai",
                         isAIGenerated: true).insert(conn)
            return Fixture(db: db, attempt: attempt.id, card: card.id, ai: "ai")
        }
    }

    private func state(_ f: Fixture) async throws -> (level: Int, run: Int)? {
        try await f.db.queue.read { db in
            try LearnState.fetchOne(db, key: f.card).map { ($0.level, $0.consecutiveCorrect) }
        }
    }

    private func answer(_ f: Fixture, _ ordinal: Int, _ correct: Bool) async throws {
        try await f.db.queue.write {
            try Study.submitTestAnswer(attemptId: f.attempt, ordinal: ordinal, given: "x", isCorrect: correct, db: $0)
        }
    }

    @Test("a right answer on a card question climbs the card one level")
    func rightClimbs() async throws {
        let f = try await make(level: .recognition, run: 1)
        try await answer(f, 0, true)
        let s = try await state(f)
        #expect(s?.level == LearnEngine.Level.recall.rawValue)
        #expect(s?.run == 2)
    }

    @Test("a card with no learn row yet starts on the ladder")
    func startsLadder() async throws {
        let f = try await make()
        try await answer(f, 0, true)
        #expect(try await state(f)?.level == LearnEngine.Level.recognition.rawValue)
    }

    @Test("one miss is remembered and two in a row drop one level, the same as Learn")
    func missRules() async throws {
        let f = try await make(level: .recall, run: 3)
        try await answer(f, 0, false)
        var s = try await state(f)
        #expect(s?.level == LearnEngine.Level.recall.rawValue)
        #expect(s?.run == -1)
        try await answer(f, 1, false)
        s = try await state(f)
        #expect(s?.level == LearnEngine.Level.recognition.rawValue)
        #expect(s?.run == 0)
    }

    @Test("a Test miss and a Learn miss add up")
    func sharedWithLearn() async throws {
        let f = try await make(level: .recall, run: 2)
        try await answer(f, 0, false)
        try await f.db.queue.write { try Study.recordLearnAnswer(cardId: f.card, wasCorrect: false, db: $0) }
        #expect(try await state(f)?.level == LearnEngine.Level.recognition.rawValue)
    }

    @Test("answering the same question again does not count twice")
    func notTwice() async throws {
        let f = try await make(level: .recognition, run: 0)
        try await answer(f, 0, true)
        try await answer(f, 0, true)
        #expect(try await state(f)?.level == LearnEngine.Level.recall.rawValue)
    }

    @Test("an AI-written question with no card changes nothing")
    func aiQuestion() async throws {
        let f = try await make()
        try await f.db.queue.write {
            try Study.submitTestAnswer(attemptId: f.attempt, ordinal: 99, given: "x", isCorrect: true, db: $0)
        }
        #expect(try await state(f) == nil)
    }

    @Test("'I was right' counts as a right answer on the ladder")
    func override() async throws {
        let f = try await make(level: .recognition, run: 0)
        try await answer(f, 0, false)
        #expect(try await state(f)?.run == -1)
        try await f.db.queue.write {
            try Study.overrideTestItemCorrect(attemptId: f.attempt, ordinal: 0, cardId: f.card, db: $0)
        }
        let s = try await state(f)
        #expect(s?.level == LearnEngine.Level.recall.rawValue)
        #expect(s?.run == 1)
    }

    @Test("the review schedule is not touched by answering, only by finishing, as before")
    func scheduleUntouched() async throws {
        let f = try await make(level: .recognition, run: 0)
        try await answer(f, 0, true)
        let reviews = try await f.db.queue.read { try Review.fetchCount($0) }
        #expect(reviews == 0)
        try await f.db.queue.write { try Study.finishTest(attemptId: f.attempt, db: $0) }
        let after = try await f.db.queue.read { try Review.fetchCount($0) }
        #expect(after == 1)
    }

    @Test("a self-rated card is proven by a right answer in a Test")
    func familiarInTest() async throws {
        let f = try await make(level: .familiar)
        try await answer(f, 0, true)
        #expect(try await state(f)?.level == LearnEngine.Level.mastered.rawValue)
    }
}
