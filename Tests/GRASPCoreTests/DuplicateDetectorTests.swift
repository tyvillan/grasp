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
        try note.write(to: firstURL, atomically: true, encoding: .utf8)
        try note.write(to: secondURL, atomically: true, encoding: .utf8)

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
}
