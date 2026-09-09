import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// `VaultScanner.importPaths(_:intoCourse:)` -- the manual counterpart to
/// `scan(vaultRoot:)`. Exercises it against a synthetic temp directory
/// standing in for "wherever the user's file picker happened to land",
/// deliberately outside any `College/<Semester>/<Course>` structure, since
/// that structure is exactly what this entry point must not require.
@Suite("ManualImport")
struct ManualImportTests {
    private func makeCourse(_ db: GRASPDatabase) async throws -> String {
        try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Manual Course")
            try course.insert(conn)
            return course.id
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-manual-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("importing a single picked file attaches it to the given course")
    func importsSingleFile() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let dir = try makeTempDir()
        // isStudyWorthy requires at least 30 words in the reflowed body, so
        // this pads past that floor rather than relying on two short pairs.
        let note = """
        Homeostasis
        The maintenance of a stable internal environment despite external change,
        covering temperature, pH, and fluid balance across the whole organism.

        Osmosis
        The movement of water across a semi-permeable membrane from an area of
        low solute concentration to an area of high solute concentration.
        """
        let fileURL = dir.appendingPathComponent("Extra Credit Notes.md")
        try note.write(to: fileURL, atomically: true, encoding: .utf8)

        let scanner = VaultScanner(database: db)
        let summary = try await scanner.importPaths([fileURL], intoCourse: courseId)

        #expect(summary.filesImportedOrUpdated == 1)
        #expect(summary.cardsCreated == 2)
        try await db.queue.read { conn in
            let material = try #require(try Material.filter(Column("courseId") == courseId).fetchOne(conn))
            #expect(material.title == "Extra Credit Notes")
            #expect(material.extractionState == .ok)
        }
    }

    @Test("importing a folder walks it recursively into the same course")
    func importsFolderRecursively() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let dir = try makeTempDir()
        let nested = dir.appendingPathComponent("Week 1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try "Mitosis\nCell division producing two genetically identical daughter cells"
            .write(to: dir.appendingPathComponent("Top Level.md"), atomically: true, encoding: .utf8)
        try "Meiosis\nCell division producing four genetically distinct gametes"
            .write(to: nested.appendingPathComponent("Nested.md"), atomically: true, encoding: .utf8)

        let scanner = VaultScanner(database: db)
        let summary = try await scanner.importPaths([dir], intoCourse: courseId)

        #expect(summary.filesImportedOrUpdated == 2)
        try await db.queue.read { conn in
            let count = try Material.filter(Column("courseId") == courseId).fetchCount(conn)
            #expect(count == 2)
        }
    }

    @Test("a manually-added course with no folderPath is untouched by a vault scan")
    func manualCourseSurvivesVaultScan() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let dir = try makeTempDir()
        try "Term\nA definition long enough to actually count as one, honestly"
            .write(to: dir.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        let scanner = VaultScanner(database: db)
        _ = try await scanner.importPaths([dir], intoCourse: courseId)

        // An unrelated vault scan (empty vault root here) must not touch,
        // duplicate, or orphan what was just manually imported.
        let emptyVaultRoot = try makeTempDir()
        _ = try await scanner.scan(vaultRoot: emptyVaultRoot)

        try await db.queue.read { conn in
            let count = try Material.filter(Column("courseId") == courseId).fetchCount(conn)
            #expect(count == 1)
        }
    }

    @Test("re-importing the same file is idempotent")
    func reimportIsIdempotent() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("Note.md")
        try "Term\nA definition long enough to actually count as one, honestly"
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let scanner = VaultScanner(database: db)
        _ = try await scanner.importPaths([fileURL], intoCourse: courseId)
        let second = try await scanner.importPaths([fileURL], intoCourse: courseId)

        #expect(second.filesUnchanged == 1)
        #expect(second.filesImportedOrUpdated == 0)
    }

    @Test("a non-existent course id fails without touching anything")
    func rejectsUnknownCourse() async throws {
        let db = try GRASPDatabase.inMemory()
        let dir = try makeTempDir()
        try "Term\nA definition long enough to actually count as one, honestly"
            .write(to: dir.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        let scanner = VaultScanner(database: db)
        let summary = try await scanner.importPaths([dir], intoCourse: "not-a-real-course")

        #expect(!summary.errors.isEmpty)
        try await db.queue.read { conn in
            let count = try Material.fetchCount(conn)
            #expect(count == 0)
        }
    }

    @Test("an unsupported file extension in a picked folder is silently skipped")
    func skipsUnsupportedExtensions() async throws {
        let db = try GRASPDatabase.inMemory()
        let courseId = try await makeCourse(db)
        let dir = try makeTempDir()
        try "not a note".write(to: dir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try "Term\nA definition long enough to actually count as one, honestly"
            .write(to: dir.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        let scanner = VaultScanner(database: db)
        let summary = try await scanner.importPaths([dir], intoCourse: courseId)

        #expect(summary.filesScanned == 1)
        #expect(summary.filesImportedOrUpdated == 1)
    }
}
