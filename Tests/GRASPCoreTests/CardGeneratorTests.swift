import Testing
import Foundation
@testable import GRASPCore

@Suite("CardGenerator")
struct CardGeneratorTests {
    @Test("NoGenerator is never available")
    func noGeneratorUnavailable() async {
        #expect(await NoGenerator().isAvailable == false)
    }

    @Test("NoGenerator's refine passes candidates through untouched")
    func noGeneratorPassesThrough() async {
        let candidates = [CandidatePair(front: "Permeability", back: "Ability to transmit fluids", sourceLine: 1)]
        let result = await NoGenerator().refine(candidates, noteContext: "")
        #expect(result == [GeneratedCard(front: "Permeability", back: "Ability to transmit fluids")])
    }

    @Test("NoGenerator's distractors exclude the correct answer")
    func noGeneratorDistractorsExcludeCorrect() async {
        let deck = ["A", "B", "C", "D", "Correct"]
        let picked = await NoGenerator().distractors(for: "Correct", deckContext: deck, count: 3)
        #expect(picked.count == 3)
        #expect(!picked.contains("Correct"))
    }

    @Test("Ollama reports unavailable when no server is running on this machine")
    func ollamaUnavailableWithoutServer() async {
        // This machine genuinely has no Ollama installed -- a real,
        // non-mocked check that the unavailable path is graceful.
        let generator = OllamaGenerator()
        #expect(await generator.isAvailable == false)
    }

    @Test("Ollama's refine falls back to untouched candidates when the server is unreachable")
    func ollamaRefineFallsBackWithoutServer() async {
        let candidates = [
            CandidatePair(front: "Porosity", back: "Percentage of open space in a rock sample", sourceLine: 1),
        ]
        let result = await OllamaGenerator().refine(candidates, noteContext: "Some geology notes.")
        #expect(result == [GeneratedCard(front: "Porosity", back: "Percentage of open space in a rock sample")])
    }

    @Test("Ollama's refine prompt asks for exactly the input count, in order")
    func ollamaRefinePromptShape() {
        let candidates = [
            CandidatePair(front: "A", back: "definition a", sourceLine: 1),
            CandidatePair(front: "B", back: "definition b", sourceLine: 2),
        ]
        let prompt = OllamaGenerator.refinePrompt(candidates: candidates, noteContext: "context")
        #expect(prompt.contains("exactly 2 objects"))
        #expect(prompt.contains("front: \"A\""))
        #expect(prompt.contains("front: \"B\""))
    }

    @Test("Ollama's distractor prompt asks for exactly the requested count")
    func ollamaDistractorPromptShape() {
        let prompt = OllamaGenerator.distractorPrompt(correctAnswer: "Permeability", deckContext: ["X", "Y"], count: 3)
        #expect(prompt.contains("Generate 3 plausible"))
        #expect(prompt.contains("Permeability"))
    }

    @Test("Foundation Models availability check completes without throwing, regardless of Apple Intelligence state")
    func foundationModelsAvailabilityIsSafeToCheck() async {
        if #available(macOS 26.0, *) {
            let generator = FoundationModelsGenerator()
            _ = await generator.isAvailable // must not crash either way
        }
    }

    @Test("selecting a generator on this machine falls back to NoGenerator or an honestly-available one")
    func selectReturnsAnAvailableOrNoGenerator() async {
        let generator = await CardGenerators.select()
        // Whatever was selected must itself report consistently: either
        // it's the explicit no-op, or it claims to actually be available.
        if generator is NoGenerator {
            #expect(Bool(true))
        } else {
            #expect(await generator.isAvailable)
        }
    }
}
