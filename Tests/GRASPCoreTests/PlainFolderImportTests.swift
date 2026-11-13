import Foundation
import Testing
import GRDB
@testable import GRASPCore

@Suite("Importing an ordinary folder")
struct PlainFolderImportTests {
    private let body = """
    Sunk cost
    A cost that has already been incurred and cannot be recovered by
    any future decision or action taken now, regardless of how the
    remaining choices in front of a person are ultimately weighed.
    """

    private func makeFolder(_ layout: [String: [String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
        for (course, files) in layout {
            let dir = root.appendingPathComponent(course)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in files { try body.write(to: dir.appendingPathComponent(file), atomically: false, encoding: .utf8) }
        }
        return root
    }

    @Test("each folder inside becomes a course, filed under the chosen time frame")
    func foldersBecomeCourses() async throws {
        let db = try GRASPDatabase.inMemory()
        let root = try makeFolder(["Biology": ["a.md"], "Chemistry": ["b.md"]])
        // A folder whose notes are identical would be skipped as a duplicate card, so vary one.
        try (body + " Extra words so the second note is its own.").write(
            to: root.appendingPathComponent("Chemistry/b.md"), atomically: false, encoding: .utf8)
        let summary = try await VaultScanner(database: db).scanFolders(root: root, timeframe: "Fall 2026")
        #expect(summary.filesImportedOrUpdated == 2 && summary.errors.isEmpty)
        let (names, terms) = try await db.queue.read { conn -> ([String], [String?]) in
            let courses = try Course.order(Column("name")).fetchAll(conn)
            let semesters = try Semester.fetchAll(conn)
            return (courses.map(\.name), courses.map { c in semesters.first { $0.id == c.semesterId }?.name })
        }
        #expect(names == ["Biology", "Chemistry"])
        #expect(terms == ["Fall 2026", "Fall 2026"])
        // Again: nothing changes.
        let again = try await VaultScanner(database: db).scanFolders(root: root, timeframe: "Fall 2026")
        #expect(again.filesImportedOrUpdated == 0 && again.filesUnchanged == 2)
        #expect(try await db.queue.read { try Course.fetchCount($0) } == 2)
    }

    @Test("a folder with no folders inside is one course, and hidden or tool folders are not courses")
    func singleCourseAndIgnored() async throws {
        let db = try GRASPDatabase.inMemory()
        let root = try makeFolder([:])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body.write(to: root.appendingPathComponent("n.md"), atomically: false, encoding: .utf8)
        _ = try await VaultScanner(database: db).scanFolders(root: root)
        let courses = try await db.queue.read { try Course.fetchAll($0).map(\.name) }
        #expect(courses == [root.lastPathComponent])

        let other = try makeFolder(["Math": ["m.md"], ".obsidian": ["junk.md"], ".git": ["x.md"]])
        let db2 = try GRASPDatabase.inMemory()
        _ = try await VaultScanner(database: db2).scanFolders(root: other)
        #expect(try await db2.queue.read { try Course.fetchAll($0).map(\.name) } == ["Math"])
        #expect(try await db2.queue.read { try Course.fetchOne($0)?.semesterId } == nil)
    }

    @Test("a folder with a College folder is read as a vault")
    func detectsVaultLayout() throws {
        let root = try makeFolder(["College/Side": ["a.md"]])
        #expect(VaultScanner.hasVaultLayout(root))
        #expect(!VaultScanner.hasVaultLayout(try makeFolder(["Biology": ["a.md"]])))
    }
}
