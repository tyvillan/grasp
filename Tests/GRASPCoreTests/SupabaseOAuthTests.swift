import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GRASPCore

/// Google sign-in (OAuth + PKCE). An extension of the REST suite so it
/// shares its serialisation: both drive the one `StubSupabase`.
extension SupabaseRESTTests {
    @Test("the PKCE challenge is the unpadded base64url SHA-256 of the verifier")
    func pkceChallenge() {
        // Worked out independently with .NET's SHA256.
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mJ0nTX6k1BbhS5vZwuj2Sa3U3vPOxs")
                == "0wFApk2ZS2fqa9yy7zQRtwK4ZkHFDcvkOVp5QB8xvrU")
        let verifier = PKCE.makeVerifier()
        #expect(verifier.count == 64)
        #expect(verifier != PKCE.makeVerifier())
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }

    @Test("the authorize link names the provider, the way back, and the challenge")
    func oauthStartURL() throws {
        let auth = SupabaseAuth(project: project, http: StubSupabase.session)
        let start = auth.oauthStart(provider: "google", redirectTo: URL(string: "grasp://auth-callback")!,
                                    verifier: "secret-verifier")
        let components = try #require(URLComponents(url: start.url, resolvingAgainstBaseURL: false))
        #expect(components.host == "example.supabase.co")
        #expect(components.path == "/auth/v1/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["provider"] == "google")
        #expect(query["redirect_to"] == "grasp://auth-callback")
        #expect(query["code_challenge"] == PKCE.challenge(for: "secret-verifier"))
        #expect(query["code_challenge_method"] == "s256")
        #expect(start.verifier == "secret-verifier")
    }

    @Test("the code from the callback is traded for a session with the verifier")
    func completeOAuth() async throws {
        StubSupabase.reset([.init(status: 200, body: tokenJSON())])
        let saved = Saved()
        let auth = SupabaseAuth(project: project, http: StubSupabase.session, persist: { saved.set($0) })
        let session = try await auth.completeOAuth(
            callback: URL(string: "grasp://auth-callback?code=abc123")!, verifier: "secret-verifier")

        #expect(session.userId == "ab12cd34-0000-4000-8000-000000000001")
        #expect(saved.get() == session)
        let request = try #require(StubSupabase.requests.first)
        #expect(request.url?.path == "/auth/v1/token")
        #expect(request.url?.query == "grant_type=pkce")
        let body = try JSONSerialization.jsonObject(with: StubSupabase.bodies[0]) as? [String: String]
        #expect(body == ["auth_code": "abc123", "code_verifier": "secret-verifier"])
    }

    @Test("a callback carrying an error shows Supabase's message and sends nothing")
    func oauthCallbackError() async {
        StubSupabase.reset([])
        let auth = SupabaseAuth(project: project, http: StubSupabase.session)
        await #expect(throws: SupabaseError.server(status: 400, message: "Email link is invalid")) {
            try await auth.completeOAuth(
                callback: URL(string: "grasp://auth-callback?error=access_denied&error_description=Email+link+is+invalid")!,
                verifier: "v")
        }
        #expect(StubSupabase.requests.isEmpty)
    }
}
