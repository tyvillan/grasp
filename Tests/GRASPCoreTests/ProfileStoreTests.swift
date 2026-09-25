import Testing
import Foundation
@testable import GRASPCore

@Suite("ProfileStore")
struct ProfileStoreTests {
    private func tempSupportDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lectern-profile-test-\(UUID().uuidString)")
    }

    @Test("a fresh install with no legacy database and no profiles.json starts empty")
    func freshInstallStartsEmpty() throws {
        let dir = tempSupportDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profiles = try ProfileStore.loadOrMigrate(supportDirectory: dir)
        #expect(profiles.isEmpty)
    }

    @Test("a pre-existing profiles.json is loaded as-is, not re-migrated")
    func existingProfilesFileIsLoaded() throws {
        let dir = tempSupportDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = [Profile(name: "Alex"), Profile(name: "Sam")]
        try ProfileStore.save(existing, supportDirectory: dir)

        let loaded = try ProfileStore.loadOrMigrate(supportDirectory: dir)
        #expect(loaded.map(\.name).sorted() == ["Alex", "Sam"])
    }

    @Test("a legacy top-level database migrates into a new default profile without data loss")
    func legacyDatabaseMigrates() throws {
        let dir = tempSupportDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Simulate a real pre-profiles installation: a populated database
        // sitting at the old top-level path.
        let legacyPath = dir.appendingPathComponent("lectern.sqlite")
        let legacyDB = try GRASPDatabase(path: legacyPath)
        try legacyDB.queue.write { conn in
            try Semester(name: "Fall 2025", slug: "fall-2025", sortKey: 1).insert(conn)
        }
        // Closed first, as it is in the app, which migrates at launch before
        // opening any database -- Windows won't move an open file.
        try legacyDB.queue.close()

        let profiles = try ProfileStore.loadOrMigrate(supportDirectory: dir)
        #expect(profiles.count == 1)
        let profile = try #require(profiles.first)

        // The legacy file must be gone from the old path (moved, not
        // copied-and-left-behind) and the new profile's database must
        // contain the exact data that was in it.
        #expect(!FileManager.default.fileExists(atPath: legacyPath.path))
        let migratedDB = try GRASPDatabase(path: profile.databaseURL(supportDirectory: dir))
        let semesterCount = try migratedDB.queue.read { try Semester.fetchCount($0) }
        #expect(semesterCount == 1)

        // Idempotency: loading again must not re-migrate or duplicate.
        let secondLoad = try ProfileStore.loadOrMigrate(supportDirectory: dir)
        #expect(secondLoad.count == 1)
        #expect(secondLoad.first?.id == profile.id)
    }

    @Test("PIN hashing is deterministic and different PINs hash differently")
    func pinHashing() {
        #expect(ProfileStore.hashPIN("1234") == ProfileStore.hashPIN("1234"))
        #expect(ProfileStore.hashPIN("1234") != ProfileStore.hashPIN("4321"))
    }
}
