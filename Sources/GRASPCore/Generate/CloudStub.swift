import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A stand-in for Google's server, for screenshots and demos of how the
/// cloud features look when it is slow, busy or unreachable. It exists only
/// in debug builds, and even there it does nothing unless the app sets
/// `mode` at launch (the app does so only with `-GRASPAllowStubs 1` and
/// `GRASP_STUB_CLOUD` in the environment). No network, no key, no real data.
public enum CloudStub {
    #if DEBUG
    /// "ok", "slow", "sections" or "unreachable".
    ///
    /// Read from the environment the first time anything asks, so it is
    /// settled before the Keychain could be touched at launch: a debug
    /// build with `-GRASPAllowStubs 1` and `GRASP_STUB_CLOUD` set.
    nonisolated(unsafe) public static var mode: String? = fromEnvironment()

    private static func fromEnvironment() -> String? {
        guard UserDefaults.standard.bool(forKey: "GRASPAllowStubs") else { return nil }
        let value = ProcessInfo.processInfo.environment["GRASP_STUB_CLOUD"]
        return (value?.isEmpty == false) ? value : nil
    }
    nonisolated(unsafe) public static var slowSeconds: Double = 40
    public static var isActive: Bool { mode != nil }
    /// `GRASP_STUB_CLOUD_RPM=3` slows the pace so the "waiting for a
    /// turn" note can be shown without waiting minutes.
    nonisolated(unsafe) public static var requestsPerMinute: Int? = {
        guard UserDefaults.standard.bool(forKey: "GRASPAllowStubs") else { return nil }
        return ProcessInfo.processInfo.environment["GRASP_STUB_CLOUD_RPM"].flatMap(Int.init)
    }()

    static func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let mode else { throw URLError(.notConnectedToInternet) }
        if mode == "unreachable" {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            throw URLError(.notConnectedToInternet)
        }
        let delay: Double = mode == "slow" ? slowSeconds : (mode == "sections" ? 3 : 0.3)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        let prompt = promptText(in: request)
        let content = canned(for: prompt)
        let reply: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
        let data = try JSONSerialization.data(withJSONObject: reply)
        let url = request.url ?? URL(string: "https://stub.invalid")!
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private static func promptText(in request: URLRequest) -> String {
        guard let body = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]],
              let text = messages.first?["content"] as? String else { return "" }
        return text
    }

    private static func canned(for prompt: String) -> String {
        let headings = ["Processes and threads", "Scheduling", "Synchronisation", "Memory"]
        if prompt.contains("You are planning a short lesson") {
            let sections = headings.map { #"{"heading": "\#($0)", "covers": "\#($0) in the note"}"# }.joined(separator: ",")
            return #"{"title": "How an operating system shares a computer", "hook": "Why does a computer seem to do many things at once?", "objectives": ["Tell a process from a thread", "Explain why scheduling needs a time slice"], "sections": [\#(sections)], "takeaways": ["A process owns memory; threads share it."]}"#
        }
        if prompt.contains("checking a lesson a student will study") { return #"{"sections": []}"# }
        if prompt.contains("You are checking flashcards") { return #"{"results": []}"# }
        if prompt.contains("find, at most,") {
            return #"[{"front": "Quantum", "back": "The fixed time slice round robin gives each thread."}, {"front": "Thrashing", "back": "A state where processes spend more time handling page faults than running."}]"#
        }
        if prompt.contains("Heading") || prompt.contains("section") {
            return #"{"paragraphs": ["A process is a program in execution with its own address space. Threads inside it share that space but each has its own stack.", "Switching between threads of one process is cheaper than switching between processes."]}"#
        }
        return "{}"
    }
    #endif
}
