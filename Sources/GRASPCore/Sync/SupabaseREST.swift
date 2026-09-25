import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Supabase sign-in and sync over plain HTTP, for platforms supabase-swift
// doesn't reach -- Windows first. The Mac and iPhone apps use supabase-swift
// (AccountService); this speaks the same two APIs directly: GoTrue for
// email + password accounts, PostgREST for the `sync_rows` table
// (supabase/schema.sql). Both clients read and write the same rows, so a
// library syncs between them.

/// Which Supabase project to talk to: its URL and its public (anon) key.
/// The key is meant to ship in apps -- row-level security, not the key,
/// keeps each account's rows private.
public struct SupabaseProject: Sendable, Equatable {
    public let url: URL
    public let anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }
}

/// A signed-in account's tokens. The access token lasts about an hour;
/// the refresh token trades for a new pair (and is replaced each time).
public struct SupabaseSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    /// Lowercased, as the Mac stores it in `LinkedAccount.userId`.
    public var userId: String
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userId: String, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userId = userId
        self.email = email
    }
}

public enum SupabaseError: Error, LocalizedError, Equatable {
    /// Supabase refused the request; the message is its own.
    case server(status: Int, message: String)
    /// Sign-up worked, but the project wants the address confirmed first.
    case confirmEmail
    case notSignedIn
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .server(_, let message): return message
        case .confirmEmail: return "Check your email to confirm the account, then sign in."
        case .notSignedIn: return "You're signed out. Sign in again to sync."
        case .invalidResponse: return "Supabase sent back something GRASP didn't understand."
        }
    }
}

/// Email + password accounts (Supabase Auth). Holds the current session,
/// refreshes it before it expires, and hands every change to `persist`
/// so the app can keep it between launches.
public actor SupabaseAuth {
    public let project: SupabaseProject
    public private(set) var session: SupabaseSession?
    private let http: URLSession
    private let persist: @Sendable (SupabaseSession?) -> Void

    public init(project: SupabaseProject, restoring session: SupabaseSession? = nil,
                http: URLSession = .shared,
                persist: @escaping @Sendable (SupabaseSession?) -> Void = { _ in }) {
        self.project = project
        self.session = session
        self.http = http
        self.persist = persist
    }

    public func signIn(email: String, password: String) async throws -> SupabaseSession {
        let body = try JSONEncoder().encode(["email": email, "password": password])
        return try await adopt(try await tokenRequest(grantType: "password", body: body))
    }

    /// Creates an account. Throws `.confirmEmail` when the project requires
    /// the address to be confirmed before the first sign-in.
    public func signUp(email: String, password: String) async throws -> SupabaseSession {
        let body = try JSONEncoder().encode(["email": email, "password": password])
        var request = authRequest(path: "auth/v1/signup")
        request.httpMethod = "POST"
        request.httpBody = body
        let data = try await send(request)
        // With confirmation on, Supabase answers with the new user and no tokens.
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw SupabaseError.confirmEmail
        }
        return try await adopt(token)
    }

    /// An access token good for at least another minute, refreshing first
    /// if needed.
    public func accessToken() async throws -> String {
        guard let current = session else { throw SupabaseError.notSignedIn }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        return try await refresh().accessToken
    }

    @discardableResult
    public func refresh() async throws -> SupabaseSession {
        guard let current = session else { throw SupabaseError.notSignedIn }
        let body = try JSONEncoder().encode(["refresh_token": current.refreshToken])
        do {
            return try await adopt(try await tokenRequest(grantType: "refresh_token", body: body))
        } catch SupabaseError.server(let status, _) where (400..<500).contains(status) {
            // The refresh token was revoked or already used: the account
            // has to sign in again.
            signOut()
            throw SupabaseError.notSignedIn
        }
    }

    /// Forgets the session on this device. Other devices stay signed in.
    public func signOut() {
        session = nil
        persist(nil)
    }

    // MARK: - Requests

    private struct TokenResponse: Decodable {
        struct User: Decodable {
            let id: String
            let email: String?
        }
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: User
    }

    private func tokenRequest(grantType: String, body: Data) async throws -> TokenResponse {
        var request = authRequest(path: "auth/v1/token", query: [URLQueryItem(name: "grant_type", value: grantType)])
        request.httpMethod = "POST"
        request.httpBody = body
        let data = try await send(request)
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw SupabaseError.invalidResponse
        }
        return token
    }

    private func adopt(_ token: TokenResponse) -> SupabaseSession {
        let adopted = SupabaseSession(
            accessToken: token.access_token, refreshToken: token.refresh_token,
            expiresAt: Date().addingTimeInterval(token.expires_in),
            userId: token.user.id.lowercased(), email: token.user.email)
        session = adopted
        persist(adopted)
        return adopted
    }

    private func authRequest(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: project.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(project.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await http.data(for: request)
        try SupabaseResponse.check(response, data)
        return data
    }
}

