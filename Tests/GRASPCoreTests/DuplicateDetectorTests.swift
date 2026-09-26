import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("DuplicateDetector")
struct DuplicateDetectorTests {
    private func card(_ front: String, _ back: String) -> Card {
        Card(materialId: nil, front: front, back: back, origin: .parser, status: .draft)
    }

    @Test("an exact duplicate matches")
    func exactDuplicateMatches() {
        let existing = card("Polymorphism", "The ability of different classes to respond to the same method call.")
        let index = DuplicateDetector.Index([existing])
        let match = index.matchId(
            front: "Polymorphism", back: "The ability of different classes to respond to the same method call."
        )
        #expect(match == existing.id)
    }

    @Test("same front, unrelated back does not match")
    func sameFrontDifferentBackDoesNotMatch() {
        let existing = card("Constructor", "The method called when an object is created.")
        let index = DuplicateDetector.Index([existing])
        let match = index.matchId(
            front: "Constructor", back: "A completely different sentence about bridge engineering and load limits."
        )
        #expect(match == nil)
    }

    @Test("same back, unrelated front does not match")
    func sameBackDifferentFrontDoesNotMatch() {
        let existing = card("Frontend", "The developer role responsible for the presentation layer of an application.")
        let index = DuplicateDetector.Index([existing])
        let match = index.matchId(
            front: "Backend", back: "The developer role responsible for the presentation layer of an application."
        )
        #expect(match == nil)
    }

    @Test("a near-duplicate with minor wording differences still matches")
    func nearDuplicateMatches() {
        // The real shape this exists for: the same term defined once in a
        // lecture note and again, slightly reworded, in a separate
        // Canvas-module summary of the same lecture.
        let existing = card("Encapsulation", "Hiding the implementation details of an object from the rest of the program.")
        let index = DuplicateDetector.Index([existing])
        let match = index.matchId(
            front: "Encapsulation",
            back: "Hiding the implementation details of an object from the rest of a program."
        )
        #expect(match == existing.id)
    }

    @Test("transitively close a chain of near-duplicates into one group")
    func transitiveGrouping() {
        let a = card("Backend", "The developer role responsible for the business layer of an application here today.")
        let b = card("Backend", "The developer role responsible for the business layer of an application here now.")
        let c = card("Backend", "The developer role responsible for the business layer of an application right now.")
        let unrelated = card("Frontend", "The developer role responsible for the presentation layer of an application.")

        let groups = DuplicateDetector.groups([a, b, c, unrelated])
        #expect(groups.count == 1)
        #expect(groups.first?.count == 3)
        let ids = Set(groups.first?.map(\.id) ?? [])
        #expect(ids == Set([a.id, b.id, c.id]))
    }

    @Test("groups (but not plain matchId) catches an exact-term pair whose independently-written definitions diverge past the back threshold")
    func groupsCatchesSameTermDivergentDefinitions() {
        // Modeled directly on real data: "Intro to Software Design" covers
        // Abstraction in both its own lecture notes and a separate
        // exam-prep slide deck, worded completely differently -- exactly
        // the shape `sameTermFrontThreshold` exists for.
        let a = card("Abstraction", "Exposing what a thing does while hiding how it does it, so a caller uses the interface without knowing the internals.")
        let b = card("Abstraction", "Hides the internal implementation details while exposing only the necessary functionality, to focus on what to do rather than how.")

        // Plain `matchId` (import-time/generation-time suppression) stays
        // strict and correctly does NOT consider these the same card.
        let strictIndex = DuplicateDetector.Index([a])
        #expect(strictIndex.matchId(front: b.front, back: b.back) == nil)

        // `groups` (the human-reviewed flow) does catch it.
        let groups = DuplicateDetector.groups([a, b])
        #expect(groups.count == 1)
        #expect(Set(groups.first?.map(\.id) ?? []) == Set([a.id, b.id]))
    }

    @Test("no duplicates among genuinely distinct cards")
    func noFalsePositives() {
        let cards = [
            card("Mitosis", "Cell division producing two genetically identical daughter cells."),
            card("Meiosis", "Cell division producing four genetically distinct gametes."),
            card("Osmosis", "The movement of water across a membrane toward higher solute concentration."),
        ]
        #expect(DuplicateDetector.groups(cards).isEmpty)
    }

