import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// Course deletion is the only destructive action in the app, so the
/// cascade is verified against real imported content rather than trusted:
/// `card.materialId` is ON DELETE SET NULL, which means cascading from the
/// course alone would strand its cards instead of removing them. This
/// mirrors the statements `AppStore.deleteCourse` runs.
@Suite("CourseDeletion")
struct CourseDeletionTests {
    private static let vaultRoot = URL(fileURLWithPath:
        "/Users/tyvillan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Master Vault")

    private func deleteCourse(_ courseId: String, db: GRASPDatabase) async throws {
        try await db.queue.write { conn in
            try conn.execute(sql: """
                DELETE FROM card WHERE materialId IN (SELECT id FROM material WHERE courseId = ?)
                """, arguments: [courseId])
            _ = try Course.deleteOne(conn, key: courseId)
        }
    }

    @Test("deleting a course removes its cards, materials, and review history -- and nothing else's")
    func deletionCascadesWithoutCollateral() async throws {
        let db = try await VaultFixture.database()

        let (geologyId, otherId) = try await db.queue.read { conn -> (String, String) in
            let geology = try #require(try Course.filter(Column("name") == "Physical Geology").fetchOne(conn))
            let other = try #require(try Course.filter(Column("name") == "Computer Logic Design").fetchOne(conn))
            return (geology.id, other.id)
        }

        // Give one geology card a review, so history is in play too.
        try await db.queue.write { conn in
            let cardId = try #require(try String.fetchOne(conn, sql: """
                SELECT id FROM card WHERE materialId IN (SELECT id FROM material WHERE courseId = ?) LIMIT 1
                """, arguments: [geologyId]))
            try Review(
                cardId: cardId, reviewedAt: Date(), grade: 3, source: "test",
                dueAfter: Date(), schedulerVersion: "fsrs-5"
            ).insert(conn)
        }

        let before = try await db.queue.read { conn in
            (
                geologyCards: try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM card WHERE materialId IN (SELECT id FROM material WHERE courseId = ?)", arguments: [geologyId]) ?? 0,
                otherCards: try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM card WHERE materialId IN (SELECT id FROM material WHERE courseId = ?)", arguments: [otherId]) ?? 0,
                reviews: try Review.fetchCount(conn)
            )
        }
        #expect(before.geologyCards > 200)   // Physical Geology parses to 232 cards
        #expect(before.otherCards > 0)
        #expect(before.reviews == 1)

        try await deleteCourse(geologyId, db: db)

        try await db.queue.read { conn in
            // The course and everything derived from it is gone...
            #expect(try Course.fetchOne(conn, key: geologyId) == nil)
            #expect(try Material.filter(Column("courseId") == geologyId).fetchCount(conn) == 0)
            #expect(try Deck.filter(Column("courseId") == geologyId).fetchCount(conn) == 0)
            #expect(try Review.fetchCount(conn) == 0)
            // ...including its cards, rather than leaving them orphaned
            // with a null materialId.
            let orphans = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM card WHERE materialId IS NULL") ?? 0
            #expect(orphans == 0)

            // ...and the untouched course still has everything.
            let otherCards = try Int.fetchOne(conn, sql: """
                SELECT COUNT(*) FROM card WHERE materialId IN (SELECT id FROM material WHERE courseId = ?)
                """, arguments: [otherId]) ?? 0
            #expect(otherCards == before.otherCards)
        }
    }

    @Test("archiving hides a course without removing anything")
    func archivingPreservesData() async throws {
        let db = try await VaultFixture.database()

        let courseId = try await db.queue.write { conn -> String in
            var course = try #require(try Course.filter(Column("name") == "Physical Geology").fetchOne(conn))
            course.isArchived = true
            try course.save(conn)
            return course.id
        }

        try await db.queue.read { conn in
            let course = try #require(try Course.fetchOne(conn, key: courseId))
            #expect(course.isArchived)
            let cards = try Int.fetchOne(conn, sql: """
                SELECT COUNT(*) FROM card WHERE materialId IN (SELECT id FROM material WHERE courseId = ?)
                """, arguments: [courseId]) ?? 0
            #expect(cards > 200)
        }
    }
}
