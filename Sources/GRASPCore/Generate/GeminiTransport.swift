import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Spaces cloud requests out to stay under the per-minute limit. Shared by
/// every transport, since the limit is per key, not per generator.
actor RequestPacer {
    static let shared = RequestPacer(minimumInterval: 60.0 / Double(CloudProvider.requestsPerMinute))

    private let minimumInterval: TimeInterval
    private var nextSlot = Date.distantPast

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func waitTurn() async throws {
        let now = Date()
        let start = max(now, nextSlot)
        nextSlot = start.addingTimeInterval(minimumInterval)
        let wait = start.timeIntervalSince(now)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }
}

/// The failures a cloud call hit, for `FallbackGenerator` to see past the
/// generators' fail-soft `try?`.
final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var last: AIBackendError?

    func record(_ error: AIBackendError) {
        lock.lock(); last = error; lock.unlock()
    }

    func reset() {
        lock.lock(); last = nil; lock.unlock()
    }

    var lastError: AIBackendError? {
        lock.lock(); defer { lock.unlock() }
        return last
    }
}

/// Google Gemini through its OpenAI-compatible endpoint.
public struct GeminiTransport: ChatTransport {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let apiKey: String
    let model: String
    let baseURL: URL
    let usage: CloudUsage
    let pacer: RequestPacer
    let failures: FailureLog?
    let send: Send
    let pause: @Sendable (TimeInterval) async throws -> Void
    /// Waits after a rate-limit before giving up on the call.
    let maxRetries: Int
    /// Models to move to, in order, when `model` stays overloaded.
    let alternates: [String]
    /// How long to wait before each retry of an overloaded model.
    let overloadPauses: [TimeInterval]

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()

    init(
        apiKey: String, model: String, baseURL: URL = CloudProvider.baseURL,
        usage: CloudUsage = .shared, pacer: RequestPacer = .shared, failures: FailureLog? = nil,
        maxRetries: Int = 2, alternates: [String] = [], overloadPauses: [TimeInterval] = [3, 8],
        send: @escaping Send = { try await GeminiTransport.session.data(for: $0) },
        pause: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.usage = usage
        self.pacer = pacer
        self.failures = failures
        self.maxRetries = maxRetries
        self.alternates = alternates
        self.overloadPauses = overloadPauses
        self.send = send
        self.pause = pause
    }

    public func complete(prompt: String, json: Bool, maxTokens: Int?) async throws -> String {
        var attempt = 0
        // Each setting a model might refuse is dropped, once, when Google
        // says it's the problem -- so a newer model with different rules
        // still answers instead of failing every call.
        var useReasoning = true
        var useJSONMode = json
        var useCap = maxTokens != nil
        var boost = 1
        // The chosen model first, then the others -- skipping any that
        // just kept failing, so the next call doesn't wait them out again.
        let candidates = [model] + alternates
        let usable = candidates.filter { !usage.isAvoided($0) }
        let order = usable.isEmpty ? [model] : usable
        var index = 0
        var overloadTries = 0
        while true {
            try Task.checkCancellation()
            try await pacer.waitTurn()
            let current = order[index]
            do {
                return try await request(
                    prompt: prompt, model: current, jsonMode: useJSONMode, maxTokens: useCap ? maxTokens : nil,
                    boost: boost, reasoning: useReasoning
                )
            } catch AIBackendError.overloaded(let status) {
                if overloadTries < overloadPauses.count {
                    AIProgress.current?.setNote("\(current) is overloaded (HTTP \(status)); trying again shortly")
                    try await pause(overloadPauses[overloadTries])
                    overloadTries += 1
                    AIProgress.current?.setNote(nil)
                } else if index + 1 < order.count {
                    usage.avoid(current)
                    index += 1
                    overloadTries = 0
                    AIProgress.current?.setNote("\(current) is overloaded, so GRASP is using \(order[index])")
                } else {
                    usage.avoid(current)
                    usage.recordTransportError("\(current) is overloaded right now (Google answered HTTP \(status)).")
                    failures?.record(.overloaded(status: status))
                    throw AIBackendError.overloaded(status: status)
                }
            } catch AIBackendError.badResponse(let body) where Self.adjust(
                body, reasoning: &useReasoning, jsonMode: &useJSONMode, cap: &useCap, boost: &boost
            ) {
                continue
            } catch AIBackendError.rateLimited(let retryAfter) where attempt < maxRetries {
                attempt += 1
                AIProgress.current?.setNote("\(CloudProvider.name) asked GRASP to slow down; waiting a moment")
                try await pause(min(max(retryAfter ?? 10, 1), 60))
                AIProgress.current?.setNote(nil)
            } catch let error as AIBackendError {
                switch error {
                case .badResponse(let body): usage.recordTransportError(Self.summarize(body))
                case .unauthorized: usage.recordTransportError("Google rejected the API key.")
                default: break
                }
                failures?.record(error)
                throw error
            }
        }
    }

    /// Reads a refusal and turns off the setting it names. False when
    /// there's nothing left to turn off, i.e. the failure is real.
    static func adjust(_ body: String, reasoning: inout Bool, jsonMode: inout Bool, cap: inout Bool,
                       boost: inout Int) -> Bool {
        let text = body.lowercased()
        if text.hasPrefix(emptyAnswerMarker) {
            // Thinking used up the allowance before any answer: more room.
            guard boost == 1 else { return false }
            boost = 3
            return true
        }
        if reasoning && text.contains("reasoning") { reasoning = false; return true }
        if jsonMode && (text.contains("response_format") || text.contains("json_object") || text.contains("json mode")) {
            jsonMode = false
            return true
        }
        if cap && (text.contains("max_tokens") || text.contains("max_completion_tokens")) { cap = false; return true }
        return false
    }

