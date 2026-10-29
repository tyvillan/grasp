import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-call timing for cloud AI requests. Debug builds only, and then only
/// when `GRASP_AI_TIMING=1` is in the environment or the `GRASPAITiming`
/// default is set. In a release build every entry point below is empty, so
/// nothing is measured, kept or logged.
///
/// A record holds sizes and durations. It never holds the prompt, the reply,
/// the URL or any header, so an API key cannot end up in one.
public enum AITiming {
    public struct Call: Sendable {
        public var feature: String
        public var model: String
        public var promptChars: Int
        public var outputChars: Int
        /// Seconds spent waiting for the request pacer's turn.
        public var pacerWait: Double
        /// Seconds from sending the request to the whole reply in hand.
        public var request: Double
        /// Seconds from sending to the first byte of the reply, when known.
        public var firstByte: Double?
        /// Seconds spent connecting (DNS, TCP, TLS), 0 for a reused connection.
        public var connect: Double?
        public var reusedConnection: Bool?
        public var status: Int
        /// Nil for a call that worked; otherwise the kind of failure, never a body.
        public var failure: String? = nil
    }

    /// Names the feature a call belongs to, for the table. Set by the
    /// harness around a run; "unlabeled" otherwise.
    @TaskLocal public static var feature: String = "unlabeled"

    /// The kind of an error, for the table: no message text from the server.
    static func describeFailure(_ error: Error) -> String {
        switch error {
        case let e as AIBackendError:
            switch e {
            case .unauthorized: return "key rejected"
            case .quotaExhausted: return "daily limit"
            case .rateLimited: return "rate limited (429)"
            case .overloaded(let status): return "overloaded (HTTP \(status))"
            case .unreachable: return "unreachable"
            case .badResponse(let body):
                return body.lowercased().hasPrefix("empty_answer") ? "empty answer" : "bad response"
            default: return "error"
            }
        case is CancellationError: return "cancelled"
        default: return "error"
        }
    }

    /// A line for the timing output about something that changed the run
    /// (the pace being halved, for instance). Text only, never a key.
    public static func event(_ text: String) {
        #if DEBUG
        guard isEnabled else { return }
        lock.lock(); events.append(text); lock.unlock()
        #endif
    }

    #if DEBUG
    nonisolated(unsafe) private static var events: [String] = []

    public static func drainEvents() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = events
        events = []
        return out
    }

    /// The collector for the request in flight on this task.
    @TaskLocal static var metrics: Metrics?

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GRASP_AI_TIMING"] == "1"
            || UserDefaults.standard.bool(forKey: "GRASPAITiming")
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var calls: [Call] = []

    static func record(_ call: Call) {
        guard isEnabled else { return }
        lock.lock(); calls.append(call); lock.unlock()
    }

    /// Everything recorded since the last drain.
    public static func drain() -> [Call] {
        lock.lock(); defer { lock.unlock() }
        let out = calls
        calls = []
        return out
    }

    /// Collects the connection timings for one request.
    final class Metrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var firstByte: Double?
        private var connect: Double?
        private var reused: Bool?
        private var httpStatus: Int?
        private var errorStatus: String?

        /// What Google answered, as a number and its own status word
        /// (NOT_FOUND, INVALID_ARGUMENT...). Never the body.
        func setAnswer(status: Int, errorStatus: String?) {
            lock.lock(); httpStatus = status; self.errorStatus = errorStatus; lock.unlock()
        }

        var answer: (status: Int?, errorStatus: String?) {
            lock.lock(); defer { lock.unlock() }
            return (httpStatus, errorStatus)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let t = metrics.transactionMetrics.last, let start = t.fetchStartDate else { return }
            lock.lock(); defer { lock.unlock() }
            reused = t.isReusedConnection
            if let first = t.responseStartDate { firstByte = first.timeIntervalSince(start) }
            if let s = t.connectStartDate, let e = t.connectEndDate { connect = e.timeIntervalSince(s) } else { connect = 0 }
        }

        var snapshot: (firstByte: Double?, connect: Double?, reused: Bool?) {
            lock.lock(); defer { lock.unlock() }
            return (firstByte, connect, reused)
        }
    }
    #else
    public static func drainEvents() -> [String] { [] }
    public static var isEnabled: Bool { false }
    static func record(_ call: Call) {}
    public static func drain() -> [Call] { [] }
    #endif
}
