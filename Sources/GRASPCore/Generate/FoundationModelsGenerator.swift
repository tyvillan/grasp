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

    public func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] {
        // Distractor generation is left to the deterministic fallback even
        // when Foundation Models is available -- the quality gain over
        // `LearnEngine.distractors` doesn't clearly justify a per-question
        // model round trip for this generator; Ollama's version does the
        // model-backed variant.
        Array(deckContext.filter { $0 != correctAnswer }.shuffled().prefix(count))
    }
}
