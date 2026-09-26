import Foundation
import GRDB

// Flashcard verdicts, Learn rounds and Tests: the Mac `AppStore`'s study
// modes, moved here so the Windows app studies exactly the same way. Each
// takes the connection its caller opened, like the rest of `Study`.
extension Study {
    // MARK: - Flashcards

    /// The Study screen's two-verdict grading: "Needs Review" or "I Know
    /// This" stands in for FSRS's four grades. It schedules the card
    /// (again / good) and also moves its Learn level, so Flashcards, Learn
    /// and Test share one idea of what's understood.
    public static func mark(_ cardId: String, understood: Bool, source: String = "flashcards",
                            now: Date = Date(), db: Database) throws {
        try grade(cardId, grade: understood ? .good : .again, source: source, now: now, db: db)
        try LearnState(
            cardId: cardId,
            level: understood ? LearnEngine.Level.mastered.rawValue : LearnEngine.Level.new.rawValue,
            consecutiveCorrect: understood ? 1 : 0, lastSeenAt: now
        ).save(db)
    }

    // MARK: - Learn

    /// Every active card in these decks as a Learn candidate, with when it
    /// was last seen.
    public static func learnCandidates(
        forDecks deckIds: [String], db: Database
    ) throws -> [(candidate: LearnEngine.Candidate, lastSeenAt: Date?)] {
        let cardIds = try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db).map(\.cardId)
        guard !cardIds.isEmpty else { return [] }
        let cards = try Card
            .filter(cardIds.contains(Column("id")))
            .filter(Column("deletedAt") == nil)
            .filter(Column("status") == CardStatus.active.rawValue)
            .fetchAll(db)
        let states = try LearnState.filter(cardIds.contains(Column("cardId"))).fetchAll(db)
        let stateByCard = Dictionary(uniqueKeysWithValues: states.map { ($0.cardId, $0) })

