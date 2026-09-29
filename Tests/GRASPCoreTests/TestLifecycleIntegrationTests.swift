import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// Exercises the test lifecycle (build questions -> record answers -> score
/// -> finish) against real vault content in an in-memory database, calling
/// the same `Study` functions `AppStore.startTest`/`submitTestAnswer`/
/// `finishTest` do -- rather than reimplementing their FSRS steps here,
/// which is what let this suite drift out of sync with a real behavior
/// change (finishing now rewards hits with Good instead of punishing
/// misses with Again).
@Suite("TestLifecycleIntegration", .enabled(if: VaultFixture.vaultExists, "needs the real notes vault on the Mac"))
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

    private struct Snapshot: Equatable {
        let due: Date
        let reps: Int
        let state: Int
    }

    private static func snapshots(_ cardIds: [String], db: GRASPDatabase) async throws -> [String: Snapshot] {
        try await db.queue.read { conn in
            try Dictionary(uniqueKeysWithValues: Card.filter(cardIds.contains(Column("id"))).fetchAll(conn)
                .map { ($0.id, Snapshot(due: $0.due, reps: $0.reps, state: $0.schedulerState)) })
        }
    }

    @Test("a test built from a real deck rewards every hit and leaves every miss untouched")
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
        let cardIds = questions.compactMap(\.cardId)

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

        let before = try await Self.snapshots(cardIds, db: db)

        // Answer the first half correctly, the second half wrong.
        try await db.queue.write { conn in
            for (index, question) in questions.enumerated() {
                let isCorrect = index < questions.count / 2
                try Study.submitTestAnswer(attemptId: attemptId, ordinal: index,
                                           given: isCorrect ? question.correctAnswer : "wrong",
                                           isCorrect: isCorrect, db: conn)
            }
        }

        let (correct, total) = try await db.queue.write { try Study.finishTest(attemptId: attemptId, db: $0) }
        #expect(correct == 5)
        #expect(total == 10)

        let after = try await Self.snapshots(cardIds, db: db)
        for (index, question) in questions.enumerated() {
            guard let cardId = question.cardId, let was = before[cardId], let now = after[cardId] else { continue }
            if index < questions.count / 2 {
                // Rewarded: graded Good, so its schedule moved forward.
                #expect(now.reps == was.reps + 1)
                #expect(now.due > was.due)
            } else {
                // A miss gets no grade at all -- exactly as it was before.
                #expect(now == was)
            }
        }
    }

    @Test("a card-less AI-generated test item is skipped when rewarding hits")
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

        // Both right, ordinal-keyed exactly like `AppStore.submitTestAnswer`.
        try await db.queue.write { conn in
            try Study.submitTestAnswer(attemptId: attemptId, ordinal: 0, given: realCard.back, isCorrect: true, db: conn)
            try Study.submitTestAnswer(attemptId: attemptId, ordinal: 1, given: "An AI-authored answer",
                                       isCorrect: true, db: conn)
        }

        let (correct, total) = try await db.queue.write { try Study.finishTest(attemptId: attemptId, db: $0) }
        #expect(correct == 2) // the AI item counts toward the score even with no backing card
        #expect(total == 2)

        // The AI item has no card to reward -- `compactMap` over `cardId`
        // naturally drops it, no special-casing -- so only the real card
        // gets a review row.
        let rewarded = try await db.queue.read { try Review.filter(Column("source") == "test").fetchCount($0) }
        #expect(rewarded == 1)
        let regraded = try await db.queue.read { try #require(try Card.fetchOne($0, key: realCard.id)) }
        #expect(regraded.reps == realCard.reps + 1)
    }
}
