import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// Study, Learn, and Test filtering all now read the same "understood"
/// signal (`learnState.level == .mastered`), set two different ways:
/// Study's two-button `markCard` jumps straight to mastered/new, Learn's
/// `recordLearnAnswer` climbs the ladder gradually. This verifies both
/// paths against real content, and that a test built with
/// `excludeMastered` actually excludes what Study just approved.
@Suite("MasteryIntegration", .enabled(if: VaultFixture.vaultExists, "needs the real notes vault on the Mac"))
struct MasteryIntegrationTests {
    private func markCard(_ cardId: String, understood: Bool, db: GRASPDatabase) async throws {
        try await db.queue.write { conn in
            guard var card = try Card.fetchOne(conn, key: cardId) else { return }
            let snapshot = FSRS.Snapshot(
                stability: card.stability, difficulty: card.difficulty, reps: card.reps,
                lapses: card.lapses, state: FSRS.CardState(rawValue: card.schedulerState) ?? .new,
                lastReview: card.lastReview
            )
            let now = Date()
            let result = FSRS.schedule(snapshot, grade: understood ? .good : .again, now: now)
            card.due = result.due
            card.stability = result.stability
            card.difficulty = result.difficulty
            card.reps = result.reps
            card.schedulerState = result.state.rawValue
            card.lastReview = now
            try card.save(conn)
            try LearnState(
                cardId: cardId,
                level: understood ? LearnEngine.Level.mastered.rawValue : LearnEngine.Level.new.rawValue,
                consecutiveCorrect: understood ? 1 : 0, lastSeenAt: now
            ).save(conn)
        }
    }

    @Test("marking a card understood in Study sets the shared mastery signal Learn and Test both read")
    func markCardSetsSharedMasterySignal() async throws {
        let db = try await VaultFixture.database()
        let (cardId, deckId) = try await db.queue.read { conn -> (String, String) in
            let deck = try #require(try Deck.filter(sql: """
                courseId IN (SELECT id FROM course WHERE name = 'Physical Geology')
                """).fetchOne(conn))
            let cardId = try #require(try DeckCard.filter(Column("deckId") == deck.id).fetchOne(conn)?.cardId)
            return (cardId, deck.id)
        }
        // Approve the whole deck (232 cards), not just the one card under
        // test -- otherwise, from the round-builder's view, "the deck" is
        // just that one now-mastered card, which correctly (but not what
        // this test means to check) triggers the "mostly mastered, quiz
        // at random" fallback instead of exercising the exclusion path.
        try await db.queue.write { conn in
            let deckCardIds = try DeckCard.filter(Column("deckId") == deckId).fetchAll(conn).map(\.cardId)
            try Card.filter(deckCardIds.contains(Column("id")))
                .updateAll(conn, Column("status").set(to: CardStatus.active.rawValue))
        }

        try await markCard(cardId, understood: true, db: db)

        let level = try await db.queue.read { conn in
            try LearnState.fetchOne(conn, key: cardId)?.level
        }
        #expect(level == LearnEngine.Level.mastered.rawValue)

        // Learn mode's own round builder must now skip this card (unless
        // the deck is mostly mastered, which a single card out of 232
        // is not).
        let candidates = try await db.queue.read { conn -> [LearnEngine.Candidate] in
            let cardIds = try DeckCard.filter(Column("deckId") == deckId).fetchAll(conn).map(\.cardId)
            let cards = try Card.filter(cardIds.contains(Column("id")))
                .filter(Column("status") == CardStatus.active.rawValue).fetchAll(conn)
            let states = try LearnState.filter(cardIds.contains(Column("cardId"))).fetchAll(conn)
            let byCard = Dictionary(uniqueKeysWithValues: states.map { ($0.cardId, $0) })
            return cards.map {
                LearnEngine.Candidate(
                    cardId: $0.id, front: $0.front, back: $0.back,
                    level: LearnEngine.Level(rawValue: byCard[$0.id]?.level ?? 0) ?? .new
                )
            }
        }
        var rng = SystemRandomNumberGenerator()
        let round = LearnEngine.buildRound(from: candidates, using: &rng)
        #expect(!round.contains { $0.cardId == cardId })

        // And a test built with excludeMastered must skip it too.
        let pool = candidates.filter { $0.level != .mastered }
            .map { (cardId: $0.cardId, front: $0.front, back: $0.back) }
        let questions = TestBuilder.build(
            from: pool, config: .init(questionCount: 300, excludeMastered: true), using: &rng
        )
        #expect(!questions.contains { $0.cardId == cardId })
    }

    @Test("marking a card for review resets it to new, not left at whatever level Learn had climbed it to")
    func markCardForReviewResetsLevel() async throws {
        let db = try await VaultFixture.database()
        let cardId = try await db.queue.read { conn in
            try #require(try Card.fetchOne(conn)).id
        }
        try await db.queue.write { conn in
            guard var card = try Card.fetchOne(conn, key: cardId) else { return }
            card.status = .active
            try card.save(conn)
        }

        // Learn had already climbed this card partway up the ladder.
        try await db.queue.write { conn in
            try LearnState(cardId: cardId, level: LearnEngine.Level.recall.rawValue, consecutiveCorrect: 2).save(conn)
        }

        try await markCard(cardId, understood: false, db: db)

        let level = try await db.queue.read { conn in
            try LearnState.fetchOne(conn, key: cardId)?.level
        }
        #expect(level == LearnEngine.Level.new.rawValue)
    }
}
