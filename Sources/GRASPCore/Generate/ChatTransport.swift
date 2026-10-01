import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a model call failed, in the terms the fallback logic needs: whether
/// trying again later, trying the other model, or telling the student is
/// the right response.
public enum AIBackendError: Error, Equatable, Sendable {
    /// Too many requests this minute. `retryAfter` is the server's own hint.
    case rateLimited(retryAfter: TimeInterval?)
    /// Today's free allowance is used up; it comes back at the reset.
    case quotaExhausted
    /// The key is missing, wrong or revoked.
    case unauthorized
    /// No connection.
    case unreachable
    /// Google is up but this model is overloaded or erroring (HTTP 5xx):
    /// try again shortly, or use another model.
    case overloaded(status: Int)
    case badResponse(String)

    /// The errors Automatic answers by switching to the local model rather
    /// than giving up: a bad key is the student's to fix, not a reason to
    /// quietly run everything somewhere else.
    var warrantsFallback: Bool {
        switch self {
        case .rateLimited, .quotaExhausted, .unreachable, .overloaded: return true
        case .unauthorized, .badResponse: return false
        }
    }
}

/// One prompt in, one answer out. Everything model-specific about *how* a
/// request is made lives behind this; every prompt and parser in
/// `OllamaGenerator` is shared by all of them.
public protocol ChatTransport: Sendable {
    func complete(prompt: String, json: Bool, maxTokens: Int?) async throws -> String
}

/// A local Ollama server's `/api/chat`.
public struct OllamaTransport: ChatTransport {
    let baseURL: URL
    let model: String

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    /// One session for every generator. A generator is made per AI action
    /// -- often several -- and each used to open its own session, never
    /// invalidated, so they piled up over a long sitting.
    ///
    /// Every request sets `stream: false`, so Ollama holds the whole answer
    /// until it's done and sends it in one burst: the "no new bytes" timeout
    /// acts as a deadline on the entire call. A full lesson section from a
    /// 7B model can take most of a minute before its first byte, so both
    /// timeouts are a generous five minutes.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    /// The same for every call, never varied per call: Ollama reloads the
    /// model whenever this changes. 8K rather than Ollama's 4K default so a
    /// typical lecture fits in one piece with room to answer.
    static let contextTokens = 8_192

    var isReachable: Bool {
        get async {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
            request.timeoutInterval = 2
            guard let (_, response) = try? await Self.session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return false }
            return http.statusCode == 200
        }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        /// Nil omits the key: Ollama's free-text default.
        let format: String?
        let stream: Bool
        /// Always false. Newer models (qwen3.5, gemma4) reason to themselves
        /// before answering unless told not to, and nothing here reads that
        /// reasoning: qwen3.5 spent 50 seconds thinking before a two-key JSON
        /// answer it gave in 0.6s with this set.
        let think: Bool
        let options: Options
        struct Message: Encodable { let role: String; let content: String }
        struct Options: Encodable {
            let num_ctx: Int
            let num_predict: Int?
        }
    }

    private struct ChatResponse: Decodable {
        let message: Message
        struct Message: Decodable { let content: String }
    }

    public func complete(prompt: String, json: Bool, maxTokens: Int?) async throws -> String {
        // Check the server is there first, in the 2-second budget. A refused
        // connection fails at once on Apple platforms, but on Windows
        // URLSession sits out the full 300-second timeout.
        guard await isReachable else { throw AIBackendError.unreachable }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model, messages: [.init(role: "user", content: prompt)],
            format: json ? "json" : nil, stream: false, think: false,
            options: .init(num_ctx: Self.contextTokens, num_predict: maxTokens)
        ))
        let (data, _) = try await Self.session.data(for: request)
        return try JSONDecoder().decode(ChatResponse.self, from: data).message.content
    }
}
