import Foundation
import Observation
import Supabase
import GRASPCore

/// The Supabase project GRASP signs in to, read from Info.plist. Nil until
/// both values are filled in -- GRASP then runs local-only and the sign-in
/// buttons explain why they're unavailable.
struct SyncConfiguration: Sendable {
    let url: URL
    let anonKey: String

    static let current: SyncConfiguration? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let raw = (info["GRASPSupabaseURL"] as? String)?.trimmingCharacters(in: .whitespaces),
              let url = URL(string: raw), url.scheme == "https",
              let key = (info["GRASPSupabaseAnonKey"] as? String)?.trimmingCharacters(in: .whitespaces),
              !key.isEmpty
        else { return nil }
        return SyncConfiguration(url: url, anonKey: key)
    }()
}

/// Someone who has just signed in.
struct SignedInAccount: Sendable, Equatable, Identifiable {
    var id: String { userId }
    let userId: String
    let email: String?
    let provider: String

    var linked: LinkedAccount { LinkedAccount(userId: userId, email: email, provider: provider) }
}

enum AccountError: LocalizedError {
    case notConfigured
    case confirmEmail(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Sign-in isn't set up in this copy of GRASP yet."
        case .confirmEmail(let email):
            return "Check \(email) for a confirmation link, open it on this Mac, and you'll be signed in."
        }
    }
}

/// Signing in, and the per-account connections sync runs over.
///
/// Every account gets its own session in the Keychain, keyed by its id, so
/// two people with profiles on one Mac stay signed in separately. Signing
/// in happens before we know whose account it is, so it runs on a
/// short-lived client and the session is then handed to that account's
/// own client (`adopt`).
@Observable
final class AccountService {
    static let shared = AccountService()

    /// Where Google and emailed links send the browser back to.
    static let callbackURL = URL(string: "grasp://auth-callback")!
    private static let signInStorageKey = "grasp-auth-signing-in"

    let configuration = SyncConfiguration.current
    var isConfigured: Bool { configuration != nil }

    /// Set when a `grasp://` link finishes a sign-in -- a magic link or an
    /// email confirmation opened from Mail. The picker watches for it.
    private(set) var completedFromLink: SignedInAccount?
    private(set) var linkError: String?

    @ObservationIgnored private var clients: [String: SupabaseClient] = [:]
    @ObservationIgnored private var signInClient: SupabaseClient?

    // MARK: - Signing in

    func signInWithGoogle() async throws -> SignedInAccount {
        let client = try freshSignInClient()
        let session = try await client.auth.signInWithOAuth(
            provider: .google, redirectTo: Self.callbackURL
        ) { session in
            // A private browser window each time, so choosing an account
            // isn't pre-empted by whichever Google account Safari last used.
            session.prefersEphemeralWebBrowserSession = true
        }
        return try await adopt(session, provider: "google")
    }

    func signIn(email: String, password: String) async throws -> SignedInAccount {
        let client = try freshSignInClient()
        let session = try await client.auth.signIn(email: email, password: password)
        return try await adopt(session, provider: "email")
    }

    /// Creates an account. When the project requires email confirmation
    /// there's no session yet, and the confirmation link completes it.
    func signUp(email: String, password: String) async throws -> SignedInAccount {
        let client = try freshSignInClient()
        let response = try await client.auth.signUp(
            email: email, password: password, redirectTo: Self.callbackURL
        )
        guard let session = response.session else { throw AccountError.confirmEmail(email) }
        return try await adopt(session, provider: "email")
    }

    /// Emails a one-tap sign-in link that opens GRASP.
    func sendSignInLink(email: String) async throws {
        let client = try freshSignInClient()
        try await client.auth.signInWithOTP(email: email, redirectTo: Self.callbackURL)
    }

    /// Finishes a sign-in from a `grasp://auth-callback` link.
    func handle(url: URL) async {
        guard url.scheme == "grasp" else { return }
        do {
            let client = try signInClient ?? freshSignInClient()
            let session = try await client.auth.session(from: url)
            completedFromLink = try await adopt(session, provider: "email")
            linkError = nil
        } catch {
            linkError = "That sign-in link didn't work -- it may have expired. Ask for a new one."
        }
    }

    func consumeCompletedFromLink() -> SignedInAccount? {
        defer { completedFromLink = nil }
        return completedFromLink
    }

