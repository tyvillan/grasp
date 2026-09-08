import Foundation
@testable import GRASPCore

/// Scans the real vault **once** per test process and hands every suite a
/// cheap file copy of the result.
///
/// Swift Testing runs suites in parallel, so when each vault-backed suite
/// did its own `VaultScanner.scan`, a full run meant ~10 concurrent scans
/// of 386 files -- each one re-extracting text from the same 236k-word
/// textbook PDF through PDFKit. That was survivable at eight suites and
/// began hanging the whole run at ten: not slow, thrashing. Copying a
/// ~6 MB SQLite file instead takes milliseconds.
///
/// `RealVaultVerification` deliberately does *not* use this -- verifying
/// what a real scan produces is the entire point of that suite.
enum VaultFixture {
    static let root = URL(fileURLWithPath:
        "/Users/tyvillan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Master Vault")

    static var vaultExists: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    /// A private database preloaded with the real vault's contents. Each
    /// caller gets its own copy, so tests can mutate (or delete) freely
    /// without affecting anyone else's.
    static func database() async throws -> GRASPDatabase {
        let master = try await VaultFixtureCache.shared.masterDatabaseURL()
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-fixture-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: master, to: copy)
        return try GRASPDatabase(path: copy)
    }
}

/// Serializes the one-time scan: whichever suite asks first pays for it,
/// everyone after that waits on the same actor and gets the cached path.
private actor VaultFixtureCache {
    static let shared = VaultFixtureCache()
    private var masterURL: URL?

    func masterDatabaseURL() async throws -> URL {
        if let masterURL { return masterURL }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-vault-master-\(UUID().uuidString).sqlite")
        // Scoped so the queue is closed (and any WAL checkpointed) before
        // the file gets copied out from under it.
        do {
            let database = try GRASPDatabase(path: url)
            _ = try await VaultScanner(database: database).scan(vaultRoot: VaultFixture.root)
        }
        masterURL = url
        return url
    }
}
