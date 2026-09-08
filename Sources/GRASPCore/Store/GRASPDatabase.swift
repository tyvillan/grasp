import Foundation
import GRDB

/// The single entry point to the app's SQLite store. Lives at
/// ~/Library/Application Support/GRASP -- NOT in iCloud. The vault stays
/// the source of truth; this database is a rebuildable derived index, so
/// losing it only costs a re-import (though review history in `review`
/// would be lost too, which is why re-sync preserves material identity
/// across renames rather than treating a move as delete+create).
///
/// Uses DatabaseQueue rather than DatabasePool: this is a single-user
/// desktop app with at most a few thousand rows, not a server workload, and
/// DatabaseQueue supports an in-memory database (used by tests/previews)
/// while DatabasePool does not.
public final class GRASPDatabase: Sendable {
    public let queue: DatabaseQueue

    public init(path: URL? = nil) throws {
        let dbURL = try path ?? Self.defaultDatabaseURL()
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.foreignKeysEnabled = true
        queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try Schema.migrator().migrate(queue)
    }

    /// `~/Library/Application Support/GRASP` -- shared by every profile;
    /// `ProfileStore` lays out each profile's own database underneath it.
    public static func supportDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return support.appendingPathComponent("GRASP", isDirectory: true)
    }

    public static func defaultDatabaseURL() throws -> URL {
        try supportDirectory().appendingPathComponent("lectern.sqlite")
    }

    /// An in-memory database for tests and previews.
    public static func inMemory() throws -> GRASPDatabase {
        try GRASPDatabase(memoryConfiguration: Configuration())
    }

    private init(memoryConfiguration config: Configuration) throws {
        var config = config
        config.foreignKeysEnabled = true
        queue = try DatabaseQueue(path: ":memory:", configuration: config)
        try Schema.migrator().migrate(queue)
    }
}
