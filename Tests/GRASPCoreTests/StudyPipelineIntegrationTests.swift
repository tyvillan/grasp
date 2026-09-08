import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// Exercises the full approve -> grade -> persist pipeline (the same
/// sequence AppStore.gradeCard runs) against real vault content in an
/// in-memory database -- proves the primitives compose correctly without
/// writing fabricated study history into the real production database.
@Suite("StudyPipelineIntegration")
struct StudyPipelineIntegrationTests {
    private static let vaultRoot = URL(fileURLWithPath:
        "/Users/tyvillan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Master Vault")

    private static func seededDatabase() async throws -> GRASPDatabase {
        let db = try GRASPDatabase.inMemory()
        _ = try await VaultScanner(database: db).scan(vaultRoot: vaultRoot)
        return db
    }

    private static func gradeCard(_ cardId: String, grade: FSRS.Grade, now: Date, db: GRASPDatabase) async throws {
        try await db.queue.write { conn in
            guard var card = try Card.fetchOne(conn, key: cardId) else { return }
            let snapshot = FSRS.Snapshot(
                stability: card.stability, difficulty: card.difficulty, reps: card.reps,
                lapses: card.lapses, state: FSRS.CardState(rawValue: card.schedulerState) ?? .new,
                lastReview: card.lastReview
            )
            let result = FSRS.schedule(snapshot, grade: grade, now: now)
            let dueBefore = card.due
            card.due = result.due
            card.stability = result.stability
            card.difficulty = result.difficulty
            card.elapsedDays = result.elapsedDays
            card.scheduledDays = result.scheduledDays
            card.reps = result.reps
            card.lapses = result.lapses
            card.schedulerState = result.state.rawValue
            card.lastReview = now
            card.updatedAt = now
            try card.save(conn)
            try Review(
                cardId: cardId, reviewedAt: now, grade: grade.rawValue, source: "test",
                dueBefore: dueBefore, dueAfter: result.due, stabilityAfter: result.stability,
                difficultyAfter: result.difficulty, schedulerVersion: "fsrs-5"
            ).save(conn)
        }
    }

    @Test("approving a deck's drafts makes them study-eligible")
    func approvingDraftsMakesThemDue() async throws {
        let db = try await Self.seededDatabase()
        let geologyDeckId = try await db.queue.read { conn -> String? in
            try Deck.filter(sql: """
                courseId IN (SELECT id FROM course WHERE name = 'Physical Geology')
                """).fetchOne(conn)?.id
        }
        let deckId = try #require(geologyDeckId)

        try await db.queue.write { conn in
            let cardIds = try DeckCard.filter(Column("deckId") == deckId).fetchAll(conn).map(\.cardId)
            try Card.filter(cardIds.contains(Column("id")))
                .updateAll(conn, Column("status").set(to: CardStatus.active.rawValue))
        }

        let due = try await db.queue.read { conn in
            try Card.filter(sql: """
                id IN (SELECT cardId FROM deckCard WHERE deckId = ?) AND status = 'active' AND due <= ?
                """, arguments: [deckId, Date()]).fetchCount(conn)
        }
        #expect(due > 200) // Physical Geology produced 232 parser cards
    }

    @Test("grading a real card through FSRS persists scheduler state and a review row")
    func gradingPersistsSchedulerState() async throws {
        let db = try await Self.seededDatabase()
        let cardId = try await db.queue.write { conn -> String in
            var card = try #require(try Card.fetchOne(conn))
            card.status = .active
            try card.save(conn)
            return card.id
        }

        let now = Date()
        try await Self.gradeCard(cardId, grade: .good, now: now, db: db)

        let (graded, reviewCount) = try await db.queue.read { conn -> (Card, Int) in
            let card = try #require(try Card.fetchOne(conn, key: cardId))
            let count = try Review.filter(Column("cardId") == cardId).fetchCount(conn)
            return (card, count)
        }
        #expect(graded.reps == 1)
        #expect(graded.due > now)
        #expect(graded.schedulerState == FSRS.CardState.learning.rawValue)
        #expect(reviewCount == 1)
    }

    @Test("grading Again schedules sooner than grading Good from the same starting state")
    func againSchedulesSoonerThanGood() async throws {
        // One seeded database, one real card: grade it "again" and persist
        // that (proving the write path), then compare against what the
        // pure algorithm alone says "good" would have done from the exact
        // same pre-grade snapshot -- no second database needed, since that
        // comparison never touches persistence.
        let db = try await Self.seededDatabase()
        let (cardId, snapshotBeforeGrading) = try await db.queue.write { conn -> (String, FSRS.Snapshot) in
            var card = try #require(try Card.fetchOne(conn))
            card.status = .active
            try card.save(conn)
            let snapshot = FSRS.Snapshot(
                stability: card.stability, difficulty: card.difficulty, reps: card.reps,
                lapses: card.lapses, state: FSRS.CardState(rawValue: card.schedulerState) ?? .new,
                lastReview: card.lastReview
            )
            return (card.id, snapshot)
        }

        let now = Date()
        try await Self.gradeCard(cardId, grade: .again, now: now, db: db)
        let dueAgain = try await db.queue.read { try #require(try Card.fetchOne($0, key: cardId)).due }
        let dueGood = FSRS.schedule(snapshotBeforeGrading, grade: .good, now: now).due

        #expect(dueAgain < dueGood)
    }
}
