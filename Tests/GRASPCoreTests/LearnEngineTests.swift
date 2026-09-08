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
        #expect(round.allSatisfy { !masteredIds.contains($0.cardId) })
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

    @Test("a miss demotes one level, never below new, and resets the streak")
    func missDemotesAndResetsStreak() {
        let result = LearnEngine.advance(level: .recall, consecutiveCorrect: 3, wasCorrect: false)
        #expect(result.level == .recognition)
        #expect(result.consecutiveCorrect == 0)
        #expect(LearnEngine.advance(level: .new, consecutiveCorrect: 0, wasCorrect: false).level == .new)
    }

    @Test("with most of the deck still unmastered, a round only draws from the unmastered cards")
    func targetsUnmasteredWhileMostRemain() {
        var rng = SystemRandomNumberGenerator()
        // 7 unmastered, 3 mastered -- 70% unmastered, well above the 20% threshold.
        let mixed = Self.candidates(count: 7, level: .new, idPrefix: "new")
            + Self.candidates(count: 3, level: .mastered, idPrefix: "mastered")
        let round = LearnEngine.buildRound(from: mixed, using: &rng)
        #expect(round.allSatisfy { $0.cardId.hasPrefix("new-") })
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
        #expect(round.contains { $0.cardId.hasPrefix("mastered-") })
    }

    @Test("a fully mastered deck still gets quizzed, not left empty")
    func fullyMasteredDeckStillProducesARound() {
        var rng = SystemRandomNumberGenerator()
        let allMastered = Self.candidates(count: 10, level: .mastered)
        let round = LearnEngine.buildRound(from: allMastered, using: &rng)
        #expect(round.count == 7)
    }

    @Test("distractors never include the card's own answer")
    func distractorsExcludeSelf() {
        var rng = SystemRandomNumberGenerator()
        let pool = Self.candidates(count: 10)
        let target = pool[0]
        let picked = LearnEngine.distractors(for: target, in: pool, count: 3, using: &rng)
        #expect(!picked.contains(target.back))
    }
}
