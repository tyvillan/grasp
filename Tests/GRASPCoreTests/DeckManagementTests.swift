import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// `GRASPCoreTests` can't import `AppStore` (it lives in the `GRASP`
/// executable target, not `GRASPCore`), so these mirror the exact GRDB
/// statements `AppStore`'s deck-management methods run -- see
/// `CourseDeletionTests.swift` for the same convention. Deliberately
/// synthetic fixtures (not the real vault): these exercise deck/card
/// membership mechanics that have nothing to do with real note content.
@Suite("DeckManagement")
struct DeckManagementTests {
    private func makeCourse(_ db: GRASPDatabase) async throws -> String {
        try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Test Course")
            try course.insert(conn)
            return course.id
        }
    }

    private func makeDeck(_ db: GRASPDatabase, courseId: String, name: String) async throws -> String {
        try await db.queue.write { conn in
            let deck = Deck(courseId: courseId, name: name)
            try deck.insert(conn)
            return deck.id
        }
    }

    private func makeCard(_ db: GRASPDatabase, inDeck deckId: String) async throws -> String {
        try await db.queue.write { conn in
            let card = Card(materialId: nil, front: "Q", back: "A", origin: .manual, status: .active)
            try card.insert(conn)
            try DeckCard(deckId: deckId, cardId: card.id).insert(conn)
            return card.id
        }
    }

    // Mirrors AppStore.deleteDeck(_:migrateCardsTo:).
    private func deleteDeck(_ deckId: String, migrateCardsTo targetDeckId: String?, db: GRASPDatabase) async throws {
        try await db.queue.write { conn in
            guard var deck = try Deck.fetchOne(conn, key: deckId) else { return }
            let now = Date()
            if let targetDeckId, targetDeckId != deckId,
               let target = try Deck.fetchOne(conn, key: targetDeckId), target.deletedAt == nil {
                let base = try Int.fetchOne(conn, sql:
                    "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?",
                    arguments: [targetDeckId]
                ) ?? 0
                try conn.execute(sql: """
                    INSERT OR IGNORE INTO deckCard (deckId, cardId, sortIndex)
                    SELECT ?, cardId, ? + (ROW_NUMBER() OVER (ORDER BY sortIndex) - 1)
                    FROM deckCard WHERE deckId = ?
                    """, arguments: [targetDeckId, base, deckId])
            } else {
                try conn.execute(sql: """
                    UPDATE card SET deletedAt = ?, updatedAt = ?
                    WHERE id IN (SELECT cardId FROM deckCard WHERE deckId = ?)
                      AND id NOT IN (SELECT cardId FROM deckCard WHERE deckId != ?)
                    """, arguments: [now, now, deckId, deckId])
            }
            try conn.execute(sql: "DELETE FROM deckCard WHERE deckId = ?", arguments: [deckId])
            deck.deletedAt = now
            deck.updatedAt = now
            try deck.save(conn)
        }
    }

    // Mirrors AppStore.moveCard(_:toDeck:).
    private func moveCard(_ cardId: String, toDeck targetDeckId: String, db: GRASPDatabase) async throws {
        try await db.queue.write { conn in
            guard let target = try Deck.fetchOne(conn, key: targetDeckId), target.deletedAt == nil else { return }
            let existing = try DeckCard.filter(Column("cardId") == cardId).fetchAll(conn)
            if existing.count == 1, existing[0].deckId == targetDeckId { return }
            try DeckCard.filter(Column("cardId") == cardId).deleteAll(conn)
            let next = try Int.fetchOne(conn, sql:
                "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?",
                arguments: [targetDeckId]
            ) ?? 0
            try DeckCard(deckId: targetDeckId, cardId: cardId, sortIndex: next).insert(conn)
        }
    }

    @Test("moving a card removes its old membership and adds the new one")
    func moveCardChangesMembership() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckA = try await makeDeck(db, courseId: courseId, name: "A")
        let deckB = try await makeDeck(db, courseId: courseId, name: "B")
        let cardId = try await makeCard(db, inDeck: deckA)

        try await moveCard(cardId, toDeck: deckB, db: db)

        try await db.queue.read { conn in
            let memberships = try DeckCard.filter(Column("cardId") == cardId).fetchAll(conn)
            #expect(memberships.count == 1)
            #expect(memberships.first?.deckId == deckB)
        }
    }

    @Test("moving a card onto its own deck is a harmless no-op")
    func moveCardOntoOwnDeckNoOps() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckA = try await makeDeck(db, courseId: courseId, name: "A")
        let cardId = try await makeCard(db, inDeck: deckA)

        try await moveCard(cardId, toDeck: deckA, db: db)

        try await db.queue.read { conn in
            let count = try DeckCard.filter(Column("cardId") == cardId).fetchCount(conn)
            #expect(count == 1)
        }
    }

    @Test("deleting a deck with migration moves cards without touching review history")
    func deleteDeckMigratesCards() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let source = try await makeDeck(db, courseId: courseId, name: "Source")
        let target = try await makeDeck(db, courseId: courseId, name: "Target")
        let cardId = try await makeCard(db, inDeck: source)
        try await db.queue.write { conn in
            try Review(cardId: cardId, reviewedAt: Date(), grade: 3, source: "test",
                       dueAfter: Date(), schedulerVersion: "fsrs-5").insert(conn)
        }

        try await deleteDeck(source, migrateCardsTo: target, db: db)

        try await db.queue.read { conn in
            let deck = try #require(try Deck.fetchOne(conn, key: source))
            #expect(deck.deletedAt != nil)
            let card = try #require(try Card.fetchOne(conn, key: cardId))
            #expect(card.deletedAt == nil)  // migrated, not removed
            let memberships = try DeckCard.filter(Column("cardId") == cardId).fetchAll(conn)
            #expect(memberships.count == 1)
            #expect(memberships.first?.deckId == target)
            #expect(try Review.filter(Column("cardId") == cardId).fetchCount(conn) == 1)
        }
    }

    @Test("migrating into a deck that already has the same card doesn't fail the whole write")
    func deleteDeckMigrationHandlesExistingMembership() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let source = try await makeDeck(db, courseId: courseId, name: "Source")
        let target = try await makeDeck(db, courseId: courseId, name: "Target")
        // A card already sitting in both decks -- the exact case a bare
        // `UPDATE deckCard SET deckId = ?` would abort on (composite PK
        // collision).
        let cardId = try await makeCard(db, inDeck: source)
        try await db.queue.write { conn in
            try DeckCard(deckId: target, cardId: cardId).insert(conn)
        }
        let untouchedCard = try await makeCard(db, inDeck: source)

        try await deleteDeck(source, migrateCardsTo: target, db: db)

        try await db.queue.read { conn in
            let sharedMemberships = try DeckCard.filter(Column("cardId") == cardId).fetchAll(conn)
            #expect(sharedMemberships.count == 1)
            #expect(sharedMemberships.first?.deckId == target)
            let otherMemberships = try DeckCard.filter(Column("cardId") == untouchedCard).fetchAll(conn)
            #expect(otherMemberships.count == 1)
            #expect(otherMemberships.first?.deckId == target)
        }
    }

    @Test("deleting a deck without migration soft-deletes its cards, preserving review rows")
    func deleteDeckWithoutMigrationSoftDeletesCards() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckId = try await makeDeck(db, courseId: courseId, name: "Doomed")
        let cardId = try await makeCard(db, inDeck: deckId)
        try await db.queue.write { conn in
            try Review(cardId: cardId, reviewedAt: Date(), grade: 2, source: "test",
                       dueAfter: Date(), schedulerVersion: "fsrs-5").insert(conn)
        }

        try await deleteDeck(deckId, migrateCardsTo: nil, db: db)

        try await db.queue.read { conn in
            let card = try #require(try Card.fetchOne(conn, key: cardId))
            #expect(card.deletedAt != nil)
            // Hard-deleting the card would cascade away its reviews --
            // soft-delete must not.
            #expect(try Review.filter(Column("cardId") == cardId).fetchCount(conn) == 1)
            #expect(try DeckCard.filter(Column("deckId") == deckId).fetchCount(conn) == 0)
        }
    }

    @Test("deleting a deck without migration spares a card that also lives in another deck")
    func deleteDeckWithoutMigrationSparesSharedCard() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckA = try await makeDeck(db, courseId: courseId, name: "A")
        let deckB = try await makeDeck(db, courseId: courseId, name: "B")
        let cardId = try await makeCard(db, inDeck: deckA)
        try await db.queue.write { conn in
            try DeckCard(deckId: deckB, cardId: cardId).insert(conn)
        }

        try await deleteDeck(deckA, migrateCardsTo: nil, db: db)

        try await db.queue.read { conn in
            let card = try #require(try Card.fetchOne(conn, key: cardId))
            #expect(card.deletedAt == nil)
            let memberships = try DeckCard.filter(Column("cardId") == cardId).fetchAll(conn)
            #expect(memberships.count == 1)
            #expect(memberships.first?.deckId == deckB)
        }
    }

    @Test("a soft-deleted deck is not resurrected by a re-import that would otherwise reuse its name")
    func softDeletedDeckIsNotResurrectedByReimport() async throws {
        let db = try GRASPDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-deck-resurrection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let scanner = VaultScanner(database: db)
        let note = """
        Term
        A definition long enough to actually count as one for this fixture.
        Padding it out past the thirty word study-worthy floor so the card
        actually gets generated instead of being skipped as too short here.
        """
        let courseId = try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Resurrection Course")
            try course.insert(conn)
            return course.id
        }

        // First import creates "Week 1" via the chapter parsed from the
        // filename.
        let fileURL = dir.appendingPathComponent("2026-01-01_Week-01_First.md")
        try note.write(to: fileURL, atomically: false, encoding: .utf8)
        _ = try await scanner.importPaths([fileURL], intoCourse: courseId)

        let originalDeckId = try await db.queue.read { conn in
            try #require(try Deck.filter(Column("courseId") == courseId)
                .filter(Column("name") == "Week 1").fetchOne(conn)).id
        }

        // Delete it exactly as a user would -- via the full deleteDeck
        // flow, which also clears its own deckCard row(s), not just a
        // bare `deletedAt` stamp.
        try await deleteDeck(originalDeckId, migrateCardsTo: nil, db: db)

        // A second note that parses to the same "Week 1" chapter must
        // create a fresh deck, not resurrect the tombstoned one.
        let secondURL = dir.appendingPathComponent("2026-01-02_Week-01_Second.md")
        try note.write(to: secondURL, atomically: false, encoding: .utf8)
        _ = try await scanner.importPaths([secondURL], intoCourse: courseId)

        try await db.queue.read { conn in
            let weekOneDecks = try Deck.filter(Column("courseId") == courseId)
                .filter(Column("name") == "Week 1").fetchAll(conn)
            #expect(weekOneDecks.count == 2)
            let liveDeck = try #require(weekOneDecks.first { $0.deletedAt == nil })
            #expect(liveDeck.id != originalDeckId)
            // Nothing was written into the tombstoned deck's membership.
            let staleMemberships = try DeckCard.filter(Column("deckId") == originalDeckId).fetchCount(conn)
            #expect(staleMemberships == 0)
        }
    }

    // MARK: - Bulk mutators (mirrors AppStore.bulkSetStatus/bulkDeleteCards/bulkMoveCards)

    private func bulkSetStatus(_ cardIds: [String], status: CardStatus, db: GRASPDatabase) async throws {
        try await db.queue.write { conn in
            let now = Date()
            try Card
                .filter(cardIds.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .updateAll(conn, Column("status").set(to: status.rawValue), Column("updatedAt").set(to: now))
        }
    }

    private func bulkDeleteCards(_ cardIds: [String], db: GRASPDatabase) async throws {
        try await db.queue.write { conn in
            let now = Date()
            try Card
                .filter(cardIds.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .updateAll(conn, Column("deletedAt").set(to: now), Column("updatedAt").set(to: now))
        }
    }

    private static let sqlVariableChunkSize = 500

    private func bulkMoveCards(_ cardIds: [String], toDeck targetDeckId: String, db: GRASPDatabase) async throws {
        try await db.queue.write { conn in
            guard let target = try Deck.fetchOne(conn, key: targetDeckId), target.deletedAt == nil else { return }
            for start in stride(from: 0, to: cardIds.count, by: Self.sqlVariableChunkSize) {
                let chunk = Array(cardIds[start..<min(start + Self.sqlVariableChunkSize, cardIds.count)])
                try DeckCard.filter(chunk.contains(Column("cardId"))).deleteAll(conn)
            }
            var next = try Int.fetchOne(conn, sql:
                "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?",
                arguments: [targetDeckId]
            ) ?? 0
            for cardId in cardIds {
                try DeckCard(deckId: targetDeckId, cardId: cardId, sortIndex: next).insert(conn)
                next += 1
            }
        }
    }

    @Test("bulkSetStatus promotes every listed card and no others")
    func bulkSetStatusPromotesListedCards() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckId = try await makeDeck(db, courseId: courseId, name: "Deck")
        let a = try await makeCard(db, inDeck: deckId)
        let b = try await makeCard(db, inDeck: deckId)
        let untouched = try await makeCard(db, inDeck: deckId)
        try await db.queue.write { conn in
            for id in [a, b, untouched] {
                guard var card = try Card.fetchOne(conn, key: id) else { continue }
                card.status = .draft
                try card.save(conn)
            }
        }

        try await bulkSetStatus([a, b], status: .active, db: db)

        try await db.queue.read { conn in
            let statusA = try Card.fetchOne(conn, key: a)?.status
            let statusB = try Card.fetchOne(conn, key: b)?.status
            let statusUntouched = try Card.fetchOne(conn, key: untouched)?.status
            #expect(statusA == .active)
            #expect(statusB == .active)
            #expect(statusUntouched == .draft)
        }
    }

    @Test("bulkDeleteCards soft-deletes every listed card, preserving review rows")
    func bulkDeleteCardsSoftDeletes() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckId = try await makeDeck(db, courseId: courseId, name: "Deck")
        let a = try await makeCard(db, inDeck: deckId)
        let b = try await makeCard(db, inDeck: deckId)
        try await db.queue.write { conn in
            try Review(cardId: a, reviewedAt: Date(), grade: 3, source: "test",
                       dueAfter: Date(), schedulerVersion: "fsrs-5").insert(conn)
        }

        try await bulkDeleteCards([a, b], db: db)

        try await db.queue.read { conn in
            let cardA = try Card.fetchOne(conn, key: a)
            let cardB = try Card.fetchOne(conn, key: b)
            let reviewCount = try Review.filter(Column("cardId") == a).fetchCount(conn)
            #expect(cardA?.deletedAt != nil)
            #expect(cardB?.deletedAt != nil)
            #expect(reviewCount == 1)
        }
    }

    @Test("bulkMoveCards moves every listed card and preserves the given order as sortIndex")
    func bulkMoveCardsPreservesOrder() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let source = try await makeDeck(db, courseId: courseId, name: "Source")
        let target = try await makeDeck(db, courseId: courseId, name: "Target")
        let a = try await makeCard(db, inDeck: source)
        let b = try await makeCard(db, inDeck: source)

        try await bulkMoveCards([b, a], toDeck: target, db: db)

        try await db.queue.read { conn in
            let memberships = try DeckCard.filter(Column("deckId") == target)
                .order(Column("sortIndex")).fetchAll(conn)
            #expect(memberships.map(\.cardId) == [b, a])
            #expect(try DeckCard.filter(Column("deckId") == source).fetchCount(conn) == 0)
        }
    }

    @Test("bulkMoveCards chunks its delete so a batch bigger than SQLite's IN(...) variable cap doesn't throw")
    func bulkMoveCardsHandlesBatchesBiggerThanTheChunkCap() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let source = try await makeDeck(db, courseId: courseId, name: "Source")
        let target = try await makeDeck(db, courseId: courseId, name: "Target")

        let count = 600 // bigger than the 500-id chunk size, on purpose
        let cardIds = try await db.queue.write { conn -> [String] in
            var ids: [String] = []
            for i in 0..<count {
                let card = Card(materialId: nil, front: "Q\(i)", back: "A\(i)", origin: .manual, status: .active)
                try card.insert(conn)
                try DeckCard(deckId: source, cardId: card.id, sortIndex: i).insert(conn)
                ids.append(card.id)
            }
            return ids
        }

        try await bulkMoveCards(cardIds, toDeck: target, db: db)

        try await db.queue.read { conn in
            let targetCount = try DeckCard.filter(Column("deckId") == target).fetchCount(conn)
            let sourceCount = try DeckCard.filter(Column("deckId") == source).fetchCount(conn)
            #expect(targetCount == count)
            #expect(sourceCount == 0)
        }
    }

    @Test("bulkMoveCards onto a soft-deleted deck is a no-op")
    func bulkMoveCardsRejectsDeletedTarget() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let source = try await makeDeck(db, courseId: courseId, name: "Source")
        let target = try await makeDeck(db, courseId: courseId, name: "Target")
        try await db.queue.write { conn in
            guard var deck = try Deck.fetchOne(conn, key: target) else { return }
            deck.deletedAt = Date()
            try deck.save(conn)
        }
        let a = try await makeCard(db, inDeck: source)

        try await bulkMoveCards([a], toDeck: target, db: db)

        try await db.queue.read { conn in
            let memberships = try DeckCard.filter(Column("cardId") == a).fetchAll(conn)
            #expect(memberships.count == 1)
            #expect(memberships.first?.deckId == source)
        }
    }
}
