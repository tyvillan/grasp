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
            _ = try await RealVaultScanGate.shared.run {
                try await VaultScanner(database: database).scan(vaultRoot: VaultFixture.root)
            }
        }
        masterURL = url
        return url
    }
}

/// A hard cap of one real, filesystem-walking vault scan at a time across
/// the whole test process. This cache's own one-time scan isn't the only
/// place that does one: `RealVaultVerification` (by design -- it exists to
/// verify a live scan, not a cached copy) and a couple of
/// `FolderExclusionTests` cases (which mutate their own fixture copy, then
/// need a real re-scan to see whether it comes back) each run their own,
/// independent real scan too. Also sets `GRASP_SKIP_OCR` before every real
/// scan -- see `ImageExtractor`'s own doc comment on that variable. Both
/// exist for the same underlying reason: a real `VNRecognizeTextRequest`
/// call, `sample`d mid-hang on a stuck test run, sat the *entire* sampling
/// window on one `dispatch_semaphore_wait_slow` deep inside Apple's own
/// `TextRecognition` internals -- reproduced with a real vault image and a
/// synthetic one, at both `.accurate` and `.fast` recognition levels, and
/// regardless of how many real scans were running at once (this gate keeps
/// that at exactly one, and it still happened). That rules out "too many
/// concurrent scans" as the actual trigger: it's Vision itself that doesn't
/// reliably tolerate running under `swift test`'s heavily concurrent host
/// process, full stop -- the same call from a plain standalone binary, no
/// test harness involved, succeeded on all 50 real images in under 1s each.
actor RealVaultScanGate {
    static let shared = RealVaultScanGate()
    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        // No setenv on Windows -- and nothing to skip there yet: OCR is
        // Vision-only until Windows.Media.Ocr lands.
        #if !os(Windows)
        setenv("GRASP_SKIP_OCR", "1", 1)
        #endif
        return try await body()
    }
}
