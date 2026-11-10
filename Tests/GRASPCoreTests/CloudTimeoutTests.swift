import Testing
import Foundation
@testable import GRASPCore

/// A newest model that hangs used to cost two minutes a call, then send the
/// whole job to the local model as "can't be reached". A model that does not
/// answer in time is now skipped for the next one, and the one that worked
/// last is asked first.
@Suite("Cloud timeouts and the last working model")
struct CloudTimeoutTests {
    /// Answers by model: "ok" models reply, the rest time out.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        let working: Set<String>
        init(working: Set<String>) { self.working = working }
        var models: [String] { lock.lock(); defer { lock.unlock() }; return asked }

        private func note(_ model: String) { lock.lock(); asked.append(model); lock.unlock() }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let model = body?["model"] as? String ?? ""
            note(model)
            guard working.contains(model) else { throw URLError(.timedOut) }
            let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func usage() -> CloudUsage {
        CloudUsage(defaults: UserDefaults(suiteName: "grasp.test.\(UUID().uuidString)")!)
    }

    private func transport(_ script: Script, usage: CloudUsage, model: String, alternates: [String],
                           failures: FailureLog? = nil) -> GeminiTransport {
        GeminiTransport(apiKey: "k", model: model, usage: usage, pacer: RequestPacer(minimumInterval: 0), failures: failures,
                        alternates: alternates, send: script.send, pause: { _ in })
    }

    @Test("a model that times out is skipped at once, with no second try, and the next one answers")
    func movesOn() async throws {
        let script = Script(working: ["gemini-3.6-flash"])
        let usage = usage()
        let answer = try await transport(script, usage: usage, model: "gemini-3.8-flash",
                                         alternates: ["gemini-3.6-flash", "gemini-2.5-flash"])
            .complete(prompt: "hi", json: false, maxTokens: nil)
        #expect(answer == "ok")
        #expect(script.models == ["gemini-3.8-flash", "gemini-3.6-flash"])
        #expect(usage.isAvoided("gemini-3.8-flash"))
        #expect(usage.lastUsedModel == "gemini-3.6-flash")
    }

    @Test("a model that timed out is not asked again on the next call")
    func notAskedAgain() async throws {
        let script = Script(working: ["gemini-3.6-flash"])
        let usage = usage()
        let t = transport(script, usage: usage, model: "gemini-3.8-flash", alternates: ["gemini-3.6-flash"])
        _ = try await t.complete(prompt: "one", json: false, maxTokens: nil)
        _ = try await t.complete(prompt: "two", json: false, maxTokens: nil)
        #expect(script.models == ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.6-flash"])
    }

    @Test("two models in a row that time out stop the call as timed out, not as unreachable")
    func twoInARow() async {
        let script = Script(working: [])
        let usage = usage()
        let failures = FailureLog()
        await #expect(throws: AIBackendError.timedOut) {
            try await transport(script, usage: usage, model: "m1", alternates: ["m2", "m3", "m4"], failures: failures)
                .complete(prompt: "hi", json: false, maxTokens: nil)
        }
        #expect(script.models == ["m1", "m2"])
        #expect(failures.lastError == .timedOut)
        #expect(usage.lastTransportError?.contains("took too long to answer") == true)
    }

    @Test("a lone model that times out says so")
    func lone() async {
        let script = Script(working: [])
        let usage = usage()
        await #expect(throws: AIBackendError.timedOut) {
            try await transport(script, usage: usage, model: "only", alternates: []).complete(prompt: "hi", json: false, maxTokens: nil)
        }
        #expect(usage.lastTransportError?.contains("took longer than 45 seconds") == true)
    }

    @Test("a timeout falls back to the local model, with its own words")
    func fallbackWords() async throws {
        #expect(AIBackendError.timedOut.warrantsFallback)
        let text = FallbackMessage.text(for: .timedOut, local: "qwen3.5:9b")
        #expect(text == "Gemini took too long to answer, so this is running on qwen3.5:9b.")
        #expect(!text.contains("can't be reached"))
        let failure = CloudFailureText.text(for: .timedOut)
        #expect(failure.hasSuffix(".") && !failure.contains(" -- "))
        #expect(CloudFailureText.isOwn(failure))
    }

    @Test("the wait for a reply is 45 seconds, not two minutes")
    func timeout() {
        #expect(GeminiTransport.requestTimeout == 45)
        #expect(GeminiTransport.session.configuration.timeoutIntervalForRequest == 45)
        #expect(GeminiTransport.session.configuration.timeoutIntervalForResource == 90)
    }

    // MARK: - The model asked first

    private func defaults(list: [String], best: String? = nil, worked: String? = nil, pinned: String? = nil) -> UserDefaults {
        let d = UserDefaults(suiteName: "grasp.test.\(UUID().uuidString)")!
        d.set(list, forKey: CloudModelSelection.listKey)
        if let best { d.set(best, forKey: CloudModelSelection.bestKey) }
        if let worked { d.set(worked, forKey: CloudModelSelection.lastWorkingKey) }
        if let pinned { d.set(pinned, forKey: CloudModelSelection.pinnedKey) }
        return d
    }
    private let list = ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-2.5-flash"]

    @Test("the model that worked last is asked first, ahead of the newest")
    func lastWorkingFirst() {
        let selection = CloudModelSelection.read(from: defaults(list: list, best: "gemini-3.8-flash", worked: "gemini-3.6-flash"))
        #expect(selection.primary == "gemini-3.6-flash")
        #expect(selection.source == "last working")
        #expect(selection.alternates == ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-2.5-flash"])
    }

    @Test("a pinned model is used alone, and a last working model that left the list is ignored")
    func pinnedAndStale() {
        let pinned = CloudModelSelection.read(from: defaults(list: list, best: "gemini-3.8-flash", worked: "gemini-3.6-flash",
                                                             pinned: "gemini-2.5-flash"))
        #expect(pinned.primary == "gemini-2.5-flash" && pinned.alternates.isEmpty)
        let stale = CloudModelSelection.read(from: defaults(list: list, best: "gemini-3.8-flash", worked: "gemini-1.0-retired"))
        #expect(stale.primary == "gemini-3.8-flash" && stale.source == "remembered")
        let none = CloudModelSelection.read(from: defaults(list: list, best: "gemini-3.8-flash"))
        #expect(none.primary == "gemini-3.8-flash")
    }

    @Test("the model that answers is remembered across launches")
    func remembered() async throws {
        let suite = "grasp.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        CloudUsage(defaults: d).recordModelUsed("gemini-3.6-flash")
        // Written on a background queue; give it a moment.
        for _ in 0..<50 where d.string(forKey: CloudModelSelection.lastWorkingKey) == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(d.string(forKey: CloudModelSelection.lastWorkingKey) == "gemini-3.6-flash")
        #expect(CloudUsage(defaults: d).lastUsedModel == "gemini-3.6-flash")
    }
}
