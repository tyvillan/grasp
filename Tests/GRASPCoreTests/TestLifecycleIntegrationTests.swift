import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// Exercises the test lifecycle (build questions -> record answers ->
/// score -> feed misses back into FSRS) against real vault content in an
/// in-memory database, mirroring what AppStore.startTest/submitTestAnswer/
/// finishTest do.
@Suite("TestLifecycleIntegration")
struct TestLifecycleIntegrationTests {
    private static let vaultRoot = URL(fileURLWithPath:
        "/Users/tyvillan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Master Vault")

    private static func seededGeologyDeck() async throws -> (db: GRASPDatabase, deckId: String) {
        let db = try await VaultFixture.database()
        let deckId = try await db.queue.write { conn -> String in
            let deck = try #require(try Deck.filter(sql: """
                courseId IN (SELECT id FROM course WHERE name = 'Physical Geology')
                """).fetchOne(conn))
            let cardIds = try DeckCard.filter(Column("deckId") == deck.id).fetchAll(conn).map(\.cardId)
            try Card.filter(cardIds.contains(Column("id")))
                .updateAll(conn, Column("status").set(to: CardStatus.active.rawValue))
            return deck.id
        }
        return (db, deckId)
    }

    @Test("a test built from a real deck produces graded, scoreable questions")
    func testLifecycleScoresCorrectly() async throws {
        let (db, deckId) = try await Self.seededGeologyDeck()

        let cards = try await db.queue.read { conn in
            let cardIds = try DeckCard.filter(Column("deckId") == deckId).fetchAll(conn).map(\.cardId)
            return try Card.filter(cardIds.contains(Column("id"))).fetchAll(conn)
                .map { (cardId: $0.id, front: $0.front, back: $0.back) }
        }
        var rng = SystemRandomNumberGenerator()
        let config = TestBuilder.Config(questionCount: 10)
        let questions = TestBuilder.build(from: cards, config: config, using: &rng)
        #expect(questions.count == 10)

        let attemptId = try await db.queue.write { conn -> String in
            let attempt = TestAttempt(deckId: deckId, configJSON: "{}", startedAt: Date())
            try attempt.insert(conn)
            for (index, q) in questions.enumerated() {
                try TestItem(
                    id: "\(q.id)-\(attempt.id)", attemptId: attempt.id, cardId: q.cardId,
                    ordinal: index, questionType: q.type.rawValue, promptText: q.prompt,
                    correctAnswer: q.correctAnswer
                ).insert(conn)
            }
            return attempt.id
        }

        // Answer the first half correctly, the second half wrong.
        for (index, question) in questions.enumerated() {
            let isCorrect = index < questions.count / 2
            try await db.queue.write { conn in
                guard var item = try TestItem
                    .filter(Column("attemptId") == attemptId)
                    .filter(Column("ordinal") == index)
                    .fetchOne(conn)
                else { return }
                item.givenAnswer = isCorrect ? question.correctAnswer : "wrong"
                item.isCorrect = isCorrect
                try item.save(conn)
            }
        }

        let (correct, total) = try await db.queue.write { conn -> (Int, Int) in
            let items = try TestItem.filter(Column("attemptId") == attemptId).fetchAll(conn)
            let correctCount = items.filter { $0.isCorrect == true }.count
            var attempt = try #require(try TestAttempt.fetchOne(conn, key: attemptId))
            attempt.finishedAt = Date()
            attempt.scoreNumerator = correctCount
            attempt.scoreDenominator = items.count
            try attempt.save(conn)
            return (correctCount, items.count)
        }
        #expect(correct == 5)
        #expect(total == 10)

        // Feed misses back into FSRS, exactly as AppStore.finishTest does.
        let missedCardIds = try await db.queue.read { conn in
            try TestItem
                .filter(Column("attemptId") == attemptId)
                .filter(Column("isCorrect") == false)
                .fetchAll(conn)
                .compactMap(\.cardId)
        }
        #expect(missedCardIds.count == 5)
        for cardId in missedCardIds {
            try await db.queue.write { conn in
                guard var card = try Card.fetchOne(conn, key: cardId) else { return }
                let snapshot = FSRS.Snapshot(
                    stability: card.stability, difficulty: card.difficulty, reps: card.reps,
                    lapses: card.lapses, state: FSRS.CardState(rawValue: card.schedulerState) ?? .new,
                    lastReview: card.lastReview
                )
                let result = FSRS.schedule(snapshot, grade: .again, now: Date())
                card.due = result.due
                card.stability = result.stability
                card.reps = result.reps
                card.schedulerState = result.state.rawValue
                try card.save(conn)
            }
        }

        let regradedCards = try await db.queue.read { conn in
            try Card.filter(missedCardIds.contains(Column("id"))).fetchAll(conn)
        }
        #expect(regradedCards.allSatisfy { $0.reps == 1 })
        #expect(regradedCards.allSatisfy { $0.schedulerState == FSRS.CardState.learning.rawValue })
    }

    @Test("a card-less AI-generated test item grades by ordinal and is skipped by FSRS feedback")
    func aiGeneratedItemGradesWithoutACard() async throws {
        let (db, deckId) = try await Self.seededGeologyDeck()

        let realCard = try await db.queue.read { conn in
            let cardIds = try DeckCard.filter(Column("deckId") == deckId).fetchAll(conn).map(\.cardId)
            return try #require(try Card.filter(cardIds.contains(Column("id"))).fetchOne(conn))
        }

        let attemptId = try await db.queue.write { conn -> String in
            let attempt = TestAttempt(deckId: deckId, configJSON: "{}", startedAt: Date())
            try attempt.insert(conn)
            try TestItem(
                id: "real-\(attempt.id)", attemptId: attempt.id, cardId: realCard.id,
                ordinal: 0, questionType: "written", promptText: realCard.front,
                correctAnswer: realCard.back
            ).insert(conn)
            try TestItem(
                id: "ai-\(attempt.id)", attemptId: attempt.id, cardId: nil,
                ordinal: 1, questionType: "written", promptText: "An AI-authored question",
                correctAnswer: "An AI-authored answer", isAIGenerated: true
            ).insert(conn)
            return attempt.id
        }

        // Miss both, ordinal-keyed exactly like `AppStore.submitTestAnswer`.
        for ordinal in [0, 1] {
            try await db.queue.write { conn in
                guard var item = try TestItem
                    .filter(Column("attemptId") == attemptId)
                    .filter(Column("ordinal") == ordinal)
                    .fetchOne(conn)
                else { return }
                item.givenAnswer = "wrong"
                item.isCorrect = false
                try item.save(conn)
            }
        }

        let (correct, total) = try await db.queue.read { conn -> (Int, Int) in
            let items = try TestItem.filter(Column("attemptId") == attemptId).fetchAll(conn)
            return (items.filter { $0.isCorrect == true }.count, items.count)
        }
        #expect(correct == 0)
        #expect(total == 2) // the AI item counts toward the score even with no backing card

        // Exactly `AppStore.gradeMissedTestItems`'s own logic: `.compactMap`
        // over `cardId` naturally drops the AI item, no special-casing.
        let missedCardIds = try await db.queue.read { conn in
            try TestItem
                .filter(Column("attemptId") == attemptId)
                .filter(Column("isCorrect") == false)
                .fetchAll(conn)
                .compactMap(\.cardId)
        }
        #expect(missedCardIds == [realCard.id])
    }
}
