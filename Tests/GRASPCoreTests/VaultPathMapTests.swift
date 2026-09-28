import Foundation
import GRDB
import Testing
@testable import GRASPCore

@Suite("VaultPathMap")
struct VaultPathMapTests {
    let map = VaultPathMap(macHome: "/Users/tyler", iCloudDrive: #"C:\Users\Tyler\iCloudDrive"#)
    let mobile = "/Users/tyler/Library/Mobile Documents"

    @Test("an app container gets its Documents folder back, and maps home again")
    func container() {
        let local = "C:/Users/Tyler/iCloudDrive/iCloud~md~obsidian/Master Vault/College/Econ/L1.md"
        let stored = mobile + "/iCloud~md~obsidian/Documents/Master Vault/College/Econ/L1.md"
        #expect(map.stored(forLocal: local) == stored)
        #expect(map.local(forStored: stored) == local)
    }

    @Test("backslashes, a leading slash and drive-letter case all match")
    func windowsSpellings() {
        let stored = mobile + "/iCloud~md~obsidian/Documents/V/a.md"
        #expect(map.stored(forLocal: #"C:\Users\Tyler\iCloudDrive\iCloud~md~obsidian\V\a.md"#) == stored)
        #expect(map.stored(forLocal: "/C:/Users/Tyler/iCloudDrive/iCloud~md~obsidian/V/a.md") == stored)
        #expect(map.stored(forLocal: "c:/users/tyler/iclouddrive/iCloud~md~obsidian/V/a.md") == stored)
    }

    @Test("Desktop, Documents and plain iCloud Drive folders")
    func otherFolders() {
        #expect(map.stored(forLocal: "C:/Users/Tyler/iCloudDrive/Desktop/g.pdf") == "/Users/tyler/Desktop/g.pdf")
        #expect(map.stored(forLocal: "C:/Users/Tyler/iCloudDrive/Projects/x.md")
                == mobile + "/com~apple~CloudDocs/Projects/x.md")
        #expect(map.local(forStored: "/Users/tyler/Desktop/g.pdf") == "C:/Users/Tyler/iCloudDrive/Desktop/g.pdf")
    }

    @Test("paths outside iCloud pass through unchanged")
    func passThrough() {
        #expect(map.stored(forLocal: "C:/Users/Tyler/Downloads/a.pdf") == "C:/Users/Tyler/Downloads/a.pdf")
        #expect(map.stored(forLocal: "C:/Users/Tyler/iCloudDriveOld/a.md") == "C:/Users/Tyler/iCloudDriveOld/a.md")
        #expect(map.local(forStored: "/Users/someoneelse/Desktop/a.pdf") == "/Users/someoneelse/Desktop/a.pdf")
        #expect(map.local(forStored: "C:/notes/a.md") == "C:/notes/a.md")
        #expect(VaultPathMap.identity.stored(forLocal: "/Users/tyler/Desktop/a.md") == "/Users/tyler/Desktop/a.md")
    }

    @Test("the Mac home is read from the library's paths")
    func macHome() throws {
        let db = try GRASPDatabase.inMemory()
        let before = try db.queue.read { try VaultPathMap.macHome(in: $0) }
        #expect(before == nil)
        try db.queue.write { conn in
            try Course(semesterId: nil, name: "Econ", folderPath: mobile + "/iCloud~md~obsidian/Documents/V/College/Econ")
                .insert(conn)
        }
        let after = try db.queue.read { try VaultPathMap.macHome(in: $0) }
        #expect(after == "/Users/tyler")
    }

    @Test("an import through iCloud for Windows updates the Mac's notes instead of duplicating them")
    func scanMatchesMacRows() async throws {
        let drive = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-icloud-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: drive) }
        let vault = drive.appendingPathComponent("iCloud~md~obsidian", isDirectory: true)
            .appendingPathComponent("Vault", isDirectory: true)
        let courseDir = vault.appendingPathComponent("College/Fall Semester 2026/Econ", isDirectory: true)
        try FileManager.default.createDirectory(at: courseDir, withIntermediateDirectories: true)
        let note = """
        # Supply and Demand

        Demand curve
        A curve showing how much buyers want to purchase at each price, holding everything else fixed.

        Supply curve
        A curve showing how much sellers offer at each price, holding everything else fixed.
        """
        try note.write(to: courseDir.appendingPathComponent("Lecture 1.md"), atomically: false, encoding: .utf8)

        let map = VaultPathMap(macHome: "/Users/tyler", iCloudDrive: drive.path)
        let db = try GRASPDatabase.inMemory()
        let first = try await VaultScanner(database: db, paths: map).scan(vaultRoot: vault)
        #expect(first.errors.isEmpty)
        #expect(first.filesImportedOrUpdated == 1)

        let macNote = mobile + "/iCloud~md~obsidian/Documents/Vault/College/Fall Semester 2026/Econ/Lecture 1.md"
        // The Mac's note in a folder that hasn't synced to this PC.
        let (course, firstPath) = try await db.queue.read { conn in
            (try Course.fetchOne(conn), try Material.fetchOne(conn)?.relativePath)
        }
        #expect(course?.folderPath == mobile + "/iCloud~md~obsidian/Documents/Vault/College/Fall Semester 2026/Econ")
        #expect(firstPath == macNote)
        let courseId = try #require(course?.id)
        try await db.queue.write { conn in
            try Material(courseId: courseId,
                         relativePath: mobile + "/iCloud~md~obsidian/Documents/Vault/College/Fall Semester 2026/Unsynced/L.md",
                         kind: .markdown, title: "L").insert(conn)
        }

        let again = try await VaultScanner(database: db, paths: map).scan(vaultRoot: vault)
        #expect(again.filesUnchanged == 1)
        #expect(again.filesImportedOrUpdated == 0)
        let counts = try await db.queue.read { conn in
            (try Course.fetchCount(conn), try Material.filter(Column("deletedAt") == nil).fetchCount(conn))
        }
        #expect(counts.0 == 1)
        #expect(counts.1 == 2)

        // A note that's gone from a folder that is here is still retired.
        try FileManager.default.removeItem(at: courseDir.appendingPathComponent("Lecture 1.md"))
        _ = try await VaultScanner(database: db, paths: map).scan(vaultRoot: vault)
        let gone = try await db.queue.read { try Material.filter(Column("relativePath") == macNote).fetchOne($0) }
        #expect(gone?.deletedAt != nil)
    }
}