    @Test("insert grows the index so later matches are found")
    func insertGrowsIndex() {
        var index = DuplicateDetector.Index([])
        #expect(index.matchId(front: "Sunk cost", back: "A cost already incurred that cannot be recovered.") == nil)
        index.insert(id: "abc", front: "Sunk cost", back: "A cost already incurred that cannot be recovered.")
        #expect(index.matchId(front: "Sunk cost", back: "A cost already incurred that cannot be recovered.") == "abc")
    }

    // MARK: - Import-time suppression (VaultScanner integration)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-dedup-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a second note repeating the same definition contributes no new card")
    func importSuppressesCrossNoteDuplicate() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Dedup Course")
            try course.insert(conn)
            return course.id
        }
        let dir = try makeTempDir()
        // isStudyWorthy requires at least 30 words in the reflowed body,
        // so this pads past that floor the same way ManualImportTests does.
        let note = """
        Sunk cost
        A cost that has already been incurred and cannot be recovered by
        any future decision or action taken now, regardless of how the
        remaining choices in front of a person are ultimately weighed.
        """
        let firstURL = dir.appendingPathComponent("Lecture.md")
        let secondURL = dir.appendingPathComponent("Canvas-Summary.md")
        try note.write(to: firstURL, atomically: false, encoding: .utf8)
        try note.write(to: secondURL, atomically: false, encoding: .utf8)

        let scanner = VaultScanner(database: db)
        let first = try await scanner.importPaths([firstURL], intoCourse: courseId)
        let second = try await scanner.importPaths([secondURL], intoCourse: courseId)

        #expect(first.cardsCreated == 1)
        #expect(first.duplicatesSkipped == 0)
        #expect(second.cardsCreated == 0)
        #expect(second.duplicatesSkipped == 1)

        try await db.queue.read { conn in
            let count = try Card.filter(Column("front") == "Sunk cost").fetchCount(conn)
            #expect(count == 1)
        }
    }

    // MARK: - applyMerges

    /// A course + one deck, ready for cards to be dropped into -- every
    /// `applyMerges` test needs at least one real deck for `DeckCard` FKs
    /// to point at.
    private func makeCourseAndDeck(_ db: Database) throws -> String {
        let course = Course(semesterId: nil, name: "Merge Test Course")
        try course.insert(db)
        let deck = Deck(courseId: course.id, name: "Merge Test Deck")
        try deck.insert(db)
        return deck.id
    }

    @Test("applyMerges re-points a loser's Review rows onto the survivor")
    func applyMergesRepointsReviews() async throws {
        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            let deckId = try self.makeCourseAndDeck(conn)
            let survivor = card("Encapsulation", "Hiding implementation details.")
            let loser = card("Encapsulation", "Hiding implementation details, reworded.")
            try survivor.insert(conn)
            try loser.insert(conn)
            try DeckCard(deckId: deckId, cardId: survivor.id).insert(conn)
            try DeckCard(deckId: deckId, cardId: loser.id).insert(conn)
            try Review(
                cardId: loser.id, reviewedAt: Date(), grade: 3, source: "flashcards",
                dueAfter: Date(), schedulerVersion: "fsrs-5"
            ).insert(conn)

            try DuplicateDetector.applyMerges(
                [.init(survivorId: survivor.id, losingIds: [loser.id])], db: conn
            )

            let survivorReviews = try Review.filter(Column("cardId") == survivor.id).fetchCount(conn)
            let loserReviews = try Review.filter(Column("cardId") == loser.id).fetchCount(conn)
            #expect(survivorReviews == 1)
            #expect(loserReviews == 0)

            let mergedLoser = try #require(try Card.fetchOne(conn, key: loser.id))
            #expect(mergedLoser.deletedAt != nil)
        }
    }

    @Test("applyMerges drops a loser's DeckCard row instead of colliding when the survivor is already in that deck")
    func applyMergesDropsCollidingDeckCard() async throws {
        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            let deckId = try self.makeCourseAndDeck(conn)
            let survivor = card("Term", "Definition A")
            let loser = card("Term", "Definition A, reworded")
            try survivor.insert(conn)
            try loser.insert(conn)
            // Both already in the same deck -- re-pointing the loser's row
            // as-is would collide with the survivor's own (deckId, cardId)
            // primary key.
            try DeckCard(deckId: deckId, cardId: survivor.id).insert(conn)
            try DeckCard(deckId: deckId, cardId: loser.id).insert(conn)

            try DuplicateDetector.applyMerges(
                [.init(survivorId: survivor.id, losingIds: [loser.id])], db: conn
            )

            let membershipCount = try DeckCard.filter(Column("deckId") == deckId).fetchCount(conn)
            #expect(membershipCount == 1)
            let survivorStillMember = try DeckCard
                .filter(Column("deckId") == deckId).filter(Column("cardId") == survivor.id)
                .fetchCount(conn)
            #expect(survivorStillMember == 1)
        }
    }

    @Test("applyMerges drops a loser's DeckCard membership in a different deck rather than giving the survivor a second deck")
    func applyMergesDropsMembershipInADifferentDeck() async throws {
        // Regression test: an earlier version of `applyMerges` moved this
        // membership onto the survivor instead of dropping it, which put
        // one card in two decks of the same course -- a state nothing
        // else in the app expects. That crashed `AppStore.cards(inDecks:)`
        // for real, the first time this shipped.
        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Merge Test Course")
            try course.insert(conn)
            let deckA = Deck(courseId: course.id, name: "Deck A")
            let deckB = Deck(courseId: course.id, name: "Deck B")
            try deckA.insert(conn)
            try deckB.insert(conn)

            let survivor = card("Term", "Definition A")
            let loser = card("Term", "Definition A, reworded")
            try survivor.insert(conn)
            try loser.insert(conn)
            try DeckCard(deckId: deckA.id, cardId: survivor.id).insert(conn)
            try DeckCard(deckId: deckB.id, cardId: loser.id).insert(conn)

            try DuplicateDetector.applyMerges(
                [.init(survivorId: survivor.id, losingIds: [loser.id])], db: conn
            )

            let survivorDeckIds = Set(
                try DeckCard.filter(Column("cardId") == survivor.id).fetchAll(conn).map(\.deckId)
            )
            #expect(survivorDeckIds == Set([deckA.id]))
            #expect(try DeckCard.filter(Column("deckId") == deckB.id).fetchCount(conn) == 0)
        }
    }

    @Test("applyMerges keeps the survivor's own LearnState and discards a loser's")
    func applyMergesPrefersSurvivorLearnState() async throws {
        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            let deckId = try self.makeCourseAndDeck(conn)
            let survivor = card("Term", "Definition")
            let loser = card("Term", "Definition, reworded")
            try survivor.insert(conn)
            try loser.insert(conn)
            try DeckCard(deckId: deckId, cardId: survivor.id).insert(conn)
            try DeckCard(deckId: deckId, cardId: loser.id).insert(conn)
            try LearnState(cardId: survivor.id, level: 3, consecutiveCorrect: 4).save(conn)
            try LearnState(cardId: loser.id, level: 1, consecutiveCorrect: 0).save(conn)

            try DuplicateDetector.applyMerges(
                [.init(survivorId: survivor.id, losingIds: [loser.id])], db: conn
            )

            let survivorState = try #require(try LearnState.fetchOne(conn, key: survivor.id))
            #expect(survivorState.level == 3) // untouched, not overwritten by the loser's
            #expect(try LearnState.fetchOne(conn, key: loser.id) == nil)
        }
    }

    @Test("applyMerges carries a loser's LearnState over when the survivor has none")
    func applyMergesCarriesOverLearnStateWhenSurvivorHasNone() async throws {
        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            let deckId = try self.makeCourseAndDeck(conn)
            let survivor = card("Term", "Definition")
            let loser = card("Term", "Definition, reworded")
            try survivor.insert(conn)
            try loser.insert(conn)
            try DeckCard(deckId: deckId, cardId: survivor.id).insert(conn)
            try DeckCard(deckId: deckId, cardId: loser.id).insert(conn)
            try LearnState(cardId: loser.id, level: 2, consecutiveCorrect: 1).save(conn)

            try DuplicateDetector.applyMerges(
                [.init(survivorId: survivor.id, losingIds: [loser.id])], db: conn
            )

            let survivorState = try #require(try LearnState.fetchOne(conn, key: survivor.id))
            #expect(survivorState.level == 2)
            #expect(try LearnState.fetchOne(conn, key: loser.id) == nil)
        }
    }
}
