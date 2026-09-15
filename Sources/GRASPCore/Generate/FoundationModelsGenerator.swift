import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model as the zero-install fallback generator: no
/// download, no server to run, but noticeably weaker than a local 7B at
/// this task, and it requires Apple Intelligence to be enabled (checked
/// for real via `SystemLanguageModel.default.availability`, never assumed
/// from the OS version alone). Gated to macOS 26+ since the universal
/// build still runs on older systems via `OllamaGenerator`/`NoGenerator`.
@available(macOS 26.0, *)
public struct FoundationModelsGenerator: CardGenerator {
    public init() {}

    public var isAvailable: Bool {
        get async {
            #if canImport(FoundationModels)
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
            return false
            #else
            return false
            #endif
        }
    }

    #if canImport(FoundationModels)
    @Generable
    fileprivate struct RefinedCard {
        @Guide(description: "A short, clear flashcard term or question")
        var front: String
        @Guide(description: "A concise, accurate answer")
        var back: String
    }
    #endif

    public func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        let fallback = candidates.map { GeneratedCard(front: $0.front, back: $0.back) }
        #if canImport(FoundationModels)
        guard await isAvailable, !candidates.isEmpty else { return fallback }
        let session = LanguageModelSession(
            instructions: "You clean up flashcards auto-extracted from lecture notes: fix parsing " +
                "artifacts, keep the front short and the back accurate, never invent facts."
        )
        var results: [GeneratedCard] = []
        for candidate in candidates {
            let prompt = """
            Note context: \(noteContext.prefix(500))
            Front: \(candidate.front)
            Back: \(candidate.back)
            """
            guard let response = try? await session.respond(to: prompt, generating: RefinedCard.self) else {
                results.append(GeneratedCard(front: candidate.front, back: candidate.back))
                continue
            }
            results.append(GeneratedCard(front: response.content.front, back: response.content.back))
        }
        return results
        #else
        return fallback
        #endif
    }

    #if canImport(FoundationModels)
    @Generable
    fileprivate struct AdditionalCards {
        @Guide(description: "Additional flashcards for concepts this note implies but doesn't already have a card for. Empty if there are none.")
        var cards: [RefinedCard]
    }
    #endif

    public func generateAdditional(
        existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?
    ) async -> [GeneratedCard] {
        #if canImport(FoundationModels)
        guard await isAvailable, maxCount > 0, !noteContext.isEmpty else { return [] }
        let instructions = """
            You are a student's study assistant. Given one of their lecture notes and the flashcards \
            already made from it, find at most a few additional concepts the note itself mentions or \
            implies but that aren't covered yet. Every fact must be directly supported by the note \
            text -- never add outside knowledge or invent an example, number, or date the note doesn't \
            contain. An empty result is normal and expected when the note has no such gap.
            """
        let session = LanguageModelSession(instructions: instructions)
        let covered = existing.map { "- \($0.front): \($0.back)" }.joined(separator: "\n")
        let trimmedTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusLine = (trimmedTopic?.isEmpty == false) ? "Focus especially on: \(trimmedTopic!).\n" : ""
        let prompt = """
        \(focusLine)Note: \(noteContext.prefix(1500))
        Cards already made from this note:
        \(covered.isEmpty ? "(none yet)" : covered)
        Propose at most \(maxCount) additional card(s).
        """
        guard let response = try? await session.respond(to: prompt, generating: AdditionalCards.self) else {
            return []
        }
        return response.content.cards.prefix(maxCount).map { GeneratedCard(front: $0.front, back: $0.back) }
        #else
        return []
        #endif
    }

    #if canImport(FoundationModels)
    @Generable
    fileprivate struct TestQuestion {
        @Guide(description: "A short free-response practice question testing understanding of the note")
        var prompt: String
        @Guide(description: "The correct answer to the question")
        var correctAnswer: String
    }

    @Generable
    fileprivate struct TestQuestions {
        @Guide(description: "Free-response practice questions grounded in the note. Empty if none are worth asking.")
        var questions: [TestQuestion]
    }
    #endif

    public func generateTestQuestions(
        existing: [CandidatePair], noteContext: String, maxCount: Int
    ) async -> [GeneratedTestQuestion] {
        #if canImport(FoundationModels)
        guard await isAvailable, maxCount > 0, !noteContext.isEmpty else { return [] }
        let instructions = """
            You are a student's study assistant, writing practice questions for a test. Given one of \
            their lecture notes and the flashcards already made from it, write a few short \
            free-response questions that test understanding of the note -- prefer connecting or \
            applying an idea over restating an existing card word-for-word. Every fact in the \
            question and its answer must be directly supported by the note text -- never add outside \
            knowledge or invent an example, number, or date the note doesn't contain. An empty result \
            is normal and expected when the note has nothing more worth asking.
            """
        let session = LanguageModelSession(instructions: instructions)
        let covered = existing.map { "- \($0.front): \($0.back)" }.joined(separator: "\n")
        let prompt = """
        Note: \(noteContext.prefix(1500))
        Cards already made from this note:
        \(covered.isEmpty ? "(none yet)" : covered)
        Write at most \(maxCount) practice question(s).
        """
        guard let response = try? await session.respond(to: prompt, generating: TestQuestions.self) else {
            return []
        }
        return response.content.questions.prefix(maxCount)
            .map { GeneratedTestQuestion(prompt: $0.prompt, correctAnswer: $0.correctAnswer) }
        #else
        return []
        #endif
    }

    #if canImport(FoundationModels)
    @Generable
    fileprivate struct ContextCheck {
        @Guide(description: "Exactly one of: valid, refine, reject")
        var verdict: String
        @Guide(description: "Only meaningful when verdict is refine: a concise definition drawn only from the note text. Empty string otherwise.")
        var refinedBack: String
    }
    #endif

    public func validateContext(
        front: String, back: String, noteContext: String, courseName: String
    ) async -> ContextValidation {
        #if canImport(FoundationModels)
        guard await isAvailable, !noteContext.isEmpty else { return ContextValidation(.valid) }
        let instructions = """
            You are checking flashcards auto-extracted from a student's notes for the course \
            "\(courseName)". A flashcard's front is a term and its back should be a general, \
            academically accurate definition of that term -- the kind that belongs in a course \
            glossary, true regardless of which specific assignment or example it came from.

            First decide whether the term itself is a real, general concept a student in this course \
            would need to know, or just a label specific to this one document (a draft's section \
            heading, an assignment instruction, a personal narrative, a fragment) -- judge the term \
            itself, not the quality of its extracted definition. If it's not a real general concept, \
            verdict is "reject". If it is: verdict is "valid" when the extracted definition already \
            states the general concept accurately; otherwise verdict is "refine" with a brand-new, \
            general, academically accurate definition written from your own knowledge of the subject. \
            Do not summarize, paraphrase, or shorten the extracted text or the note's specific \
            example -- state what the term actually means in general, even if that differs from what \
            the specific extracted text or note said.
            """
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Term: \(front)
        Extracted definition: \(back)
        Note: \(noteContext.prefix(1500))
        """
        guard let response = try? await session.respond(to: prompt, generating: ContextCheck.self) else {
            return ContextValidation(.valid)
        }
        switch response.content.verdict.lowercased() {
        case "refine":
            let refined = response.content.refinedBack.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !refined.isEmpty else { return ContextValidation(.valid) }
            return ContextValidation(.refine(newBack: refined))
        case "reject":
            return ContextValidation(.reject)
        default:
            return ContextValidation(.valid)
        }
        #else
        return ContextValidation(.valid)
        #endif
    }

    public func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] {
        // Distractor generation is left to the deterministic fallback even
        // when Foundation Models is available -- the quality gain over
        // `LearnEngine.distractors` doesn't clearly justify a per-question
        // model round trip for this generator; Ollama's version does the
        // model-backed variant.
        Array(deckContext.filter { $0 != correctAnswer }.shuffled().prefix(count))
    }
}
