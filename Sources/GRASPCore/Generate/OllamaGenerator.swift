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

    private struct TagsResponse: Decodable {
        let models: [ModelEntry]
        struct ModelEntry: Decodable { let name: String }
    }

    /// The model names actually pulled on this server, for Settings'
    /// status section -- an empty array (never a thrown error) whether
    /// that's because the server is unreachable, in the 2-second budget
    /// every check in this type keeps, or reachable but genuinely bare.
    public func installedModels() async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data)
        else { return [] }
        return decoded.models.map(\.name)
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

    public func generateAdditional(
        existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?
    ) async -> [GeneratedCard] {
        guard maxCount > 0, !noteContext.isEmpty else { return [] }
        let prompt = Self.generateAdditionalPrompt(
            existing: existing, noteContext: noteContext, maxCount: maxCount, topic: topic
        )
        guard let content = try? await chat(prompt: prompt),
              let data = content.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RefinedPairDTO].self, from: data)
        else { return [] }
        return Array(decoded.prefix(maxCount)).map { GeneratedCard(front: $0.front, back: $0.back) }
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

    /// Deliberately more restrictive than `refinePrompt`: this one is
    /// allowed to add cards the parser never produced, so the instruction
    /// to stay grounded in the note text (and to prefer an empty array
    /// over a forced answer) matters even more here than it does there.
    /// `topic`, when given, narrows *where to look* -- it never relaxes
    /// the "don't add outside knowledge" instruction below it.
    static func generateAdditionalPrompt(
        existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String? = nil
    ) -> String {
        let covered = existing.map { "- \($0.front): \($0.back)" }.joined(separator: "\n")
        let trimmedTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusLine = (trimmedTopic?.isEmpty == false) ? "Focus especially on: \(trimmedTopic!).\n\n" : ""
        return """
        You are a student's study assistant. Below is one of their lecture notes, and the flashcards \
        already made from it. Your job is to find, at most, \(maxCount) additional concept(s) this \
        note itself mentions or clearly implies but that aren't covered by an existing card yet -- \
        for example a term used in passing but never given its own definition, or a listed item \
        without an example. Every fact on a new card must be directly supported by the note text \
        below. Do not add outside knowledge, and do not invent an example, number, or date that \
        isn't in the note. If you can't find any such gap, return an empty array -- that is a normal \
        and expected result, not a failure.

        \(focusLine)Note:
        \(noteContext.prefix(3000))

        Cards already made from this note:
        \(covered.isEmpty ? "(none yet)" : covered)

        Respond with ONLY a JSON array of at most \(maxCount) objects, each shaped \
        {"front": "...", "back": "..."}. Return [] if there is nothing worth adding. No other text.
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
