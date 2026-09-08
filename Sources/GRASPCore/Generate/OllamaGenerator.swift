import Foundation

/// Talks to a local Ollama server (`127.0.0.1:11434`) for card refinement
/// and distractor generation. Ollama isn't installed on the machine this
/// was built on, so this is written against the documented REST API and
/// verified only by what's actually testable without a server: prompt
/// construction, response parsing, and graceful unavailability. Every
/// failure mode (server not running, model not pulled, malformed JSON
/// back) falls back to returning the input untouched rather than
/// throwing -- callers never need a special case for "Ollama isn't set
/// up," which is the whole point of it being optional.
public struct OllamaGenerator: CardGenerator {
    private let baseURL: URL
    private let model: String
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String = "qwen2.5:7b-instruct"
    ) {
        self.baseURL = baseURL
        self.model = model
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    public var isAvailable: Bool {
        get async {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
            request.timeoutInterval = 2
            guard let (_, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return false }
            return http.statusCode == 200
        }
    }

    /// Candidates are batched (per the design, ~15 at a time) so a single
    /// request/response stays small enough for a 7-8B local model to
    /// handle reliably; batches run sequentially to stay polite to a
    /// single local server with no concurrency budget of its own.
    private static let batchSize = 15

    public func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        guard !candidates.isEmpty else { return [] }
        var results: [GeneratedCard] = []
        for batch in stride(from: 0, to: candidates.count, by: Self.batchSize) {
            let slice = Array(candidates[batch..<min(batch + Self.batchSize, candidates.count)])
            results += await refineBatch(slice, noteContext: noteContext)
        }
        return results
    }

    private func refineBatch(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        let fallback = candidates.map { GeneratedCard(front: $0.front, back: $0.back) }
        let prompt = Self.refinePrompt(candidates: candidates, noteContext: noteContext)
        guard let content = try? await chat(prompt: prompt),
              let data = content.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RefinedPairDTO].self, from: data),
              decoded.count == candidates.count
        else { return fallback }
        return decoded.map { GeneratedCard(front: $0.front, back: $0.back) }
    }

    public func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] {
        let fallback = Array(deckContext.filter { $0 != correctAnswer }.shuffled().prefix(count))
        guard !deckContext.isEmpty else { return fallback }
        let prompt = Self.distractorPrompt(correctAnswer: correctAnswer, deckContext: deckContext, count: count)
        guard let content = try? await chat(prompt: prompt),
              let data = content.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data),
              !decoded.isEmpty
        else { return fallback }
        return Array(decoded.prefix(count))
    }

    // MARK: - HTTP

    private struct RefinedPairDTO: Decodable {
        let front: String
        let back: String
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let format: String
        let stream: Bool
        struct Message: Encodable { let role: String; let content: String }
    }

    private struct ChatResponse: Decodable {
        let message: Message
        struct Message: Decodable { let content: String }
    }

    private func chat(prompt: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model, messages: [.init(role: "user", content: prompt)], format: "json", stream: false
        ))
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(ChatResponse.self, from: data).message.content
    }

    // MARK: - Prompts

    static func refinePrompt(candidates: [CandidatePair], noteContext: String) -> String {
        let items = candidates.enumerated()
            .map { "\($0.offset). front: \"\($0.element.front)\" back: \"\($0.element.back)\"" }
            .joined(separator: "\n")
        return """
        You are cleaning up flashcards auto-extracted from a student's lecture notes. \
        For each numbered pair below, rewrite the front as a short, clear term or question, \
        and the back as a concise, accurate answer -- fix any obvious OCR/parsing artifacts, \
        but preserve the actual meaning. Do not invent facts not implied by the note context.

        Note context:
        \(noteContext.prefix(2000))

        Pairs:
        \(items)

        Respond with ONLY a JSON array of exactly \(candidates.count) objects, in the same order, \
        each shaped {"front": "...", "back": "..."}. No other text.
        """
    }

    static func distractorPrompt(correctAnswer: String, deckContext: [String], count: Int) -> String {
        let examples = deckContext.prefix(20).map { "- \($0)" }.joined(separator: "\n")
        return """
        The correct answer to a flashcard question is: "\(correctAnswer)"

        Here are other real answers from the same deck, for style and topic grounding:
        \(examples)

        Generate \(count) plausible but definitely incorrect distractor answers for a multiple-choice \
        question, in the same style and length as the correct answer. They must be clearly wrong to \
        someone who knows the material, not near-duplicates of the correct answer.

        Respond with ONLY a JSON array of \(count) strings. No other text.
        """
    }
}
