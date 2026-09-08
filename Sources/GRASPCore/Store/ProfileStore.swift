import Foundation
import CryptoKit

/// A named local profile so more than one person can use the same
/// installed copy of GRASP with separate data -- each profile gets its
/// own SQLite database under `Profiles/<id>/lectern.sqlite`. There is no
/// account system beyond this: no network, no server, nothing shared
/// between profiles. A PIN is a light deterrent against a sibling opening
/// the wrong profile, not real access control -- it is hashed (SHA-256,
/// fixed salt) only so it isn't sitting in plain text in a JSON file that
/// syncs nowhere anyway.
public struct Profile: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var pinHash: String?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, name: String, pinHash: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.pinHash = pinHash
        self.createdAt = createdAt
    }

    /// A fixed id recognized by `AppStore` as "use an ephemeral in-memory
    /// database" -- SwiftUI previews and anywhere else that needs a
    /// throwaway store with no disk footprint.
    public static let previewID = "preview"
    public static let preview = Profile(id: previewID, name: "Preview")

    public func databaseURL(supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("lectern.sqlite")
    }
}

/// Reads/writes `profiles.json` and handles the one-time migration of data
/// created before profiles existed: a single global `lectern.sqlite` at
/// the top of the support directory becomes the first profile's database
/// rather than being orphaned or silently ignored.
public enum ProfileStore {
    private static let pinSalt = "lectern-local-pin-v1"

    public static func hashPIN(_ pin: String) -> String {
        SHA256.hash(data: Data((pinSalt + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func profilesFileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("profiles.json")
    }

    private static func legacyDatabaseURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("lectern.sqlite")
    }

    /// Loads existing profiles, migrating a pre-profiles installation on
    /// first run: if `profiles.json` doesn't exist yet but a legacy
    /// top-level database does, that database is moved into a new default
    /// profile rather than left behind or overwritten.
    public static func loadOrMigrate(supportDirectory: URL) throws -> [Profile] {
        let fm = FileManager.default
        let profilesURL = profilesFileURL(supportDirectory: supportDirectory)

        if fm.fileExists(atPath: profilesURL.path) {
            let data = try Data(contentsOf: profilesURL)
            return try JSONDecoder().decode([Profile].self, from: data)
        }

        var profiles: [Profile] = []
        let legacyDB = legacyDatabaseURL(supportDirectory: supportDirectory)
        if fm.fileExists(atPath: legacyDB.path) {
            let profile = Profile(name: NSFullUserName())
            let newDBURL = profile.databaseURL(supportDirectory: supportDirectory)
            try fm.createDirectory(at: newDBURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: legacyDB, to: newDBURL)
            // SQLite may have left WAL/SHM sidecars next to the legacy file.
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: legacyDB.path + suffix)
                if fm.fileExists(atPath: sidecar.path) {
                    try? fm.moveItem(at: sidecar, to: URL(fileURLWithPath: newDBURL.path + suffix))
                }
            }
            profiles = [profile]
        }

        try save(profiles, supportDirectory: supportDirectory)
        return profiles
    }

    public static func save(_ profiles: [Profile], supportDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: profilesFileURL(supportDirectory: supportDirectory), options: .atomic)
    }
}
