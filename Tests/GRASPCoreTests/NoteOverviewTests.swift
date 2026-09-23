import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// Covers the v7 migration, the staleness rule, and the deck-to-material
/// join. That join is the one piece of SQL in this feature with a real trap
/// in it -- `card.materialId` is nullable for two different reasons -- which
/// is why it lives in `GRASPCore` and is tested directly rather than
/// mirrored as a private helper the way `AppStore`'s statements are.
@Suite("Note overview")
struct NoteOverviewTests {

    private func makeCourse(_ db: GRASPDatabase) async throws -> String {
        try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Biology")
            try course.insert(conn)
            return course.id
        }
    }

    private func makeMaterial(
        _ db: GRASPDatabase, courseId: String, title: String,
        hash: String? = "hash-1", noteDate: Date? = nil, deleted: Bool = false
    ) async throws -> String {
        try await db.queue.write { conn in
            let material = Material(
                courseId: courseId, relativePath: "/vault/\(title).md", kind: .markdown,
                contentHash: hash, title: title, noteDate: noteDate,
                deletedAt: deleted ? Date() : nil
            )
            try material.insert(conn)
            return material.id
        }
    }

    private func makeDeck(_ db: GRASPDatabase, courseId: String) async throws -> String {
        try await db.queue.write { conn in
            let deck = Deck(courseId: courseId, name: "Chapter 1")
            try deck.insert(conn)
            return deck.id
        }
    }

    @discardableResult
    private func makeCard(
        _ db: GRASPDatabase, deckId: String, materialId: String?, deleted: Bool = false
    ) async throws -> String {
        try await db.queue.write { conn in
            let card = Card(
                materialId: materialId, front: "Q", back: "A",
                origin: materialId == nil ? .manual : .parser,
                status: .active, deletedAt: deleted ? Date() : nil
            )
            try card.insert(conn)
            try DeckCard(deckId: deckId, cardId: card.id).insert(conn)
            return card.id
        }
    }

    private func makeOverview(
        _ db: GRASPDatabase, materialId: String, hash: String?
    ) async throws {
        try await db.queue.write { conn in
            try NoteOverview(
                materialId: materialId,
                bodyJSON: OverviewCoding.encode(OverviewDocument(
                    sections: [OverviewSection(heading: "A claim", paragraphs: ["Explained."])]
                )),
                sourceContentHash: hash, generator: .ollama
            ).save(conn)
        }
    }

    // MARK: - Migration and record

    @Test("migrates to v7 and stores an overview round-trip")
    func migrationAndRoundTrip() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let materialId = try await makeMaterial(db, courseId: courseId, title: "Lecture 1")

        let document = OverviewDocument(
            title: "A cell divides in four fixed stages",
            sections: [OverviewSection(
                heading: "The stages always run in the same order",
                paragraphs: ["Four stages, always in the same order."],
                terms: [OverviewDefinition(term: "Chromatid", text: "A copy.")]
            )]
        )
        try await db.queue.write { conn in
            try NoteOverview(
                materialId: materialId, bodyJSON: OverviewCoding.encode(document),
                mermaidSource: "graph TD\nA-->B", sourceContentHash: "hash-1",
                sourceWordCount: 400, chunkCount: 1, generator: .ollama,
                model: "qwen2.5:7b-instruct"
            ).insert(conn)
        }

        try await db.queue.read { conn in
            let stored = try #require(try NoteOverview.fetchOne(conn, key: materialId))
            #expect(stored.generator == .ollama)
            #expect(stored.model == "qwen2.5:7b-instruct")
            #expect(stored.mermaidSource == "graph TD\nA-->B")
            #expect(stored.document() == document)
        }
    }

    @Test("deleting a material takes its overview with it")
    func cascadeDelete() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let materialId = try await makeMaterial(db, courseId: courseId, title: "Lecture 1")
        try await makeOverview(db, materialId: materialId, hash: "hash-1")

        try await db.queue.write { conn in
            _ = try Material.deleteOne(conn, key: materialId)
        }
        let remaining = try await db.queue.read { conn in try NoteOverview.fetchCount(conn) }
        #expect(remaining == 0)
    }

    // MARK: - Staleness

    @Test("is fresh while the note's hash is unchanged and stale once it moves")
    func staleness() {
        let material = Material(
            courseId: "c1", relativePath: "/a.md", kind: .markdown,
            contentHash: "hash-1", title: "A"
        )
        let fresh = NoteOverview(
            materialId: material.id, bodyJSON: "{}", sourceContentHash: "hash-1", generator: .ollama
        )
        #expect(!fresh.isStale(for: material))

        let stale = NoteOverview(
            materialId: material.id, bodyJSON: "{}", sourceContentHash: "hash-0", generator: .ollama
        )
        #expect(stale.isStale(for: material))
    }

    @Test("treats a body from an older document shape as stale")
    func schemaVersionMismatchIsStale() {
        let material = Material(
            courseId: "c1", relativePath: "/a.md", kind: .markdown,
            contentHash: "hash-1", title: "A"
        )
        let old = NoteOverview(
            materialId: material.id, bodyJSON: "{}",
            bodySchemaVersion: NoteOverview.currentBodySchemaVersion - 1,
            sourceContentHash: "hash-1", generator: .ollama
        )
        #expect(old.isStale(for: material))
        #expect(old.document() == nil)
    }

    @Test("reports fresh when the note has no hash to compare against")
    func noHashMeansNoNag() {
        // Otherwise the badge would say "out of date" forever: rewriting
        // stores the same nil back, so nothing could ever clear it.
        let material = Material(
            courseId: "c1", relativePath: "/a.md", kind: .markdown,
            contentHash: nil, title: "A"
        )
        let overview = NoteOverview(
            materialId: material.id, bodyJSON: "{}", sourceContentHash: nil, generator: .ollama
        )
        #expect(!overview.isStale(for: material))
    }

    // MARK: - The deck to material join

    @Test("finds the notes behind a deck through its cards")
    func materialsForDeck() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckId = try await makeDeck(db, courseId: courseId)
        let first = try await makeMaterial(db, courseId: courseId, title: "Lecture 1")
        let second = try await makeMaterial(db, courseId: courseId, title: "Lecture 2")
        try await makeCard(db, deckId: deckId, materialId: first)
        try await makeCard(db, deckId: deckId, materialId: second)

        let found = try await db.queue.read { conn in
            try OverviewQueries.materials(forDecks: [deckId], db: conn)
        }
        #expect(found.count == 2)
    }

    @Test("ignores hand-typed cards, which have no note behind them")
    func handTypedCardsContributeNothing() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckId = try await makeDeck(db, courseId: courseId)
        try await makeCard(db, deckId: deckId, materialId: nil)

        let found = try await db.queue.read { conn in
            try OverviewQueries.materials(forDecks: [deckId], db: conn)
        }
        #expect(found.isEmpty)
    }

    @Test("ignores soft-deleted cards and soft-deleted materials")
    func softDeletesAreExcluded() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckId = try await makeDeck(db, courseId: courseId)
        let live = try await makeMaterial(db, courseId: courseId, title: "Live")
        let viaDeletedCard = try await makeMaterial(db, courseId: courseId, title: "Orphan")
        let deletedMaterial = try await makeMaterial(
            db, courseId: courseId, title: "Gone", deleted: true
        )
        try await makeCard(db, deckId: deckId, materialId: live)
        try await makeCard(db, deckId: deckId, materialId: viaDeletedCard, deleted: true)
        try await makeCard(db, deckId: deckId, materialId: deletedMaterial)

        let found = try await db.queue.read { conn in
            try OverviewQueries.materials(forDecks: [deckId], db: conn)
        }
        #expect(found.map(\.title) == ["Live"])
    }

    @Test("lists a note once however many of its cards are in the deck")
    func materialsAreDistinct() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckId = try await makeDeck(db, courseId: courseId)
        let materialId = try await makeMaterial(db, courseId: courseId, title: "Lecture 1")
        for _ in 0..<5 { try await makeCard(db, deckId: deckId, materialId: materialId) }

        let found = try await db.queue.read { conn in
            try OverviewQueries.materials(forDecks: [deckId], db: conn)
        }
        #expect(found.count == 1)
    }

    @Test("reads in note-date order with undated notes last")
    func orderedByNoteDate() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckId = try await makeDeck(db, courseId: courseId)
        let undated = try await makeMaterial(db, courseId: courseId, title: "Undated", noteDate: nil)
        let later = try await makeMaterial(
            db, courseId: courseId, title: "Later", noteDate: Date(timeIntervalSince1970: 2_000_000)
        )
        let earlier = try await makeMaterial(
            db, courseId: courseId, title: "Earlier", noteDate: Date(timeIntervalSince1970: 1_000_000)
        )
        for id in [undated, later, earlier] {
            try await makeCard(db, deckId: deckId, materialId: id)
        }

        let found = try await db.queue.read { conn in
            try OverviewQueries.materials(forDecks: [deckId], db: conn)
        }
        #expect(found.map(\.title) == ["Earlier", "Later", "Undated"])
    }

    @Test("returns nothing for an empty deck list rather than every material")
    func emptyDeckList() async throws {
        let db = try GRASPDatabase.inMemory()
        let found = try await db.queue.read { conn in
            try OverviewQueries.materials(forDecks: [], db: conn)
        }
        #expect(found.isEmpty)
    }

    // MARK: - Status

    @Test("counts coverage and staleness per deck")
    func statusByDeck() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckId = try await makeDeck(db, courseId: courseId)
        let fresh = try await makeMaterial(db, courseId: courseId, title: "Fresh", hash: "h1")
        let stale = try await makeMaterial(db, courseId: courseId, title: "Stale", hash: "h2")
        let missing = try await makeMaterial(db, courseId: courseId, title: "Missing", hash: "h3")
        for id in [fresh, stale, missing] {
            try await makeCard(db, deckId: deckId, materialId: id)
        }
        try await makeOverview(db, materialId: fresh, hash: "h1")
        try await makeOverview(db, materialId: stale, hash: "old")

        let status = try await db.queue.read { conn in
            try OverviewQueries.statusByDeck(db: conn)
        }
        let deck = try #require(status[deckId])
        #expect(deck.materialCount == 3)
        #expect(deck.overviewCount == 2)
        #expect(deck.staleCount == 1)
        #expect(!deck.isComplete)
    }

    @Test("does not call a note stale when it has no hash at all")
    func statusHonoursTheNoHashRule() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let deckId = try await makeDeck(db, courseId: courseId)
        let hashless = try await makeMaterial(db, courseId: courseId, title: "Hashless", hash: nil)
        try await makeCard(db, deckId: deckId, materialId: hashless)
        try await makeOverview(db, materialId: hashless, hash: nil)

        let status = try await db.queue.read { conn in
            try OverviewQueries.statusByDeck(db: conn)
        }
        // Must agree with `NoteOverview.isStale(for:)`, or the tab badge
        // and the banner would contradict each other on screen.
        #expect(status[deckId]?.staleCount == 0)
        #expect(status[deckId]?.isComplete == true)
    }
}
