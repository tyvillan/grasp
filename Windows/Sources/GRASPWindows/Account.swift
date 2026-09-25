import Foundation
import GRASPCore
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The profile's GRASP account on this PC: signing in with email and
/// password, and keeping the library in sync with the Mac and iPhone
/// through the same Supabase rows. The Windows counterpart of the Mac's
/// AccountService + SyncController, on GRASPCore's REST client instead of
/// supabase-swift.
@Observable
final class Account {
    /// The signed-in address, or nil when signed out.
    private(set) var email: String?
    /// What sync last did, for the sidebar.
    private(set) var status: String?
    private(set) var isSyncing = false

    private let auth: SupabaseAuth
    private let transport: SupabaseRESTTransport
    private let engine: SyncEngine
    private var profile: Profile
    private let supportDirectory: URL
    private let onRemoteChanges: () -> Void
    private var loop: Task<Void, Never>?
    private var pendingSync: Task<Void, Never>?

    /// How often a signed-in library syncs on its own, and how long after a
    /// local change -- the Mac's intervals.
    private static let interval: Duration = .seconds(120)
    private static let afterChange: Duration = .seconds(8)

    init(database: GRASPDatabase, profile: Profile, supportDirectory: URL, onRemoteChanges: @escaping () -> Void) {
        self.profile = profile
        self.supportDirectory = supportDirectory
        self.onRemoteChanges = onRemoteChanges
        engine = SyncEngine(database: database)

        let vault = profile.databaseURL(supportDirectory: supportDirectory)
            .deletingLastPathComponent().appendingPathComponent("session.bin")
        let restored = SessionVault.load(from: vault)
        auth = SupabaseAuth(project: SupabaseSettings.project, restoring: restored,
                            persist: { SessionVault.save($0, to: vault) })
        transport = SupabaseRESTTransport(auth: auth)
        email = restored?.email

        if restored != nil, (try? engine.status().enabled) == true {
            start()
        }
    }

    // MARK: - Signing in

    /// Signs in (or creates the account), links this profile to it, and
    /// starts syncing. An account that already has a library downloads it;
    /// the first device on an account uploads its own.
    func signIn(email: String, password: String, createAccount: Bool) async throws {
        let session = createAccount
            ? try await auth.signUp(email: email, password: password)
            : try await auth.signIn(email: email, password: password)

        let current = try engine.status()
        if !current.enabled || current.accountUserId != session.userId {
            let accountHasLibrary = try await transport.accountHasData()
            try engine.enable(accountUserId: session.userId, uploadExisting: !accountHasLibrary)
        }
        profile.account = LinkedAccount(userId: session.userId, email: session.email, provider: "email")
        try ProfileStore.update(profile, supportDirectory: supportDirectory)
        self.email = session.email ?? email
        status = nil
        start()
    }

    /// Stops syncing and signs out on this PC. The library stays here.
    func signOut() async {
        loop?.cancel()
        pendingSync?.cancel()
        await auth.signOut()
        try? engine.disable()
        profile.account = nil
        try? ProfileStore.update(profile, supportDirectory: supportDirectory)
        email = nil
        status = nil
    }

    // MARK: - Syncing

    func syncNow() async {
        guard email != nil, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let report = try await engine.sync(using: transport)
            status = "Synced at \(Date().formatted(date: .omitted, time: .shortened))"
            if report.pulled > 0 { onRemoteChanges() }
        } catch SupabaseError.notSignedIn {
            loop?.cancel()
            email = nil
            status = "Signed out. Sign in again to keep syncing."
        } catch {
            status = Self.describe(error)
        }
    }

    /// Something changed in the library: sync shortly, once the change has
    /// settled, rather than waiting for the next scheduled sync.
    func noteLocalChange() {
        guard email != nil else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: Self.afterChange)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut].contains(urlError.code) {
            return "Offline. Changes will sync when you're back online."
        }
        if text.localizedCaseInsensitiveContains("relation") && text.contains("sync_rows") {
            return "The sync table isn't set up in Supabase yet: run supabase/schema.sql."
        }
        return "Couldn't sync: \(text)"
    }
}
