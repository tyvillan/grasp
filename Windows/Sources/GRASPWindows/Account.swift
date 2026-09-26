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
        }    }

    // MARK: - Signing in

    /// Signs in (or creates the account), links this profile to it, and
    /// starts syncing. An account that already has a library downloads it;
    /// the first device on an account uploads its own.
    func signIn(email: String, password: String, createAccount: Bool) async throws {
        let session = createAccount
            ? try await auth.signUp(email: email, password: password)
            : try await auth.signIn(email: email, password: password)
        try await link(session, provider: "email")
    }

    // MARK: - Google

    /// Where a Google sign-in stands, for the sign-in sheet.
    enum GoogleState: Equatable {
        case idle
        /// The browser is open; waiting for it to come back to `grasp://`.
        case waiting
        case failed(String)
    }
    private(set) var google: GoogleState = .idle
    /// The PKCE secret for the sign-in in progress. Only in memory: a
    /// sign-in the app was restarted in the middle of just starts again.
    private var googleVerifier: String?

    /// Where the Mac's Google sign-in comes back to, too -- already on the
    /// Supabase project's allowed list.
    static let callbackURL = URL(string: "grasp://auth-callback")!

    /// The Google sign-in page to open in the browser.
    func startGoogleSignIn() -> URL {
        let start = auth.oauthStart(provider: "google", redirectTo: Self.callbackURL)
        googleVerifier = start.verifier
        google = .waiting
        watchForLink()
        return start.url
    }

    func cancelGoogleSignIn() {
        linkWatch?.cancel()
        googleVerifier = nil
        if google != .idle { google = .idle }
    }

    private var linkWatch: Task<Void, Never>?

    /// Checks twice a second for the link the browser hands back (see
    /// `SignInLink`), for as long as a sign-in waits -- up to ten minutes,
    /// after which the verifier is dropped and Google has to start again.
    private func watchForLink() {
        linkWatch?.cancel()
        #if os(Windows)
        SignInLink.discard()
        linkWatch = Task { [weak self] in
            for _ in 0..<1200 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.google == .waiting else { return }
                if let url = SignInLink.take() {
                    await self.handle(url: url)
                    return
                }
            }
            self?.cancelGoogleSignIn()
        }
        #endif
    }

    /// The browser came back with a `grasp://auth-callback` link.
    func handle(url: URL) async {
        guard url.scheme == "grasp", url.host == "auth-callback" else { return }
        guard let verifier = googleVerifier else {
            google = .failed("That sign-in was started before GRASP restarted. Try Continue with Google again.")
            return
        }
        googleVerifier = nil
        do {
            let session = try await auth.completeOAuth(callback: url, verifier: verifier)
            try await link(session, provider: "google")
            google = .idle
        } catch {
            google = .failed(error.localizedDescription)
        }
    }

    // MARK: - Linking

    /// Links this profile to the signed-in account and starts syncing.
    private func link(_ session: SupabaseSession, provider: String) async throws {
        let current = try engine.status()
        if !current.enabled || current.accountUserId != session.userId {
            let accountHasLibrary = try await transport.accountHasData()
            try engine.enable(accountUserId: session.userId, uploadExisting: !accountHasLibrary)
        }
        profile.account = LinkedAccount(userId: session.userId, email: session.email, provider: provider)
        try ProfileStore.update(profile, supportDirectory: supportDirectory)
        self.email = session.email ?? "Signed in"
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
