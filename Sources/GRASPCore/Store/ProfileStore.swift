import Foundation
import CryptoKit

/// A named local profile so more than one person can use the same
/// installed copy of GRASP with separate data -- each profile gets its
/// own SQLite database under `Profiles/<id>/lectern.sqlite`. A profile is
/// local-only unless it's signed in to an account (`account`), in which
/// case its library syncs with that account's other devices; profiles
/// never share data with each other. A PIN is a light deterrent against a
/// sibling opening the wrong profile, not real access control -- it is
/// hashed (SHA-256, fixed salt) only so it isn't sitting in plain text in
/// profiles.json.
public struct Profile: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var pinHash: String?
    public let createdAt: Date
    /// Set when the profile is signed in to an account and syncs its
    /// library across devices. Nil for a local-only profile -- absent from
    /// older profiles.json files, which decode as local-only.
    public var account: LinkedAccount?

    public init(id: String = UUID().uuidString, name: String, pinHash: String? = nil,
                createdAt: Date = Date(), account: LinkedAccount? = nil) {
        self.id = id
        self.name = name
        self.pinHash = pinHash
        self.createdAt = createdAt
        self.account = account
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

/// The account a synced profile belongs to.
public struct LinkedAccount: Codable, Sendable, Equatable {
    /// The account's id on the sync server; one profile per account on a Mac.
    public var userId: String
    public var email: String?
    /// "google" or "email".
    public var provider: String

    public init(userId: String, email: String?, provider: String) {
        self.userId = userId
        self.email = email
        self.provider = provider
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

    /// Replaces one profile in the saved list, leaving the rest alone.
    public static func update(_ profile: Profile, supportDirectory: URL) throws {
        var profiles = try loadOrMigrate(supportDirectory: supportDirectory)
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        try save(profiles, supportDirectory: supportDirectory)
    }

    public static func save(_ profiles: [Profile], supportDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let url = profilesFileURL(supportDirectory: supportDirectory)
        // A file that exists but won't decode is set aside before it's
        // replaced. The picker shows no profiles when loading fails, and
        // creating one then wrote a list of just that one over the file --
        // every existing profile gone from the list, their data orphaned.
        if let existing = try? Data(contentsOf: url),
           (try? JSONDecoder().decode([Profile].self, from: existing)) == nil {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? fm.copyItem(at: url, to: backup)
        }
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: url, options: .atomic)
    }
}
