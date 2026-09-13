import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// `GRASPCoreTests` can't import `AppStore` (see `DeckManagementTests`'s
/// note on the same convention), so these mirror the exact statements
/// `AppStore.findOrCreateSemester(name:)` and `AppStore.unfiledCourses`
/// run, for the freeform-timeline-input feature.
@Suite("Timeline")
struct TimelineTests {
    private static func slugify(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(
            of: "[^a-z0-9]+", with: "-", options: .regularExpression
        )
        let trimmed = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? text.lowercased() : trimmed
    }

    // Mirrors AppStore.findOrCreateSemester(name:).
    private func findOrCreateSemester(name: String, db: GRASPDatabase) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.slugify(trimmed)
        return try await db.queue.write { conn -> String in
            if let existing = try Semester.filter(Column("slug") == slug).fetchOne(conn) {
                return existing.id
            }
            let nextSortKey = (try Int.fetchOne(conn, sql: "SELECT COALESCE(MAX(sortKey), 0) + 1 FROM semester")) ?? 1
            let semester = Semester(name: trimmed, slug: slug, sortKey: nextSortKey)
            try semester.insert(conn)
            return semester.id
        }
    }

    @Test("a brand-new freeform timeline creates a semester with a slugified name")
    func createsNewFreeformSemester() async throws {
        let db = try GRASPDatabase.inMemory()
        let id = try await findOrCreateSemester(name: "Quarter 1", db: db)

        try await db.queue.read { conn in
            let semester = try #require(try Semester.fetchOne(conn, key: id))
            #expect(semester.name == "Quarter 1")
            #expect(semester.slug == "quarter-1")
        }
    }

    @Test("typing the same freeform timeline twice reuses the same row")
    func reusesExistingSemesterOnRepeat() async throws {
        let db = try GRASPDatabase.inMemory()
        let first = try await findOrCreateSemester(name: "2026-2027", db: db)
        let second = try await findOrCreateSemester(name: "2026-2027", db: db)
        #expect(first == second)

        try await db.queue.read { conn in
            let count = try Semester.fetchCount(conn)
            #expect(count == 1)
        }
    }

    @Test("a timeline made entirely of non-alphanumeric characters still dedupes on repeat")
    func nonAlphanumericTimelineStillDedupes() async throws {
        // Every character here falls outside [a-z0-9], so the slugifier's
        // regex-based reduction collapses to "" -- this is the exact case
        // that used to fall back to a fresh random UUID per call, which
        // meant typing the identical text twice created two rows instead
        // of reusing the first.
        let db = try GRASPDatabase.inMemory()
        let first = try await findOrCreateSemester(name: "秋季", db: db)
        let second = try await findOrCreateSemester(name: "秋季", db: db)
        #expect(first == second)

        try await db.queue.read { conn in
            let count = try Semester.fetchCount(conn)
            #expect(count == 1)
        }
    }

    @Test("typing the exact display name of a vault-created semester resolves to that same row")
    func matchesVaultCreatedSemesterBySlug() async throws {
        let db = try GRASPDatabase.inMemory()
        // What the vault importer's own SemesterSlug scheme would have
        // produced for a "Fall Semester 2026" folder tagged fall-2026.
        let (importedSlug, importedName, importedSortKey) = SemesterSlug.resolve(
            tags: ["fall-2026"], folderName: ""
        )
        let importedId = try await db.queue.write { conn -> String in
            let semester = Semester(name: importedName, slug: importedSlug, sortKey: importedSortKey)
            try semester.insert(conn)
            return semester.id
        }

        let handTypedId = try await findOrCreateSemester(name: "Fall 2026", db: db)
        #expect(handTypedId == importedId)

        try await db.queue.read { conn in
            let count = try Semester.fetchCount(conn)
            #expect(count == 1)
        }
    }

    @Test("a new freeform semester sorts after every existing one")
    func newSemesterSortsLast() async throws {
        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            try Semester(name: "Fall 2025", slug: "fall-2025", sortKey: 20253).insert(conn)
            try Semester(name: "Spring 2026", slug: "spring-2026", sortKey: 20261).insert(conn)
        }

        let id = try await findOrCreateSemester(name: "Quarter 1", db: db)

        try await db.queue.read { conn in
            let newSemester = try #require(try Semester.fetchOne(conn, key: id))
            let maxExisting = try Int.fetchOne(conn, sql:
                "SELECT MAX(sortKey) FROM semester WHERE id != ?", arguments: [id]
            ) ?? 0
            #expect(newSemester.sortKey > maxExisting)
        }
    }

    /// A minimal synthetic vault -- `<root>/College/<semester folder>/<course
    /// folder>/Note.md` -- tagged with a real semester so `VaultScanner`
    /// resolves it through `SemesterSlug`, not the freeform path. Discovers
    /// its own path via `contentsOfDirectory` on the parent (matching
    /// `FolderExclusionTests`' fixture) so it's byte-identical to what
    /// `VaultScanner` itself sees, sidestepping the `/var` vs `/private/var`
    /// symlink mismatch `FileManager.temporaryDirectory` alone doesn't
    /// resolve reliably.
    private func makeFakeVault() throws -> URL {
        let tempBase = FileManager.default.temporaryDirectory
        let dirName = "grasp-timeline-\(UUID().uuidString)"
        let root = tempBase.appendingPathComponent(dirName, isDirectory: true)
        let courseDir = root
            .appendingPathComponent("College", isDirectory: true)
            .appendingPathComponent("Fall Semester 2026", isDirectory: true)
            .appendingPathComponent("Test Course", isDirectory: true)
        try FileManager.default.createDirectory(at: courseDir, withIntermediateDirectories: true)

        let note = """
        ---
        tags: [college, fall-2026, lecture]
        ---

        # A Note

        Some content long enough to be worth a card, definitely.
        """
        try note.write(to: courseDir.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        let discovered = try FileManager.default
            .contentsOfDirectory(at: tempBase, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent == dirName }
        return discovered ?? root
    }

    @Test("a real vault import corrects a freeform semester's placeholder sortKey once its true chronology is known")
    func vaultImportReconcilesFreeformSortKey() async throws {
        let vaultRoot = try makeFakeVault()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let db = try GRASPDatabase.inMemory()
        // Simulates typing "Fall 2026" by hand (AppStore.findOrCreateSemester(name:))
        // before the vault ever imports anything tagged fall-2026 -- it
        // only ever gets a small placeholder sortKey, not the real
        // year*10+termOrder value.
        let placeholderId = try await db.queue.write { conn -> String in
            let semester = Semester(name: "Fall 2026", slug: "fall-2026", sortKey: 1)
            try semester.insert(conn)
            return semester.id
        }

        _ = try await VaultScanner(database: db).scan(vaultRoot: vaultRoot)

        try await db.queue.read { conn in
            let count = try Semester.fetchCount(conn)
            #expect(count == 1) // reconciled in place, not duplicated
            let semester = try #require(try Semester.fetchOne(conn, key: placeholderId))
            let (_, _, realSortKey) = SemesterSlug.resolve(tags: ["fall-2026"], folderName: "")
            #expect(semester.sortKey == realSortKey)
            #expect(semester.sortKey != 1)
        }
    }

    @Test("a folder-backed course with no timeline now groups alongside a manually-added one")
    func unfiledCoursesIncludesFolderBackedCourses() async throws {
        // Mirrors AppStore.unfiledCourses / reload()'s coursesBySemester
        // grouping -- the fix broadens this from "manually-added only" to
        // "every course with no timeline", so a vault-imported course with
        // no semester is no longer invisible in the sidebar.
        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            try Course(semesterId: nil, name: "Manually Added", folderPath: nil).insert(conn)
            try Course(semesterId: nil, name: "From The Vault", folderPath: "/vault/Some Course").insert(conn)
        }

        try await db.queue.read { conn in
            let courses = try Course.filter(Column("isArchived") == false).fetchAll(conn)
            let coursesBySemester = Dictionary(grouping: courses, by: \.semesterId)
            let unfiled = coursesBySemester[nil] ?? []
            #expect(unfiled.count == 2)
            #expect(unfiled.contains { $0.name == "Manually Added" })
            #expect(unfiled.contains { $0.name == "From The Vault" })
        }
    }
}
