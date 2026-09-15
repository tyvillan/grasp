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

    public func generateTestQuestions(
        existing: [CandidatePair], noteContext: String, maxCount: Int
    ) async -> [GeneratedTestQuestion] {
        guard maxCount > 0, !noteContext.isEmpty else { return [] }
        let prompt = Self.generateTestQuestionsPrompt(existing: existing, noteContext: noteContext, maxCount: maxCount)
        guard let content = try? await chat(prompt: prompt),
              let data = content.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([TestQuestionDTO].self, from: data)
        else { return [] }
        return Array(decoded.prefix(maxCount)).map { GeneratedTestQuestion(prompt: $0.prompt, correctAnswer: $0.answer) }
    }

    public func validateContext(
        front: String, back: String, noteContext: String, courseName: String
    ) async -> ContextValidation {
        guard !noteContext.isEmpty else { return ContextValidation(.valid) }
        let prompt = Self.validateContextPrompt(front: front, back: back, noteContext: noteContext, courseName: courseName)
        guard let content = try? await chat(prompt: prompt),
              let data = content.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ContextValidationDTO.self, from: data)
        else { return ContextValidation(.valid) }
        switch decoded.verdict.lowercased() {
        case "refine":
            guard let refined = decoded.refinedBack?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !refined.isEmpty
            else { return ContextValidation(.valid) }
            return ContextValidation(.refine(newBack: refined))
        case "reject":
            return ContextValidation(.reject)
        default:
            return ContextValidation(.valid)
        }
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

    private struct TestQuestionDTO: Decodable {
        let prompt: String
        let answer: String
    }

    private struct ContextValidationDTO: Decodable {
        let verdict: String
        let refinedBack: String?
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

    /// Same grounding contract as `generateAdditionalPrompt` (every fact
    /// must come from `noteContext`, an empty array is a normal result),
    /// but asks for a `{"prompt","answer"}` shape rather than
    /// `{"front","back"}` -- deliberately different field names so the
    /// model reads this as "ask a question, state its answer" rather than
    /// "flashcard term/definition." These are test-only and never
    /// persisted, so there's no `topic` steering parameter to plumb here.
    static func generateTestQuestionsPrompt(
        existing: [CandidatePair], noteContext: String, maxCount: Int
    ) -> String {
        let covered = existing.map { "- \($0.front): \($0.back)" }.joined(separator: "\n")
        return """
        You are a student's study assistant, writing practice questions for a test. Below is one \
        of their lecture notes, and the flashcards already made from it. Write, at most, \(maxCount) \
        short free-response practice question(s) that test understanding of this note -- prefer \
        something that requires connecting or applying an idea from the note over one that just \
        restates an existing card word-for-word. Every fact in the question and its answer must be \
        directly supported by the note text below. Do not add outside knowledge, and do not invent \
        an example, number, or date that isn't in the note. If the note doesn't support any good \
        question beyond what's already covered, return an empty array -- that is a normal and \
        expected result, not a failure.

        Note:
        \(noteContext.prefix(3000))

        Cards already made from this note:
        \(covered.isEmpty ? "(none yet)" : covered)

        Respond with ONLY a JSON array of at most \(maxCount) objects, each shaped \
        {"prompt": "...", "answer": "..."}. Return [] if there is nothing worth asking. No other text.
        """
    }

    /// Checks one already-extracted card's definition for the same
    /// "assignment logistics, not a definition" shape `PairParser`'s own
    /// deterministic filters catch by keyword/pattern -- this is the
    /// semantic backstop for the cases those miss (a rubric mention
    /// phrased as if it were content, a document-specific label, a vague
    /// fragment that reads grammatically fine but explains nothing).
    ///
    /// Two judgments, kept explicitly separate, because collapsing them
    /// into one is what caused a real bug: the model would take a bad
    /// card and just smooth over/summarize whatever text it was given --
    /// on Tyler's real College Writing course, "Con" (a garbled 3-point
    /// list about animal testing) came back truncated to its first
    /// clause, and "Topic Sentence"/"Thesis" came back nearly verbatim
    /// unchanged, none of them an actual definition of the term. First
    /// judge whether the TERM itself is a real, general course concept at
    /// all (independent of how bad its extracted definition is) -- a
    /// student's own essay-draft heading or an assignment instruction
    /// isn't one, no matter how it's phrased. Only for a term that
    /// passes that bar does a `refine` verdict ask for a *brand-new*
    /// general definition from the model's own subject knowledge, with
    /// summarizing/paraphrasing the specific extracted text explicitly
    /// ruled out.
    static func validateContextPrompt(
        front: String, back: String, noteContext: String, courseName: String
    ) -> String {
        """
        You are checking flashcards auto-extracted from a student's notes for the course \
        "\(courseName)". A flashcard's front is a term and its back should be a general, \
        academically accurate definition of that term -- the kind of definition that belongs in a \
        course glossary, true regardless of which specific assignment or example it came from.

        Term: \(front)
        Extracted definition: \(back)

        For reference, the note this was extracted from:
        \(noteContext.prefix(2000))

        First, decide: is "\(front)" itself a real, general concept a student in "\(courseName)" would \
        need to know -- the kind of term that belongs in a glossary -- or is it just a label specific \
        to this one document (a draft's section heading, an assignment instruction, a personal \
        narrative, a fragment)? Judge the TERM itself, not the quality of its extracted definition -- a \
        real term can still have a bad extracted definition.

        If "\(front)" is NOT a real general concept -- it only makes sense as a label for this \
        document's own specific content -- respond {"verdict": "reject"}.

        If "\(front)" IS a real general concept:
        - If the extracted definition already states the general concept accurately, respond \
        {"verdict": "valid"}.
        - Otherwise respond {"verdict": "refine", "refinedBack": "..."} with a brand-new, general, \
        academically accurate definition of the concept, written from your own knowledge of the \
        subject. Do NOT summarize, paraphrase, or shorten the extracted text or the note's specific \
        example -- state what the term actually means in general, the way a glossary would, even if \
        that differs from what the specific extracted text or note said.

        Respond with ONLY one JSON object shaped {"verdict": "...", "refinedBack": "..."} \
        ("refinedBack" only needed when verdict is "refine"). No other text.
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