    /// Moves a new session onto the account's own client and forgets the
    /// sign-in client's copy -- removing it from the Keychain rather than
    /// signing out, which would revoke the very session just handed over.
    private func adopt(_ session: Session, provider: String) async throws -> SignedInAccount {
        let userId = session.user.id.uuidString.lowercased()
        let client = try client(for: userId)
        try await client.auth.setSession(accessToken: session.accessToken, refreshToken: session.refreshToken)
        try? KeychainLocalStorage().remove(key: Self.signInStorageKey)
        signInClient = nil
        return SignedInAccount(userId: userId, email: session.user.email, provider: provider)
    }

    private func freshSignInClient() throws -> SupabaseClient {
        guard let configuration else { throw AccountError.notConfigured }
        let client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.anonKey,
            options: SupabaseClientOptions(auth: .init(
                redirectToURL: Self.callbackURL,
                storageKey: Self.signInStorageKey,
                emitLocalSessionAsInitialSession: true
            ))
        )
        signInClient = client
        return client
    }

    // MARK: - Per-account clients

    /// The account's own connection, with its session in the Keychain.
    func client(for userId: String) throws -> SupabaseClient {
        if let existing = clients[userId] { return existing }
        guard let configuration else { throw AccountError.notConfigured }
        let client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.anonKey,
            options: SupabaseClientOptions(auth: .init(
                redirectToURL: Self.callbackURL,
                storageKey: "grasp-auth-\(userId)",
                emitLocalSessionAsInitialSession: true
            ))
        )
        clients[userId] = client
        return client
    }

    /// Whether the account still has a usable session on this Mac.
    func hasSession(for userId: String) async -> Bool {
        guard let client = try? client(for: userId) else { return false }
        return (try? await client.auth.session) != nil
    }

    /// Whether the account already holds a library from another device --
    /// nil when that can't be checked (offline). Decides whether signing in
    /// on this Mac should download that library or upload this one.
    func accountHasData(userId: String) async -> Bool? {
        guard let client = try? client(for: userId) else { return nil }
        struct Probe: Decodable { let row_key: String }
        let rows: [Probe]? = try? await client.from("sync_rows")
            .select("row_key").limit(1).execute().value
        return rows.map { !$0.isEmpty }
    }

    /// Adds (or changes) the account's password, so it can sign in with
    /// email and password where Google sign-in isn't available -- GRASP on
    /// Windows, for now. Same account, same library.
    func setPassword(_ password: String, userId: String) async throws {
        let client = try client(for: userId)
        try await client.auth.update(user: UserAttributes(password: password))
    }

    func signOut(userId: String) async {
        guard let client = try? client(for: userId) else { return }
        try? await client.auth.signOut(scope: .local)
        clients[userId] = nil
    }
}

/// `SyncTransport` over the `sync_rows` table (supabase/schema.sql).
struct SupabaseSyncTransport: SyncTransport {
    let client: SupabaseClient
    let userId: String

    private struct Row: Codable {
        var user_id: String
        var table_name: String
        var row_key: String
        var data: [String: SyncValue]?
        var deleted: Bool
        var device_id: String?
        var updated_at: String?
    }

    /// Requests are kept under a couple of megabytes: a batch of five
    /// hundred rows is tiny for cards and far too big for note text.
    private static let maximumRequestBytes = 2_000_000

    func push(_ records: [SyncRecord]) async throws {
        let rows = records.map {
            Row(user_id: userId, table_name: $0.table, row_key: $0.rowKey,
                data: $0.data, deleted: $0.deleted, device_id: $0.deviceId, updated_at: nil)
        }
        let encoder = JSONEncoder()
        var batch: [Row] = []
        var batchBytes = 0
        func send() async throws {
            guard !batch.isEmpty else { return }
            try await client.from("sync_rows")
                .upsert(batch, onConflict: "user_id,table_name,row_key", returning: .minimal)
                .execute()
            batch = []
            batchBytes = 0
        }
        for row in rows {
            let size = (try? encoder.encode(row).count) ?? 0
            if batchBytes + size > Self.maximumRequestBytes { try await send() }
            batch.append(row)
            batchBytes += size
        }
        try await send()
    }

    func pull(since: String?, offset: Int, limit: Int) async throws -> [SyncRecord] {
        var query = client.from("sync_rows")
            .select("user_id,table_name,row_key,data,deleted,device_id,updated_at")
        if let since { query = query.gt("updated_at", value: since) }
        let rows: [Row] = try await query
            .order("updated_at")
            .order("table_name")
            .order("row_key")
            .range(from: offset, to: offset + limit - 1)
            .execute()
            .value
        return rows.map {
            SyncRecord(table: $0.table_name, rowKey: $0.row_key, data: $0.data, deleted: $0.deleted,
                       deviceId: $0.device_id, updatedAt: $0.updated_at)
        }
    }
}
