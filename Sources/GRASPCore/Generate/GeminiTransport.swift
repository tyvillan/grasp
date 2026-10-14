import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How urgent a request is. A student waiting on one answer (the AI judge,
/// "Explain this") must not sit behind a queue of background generation.
enum RequestPriority: Sendable { case background, interactive }

/// Per-request context carried by the task, so the transport needs no
/// extra parameters: the priority lane, and a gate the caller can watch to
/// start its own clock when the request is really sent.
enum AIRequestContext {
    @TaskLocal static var priority: RequestPriority = .background
    @TaskLocal static var gate: SendGate?
}

/// Whether a request is still waiting for the pacer's turn. A timeout that
/// is about the answer's speed holds its clock while this is true.
final class SendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = false
    var isQueued: Bool { lock.lock(); defer { lock.unlock() }; return queued }
    func setQueued(_ value: Bool) { lock.lock(); queued = value; lock.unlock() }
}

/// Spaces cloud requests out to stay under the per-minute limit. Shared by
/// every transport, since the limit is per key, not per generator.
///
/// Background requests go one at a time in arrival order, spaced
/// `minimumInterval` apart. An interactive request does not wait behind
/// them: it goes at once. It still counts: it is recorded in the same
/// one-minute window, so the background requests after it wait for room.
/// The window may be exceeded by one request in ten (at least one) for an
/// interactive call, because a student waiting is worth that and a
/// rate-limit reply is retried anyway.
actor RequestPacer {
    static let shared = RequestPacer(minimumInterval: 60.0 / Double(CloudProvider.requestsPerMinute))

    private var minimumInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var sends: [Date] = []
    private var lastSend = Date.distantPast
    private var queue: [UInt64] = []
    private var nextTicket: UInt64 = 0

    /// `now` and `sleep` are the clock, replaceable so a test can run the
    /// pacer on a clock it moves by hand instead of waiting in real time.
    init(minimumInterval: TimeInterval,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
             try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
         }) {
        self.minimumInterval = minimumInterval
        self.now = now
        self.sleep = sleep
    }

    /// Requests waiting for a turn (background ones), for tests.
    var waitingCount: Int { queue.count }

    private var planRate = GeminiPlan.freeRequestsPerMinute
    private var halvings = 0

    /// The rate in force: the plan's, halved once for each time a paid
    /// key was told to slow down this session, never below the free pace.
    var effectiveRequestsPerMinute: Int {
        halvings == 0 ? planRate : max(GeminiPlan.freeRequestsPerMinute, planRate >> halvings)
    }

    /// Follows the plan setting; takes effect for the next request.
    func setRequestsPerMinute(_ rate: Int) {
        planRate = max(1, rate)
        minimumInterval = 60.0 / Double(effectiveRequestsPerMinute)
    }

    /// A 429 on a paid key: halve the rate for the rest of the session.
    /// Returns the new rate, or nil when already at the free pace.
    @discardableResult
    func halveRate() -> Int? {
        guard planRate > GeminiPlan.freeRequestsPerMinute,
              effectiveRequestsPerMinute > GeminiPlan.freeRequestsPerMinute else { return nil }
        halvings += 1
        minimumInterval = 60.0 / Double(effectiveRequestsPerMinute)
        return effectiveRequestsPerMinute
    }

    func waitTurn(priority: RequestPriority = AIRequestContext.priority) async throws {
        guard minimumInterval > 0 else { return }
        let ticket = nextTicket
        nextTicket += 1
        if priority == .background { queue.append(ticket) }
        defer { queue.removeAll { $0 == ticket } }
        while true {
            try Task.checkCancellation()
            let now = self.now()
            sends.removeAll { now.timeIntervalSince($0) >= 60 }
            let limit = max(1, Int((60 / minimumInterval).rounded()))
            let allowed = priority == .interactive ? limit + max(1, limit / 10) : limit
            var wait: TimeInterval = 0
            if sends.count >= allowed { wait = max(wait, 60 - now.timeIntervalSince(sends[0])) }
            if priority == .background {
                wait = max(wait, minimumInterval - now.timeIntervalSince(lastSend))
            }
            let isNext = priority == .interactive || queue.first == ticket
            if wait <= 0 && isNext {
                sends.append(now)
                lastSend = now
                return
            }
            try await sleep(max(wait, 0.025))
        }
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
        send: @escaping Send = { request in
            #if DEBUG
            if CloudStub.isActive { return try await CloudStub.respond(request) }
            if AITiming.isEnabled, let metrics = AITiming.metrics {
                return try await GeminiTransport.session.data(for: request, delegate: metrics)
            }
            #endif
            return try await GeminiTransport.session.data(for: request)
        },
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

    /// Models fail one at a time: overload and daily quotas are both
    /// per-model at Google, so a call walks down the model list instead of
    /// giving up on the first one. It stops early only when three models in
    /// a row have given up as overloaded -- at that point it's the service,
    /// not the model.
    public func complete(prompt: String, json: Bool, maxTokens: Int?) async throws -> String {
        // Each setting a model might refuse is dropped, once, when Google
        // says it's the problem -- so a newer model with different rules
        // still answers instead of failing every call.
        var useReasoning = true
        var useJSONMode = json
        var useCap = maxTokens != nil
        var boost = 1
        // The chosen model first, then the rest in list order -- skipping
        // any that just failed, so the next call doesn't wait them out again.
        // Only the shared pacer follows the plan setting; a pacer made for a test keeps its own pace.
        if pacer === RequestPacer.shared {
            var rate = CloudProvider.requestsPerMinute
            #if DEBUG
            if CloudStub.isActive, let slowed = CloudStub.requestsPerMinute { rate = slowed }
            #endif
            await pacer.setRequestsPerMinute(rate)
        }
        let usable = ([model] + alternates).filter { !usage.isAvoided($0) }
        let order = usable.isEmpty ? [model] : usable
        var index = 0
        var retries = 0
        var overloadedModels = 0
        #if DEBUG
        var pacerWaited = 0.0
        #endif
        while true {
            try Task.checkCancellation()
            #if DEBUG
            let pacerStart = Date()
            #endif
            let gate = AIRequestContext.gate
            gate?.setQueued(true)
            // A long wait for a turn is the free plan's pace, not a fault;
            // say so, and say how to change it.
            let pacingNote = Self.notify(after: 8, CloudProvider.pacingNote)
            do { try await pacer.waitTurn() } catch { pacingNote.cancel(); gate?.setQueued(false); throw error }
            pacingNote.cancel()
            gate?.setQueued(false)
            #if DEBUG
            pacerWaited = Date().timeIntervalSince(pacerStart)
            #endif
            let current = order[index]
            let isLast = index + 1 >= order.count
            func moveToNext(_ reason: String) {
                index += 1
                retries = 0
                AIProgress.current?.setNote("\(reason), so GRASP is using \(order[index])")
            }
            let slowNote = Self.notify(after: 25, CloudProvider.slowNote)
            defer { slowNote.cancel() }
            do {
                #if DEBUG
                let started = Date()
                let metrics = AITiming.Metrics()
                let answer: String
                do {
                    answer = try await AITiming.$metrics.withValue(metrics) {
                        try await request(
                            prompt: prompt, model: current, jsonMode: useJSONMode, maxTokens: useCap ? maxTokens : nil,
                            boost: boost, reasoning: useReasoning
                        )
                    }
                } catch {
                    // A failed call is a row too: its time is real, and the
                    // kind of failure (never the body) says why.
                    AITiming.record(.init(
                        feature: AITiming.feature, model: current, promptChars: prompt.count, outputChars: 0,
                        pacerWait: pacerWaited, request: Date().timeIntervalSince(started),
                        firstByte: nil, connect: nil, reusedConnection: nil, status: 0,
                        failure: AITiming.describeFailure(error)))
                    throw error
                }
                let seen = metrics.snapshot
                AITiming.record(.init(
                    feature: AITiming.feature, model: current, promptChars: prompt.count, outputChars: answer.count,
                    pacerWait: pacerWaited, request: Date().timeIntervalSince(started),
                    firstByte: seen.firstByte, connect: seen.connect, reusedConnection: seen.reused, status: 200))
                return answer
                #else
                return try await request(
                    prompt: prompt, model: current, jsonMode: useJSONMode, maxTokens: useCap ? maxTokens : nil,
                    boost: boost, reasoning: useReasoning
                )
                #endif
            } catch AIBackendError.overloaded(let status) {
                // The first model gets the full wait; the others one short one.
                let pauses = index == 0 ? overloadPauses : Array(overloadPauses.prefix(1))
                if retries < pauses.count {
                    AIProgress.current?.setNote("\(current) is overloaded (HTTP \(status)); trying again shortly")
                    try await pause(pauses[retries])
                    retries += 1
                    AIProgress.current?.setNote(nil)
                    continue
                }
                usage.avoid(current, reason: "overloaded")
                overloadedModels += 1
                if isLast || overloadedModels >= 3 {
                    usage.recordTransportError(overloadedModels >= 3
                        ? "Google's Gemini service looks overloaded: \(overloadedModels) models in a row answered HTTP \(status)."
                        : "\(current) is overloaded right now (Google answered HTTP \(status)).")
                    failures?.record(.overloaded(status: status))
                    throw AIBackendError.overloaded(status: status)
                }
                moveToNext("\(current) is overloaded")
            } catch AIBackendError.quotaExhausted {
                // Daily free quotas are per model: this one is done until
                // the reset, but the next may have plenty left.
                usage.avoid(current, for: max(60, CloudUsage.nextReset(after: Date()).timeIntervalSinceNow),
                            reason: "free limit used up today")
                if isLast {
                    usage.pauseForQuota()
                    failures?.record(.quotaExhausted)
                    throw AIBackendError.quotaExhausted
                }
                moveToNext("today's free limit for \(current) is used up")
            } catch AIBackendError.rateLimited(let retryAfter) {
                if pacer === RequestPacer.shared, AIPreferences.geminiPlan == .paid,
                   let slower = await pacer.halveRate() {
                    AITiming.event("Paid key got a 429: pace halved to \(slower) requests per minute for the rest of the session")
                }
                if retries < maxRetries {
                    retries += 1
                    AIProgress.current?.setNote("\(CloudProvider.name) asked GRASP to slow down; waiting a moment")
                    try await pause(min(max(retryAfter ?? 10, 1), 60))
                    AIProgress.current?.setNote(nil)
                    continue
                }
                usage.avoid(current, for: 60, reason: "busy")
                if isLast {
                    failures?.record(.rateLimited(retryAfter: retryAfter))
                    throw AIBackendError.rateLimited(retryAfter: retryAfter)
                }
                moveToNext("\(current) is busy")
            } catch AIBackendError.badResponse(let body) where Self.adjust(
                body, reasoning: &useReasoning, jsonMode: &useJSONMode, cap: &useCap, boost: &boost
            ) {
                continue
            } catch AIBackendError.badResponse(let body) where !isLast && Self.isModelUnavailable(body) {
                // Renamed, retired or not offered to this key: skip it for an hour.
                usage.avoid(current, for: 3_600, reason: "not available to your key")
                moveToNext("\(current) isn't available")
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

    /// Shows `text` as the job's note if the call is still going after
    /// `seconds`, and takes it down again when cancelled. The caller cancels
    /// the returned task as soon as the call is over.
    static func notify(after seconds: Double, _ text: String) -> Task<Void, Never> {
        let progress = AIProgress.current
        return Task {
            guard let progress else { return }
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            progress.setNote(text)
            // Held until cancelled, then cleared if nothing replaced it.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
            if progress.snapshot.note == text { progress.setNote(nil) }
        }
    }

    /// A model Google won't serve to this key, as opposed to a request that
    /// is wrong for every model.
    static func isModelUnavailable(_ body: String) -> Bool {
        let text = body.lowercased()
        return text.contains("is not found") || text.contains("not supported for generatecontent")
            || text.contains("is not available") || text.contains("no longer available")
            || text.contains("has been deprecated") || text.contains("does not exist")
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
            usage.recordModelUsed(model)
            return content
        case 401, 403:
            throw AIBackendError.unauthorized
        case 400 where Self.isKeyRejection(body):
            throw AIBackendError.unauthorized
        case 429:
            if Self.isDailyQuota(body) { throw AIBackendError.quotaExhausted }
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
        #if DEBUG
        if CloudStub.isActive { return [CloudProvider.fallbackModel] }
        #endif
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