        return cards.map { card in
            let state = stateByCard[card.id]
            let level = LearnEngine.Level(rawValue: state?.level ?? 0) ?? .new
            let candidate = LearnEngine.Candidate(cardId: card.id, front: card.front, back: card.back, level: level)
            return (candidate, state?.lastSeenAt)
        }
    }

    /// One Learn round: cards not yet mastered, least-recently-seen first,
    /// each asked at its ladder level -- and once most of the deck is
    /// mastered, a random reinforcement sample (see `LearnEngine.buildRound`).
    public static func learnRound<R: RandomNumberGenerator>(
        forDecks deckIds: [String], using rng: inout R, db: Database
    ) throws -> [LearnEngine.RoundQuestion] {
        let candidates = try learnCandidates(forDecks: deckIds, db: db)
            .sorted { a, b in a.lastSeenAt ?? .distantPast < b.lastSeenAt ?? .distantPast }
            .map(\.candidate)
        return LearnEngine.buildRound(from: candidates, using: &rng)
    }

    /// One Learn answer: advances the card's ladder level and streak,
    /// independent of FSRS scheduling.
    public static func recordLearnAnswer(cardId: String, wasCorrect: Bool, now: Date = Date(), db: Database) throws {
        let existing = try LearnState.fetchOne(db, key: cardId)
        let currentLevel = LearnEngine.Level(rawValue: existing?.level ?? 0) ?? .new
        let (nextLevel, streak) = LearnEngine.advance(
            level: currentLevel, consecutiveCorrect: existing?.consecutiveCorrect ?? 0, wasCorrect: wasCorrect
        )
        try LearnState(cardId: cardId, level: nextLevel.rawValue, consecutiveCorrect: streak, lastSeenAt: now)
            .save(db)
    }

    /// How much of these decks has been proven understood.
    public static func mastery(forDecks deckIds: [String], db: Database) throws -> (mastered: Int, total: Int) {
        let candidates = try learnCandidates(forDecks: deckIds, db: db).map(\.candidate)
        return (candidates.filter { $0.level == .mastered }.count, candidates.count)
    }

    /// Each card's Learn level; a card with no row yet is `.new`.
    public static func learnLevels(forDecks deckIds: [String], db: Database) throws -> [String: LearnEngine.Level] {
        let candidates = try learnCandidates(forDecks: deckIds, db: db)
        return Dictionary(uniqueKeysWithValues: candidates.map { ($0.candidate.cardId, $0.candidate.level) })
    }

    // MARK: - Tests

    /// A test still reads as "mostly the deck's own cards" even with AI
    /// questions on -- roughly a third of the requested count, capped.
    public static func aiQuestionBudget(for questionCount: Int) -> Int { max(0, min(questionCount / 3, 10)) }

    /// Builds a test from the decks' active cards plus any AI questions the
    /// caller already has, and writes the attempt and one item per question
    /// up front (answers are filled in as they're given). Returns an empty
    /// attempt id and no questions when every card was filtered out.
    public static func startTest<R: RandomNumberGenerator>(
        deckIds: [String], config: TestBuilder.Config, aiQuestions: [LearnEngine.RoundQuestion] = [],
        using rng: inout R, db: Database
    ) throws -> (attemptId: String, questions: [LearnEngine.RoundQuestion]) {
        var cards = try learnCandidates(forDecks: deckIds, db: db).map(\.candidate)
        if config.excludeMastered {
            cards = cards.filter { $0.level != .mastered }
        }
        let pool = cards.map { (cardId: $0.cardId, front: $0.front, back: $0.back) }
        var cardConfig = config
        cardConfig.questionCount = max(0, config.questionCount - aiQuestions.count)
        var questions = TestBuilder.build(from: pool, config: cardConfig, using: &rng) + aiQuestions
        if config.shuffle { questions.shuffle(using: &rng) }
        guard !questions.isEmpty else { return ("", []) }

        let attempt = TestAttempt(deckId: deckIds.count == 1 ? deckIds.first : nil, configJSON: "{}", startedAt: Date())
        try attempt.insert(db)
        for (index, question) in questions.enumerated() {
            try TestItem(
                id: question.id + "-" + attempt.id, attemptId: attempt.id, cardId: question.cardId,
                ordinal: index, questionType: question.type.rawValue, promptText: question.prompt,
                choicesJSON: question.choices.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) },
                correctAnswer: question.correctAnswer, isAIGenerated: question.cardId == nil
            ).insert(db)
        }
        return (attempt.id, questions)
    }

    public static func submitTestAnswer(attemptId: String, ordinal: Int, given: String, isCorrect: Bool,
                                        db: Database) throws {
        guard var item = try TestItem
            .filter(Column("attemptId") == attemptId)
            .filter(Column("ordinal") == ordinal)
            .fetchOne(db)
        else { return }
        item.givenAnswer = given
        item.isCorrect = isCorrect
        try item.save(db)
    }

    /// Scores the attempt, then schedules every missed card for review
    /// again -- a missed test question is as clear a lapse as an "Again".
    @discardableResult
    public static func finishTest(attemptId: String, now: Date = Date(), db: Database) throws -> (correct: Int, total: Int) {
        let items = try TestItem.filter(Column("attemptId") == attemptId).fetchAll(db)
        let correct = items.filter { $0.isCorrect == true }.count
        if var attempt = try TestAttempt.fetchOne(db, key: attemptId) {
            attempt.finishedAt = now
            attempt.scoreNumerator = correct
            attempt.scoreDenominator = items.count
            try attempt.save(db)
        }
        for cardId in items.filter({ $0.isCorrect == false }).compactMap(\.cardId) {
            try grade(cardId, grade: .again, source: "test", now: now, db: db)
        }
        return (correct, items.count)
    }

    /// "I was right": marks a graded-wrong answer correct. On a finished
    /// attempt that also bumps the score and re-grades the card Good, since
    /// finishing already scheduled it as a miss.
    public static func overrideTestItemCorrect(attemptId: String, ordinal: Int, cardId: String?,
                                               now: Date = Date(), db: Database) throws {
        guard var item = try TestItem
            .filter(Column("attemptId") == attemptId)
            .filter(Column("ordinal") == ordinal)
            .fetchOne(db),
            item.isCorrect != true
        else { return }
        item.isCorrect = true
        try item.save(db)
        guard var attempt = try TestAttempt.fetchOne(db, key: attemptId), attempt.finishedAt != nil else { return }
        attempt.scoreNumerator = min((attempt.scoreNumerator ?? 0) + 1, attempt.scoreDenominator ?? .max)
        try attempt.save(db)
        if let cardId {
            try grade(cardId, grade: .good, source: "test-override", now: now, db: db)
        }
    }
}
