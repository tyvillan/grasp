import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GRASPCore

/// Answers requests from a script instead of the network, and records
/// what was asked -- so the REST client's requests can be checked against
/// what Supabase expects, and its parsing against what Supabase sends.
final class StubSupabase: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
    }
    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    static let lock = NSLock()

    static func reset(_ replies: [Reply]) {
        lock.withLock { self.replies = replies; requests = []; bodies = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply: Reply = Self.lock.withLock {
            Self.requests.append(request)
            Self.bodies.append(request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data())
            return Self.replies.isEmpty ? Reply(status: 500, body: "{}") : Self.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSupabase.self]
        return URLSession(configuration: configuration)
    }
}

@Suite("SupabaseREST", .serialized)
struct SupabaseRESTTests {
    let project = SupabaseProject(url: URL(string: "https://example.supabase.co")!, anonKey: "anon-key")

    private func tokenJSON(access: String = "access-1", refresh: String = "refresh-1", expiresIn: Int = 3600) -> String {
        """
        {"access_token":"\(access)","token_type":"bearer","expires_in":\(expiresIn),
         "refresh_token":"\(refresh)","user":{"id":"AB12CD34-0000-4000-8000-000000000001","email":"t@example.com"}}
        """
    }

    @Test("signing in posts the password grant and keeps the session, user id lowercased")
    func signIn() async throws {
        StubSupabase.reset([.init(status: 200, body: tokenJSON())])
        let saved = Saved()
        let auth = SupabaseAuth(project: project, http: StubSupabase.session, persist: { saved.set($0) })
        let session = try await auth.signIn(email: "t@example.com", password: "hunter22")

        #expect(session.accessToken == "access-1")
        #expect(session.userId == "ab12cd34-0000-4000-8000-000000000001")
        #expect(saved.get() == session)
        let request = try #require(StubSupabase.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/auth/v1/token")
        #expect(request.url?.query == "grant_type=password")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon-key")
        let body = try JSONSerialization.jsonObject(with: StubSupabase.bodies[0]) as? [String: String]
        #expect(body == ["email": "t@example.com", "password": "hunter22"])
    }

