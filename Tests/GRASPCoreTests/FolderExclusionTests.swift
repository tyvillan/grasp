import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// `ExcludedFolder` is what makes deleting a vault-backed course actually
/// permanent -- without it, the next `scan(vaultRoot:)` finds no existing
/// `Course` row for that folder and just creates a fresh one, exactly as
/// if the folder had never been seen before. These mirror the exact
/// statements `AppStore.excludeFolder`/`removeCourseAndExclude` run, per
/// this test target's usual "AppStore itself isn't reachable from here"
/// convention (see `CourseDeletionTests`, `DeckManagementTests`).
@Suite("FolderExclusion")
struct FolderExclusionTests {
    /// `temporaryDirectory` starts from an unresolved `/var/...` symlink
    /// path, and `URL.resolvingSymlinksInPath()` turned out not to
    /// reliably resolve it back to the `/private/var/...` form `Foundation`'s
    /// own directory-listing APIs return -- what `VaultScanner` actually
    /// walks with. So instead of trusting either, this discovers the root
    /// the exact same way the scanner would: by listing its parent
    /// directory and taking the matching entry.
    private func makeFakeVault() throws -> URL {
        let tempBase = FileManager.default.temporaryDirectory
        let dirName = "lectern-exclusion-\(UUID().uuidString)"
        let root = tempBase.appendingPathComponent(dirName, isDirectory: true)
        let courseDir = root
            .appendingPathComponent("College", isDirectory: true)
            .appendingPathComponent("Fall Semester 2025-2026", isDirectory: true)
            .appendingPathComponent("Club Baseball", isDirectory: true)
        try FileManager.default.createDirectory(at: courseDir, withIntermediateDirectories: true)

        let note = """
        ---
        tags: [college, fall-2025, lecture]
        ---

        # Practice Schedule

        Batting practice
        Every Tuesday and Thursday at 4pm on the intramural fields, weather permitting.

        Team dues
        Fifty dollars per semester, due before the first scrimmage of the season.
        """
        try note.write(to: courseDir.appendingPathComponent("Schedule.md"), atomically: true, encoding: .utf8)

        let discovered = try FileManager.default
            .contentsOfDirectory(at: tempBase, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent == dirName }
        return discovered ?? root
    }

    @Test("a folder excluded before the first scan is never walked or turned into a course")
    func excludedFolderIsNeverImported() async throws {
        let vaultRoot = try makeFakeVault()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let courseDir = vaultRoot
            .appendingPathComponent("College", isDirectory: true)
            .appendingPathComponent("Fall Semester 2025-2026", isDirectory: true)
            .appendingPathComponent("Club Baseball", isDirectory: true)

        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            try ExcludedFolder(folderPath: courseDir.path).insert(conn)
        }

        let summary = try await VaultScanner(database: db).scan(vaultRoot: vaultRoot)
        #expect(summary.filesScanned == 0)
        #expect(summary.errors.isEmpty)

