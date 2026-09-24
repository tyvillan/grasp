import Foundation
import Observation
import GRASPCore

/// Runs sync for the open profile: when it happens, and what the screen
/// says about it.
///
/// Syncs when the profile opens, a few seconds after the library changes
/// (so a burst of grading goes up as one push, not fifty), and every couple
/// of minutes to pick up what other devices did. Never while another sync
/// is running, and quietly skipped offline -- the next one catches up.
@Observable
final class SyncController {
    enum State: Equatable {
        /// Not signed in: this profile's library lives only on this Mac.
        case localOnly
        /// Signed in, but this copy of GRASP has no Supabase project set.
        case notConfigured
        /// Signed in on a profile whose session has expired or was revoked.
        case signedOut
        case idle
        case syncing
        case failed(String)
    }

    private(set) var state: State = .localOnly
    private(set) var account: LinkedAccount?
    private(set) var lastSyncedAt: Date?
    private(set) var pendingChanges = 0

    private let engine: SyncEngine
    private var profile: Profile
    private let accounts = AccountService.shared
    /// Called after a pull brought in changes, so the store re-reads.
    private let onRemoteChanges: () -> Void

    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?

    static let periodicInterval: Duration = .seconds(120)
    static let changeDebounce: Duration = .seconds(8)

    init(database: GRASPDatabase, profile: Profile, onRemoteChanges: @escaping () -> Void) {
        self.engine = SyncEngine(database: database)
        self.profile = profile
        self.account = profile.account
        self.onRemoteChanges = onRemoteChanges
        refreshStatus()
    }

    /// Starts syncing if this profile is signed in.
    func start() {
        guard let account = profile.account else { state = .localOnly; return }
        guard accounts.isConfigured else { state = .notConfigured; return }
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            guard await self?.accounts.hasSession(for: account.userId) == true else {
                self?.state = .signedOut
                return
            }
            // Ends when the profile closes and the store goes away.
            while !Task.isCancelled, let self {
                self.syncNow()
                try? await Task.sleep(for: Self.periodicInterval)
            }
        }
    }

    func stop() {
        periodicTask?.cancel()
        debounceTask?.cancel()
    }

    /// The library changed here; push it shortly.
    func noteLocalChange() {
        guard profile.account != nil, state != .signedOut else { return }
        refreshStatus()
        // Nothing queued -- a reload after a pull, say -- means nothing to push.
        guard pendingChanges > 0 else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    func syncNow() {
        guard running == nil, let account = profile.account, state != .signedOut,
              let client = try? accounts.client(for: account.userId)
        else { return }
        state = .syncing
        let engine = self.engine
        let transport = SupabaseSyncTransport(client: client, userId: account.userId)
        running = Task { [weak self] in
            do {
                let report = try await engine.sync(using: transport)
                self?.state = .idle
                self?.refreshStatus()
                if report.pulled > 0 { self?.onRemoteChanges() }
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(Self.describe(error))
            }
            self?.running = nil
        }
    }

    private func refreshStatus() {
        guard let status = try? engine.status() else { return }
        lastSyncedAt = status.lastSyncedAt
        pendingChanges = status.pendingChanges
    }

    private static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        if (error as? URLError)?.code == .notConnectedToInternet {
            return "Offline -- changes will sync when you're back online."
        }
        if text.localizedCaseInsensitiveContains("relation") && text.contains("sync_rows") {
            return "The sync table isn't set up in Supabase yet -- run supabase/schema.sql."
        }
        return "Couldn't sync: \(text)"
    }

    // MARK: - Linking

    /// Signs this profile in to `signedIn`'s account. With `uploadLibrary`
    /// its whole library goes up -- the first device of an account; without,
    /// it starts pulling the account's library into this one.
    func link(_ signedIn: SignedInAccount, uploadLibrary: Bool) throws {
        try engine.enable(accountUserId: signedIn.userId, uploadExisting: uploadLibrary)
        profile.account = signedIn.linked
        try ProfileStore.update(profile, supportDirectory: AppPaths.supportDirectory())
        account = profile.account
        state = .idle
        start()
    }

    /// Stops syncing this profile and signs its account out on this Mac.
    /// The library stays here, as a local-only profile.
    func signOut() async {
        stop()
        running?.cancel()
        if let account = profile.account { await accounts.signOut(userId: account.userId) }
        try? engine.disable()
        profile.account = nil
        try? ProfileStore.update(profile, supportDirectory: AppPaths.supportDirectory())
        account = nil
        state = .localOnly
        refreshStatus()
    }

    /// Signs back in on a profile whose session lapsed, keeping its link.
    func resume(_ signedIn: SignedInAccount) {
        guard signedIn.userId == profile.account?.userId else {
            state = .failed("That's a different account from the one this profile syncs with.")
            return
        }
        state = .idle
        start()
    }
}
