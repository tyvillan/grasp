import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GRASPCore

/// Canned HTTP answers, in order, and the requests that asked for them.
private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(status: Int, body: String, headers: [String: String])]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [(Int, String)], headers: [String: String] = [:]) {
        self.answers = answers.map { ($0.0, $0.1, headers) }
    }

    var send: GeminiTransport.Send {
        { [self] request in answer(request) }
    }

    private func answer(_ request: URLRequest) -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let answer: (status: Int, body: String, headers: [String: String]) = answers.isEmpty ? (500, "", [:]) : answers.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status,
                                       httpVersion: nil, headerFields: answer.headers)!
        return (Data(answer.body.utf8), response)
    }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

    func body(_ index: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: requests[index].httpBody ?? Data(), encoding: .utf8) ?? ""
    }
}

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class Pauses: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var waits: [TimeInterval] = []
    func record(_ seconds: TimeInterval) { lock.lock(); waits.append(seconds); lock.unlock() }
}

private func freshUsage(clock: Clock = Clock(Date())) -> CloudUsage {
    CloudUsage(defaults: UserDefaults(suiteName: "grasp.test.\(UUID().uuidString)")!, now: { clock.now })
}

private func reply(_ content: String) -> String {
    let escaped = String(data: try! JSONSerialization.data(withJSONObject: [content], options: [.fragmentsAllowed]), encoding: .utf8)!
    return #"{"choices":[{"message":{"role":"assistant","content":"# + escaped.dropFirst().dropLast() + "}}]}"
}

private func transport(_ server: FakeServer, usage: CloudUsage, failures: FailureLog? = nil,
                       pauses: Pauses = Pauses(), model: String = "gemini-2.5-flash",
                       alternates: [String] = []) -> GeminiTransport {
    GeminiTransport(apiKey: "test-key", model: model, usage: usage, pacer: RequestPacer(minimumInterval: 0),
                    failures: failures, alternates: alternates, send: server.send, pause: { pauses.record($0) })
}