    @Test("a wrong password surfaces Supabase's own message")
    func wrongPassword() async {
        StubSupabase.reset([.init(status: 400, body: #"{"error":"invalid_grant","error_description":"Invalid login credentials"}"#)])
        let auth = SupabaseAuth(project: project, http: StubSupabase.session)
        await #expect(throws: SupabaseError.server(status: 400, message: "Invalid login credentials")) {
            try await auth.signIn(email: "t@example.com", password: "nope")
        }
    }

    @Test("sign-up without tokens in the reply means the email needs confirming")
    func signUpNeedsConfirmation() async {
        StubSupabase.reset([.init(status: 200, body: #"{"id":"u1","email":"t@example.com","confirmation_sent_at":"2026-09-25T00:00:00Z"}"#)])
        let auth = SupabaseAuth(project: project, http: StubSupabase.session)
        await #expect(throws: SupabaseError.confirmEmail) {
            try await auth.signUp(email: "t@example.com", password: "hunter22")
        }
    }

    @Test("an access token about to expire is refreshed first, and the new pair saved")
    func refreshesNearExpiry() async throws {
        StubSupabase.reset([.init(status: 200, body: tokenJSON(access: "access-2", refresh: "refresh-2"))])
        let expiring = SupabaseSession(accessToken: "access-1", refreshToken: "refresh-1",
                                       expiresAt: Date().addingTimeInterval(30), userId: "u1", email: nil)
        let saved = Saved()
        let auth = SupabaseAuth(project: project, restoring: expiring, http: StubSupabase.session,
                                persist: { saved.set($0) })
        let token = try await auth.accessToken()

        #expect(token == "access-2")
        #expect(saved.get()?.refreshToken == "refresh-2")
        #expect(StubSupabase.requests.first?.url?.query == "grant_type=refresh_token")
        let body = try JSONSerialization.jsonObject(with: StubSupabase.bodies[0]) as? [String: String]
        #expect(body == ["refresh_token": "refresh-1"])
    }

    @Test("a revoked refresh token signs the device out")
    func revokedRefreshSignsOut() async throws {
        StubSupabase.reset([.init(status: 400, body: #"{"error_description":"Invalid Refresh Token"}"#)])
        let expired = SupabaseSession(accessToken: "a", refreshToken: "r", expiresAt: .distantPast, userId: "u1", email: nil)
        let saved = Saved(expired)
        let auth = SupabaseAuth(project: project, restoring: expired, http: StubSupabase.session,
                                persist: { saved.set($0) })
        await #expect(throws: SupabaseError.notSignedIn) { try await auth.accessToken() }
        #expect(await auth.session == nil)
        #expect(saved.get() == nil)
    }

    private func signedInTransport() -> SupabaseRESTTransport {
        let session = SupabaseSession(accessToken: "token", refreshToken: "r", expiresAt: .distantFuture,
                                      userId: "u1", email: nil)
        let auth = SupabaseAuth(project: project, restoring: session, http: StubSupabase.session)
        return SupabaseRESTTransport(auth: auth, http: StubSupabase.session)
    }

    @Test("push upserts on the sync_rows key, with every column present even for a deletion")
    func push() async throws {
        StubSupabase.reset([.init(status: 201, body: "")])
        try await signedInTransport().push([
            SyncRecord(table: "card", rowKey: "c1", data: ["front": .text("Pivot"), "reps": .integer(2)],
                       deleted: false, deviceId: "d1"),
            SyncRecord(table: "deck", rowKey: "k1", data: nil, deleted: true, deviceId: "d1"),
        ])

        let request = try #require(StubSupabase.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/sync_rows")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "on_conflict", value: "user_id,table_name,row_key")))
        #expect(request.value(forHTTPHeaderField: "Prefer") == "resolution=merge-duplicates,return=minimal")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")

        let rows = try #require(try JSONSerialization.jsonObject(with: StubSupabase.bodies[0]) as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(rows[0]["user_id"] as? String == "u1")
        #expect((rows[0]["data"] as? [String: Any])?["front"] as? String == "Pivot")
        #expect(Set(rows[1].keys) == ["user_id", "table_name", "row_key", "data", "deleted", "device_id"])
        #expect(rows[1]["data"] is NSNull)
        #expect(rows[1]["deleted"] as? Bool == true)
    }

    @Test("pull asks for rows after the cursor, in order and by page, and reads them back")
    func pull() async throws {
        StubSupabase.reset([.init(status: 200, body: """
            [{"user_id":"u1","table_name":"card","row_key":"c1","data":{"front":"Pivot","reps":2},
              "deleted":false,"device_id":"d2","updated_at":"2026-09-25T18:04:45.604123+00:00"},
             {"user_id":"u1","table_name":"deck","row_key":"k1","data":null,
              "deleted":true,"device_id":"d2","updated_at":"2026-09-25T18:04:46+00:00"}]
            """)])
        let records = try await signedInTransport().pull(since: "2026-09-25T18:00:00.000+00:00", offset: 1000, limit: 1000)

        let request = try #require(StubSupabase.requests.first)
        let rawQuery = try #require(request.url?.query)
        #expect(rawQuery.contains("updated_at=gt.2026-09-25T18:00:00.000%2B00:00"))
        #expect(rawQuery.contains("order=updated_at,table_name,row_key"))
        #expect(rawQuery.contains("offset=1000"))
        #expect(rawQuery.contains("limit=1000"))

        #expect(records.count == 2)
        #expect(records[0] == SyncRecord(table: "card", rowKey: "c1", data: ["front": .text("Pivot"), "reps": .integer(2)],
                                         deleted: false, deviceId: "d2", updatedAt: "2026-09-25T18:04:45.604123+00:00"))
        #expect(records[1].data == nil)
        #expect(records[1].deleted)
    }

    @Test("a missing sync_rows table comes back as PostgREST's message")
    func missingTable() async {
        StubSupabase.reset([.init(status: 404, body: #"{"code":"42P01","message":"relation \"public.sync_rows\" does not exist"}"#)])
        await #expect(throws: SupabaseError.server(status: 404, message: "relation \"public.sync_rows\" does not exist")) {
            try await signedInTransport().pull(since: nil, offset: 0, limit: 1000)
        }
    }

    @Test("pushing or pulling while signed out fails without a request")
    func signedOut() async {
        StubSupabase.reset([])
        let transport = SupabaseRESTTransport(auth: SupabaseAuth(project: project, http: StubSupabase.session),
                                              http: StubSupabase.session)
        await #expect(throws: SupabaseError.notSignedIn) { try await transport.pull(since: nil, offset: 0, limit: 10) }
        #expect(StubSupabase.requests.isEmpty)
    }
}

/// A thread-safe box for what `persist` was last handed.
final class Saved: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SupabaseSession?
    init(_ value: SupabaseSession? = nil) { self.value = value }
    func set(_ new: SupabaseSession?) { lock.withLock { value = new } }
    func get() -> SupabaseSession? { lock.withLock { value } }
}
