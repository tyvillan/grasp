import Foundation
import GRDB
import Testing
@testable import GRASPCore

@Suite("Add files to a deck")
struct ImportIntoDeckTests {
    private let note = """
    Sunk cost
    A cost that has already been incurred and cannot be recovered by
    any future decision or action taken now, regardless of how the
    remaining choices in front of a person are ultimately weighed.
    """

    private func tempFile(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-into-deck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try note.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func setup() async throws -> (GRASPDatabase, courseId: String, deckId: String) {
        let db = try GRASPDatabase.inMemory()
        let ids: (String, String) = try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Systems")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Missed Lecture", chapter: nil)
            try deck.insert(conn)
            return (course.id, deck.id)
        }
        return (db, ids.0, ids.1)
    }

    private func deckName(ofCardFronted front: String, db: GRASPDatabase) async throws -> String? {
        try await db.queue.read { conn in
            try String.fetchOne(conn, sql: """
                SELECT d.name FROM card c JOIN deckCard dc ON dc.cardId = c.id
                JOIN deck d ON d.id = dc.deckId WHERE c.front = ?
                """, arguments: [front])
        }
    }

    @Test("without a deck, cards go where the file's name says, as before")
    func defaultDeck() async throws {
        let (db, courseId, _) = try await setup()
        let scanner = VaultScanner(database: db)
        _ = try await scanner.importPaths([try tempFile("Lecture.md")], intoCourse: courseId)
        #expect(try await deckName(ofCardFronted: "Sunk cost", db: db) == "General")
    }

    @Test("with a deck, the file's cards land in that deck")
    func cardsLandInDeck() async throws {
        let (db, courseId, deckId) = try await setup()
        let scanner = VaultScanner(database: db)
        let summary = try await scanner.importPaths(
            [try tempFile("Lecture.md")], intoCourse: courseId, intoDeck: deckId)
        #expect(summary.cardsCreated == 1)
        #expect(try await deckName(ofCardFronted: "Sunk cost", db: db) == "Missed Lecture")
    }

    @Test("a file already imported into General moves its drafts when added to a deck")
    func reimportMovesDrafts() async throws {
        let (db, courseId, deckId) = try await setup()
        let scanner = VaultScanner(database: db)
        let url = try tempFile("Lecture.md")
        _ = try await scanner.importPaths([url], intoCourse: courseId)
        #expect(try await deckName(ofCardFronted: "Sunk cost", db: db) == "General")

        let again = try await scanner.importPaths([url], intoCourse: courseId, intoDeck: deckId)
        #expect(again.filesUnchanged == 0)
        #expect(try await deckName(ofCardFronted: "Sunk cost", db: db) == "Missed Lecture")
        let cards = try await db.queue.read { try Card.filter(Column("front") == "Sunk cost").fetchCount($0) }
        #expect(cards == 1)
    }

    @Test("a deck from another course is ignored, not written into")
    func wrongCourseDeckIgnored() async throws {
        let (db, courseId, _) = try await setup()
        let otherDeck = try await db.queue.write { conn -> String in
            let other = Course(semesterId: nil, name: "Other")
            try other.insert(conn)
            let deck = Deck(courseId: other.id, name: "Elsewhere", chapter: nil)
            try deck.insert(conn)
            return deck.id
        }
        let scanner = VaultScanner(database: db)
        _ = try await scanner.importPaths(
            [try tempFile("Lecture.md")], intoCourse: courseId, intoDeck: otherDeck)
        #expect(try await deckName(ofCardFronted: "Sunk cost", db: db) == "General")
    }
}