enum SupabaseResponse {
    /// Throws Supabase's own message for anything outside 2xx. Auth errors
    /// arrive as `error_description`, `msg` or `message` depending on the
    /// endpoint and version; PostgREST's as `message`.
    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = ["error_description", "msg", "message", "error"]
            .lazy.compactMap { object[$0] as? String }.first
            ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        throw SupabaseError.server(status: http.statusCode, message: message)
    }
}

/// `SyncTransport` over the `sync_rows` table -- the same requests the Mac's
/// supabase-swift transport makes, written out as PostgREST calls.
public struct SupabaseRESTTransport: SyncTransport {
    public let auth: SupabaseAuth
    private let http: URLSession

    public init(auth: SupabaseAuth, http: URLSession = .shared) {
        self.auth = auth
        self.http = http
    }

    /// Requests stay under a couple of megabytes, as on the Mac: five
    /// hundred cards is tiny, five hundred notes' text is not.
    static let maximumRequestBytes = 2_000_000
    static let columns = "user_id,table_name,row_key,data,deleted,device_id,updated_at"

    struct Row: Codable {
        var user_id: String
        var table_name: String
        var row_key: String
        var data: [String: SyncValue]?
        var deleted: Bool
        var device_id: String?
        var updated_at: String?

        // Every key written, nulls included: PostgREST takes a bulk
        // insert's columns from its first object, so a deletion's missing
        // `data` would otherwise go missing for the whole batch.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(user_id, forKey: .user_id)
            try container.encode(table_name, forKey: .table_name)
            try container.encode(row_key, forKey: .row_key)
            try container.encode(data, forKey: .data)
            try container.encode(deleted, forKey: .deleted)
            try container.encode(device_id, forKey: .device_id)
        }
    }

    public func push(_ records: [SyncRecord]) async throws {
        guard let userId = await auth.session?.userId else { throw SupabaseError.notSignedIn }
        let encoder = JSONEncoder()
        var batch: [Row] = []
        var batchBytes = 0
        func send() async throws {
            guard !batch.isEmpty else { return }
            var request = try await tableRequest(query: [
                URLQueryItem(name: "on_conflict", value: "user_id,table_name,row_key"),
                URLQueryItem(name: "columns", value: "user_id,table_name,row_key,data,deleted,device_id"),
            ])
            request.httpMethod = "POST"
            request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = try encoder.encode(batch)
            let (data, response) = try await http.data(for: request)
            try SupabaseResponse.check(response, data)
            batch = []
            batchBytes = 0
        }
        for record in records {
            let row = Row(user_id: userId, table_name: record.table, row_key: record.rowKey,
                          data: record.data, deleted: record.deleted, device_id: record.deviceId)
            let size = (try? encoder.encode(row).count) ?? 0
            if batchBytes + size > Self.maximumRequestBytes { try await send() }
            batch.append(row)
            batchBytes += size
        }
        try await send()
    }

    public func pull(since: String?, offset: Int, limit: Int) async throws -> [SyncRecord] {
        var query = [
            URLQueryItem(name: "select", value: Self.columns),
            URLQueryItem(name: "order", value: "updated_at,table_name,row_key"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let since { query.append(URLQueryItem(name: "updated_at", value: "gt.\(since)")) }
        let request = try await tableRequest(query: query)
        let (data, response) = try await http.data(for: request)
        try SupabaseResponse.check(response, data)
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            throw SupabaseError.invalidResponse
        }
        return rows.map {
            SyncRecord(table: $0.table_name, rowKey: $0.row_key, data: $0.data, deleted: $0.deleted,
                       deviceId: $0.device_id, updatedAt: $0.updated_at)
        }
    }

    /// Whether this account already has a synced library -- the choice
    /// between uploading this device's library and downloading the account's.
    public func accountHasData() async throws -> Bool {
        let request = try await tableRequest(query: [
            URLQueryItem(name: "select", value: "row_key"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        let (data, response) = try await http.data(for: request)
        try SupabaseResponse.check(response, data)
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        return !(rows ?? []).isEmpty
    }

    private func tableRequest(query: [URLQueryItem]) async throws -> URLRequest {
        let token = try await auth.accessToken()
        let project = auth.project
        var components = URLComponents(url: project.url.appendingPathComponent("rest/v1/sync_rows"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = query
        // A timestamp's "+00:00" must reach PostgREST as a plus, not a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.setValue(project.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