        try await db.queue.read { conn in
            let course = try Course.filter(Column("name") == "Club Baseball").fetchOne(conn)
            let materialCount = try Material.fetchCount(conn)
            #expect(course == nil)
            #expect(materialCount == 0)
        }
    }

    @Test("a non-excluded folder imports normally, for contrast")
    func nonExcludedFolderImportsNormally() async throws {
        let vaultRoot = try makeFakeVault()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let db = try GRASPDatabase.inMemory()
        let summary = try await VaultScanner(database: db).scan(vaultRoot: vaultRoot)
        #expect(summary.filesScanned == 1)

        try await db.queue.read { conn in
            let course = try Course.filter(Column("name") == "Club Baseball").fetchOne(conn)
            #expect(course != nil)
        }
    }

    @Test("excluding, then deleting, a real vault-backed course keeps it from coming back on rescan")
    func excludedCourseStaysGoneAfterRescan() async throws {
        let db = try await VaultFixture.database()

        let (courseId, folderPath) = try await db.queue.read { conn -> (String, String) in
            let course = try #require(try Course.filter(Column("name") == "Physical Geology").fetchOne(conn))
            return (course.id, try #require(course.folderPath))
        }

        // Mirrors AppStore.removeCourseAndExclude exactly.
        try await db.queue.write { conn in
            try ExcludedFolder(folderPath: folderPath).insert(conn)
            try conn.execute(sql: """
                DELETE FROM card WHERE id IN (
                    SELECT cardId FROM deckCard WHERE deckId IN (SELECT id FROM deck WHERE courseId = ?)
                )
                """, arguments: [courseId])
            _ = try Course.deleteOne(conn, key: courseId)
        }

        _ = try await VaultScanner(database: db).scan(vaultRoot: VaultFixture.root)

        try await db.queue.read { conn in
            let course = try Course.filter(Column("name") == "Physical Geology").fetchOne(conn)
            #expect(course == nil)
        }
    }

    @Test("deleting a real vault-backed course WITHOUT excluding it does resurrect on rescan -- the exact bug this feature fixes")
    func plainDeleteWithoutExclusionResurrectsOnRescan() async throws {
        let db = try await VaultFixture.database()

        let courseId = try await db.queue.read { conn in
            try #require(try Course.filter(Column("name") == "Physical Geology").fetchOne(conn)).id
        }
        try await db.queue.write { conn in
            try conn.execute(sql: """
                DELETE FROM card WHERE id IN (
                    SELECT cardId FROM deckCard WHERE deckId IN (SELECT id FROM deck WHERE courseId = ?)
                )
                """, arguments: [courseId])
            _ = try Course.deleteOne(conn, key: courseId)
        }
        try await db.queue.read { conn in
            let course = try Course.filter(Column("name") == "Physical Geology").fetchOne(conn)
            #expect(course == nil)
        }

        _ = try await VaultScanner(database: db).scan(vaultRoot: VaultFixture.root)

        try await db.queue.read { conn in
            let recreated = try Course.filter(Column("name") == "Physical Geology").fetchOne(conn)
            #expect(recreated != nil)
            #expect(recreated?.id != courseId) // a brand new row, not the same course coming back
        }
    }

    @Test("excludeFolder then includeFolder round-trips cleanly")
    func excludeThenIncludeRoundTrips() async throws {
        let db = try GRASPDatabase.inMemory()
        let path = "/tmp/some-fake-course-folder"

        try await db.queue.write { conn in
            try ExcludedFolder(folderPath: path).insert(conn, onConflict: .ignore)
        }
        try await db.queue.read { conn in
            let excluded = try ExcludedFolder.fetchOne(conn, key: path)
            #expect(excluded != nil)
        }

        try await db.queue.write { conn in
            _ = try ExcludedFolder.deleteOne(conn, key: path)
        }
        try await db.queue.read { conn in
            let excluded = try ExcludedFolder.fetchOne(conn, key: path)
            #expect(excluded == nil)
        }
    }

    @Test("manually importing the excluded folder itself lifts the exclusion")
    func manualImportOfExcludedFolderLiftsExclusion() async throws {
        let vaultRoot = try makeFakeVault()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let courseDir = vaultRoot
            .appendingPathComponent("College", isDirectory: true)
            .appendingPathComponent("Fall Semester 2025-2026", isDirectory: true)
            .appendingPathComponent("Club Baseball", isDirectory: true)

        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            try ExcludedFolder(folderPath: courseDir.path).insert(conn)
        }
        let courseId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Club Baseball, Take Two")
            try course.insert(conn)
            return course.id
        }

        _ = try await VaultScanner(database: db).importPaths([courseDir], intoCourse: courseId)

        try await db.queue.read { conn in
            let excluded = try ExcludedFolder.fetchOne(conn, key: courseDir.path)
            #expect(excluded == nil)
        }
    }

    @Test("manually importing a single file inside an excluded folder also lifts it")
    func manualImportOfFileInsideExcludedFolderLiftsExclusion() async throws {
        let vaultRoot = try makeFakeVault()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let courseDir = vaultRoot
            .appendingPathComponent("College", isDirectory: true)
            .appendingPathComponent("Fall Semester 2025-2026", isDirectory: true)
            .appendingPathComponent("Club Baseball", isDirectory: true)
        let fileInside = courseDir.appendingPathComponent("Schedule.md")

        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            try ExcludedFolder(folderPath: courseDir.path).insert(conn)
        }
        let courseId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Club Baseball, Take Two")
            try course.insert(conn)
            return course.id
        }

        _ = try await VaultScanner(database: db).importPaths([fileInside], intoCourse: courseId)

        try await db.queue.read { conn in
            let excluded = try ExcludedFolder.fetchOne(conn, key: courseDir.path)
            #expect(excluded == nil)
        }
    }

    @Test("a plain scan(vaultRoot:) never lifts an exclusion on its own -- only a manual import does")
    func automaticScanNeverLiftsExclusion() async throws {
        let vaultRoot = try makeFakeVault()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let courseDir = vaultRoot
            .appendingPathComponent("College", isDirectory: true)
            .appendingPathComponent("Fall Semester 2025-2026", isDirectory: true)
            .appendingPathComponent("Club Baseball", isDirectory: true)

        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            try ExcludedFolder(folderPath: courseDir.path).insert(conn)
        }

        _ = try await VaultScanner(database: db).scan(vaultRoot: vaultRoot)

        try await db.queue.read { conn in
            let excluded = try ExcludedFolder.fetchOne(conn, key: courseDir.path)
            #expect(excluded != nil)
        }
    }
}