/// Answers every call with "local", so a test can tell where a call landed.
private struct LocalStub: CardGenerator {
    var isAvailable: Bool { get async { true } }
    func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        [GeneratedCard(front: "local", back: "local")]
    }
    func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { ["local"] }
    func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
    func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
    func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation {
        ContextValidation(.valid)
    }
    func generateOverview(noteTitle: String, courseName: String, noteContext: String,
                          includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview { .empty }
    func generateFigures(noteTitle: String, courseName: String, noteContext: String,
                         sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
}

private struct EchoTransport: ChatTransport {
    let answer: String
    func complete(prompt: String, json: Bool, maxTokens: Int?) async throws -> String { answer }
}

@Suite("CloudAI")
struct CloudAITests {
    @Test("a 200 reply is read from choices[0].message.content, with the key, JSON mode and thinking off")
    func readsContent() async throws {
        let server = FakeServer([(200, reply(#"{"items":[]}"#))])
        let usage = freshUsage()
        let answer = try await transport(server, usage: usage).complete(prompt: "hi", json: true, maxTokens: 100)
        #expect(answer == #"{"items":[]}"#)
        #expect(server.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(server.requests.first?.url?.absoluteString.hasSuffix("openai/chat/completions") == true)
        let body = server.body(0)
        #expect(body.contains(#""json_object""#))
        #expect(body.contains(#""reasoning_effort":"none""#))
        #expect(body.contains(#""max_tokens":2048"#))
        #expect(usage.requestsToday == 1)
    }

    @Test("a rejected key is unauthorized, not a reason to quietly fall back")
    func badKey() async {
        let failures = FailureLog()
        let server = FakeServer([(400, #"{"error":{"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"#)])
        await #expect(throws: AIBackendError.unauthorized) {
            try await transport(server, usage: freshUsage(), failures: failures).complete(prompt: "hi", json: true, maxTokens: nil)
        }
        #expect(failures.lastError == .unauthorized)
        #expect(AIBackendError.unauthorized.warrantsFallback == false)
    }

    @Test("Google's other wording for a rejected key is unauthorized too")
    func rejectedKeyWording() async {
        let server = FakeServer([(400, #"{"error":{"code":400,"message":"Please pass a valid API key","status":"INVALID_ARGUMENT"}}"#)])
        await #expect(throws: AIBackendError.unauthorized) {
            try await transport(server, usage: freshUsage()).complete(prompt: "hi", json: true, maxTokens: nil)
        }
    }

    @Test("a request that can't be sent is unreachable, and the cause is kept for Settings to show")
    func recordsTransportError() async {
        let usage = freshUsage()
        let gemini = GeminiTransport(apiKey: "k", model: "gemini-2.5-flash", usage: usage,
                                     pacer: RequestPacer(minimumInterval: 0),
                                     send: { _ in throw URLError(.secureConnectionFailed) })
        await #expect(throws: AIBackendError.unreachable) {
            try await gemini.complete(prompt: "hi", json: true, maxTokens: nil)
        }
        #expect(usage.lastTransportError?.contains("code -1200") == true)
    }

    @Test("a pasted key is cleaned of prefixes and quotes, and refused when it can't work")
    func sanitizesKeys() {
        let real = "AIzaSyA-0123456789abcdefghijklmnopqrstu"
        #expect(AIKeyStore.sanitize("  \(real)\n").key == real)
        #expect(AIKeyStore.sanitize("GEMINI_API_KEY=\(real)").key == real)
        #expect(AIKeyStore.sanitize("GOOGLE_API_KEY=\"\(real)\"").key == real)
        #expect(AIKeyStore.sanitize("Bearer \(real)").key == real)
        #expect(AIKeyStore.sanitize(real).problem == nil)
        #expect(AIKeyStore.sanitize("AIzaSyA-0123456789…rstu").problem?.contains("ellipsis") == true)
        #expect(AIKeyStore.sanitize("AIza SyA 0123456789abcdefghij").problem?.contains("spaces") == true)
        #expect(AIKeyStore.sanitize("short").problem?.contains("too short") == true)
        #expect(AIKeyStore.sanitize("   ").problem == nil)
    }

    @Test("an overloaded model is retried after a pause, then replaced by the next model, which is remembered")
    func switchesFromOverloadedModel() async throws {
        let usage = freshUsage()
        let pauses = Pauses()
        let down = #"{"error":{"code":503,"message":"The model is overloaded. Please try again later."}}"#
        let server = FakeServer([(503, down), (503, down), (503, down), (200, reply("{}")), (200, reply("{}"))])
        let first = transport(server, usage: usage, pauses: pauses, model: "gemini-3.8-flash", alternates: ["gemini-2.5-flash"])
        _ = try await first.complete(prompt: "hi", json: true, maxTokens: nil)
        #expect(pauses.waits == [3, 8])
        #expect(server.requestCount == 4)
        #expect(server.body(0).contains("gemini-3.8-flash"))
        #expect(server.body(3).contains("gemini-2.5-flash"))
        #expect(usage.isAvoided("gemini-3.8-flash"))

        // The next call goes straight to the model that worked.
        _ = try await transport(server, usage: usage, pauses: pauses, model: "gemini-3.8-flash",
                                alternates: ["gemini-2.5-flash"]).complete(prompt: "again", json: true, maxTokens: nil)
        #expect(server.requestCount == 5)
        #expect(server.body(4).contains("gemini-2.5-flash"))
    }

    @Test("when every model is overloaded the call fails as overloaded, with the reason kept")
    func everyModelOverloaded() async {
        let usage = freshUsage()
        let down = #"{"error":{"code":503,"message":"overloaded"}}"#
        let server = FakeServer(Array(repeating: (503, down), count: 12))
        await #expect(throws: AIBackendError.overloaded(status: 503)) {
            try await transport(server, usage: usage, model: "gemini-3.8-flash", alternates: ["gemini-2.5-flash"])
                .complete(prompt: "hi", json: true, maxTokens: nil)
        }
        #expect(usage.lastTransportError?.contains("overloaded") == true)
        #expect(AIBackendError.overloaded(status: 503).warrantsFallback)
    }

    @Test("alternates are the rest of the list, in the order the picker shows it")
    func alternateOrdering() {
        let known = ["gemini-3.8-flash", "gemini-3.1-flash-preview", "gemini-3.1-pro", "gemini-2.5-flash", "gemini-2.5-pro"]
        #expect(AIPreferences.alternates(from: known, besides: "gemini-3.8-flash")
                == ["gemini-3.1-flash-preview", "gemini-3.1-pro", "gemini-2.5-flash", "gemini-2.5-pro"])
        #expect(AIPreferences.alternates(from: [], besides: "gemini-3.8-flash") == [CloudProvider.fallbackModel])
        #expect(AIPreferences.alternates(from: [], besides: CloudProvider.fallbackModel).isEmpty)
    }

    @Test("a model whose daily free quota is gone is skipped for the next, and only the last one pauses the cloud")
    func quotaIsPerModel() async throws {
        let usage = freshUsage()
        let quota = #"{"error":{"code":429,"message":"Quota exceeded for metric: GenerateRequestsPerDayPerProjectPerModel-FreeTier, limit: 0"}}"#
        let server = FakeServer([(429, quota), (200, reply("{}"))])
        _ = try await transport(server, usage: usage, model: "gemini-2.5-pro", alternates: ["gemini-2.5-flash"])
            .complete(prompt: "hi", json: true, maxTokens: nil)
        #expect(server.body(1).contains("gemini-2.5-flash"))
        #expect(usage.pausedUntil == nil)
        #expect(usage.isAvoided("gemini-2.5-pro"))

        let allGone = FakeServer([(429, quota), (429, quota)])
        await #expect(throws: AIBackendError.quotaExhausted) {
            try await transport(allGone, usage: freshUsage(), model: "gemini-2.5-pro", alternates: ["gemini-2.5-flash"])
                .complete(prompt: "hi", json: true, maxTokens: nil)
        }
    }

    @Test("three overloaded models in a row means the service is struggling, so the call stops walking the list")
    func serviceWideOverload() async {
        let usage = freshUsage()
        let down = #"{"error":{"code":503,"message":"overloaded"}}"#
        let server = FakeServer(Array(repeating: (503, down), count: 40))
        await #expect(throws: AIBackendError.overloaded(status: 503)) {
            try await transport(server, usage: usage, model: "m1", alternates: ["m2", "m3", "m4", "m5", "m6"])
                .complete(prompt: "hi", json: true, maxTokens: nil)
        }
        #expect(usage.lastTransportError?.contains("service looks overloaded") == true)
        #expect(!usage.isAvoided("m4"))
    }

    @Test("a model Google doesn't serve to this key is skipped, not treated as a failure")
    func skipsUnavailableModel() async throws {
        let server = FakeServer([(404, #"{"error":{"code":404,"message":"models/gemini-9 is not found for API version v1beta"}}"#),
                                 (200, reply("{}"))])
        _ = try await transport(server, usage: freshUsage(), model: "gemini-9", alternates: ["gemini-2.5-flash"])
            .complete(prompt: "hi", json: true, maxTokens: nil)
        #expect(server.body(1).contains("gemini-2.5-flash"))
    }

    @Test("an empty answer (thinking used the allowance) is retried with three times the room")
    func retriesEmptyAnswer() async throws {
        let empty = #"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#
        let server = FakeServer([(200, empty), (200, reply("{\"ok\":true}"))])
        let answer = try await transport(server, usage: freshUsage()).complete(prompt: "hi", json: true, maxTokens: 900)
        #expect(answer == #"{"ok":true}"#)
        #expect(server.requestCount == 2)
        #expect(server.body(0).contains(#""max_tokens":3600"#))
        #expect(server.body(1).contains(#""max_tokens":10800"#))
    }

    @Test("a model that refuses JSON mode is asked again without it")
    func dropsJSONMode() async throws {
        let server = FakeServer([(400, #"{"error":{"message":"response_format is not supported for this model"}}"#),
                                 (200, reply("{}"))])
        _ = try await transport(server, usage: freshUsage()).complete(prompt: "hi", json: true, maxTokens: nil)
        #expect(server.body(0).contains("json_object"))
        #expect(!server.body(1).contains("json_object"))
    }

    @Test("a refusal GRASP can't fix is reported in Google's own words")
    func reportsGoogleMessage() async {
        let usage = freshUsage()
        let server = FakeServer([(404, #"[{"error":{"code":404,"message":"models/gemini-9 is not found for API version v1beta"}}]"#)])
        await #expect(throws: AIBackendError.self) {
            try await transport(server, usage: usage).complete(prompt: "hi", json: true, maxTokens: nil)
        }
        #expect(usage.lastTransportError == "Google said: models/gemini-9 is not found for API version v1beta")
    }

    @Test("recording usage never holds the lock while settings change observers run (this once froze the app)")
    func noDeadlockWithDefaultsObservers() {
        let defaults = UserDefaults(suiteName: "grasp.test.\(UUID().uuidString)")!
        let usage = CloudUsage(defaults: defaults)
        // SwiftUI observes defaults and reacts on the writing thread -- and
        // what it draws reads this same object.
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in
            _ = usage.requestsToday
            _ = usage.pausedUntil
            _ = usage.lastFallback
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<50 { usage.recordRequest() }
            usage.recordFallback("Gemini is busy right now, so this is running on qwen3.5:9b.")
            usage.pauseForQuota()
            usage.clearPause()
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(usage.requestsToday == CloudProvider.estimatedRequestsPerDay)
        #expect(usage.lastFallback?.contains("qwen3.5:9b") == true)
    }

    @Test("a per-minute 429 waits the server's retryDelay and tries again")
    func retriesRateLimit() async throws {
        let limited = #"{"error":{"code":429,"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay": "17s"}]}}"#
        let server = FakeServer([(429, limited), (200, reply("{}"))])
        let pauses = Pauses()
        let answer = try await transport(server, usage: freshUsage(), pauses: pauses).complete(prompt: "hi", json: true, maxTokens: nil)
        #expect(answer == "{}")
        #expect(pauses.waits == [17])
        #expect(server.requestCount == 2)
    }

    @Test("a per-day 429 is quota exhausted, and pauses the cloud until the reset")
    func dailyQuota() async {
        let body = #"{"error":{"code":429,"details":[{"violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]}]}}"#
        let usage = freshUsage()
        await #expect(throws: AIBackendError.quotaExhausted) {
            try await transport(FakeServer([(429, body)]), usage: usage).complete(prompt: "hi", json: true, maxTokens: nil)
        }
        #expect(usage.pausedUntil != nil)
        #expect(usage.estimatedRemainingToday == 0)
    }

    @Test("a model that rejects reasoning_effort is asked again without it")
    func dropsReasoning() async throws {
        let server = FakeServer([(400, #"{"error":{"message":"reasoning_effort is not supported for this model"}}"#),
                                 (200, reply("{}"))])
        _ = try await transport(server, usage: freshUsage(), model: "gemini-3.1-pro").complete(prompt: "hi", json: true, maxTokens: nil)
        #expect(server.body(0).contains("reasoning_effort"))
        #expect(!server.body(1).contains("reasoning_effort"))
    }

    @Test("Automatic with Ollama: a call the cloud can't take runs locally, and later calls skip the cloud")
    func fallbackTransport() async throws {
        let usage = freshUsage()
        let quota = #"{"error":{"message":"Quota exceeded for GenerateRequestsPerDayPerProjectPerModel-FreeTier"}}"#
        let server = FakeServer([(429, quota)])
        let fallback = FallbackTransport(primary: transport(server, usage: usage),
                                         secondary: EchoTransport(answer: "from local"),
                                         secondaryName: "qwen3.5:9b", usage: usage)
        let first = try await fallback.complete(prompt: "a", json: true, maxTokens: nil)
        let second = try await fallback.complete(prompt: "b", json: true, maxTokens: nil)
        #expect(first == "from local")
        #expect(second == "from local")
        #expect(server.requestCount == 1)
        #expect(usage.lastFallback?.contains("qwen3.5:9b") == true)
    }

    @Test("Automatic with Apple's model: a whole call the cloud couldn't finish is redone locally")
    func fallbackGenerator() async {
        let usage = freshUsage()
        let failures = FailureLog()
        let gemini = GeminiTransport(apiKey: "k", model: "gemini-2.5-flash", usage: usage,
                                     pacer: RequestPacer(minimumInterval: 0), failures: failures,
                                     send: { _ in throw URLError(.notConnectedToInternet) })
        let cloud = CloudGenerator(model: "gemini-2.5-flash", localModelName: nil, hasKey: true, failures: failures,
                                   pipeline: OllamaGenerator(transport: gemini, model: "gemini-2.5-flash", wordBudget: 6_000))
        let automatic = FallbackGenerator(cloud: cloud, local: LocalStub(), localName: "Apple's on-device model", usage: usage)
        let cards = await automatic.refine([CandidatePair(front: "Term", back: "Meaning", sourceLine: 1)], noteContext: "notes")
        #expect(cards.map(\.front) == ["local"])
        #expect(usage.lastFallback?.contains("can't be reached") == true)
    }

    @Test("select picks by mode, key and what's local")
    func selection() {
        let ollama = OllamaGenerator(model: "qwen3.5:9b")
        #expect(CardGenerators.select(mode: .local, cloudKey: "k", cloudModel: "m", local: ollama) is OllamaGenerator)
        #expect(CardGenerators.select(mode: .cloud, cloudKey: nil, cloudModel: "m", local: ollama) is NoGenerator)
        #expect(CardGenerators.select(mode: .automatic, cloudKey: nil, cloudModel: "m", local: ollama) is OllamaGenerator)

        let cloud = CardGenerators.select(mode: .cloud, cloudKey: "k", cloudModel: "m", local: NoGenerator())
        #expect((cloud as? CloudGenerator)?.localModelName == nil)
        #expect((cloud as? CloudGenerator)?.overviewContextWordBudget == 6_000)

        let withOllama = CardGenerators.select(mode: .automatic, cloudKey: "k", cloudModel: "m", local: ollama)
        #expect((withOllama as? CloudGenerator)?.localModelName == "qwen3.5:9b")
        #expect((withOllama as? CloudGenerator)?.overviewContextWordBudget == 3_000)

        #expect(CardGenerators.select(mode: .automatic, cloudKey: "k", cloudModel: "m", local: LocalStub()) is FallbackGenerator)
        #expect(OverviewOrigin.of(withOllama)?.origin == .cloud)
        #expect(OverviewOrigin.of(ollama)?.origin == .ollama)
    }

    @Test("today's count and a quota pause both end at midnight Pacific")
    func dayRollover() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = CloudProvider.quotaTimeZone
        let lateEvening = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 23, minute: 50)))
        let clock = Clock(lateEvening)
        let usage = freshUsage(clock: clock)
        usage.recordRequest()
        usage.recordRequest()
        usage.pauseForQuota()
        #expect(usage.requestsToday == CloudProvider.estimatedRequestsPerDay)
        #expect(usage.pausedUntil != nil)

        clock.now = lateEvening.addingTimeInterval(15 * 60)
        #expect(usage.requestsToday == 0)
        #expect(usage.pausedUntil == nil)
    }

    @Test("the live model list is narrowed to text models, newest Flash first")
    func modelRanking() {
        let ranked = CloudProvider.chatModels(from: [
            "models/gemini-2.5-flash", "gemini-3.1-pro", "gemini-3.1-flash", "gemini-3.1-flash-lite",
            "gemini-2.5-flash-image", "gemini-embedding-001", "gemma-3-27b-it", "gemini-3.1-flash-preview-tts",
        ])
        #expect(ranked.first == "gemini-3.1-flash")
        #expect(ranked.contains("gemini-2.5-flash"))
        #expect(!ranked.contains { $0.contains("image") || $0.contains("embedding") || $0.contains("tts") || $0.hasPrefix("gemma") })
        #expect(ranked.firstIndex(of: "gemini-3.1-pro")! < ranked.firstIndex(of: "gemini-3.1-flash-lite")!)
    }

    @Test("a big job warns only when it won't fit in what's left today")
    func quotaWarning() {
        let usage = freshUsage()
        #expect(AIQuotaEstimate.warning(needed: 10, mode: .automatic, usage: usage) == nil)
        #expect(AIQuotaEstimate.warning(needed: 10_000, mode: .local, usage: usage) == nil)
        let automatic = AIQuotaEstimate.warning(needed: 10_000, mode: .automatic, usage: usage)
        #expect(automatic?.contains("finish the rest on your local model") == true)
        let cloud = AIQuotaEstimate.warning(needed: 10_000, mode: .cloud, usage: usage)
        #expect(cloud?.contains("midnight Pacific") == true)
    }
}
