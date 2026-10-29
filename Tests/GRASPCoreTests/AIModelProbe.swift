import Testing
import Foundation
@testable import GRASPCore

/// Sends the same card-generation request once to every model the key
/// lists and prints how each one answered. Skipped unless
/// `GRASP_TIMING_PROBE=1`. About one request per model.
///
/// Output carries only: model name, HTTP status, Google's status word,
/// timings, token counts, and for a 429 the quota's name and limit value
/// (checked to be plain identifiers and digits). Never the key, the URL, or
/// any response body.
@Suite("AI model probe")
struct AIModelProbe {
    @Test("one request per listed model",
          .enabled(if: ProcessInfo.processInfo.environment["GRASP_TIMING_PROBE"] == "1"))
    func probe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["GRASP_TIMING_GEMINI_KEY"], !key.isEmpty else {
            Issue.record("GRASP_TIMING_GEMINI_KEY is not set")
            return
        }
        let ids = try await GeminiTransport.listModels(apiKey: key)
        let models = CloudProvider.chatModels(from: ids)
        let prompt = OllamaGenerator.plainNotationRule + OllamaGenerator.generateAdditionalPrompt(
            existing: [], noteContext: AIFeatureTimingHarness.note, maxCount: 5)

        var lines = ["model | HTTP | status | first byte s | total s | prompt tok | output tok | quota"]
        for (index, model) in models.enumerated() {
            if index > 0 { try await Task.sleep(nanoseconds: 7_000_000_000) }
            lines.append(await Self.ask(model: model, prompt: prompt, key: key))
        }
        let out = lines.joined(separator: "\n") + "\n"
        try out.write(toFile: env["GRASP_TIMING_OUT"] ?? "/tmp/cloud-speed-probe.txt", atomically: true, encoding: .utf8)
        #expect(!models.isEmpty)
    }

    private struct Body: Encodable {
        let model: String
        let messages: [Message]
        let response_format: Format
        let reasoning_effort: String
        struct Message: Encodable { let role: String; let content: String }
        struct Format: Encodable { let type: String }
    }

    static func ask(model: String, prompt: String, key: String) async -> String {
        var request = URLRequest(url: CloudProvider.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(Body(
            model: model, messages: [.init(role: "user", content: prompt)],
            response_format: .init(type: "json_object"),
            reasoning_effort: GeminiTransport.reasoningEffort(for: model)))
        let metrics = AITiming.Metrics()
        let started = Date()
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request, delegate: metrics)
            let total = Date().timeIntervalSince(started)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let first = metrics.snapshot.firstByte.map { String(format: "%.1f", $0) } ?? "-"
            if status == 200 {
                let usage = tokens(in: data)
                return String(format: "%@ | 200 | OK | %@ | %.1f | %@ | %@ | -", model, first, total, usage.0, usage.1)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            let word = GeminiTransport.errorStatusWord(in: body) ?? "-"
            return String(format: "%@ | %d | %@ | %@ | %.1f | - | - | %@", model, status, word, first, total, quota(in: data))
        } catch {
            return "\(model) | 0 | \(GeminiTransport.describe(error).prefix(60)) | - | - | - | - | -"
        }
    }

    private static func tokens(in data: Data) -> (String, String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else { return ("-", "-") }
        let p = (usage["prompt_tokens"] as? Int).map(String.init) ?? "-"
        let c = (usage["completion_tokens"] as? Int).map(String.init) ?? "-"
        return (p, c)
    }

    /// The quota a 429 names: its id and limit value, each checked to be a
    /// plain identifier or digits, so nothing else can reach the output.
    static func quota(in data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return "-" }
        let object = (json as? [[String: Any]])?.first ?? (json as? [String: Any])
        guard let details = (object?["error"] as? [String: Any])?["details"] as? [[String: Any]] else { return "-" }
        var found: [String] = []
        for detail in details {
            for violation in (detail["violations"] as? [[String: Any]]) ?? [] {
                guard let id = violation["quotaId"] as? String,
                      id.count <= 80, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
                else { continue }
                let value = (violation["quotaValue"] as? String).flatMap { $0.allSatisfy(\.isNumber) && $0.count <= 12 ? $0 : nil }
                let kind = id.contains("PerDay") ? "per day" : (id.contains("PerMinute") ? "per minute" : "other")
                found.append("\(id)=\(value ?? "?") (\(kind))")
            }
        }
        return found.isEmpty ? "-" : found.joined(separator: "; ")
    }
}
