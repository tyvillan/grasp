import Testing
@testable import GRASPCore

@Suite("LearnEngine")
struct LearnEngineTests {
    private static func candidates(count: Int, level: LearnEngine.Level = .new, idPrefix: String = "card") -> [LearnEngine.Candidate] {
        (0..<count).map {
            LearnEngine.Candidate(cardId: "\(idPrefix)-\($0)", front: "Term \($0)", back: "Definition number \($0)", level: level)
        }
    }

    @Test("a round holds at most 7 questions")
    func roundIsCappedAtSeven() {
        var rng = SystemRandomNumberGenerator()
        let round = LearnEngine.buildRound(from: Self.candidates(count: 20), using: &rng)
        #expect(round.count == 7)
    }

    @Test("mastered cards never appear in a round")
    func masteredCardsAreExcluded() {
        var rng = SystemRandomNumberGenerator()
        let mixed = Self.candidates(count: 3, level: .mastered, idPrefix: "mastered")
            + Self.candidates(count: 3, level: .new, idPrefix: "new")
        let round = LearnEngine.buildRound(from: mixed, using: &rng)
        let masteredIds = Set(mixed.filter { $0.level == .mastered }.map(\.cardId))
        #expect(round.allSatisfy { $0.cardId != nil && !masteredIds.contains($0.cardId!) })
    }

    @Test("a new card gets a multiple-choice question with the correct answer among the choices")
    func newCardIsMultipleChoice() {
        var rng = SystemRandomNumberGenerator()
        let round = LearnEngine.buildRound(from: Self.candidates(count: 5, level: .new), using: &rng)
        let question = try! #require(round.first)
        #expect(question.type == .multipleChoice)
        let choices = try! #require(question.choices)
        #expect(choices.contains(question.correctAnswer))
        #expect(Set(choices).count == choices.count) // no duplicate distractors
    }

    @Test("a recall-level card gets a written question")
    func recallCardIsWritten() {
        var rng = SystemRandomNumberGenerator()
        let round = LearnEngine.buildRound(from: Self.candidates(count: 3, level: .recall), using: &rng)
        #expect(round.allSatisfy { $0.type == .written })
    }

    @Test("a correct answer promotes one level, capped at mastered")
    func correctAnswerPromotes() {
        #expect(LearnEngine.advance(level: .new, consecutiveCorrect: 0, wasCorrect: true).level == .recognition)
        #expect(LearnEngine.advance(level: .recall, consecutiveCorrect: 2, wasCorrect: true).level == .mastered)
        #expect(LearnEngine.advance(level: .mastered, consecutiveCorrect: 5, wasCorrect: true).level == .mastered)
    }

    @Test("one miss does not drop the card; it is remembered")
    func firstMissIsRemembered() {
        let result = LearnEngine.advance(level: .recall, consecutiveCorrect: 3, wasCorrect: false)
        #expect(result.level == .recall)
        #expect(result.consecutiveCorrect == -1)
        #expect(LearnEngine.advance(level: .new, consecutiveCorrect: 0, wasCorrect: false).level == .new)
    }

    @Test("two misses in a row drop one level, never below new, and start the run over")
    func secondMissDrops() {
        let first = LearnEngine.advance(level: .recall, consecutiveCorrect: 3, wasCorrect: false)
        let second = LearnEngine.advance(level: .recall, consecutiveCorrect: first.consecutiveCorrect, wasCorrect: false)
        #expect(second.level == .recognition)
        #expect(second.consecutiveCorrect == 0)
        // A third miss is a fresh first miss.
        let third = LearnEngine.advance(level: .recognition, consecutiveCorrect: second.consecutiveCorrect, wasCorrect: false)
        #expect(third.level == .recognition)
        #expect(third.consecutiveCorrect == -1)
        // Never below new.
        let floor = LearnEngine.advance(level: .new, consecutiveCorrect: -1, wasCorrect: false)
        #expect(floor.level == .new)
    }

    @Test("a right answer between two misses clears the first")
    func rightClearsMiss() {
        let miss = LearnEngine.advance(level: .recall, consecutiveCorrect: 2, wasCorrect: false)
        let right = LearnEngine.advance(level: .recall, consecutiveCorrect: miss.consecutiveCorrect, wasCorrect: true)
        #expect(right.level == .mastered)
        #expect(right.consecutiveCorrect == 1)
        let missAgain = LearnEngine.advance(level: .mastered, consecutiveCorrect: right.consecutiveCorrect, wasCorrect: false)
        #expect(missAgain.level == .mastered)
        #expect(missAgain.consecutiveCorrect == -1)
    }

    @Test("an older client's streak of 0 or more reads as no earlier miss")
    func oldRowsAreFresh() {
        for run in [0, 1, 7] {
            let result = LearnEngine.advance(level: .mastered, consecutiveCorrect: run, wasCorrect: false)
            #expect(result.level == .mastered)
            #expect(result.consecutiveCorrect == -1)
        }
    }

