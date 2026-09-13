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

    public func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] {
        // Distractor generation is left to the deterministic fallback even
        // when Foundation Models is available -- the quality gain over
        // `LearnEngine.distractors` doesn't clearly justify a per-question
        // model round trip for this generator; Ollama's version does the
        // model-backed variant.
        Array(deckContext.filter { $0 != correctAnswer }.shuffled().prefix(count))
    }
}