    static let emptyAnswerMarker = "empty_answer"

    /// A refusal in words: Google's own message when it gave one.
    static func summarize(_ body: String) -> String {
        if body.lowercased().hasPrefix(emptyAnswerMarker) {
            return "Google returned an empty answer (\(body.dropFirst(emptyAnswerMarker.count).trimmingCharacters(in: .whitespaces)))."
        }
        if let message = errorMessage(in: body) { return "Google said: \(message)" }
        return "Google answered with something GRASP couldn't read: \(body.prefix(300))"
    }

    static func errorMessage(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let object = (json as? [[String: Any]])?.first ?? (json as? [String: Any])
        let message = (object?["error"] as? [String: Any])?["message"] as? String
        return message.map { String($0.prefix(300)) }
    }

    private struct Body: Encodable {
        let model: String
        let messages: [Message]
        let response_format: Format?
        let max_tokens: Int?
        let reasoning_effort: String?
        struct Message: Encodable { let role: String; let content: String }
        struct Format: Encodable { let type: String }
    }

    private struct Reply: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Message
            let finish_reason: String?
        }
        struct Message: Decodable { let content: String? }
    }

    /// Thinking spends the answer's token allowance on reasoning nobody
    /// reads, and slows every call; turned as far down as each model allows.
    static func reasoningEffort(for model: String) -> String {
        model.contains("2.5") ? "none" : "low"
    }

    private func request(
        prompt: String, model: String, jsonMode: Bool, maxTokens: Int?, boost: Int, reasoning: Bool
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // The caps were sized for a local model's runaways; a cloud model
        // that still thinks a little counts that against the same allowance,
        // so it gets more room rather than a JSON answer cut off mid-way.
        request.httpBody = try JSONEncoder().encode(Body(
            model: model, messages: [.init(role: "user", content: prompt)],
            response_format: jsonMode ? .init(type: "json_object") : nil,
            max_tokens: maxTokens.map { max($0 * 4, 2_048) * boost },
            reasoning_effort: reasoning ? Self.reasoningEffort(for: model) : nil
        ))
        usage.recordRequest()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            usage.recordTransportError(Self.describe(error))
            throw AIBackendError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        switch status {
        case 200:
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let choice = reply.choices.first
            else { throw AIBackendError.badResponse(body) }
            guard let content = choice.message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw AIBackendError.badResponse("\(Self.emptyAnswerMarker) finish_reason: \(choice.finish_reason ?? "none")") }
            usage.recordTransportError(nil)
            return content
        case 401, 403:
            throw AIBackendError.unauthorized
        case 400 where Self.isKeyRejection(body):
            throw AIBackendError.unauthorized
        case 429:
            if Self.isDailyQuota(body) {
                usage.pauseForQuota()
                throw AIBackendError.quotaExhausted
            }
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw AIBackendError.rateLimited(retryAfter: header ?? Self.retryDelay(in: body))
        case 500...599:
            usage.recordTransportError("\(model) is overloaded right now (Google answered HTTP \(status)).")
            throw AIBackendError.overloaded(status: status)
        case 0:
            usage.recordTransportError("Google didn't answer.")
            throw AIBackendError.unreachable
        default:
            throw AIBackendError.badResponse(body)
        }
    }

    /// Google's wordings for a key it won't accept: "API key not valid",
    /// "Please pass a valid API key", status API_KEY_INVALID.
    static func isKeyRejection(_ body: String) -> Bool {
        let text = body.lowercased()
        return text.contains("api_key_invalid") || text.contains("api key not valid")
            || text.contains("valid api key") || text.contains("api key expired")
    }

    /// What went wrong, for the student: the error code and its description.
    static func describe(_ error: Error) -> String {
        if let url = error as? URLError { return "\(url.localizedDescription) (code \(url.code.rawValue))" }
        return String(describing: error)
    }

    /// Whether a transport error means "no connection" rather than "this
    /// request is malformed" -- a bad character in the key fails the
    /// request the same way a dead network does, and has to be told apart.
    static func isConnectivity(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Gemini names the quota a 429 hit; a per-day one won't clear by waiting.
    static func isDailyQuota(_ body: String) -> Bool {
        body.contains("PerDay") || body.lowercased().contains("per day")
    }

    /// `"retryDelay": "17s"` in a 429's details.
    static func retryDelay(in body: String) -> TimeInterval? {
        guard let range = body.range(of: #""retryDelay"\s*:\s*"([0-9.]+)s""#, options: .regularExpression) else { return nil }
        let value = body[range].split(separator: ":").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"s"))
        return value.flatMap(TimeInterval.init)
    }

    /// The model ids this key can use.
    public static func listModels(apiKey: String, baseURL: URL = CloudProvider.baseURL) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if isConnectivity(error) { throw AIBackendError.unreachable }
            throw AIBackendError.badResponse("The request couldn't be sent: \(describe(error))")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        switch status {
        case 200: break
        case 400 where !isKeyRejection(body): throw AIBackendError.badResponse("Google answered HTTP 400: \(body.prefix(200))")
        case 400, 401, 403: throw AIBackendError.unauthorized
        case 429: throw AIBackendError.quotaExhausted
        case 500...599: throw AIBackendError.overloaded(status: status)
        default: throw AIBackendError.badResponse("Google answered HTTP \(status): \(body.prefix(200))")
        }
        struct List: Decodable { let data: [Entry]; struct Entry: Decodable { let id: String } }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else {
            throw AIBackendError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        return list.data.map(\.id)
    }
}