    @Test("with most of the deck still unmastered, a round only draws from the unmastered cards")
    func targetsUnmasteredWhileMostRemain() {
        var rng = SystemRandomNumberGenerator()
        // 7 unmastered, 3 mastered -- 70% unmastered, well above the 20% threshold.
        let mixed = Self.candidates(count: 7, level: .new, idPrefix: "new")
            + Self.candidates(count: 3, level: .mastered, idPrefix: "mastered")
        let round = LearnEngine.buildRound(from: mixed, using: &rng)
        #expect(round.allSatisfy { $0.cardId?.hasPrefix("new-") == true })
    }

    @Test("once most of the deck is mastered, a round draws at random from the whole deck")
    func reinforcesRandomlyOnceMostlyMastered() {
        var rng = SystemRandomNumberGenerator()
        // 1 unmastered, 9 mastered -- 10% unmastered, at/below the 20% threshold.
        let mixed = Self.candidates(count: 1, level: .new, idPrefix: "new")
            + Self.candidates(count: 9, level: .mastered, idPrefix: "mastered")
        let round = LearnEngine.buildRound(from: mixed, using: &rng)
        // The round should be able to include mastered cards now, not
        // just the single straggler.
        #expect(round.contains { $0.cardId?.hasPrefix("mastered-") == true })
    }

    @Test("a fully mastered deck still gets quizzed, not left empty")
    func fullyMasteredDeckStillProducesARound() {
        var rng = SystemRandomNumberGenerator()
        let allMastered = Self.candidates(count: 10, level: .mastered)
        let round = LearnEngine.buildRound(from: allMastered, using: &rng)
        #expect(round.count == 7)
    }

    @Test("every question in a Learn round has a real backing card")
    func everyQuestionHasACardId() {
        var rng = SystemRandomNumberGenerator()
        let round = LearnEngine.buildRound(from: Self.candidates(count: 10), using: &rng)
        #expect(round.allSatisfy { $0.cardId != nil })
    }

    @Test("distractors never include the card's own answer")
    func distractorsExcludeSelf() {
        var rng = SystemRandomNumberGenerator()
        let pool = Self.candidates(count: 10)
        let target = pool[0]
        let picked = LearnEngine.distractors(for: target, in: pool, count: 3, using: &rng)
        #expect(!picked.contains(target.back))
    }

    @Test("a question-style card at the true/false slot stays multiple choice; a term there can still be true/false")
    func learnRoundSkipsTrueFalseForQuestions() {
        // Recognition-level cards: every third question is the true/false filler.
        let questionCards = (0..<7).map {
            LearnEngine.Candidate(cardId: "q-\($0)", front: "What is term \($0)?", back: "Definition \($0)", level: .recognition)
        }
        let termCards = (0..<7).map {
            LearnEngine.Candidate(cardId: "t-\($0)", front: "Term \($0)", back: "Definition \($0)", level: .recognition)
        }
        for _ in 0..<40 {
            var rng = SystemRandomNumberGenerator()
            #expect(LearnEngine.buildRound(from: questionCards, using: &rng).allSatisfy { $0.type != .trueFalse })
        }
        var sawTrueFalse = false
        for _ in 0..<40 {
            var rng = SystemRandomNumberGenerator()
            if LearnEngine.buildRound(from: termCards, using: &rng).contains(where: { $0.type == .trueFalse }) {
                sawTrueFalse = true
            }
        }
        #expect(sawTrueFalse)
    }
}

@Suite("Two misses in a row, stored")
struct TwoMissStoredTests {
    @Test("Learn answers drop a card only on the second miss in a row, and it persists between answers")
    func persists() async throws {
        let db = try GRASPDatabase.inMemory()
        let cardId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "C"); try course.insert(conn)
            let card = Card(materialId: nil, front: "f", back: "b", origin: .manual, status: .active)
            try card.insert(conn)
            try LearnState(cardId: card.id, level: LearnEngine.Level.recall.rawValue, consecutiveCorrect: 2).save(conn)
            return card.id
        }
        func state() async throws -> LearnState {
            try await db.queue.read { try #require(try LearnState.fetchOne($0, key: cardId)) }
        }
        try await db.queue.write { try Study.recordLearnAnswer(cardId: cardId, wasCorrect: false, db: $0) }
        var s = try await state()
        #expect(s.level == LearnEngine.Level.recall.rawValue)
        #expect(s.consecutiveCorrect == -1)
        try await db.queue.write { try Study.recordLearnAnswer(cardId: cardId, wasCorrect: false, db: $0) }
        s = try await state()
        #expect(s.level == LearnEngine.Level.recognition.rawValue)
        #expect(s.consecutiveCorrect == 0)
        // A miss, a right answer, a miss: nothing drops.
        try await db.queue.write { try Study.recordLearnAnswer(cardId: cardId, wasCorrect: false, db: $0) }
        try await db.queue.write { try Study.recordLearnAnswer(cardId: cardId, wasCorrect: true, db: $0) }
        try await db.queue.write { try Study.recordLearnAnswer(cardId: cardId, wasCorrect: false, db: $0) }
        s = try await state()
        #expect(s.level == LearnEngine.Level.recall.rawValue)
        #expect(s.consecutiveCorrect == -1)
    }
}
