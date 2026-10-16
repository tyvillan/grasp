import Foundation
import GRASPCore

/// A canned question writer for screenshots and demos, so nothing calls a
/// model: `GRASP_STUB_QUESTIONS=1` with `-GRASPAllowStubs 1`, debug builds
/// only (see `StubHooks`). It returns good questions, one that repeats a
/// question already saved, one that says the notes don't define it, one with
/// no options to choose from, and one whose second opinion disagrees, so
/// every kind of dropped item shows up.
struct StubQuestionGenerator: CardGenerator {
    var isAvailable: Bool { get async { true } }

    func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        candidates.map { GeneratedCard(front: $0.front, back: $0.back) }
    }

    func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }

    func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }

    func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation {
        ContextValidation(.valid)
    }

    func generateOverview(noteTitle: String, courseName: String, noteContext: String, includeFormulas: Bool,
                          partLabel: String?) async -> GeneratedOverview { .empty }

    func generateFigures(noteTitle: String, courseName: String, noteContext: String,
                         sectionHeadings: [String]) async -> [GeneratedFigure] { [] }

    private func isEvolution(_ context: String) -> Bool { context.lowercased().contains("evolution") }

    func generateProblems(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String],
        subject: ProblemSubject, kinds: [ProblemKind], count: Int
    ) async -> [GeneratedProblem] {
        guard kinds.contains(.multipleChoice) else { return [] }
        if isEvolution(noteContext) {
            return [
                GeneratedProblem(kind: .multipleChoice, prompt: "Which idea says that traits gained during a lifetime are passed to offspring?",
                                 choices: ["Natural selection", "Inheritance of acquired characteristics", "Uniformitarianism", "Catastrophism"], correct: 1,
                                 explanation: "That is Lamarck's inheritance of acquired characteristics. Darwin's mechanism works on variation, not on traits gained in life."),
                GeneratedProblem(kind: .multipleChoice, prompt: "What does fitness measure in evolutionary theory?",
                                 choices: ["Strength", "Reproductive success", "Intelligence", "Size"], correct: 1,
                                 explanation: "Fitness is an individual's reproductive success, the number of surviving offspring."),
                GeneratedProblem(kind: .multipleChoice, prompt: "What does the term gene mean in this chapter?",
                                 choices: ["It is not defined in the notes", "A unit of heredity", "A protein", "A trait"], correct: 0),
                GeneratedProblem(kind: .multipleChoice, prompt: "Which of the following describes heterozygous organisms in the notes?",
                                 choices: ["Same alleles from each parent", "Different alleles from each parent", "Two copies of a dominant trait", "No alleles"], correct: 0),
            ]
        }
        return [
            GeneratedProblem(kind: .multipleChoice, prompt: "Which perspective is based on collecting data through direct contact and full immersion?",
                             choices: ["Field-based", "Holistic", "Comparative", "Evolutionary"], correct: 0,
                             explanation: "Field-based work means being there."),
            GeneratedProblem(kind: .multipleChoice, prompt: "Which subfield examines human and primate evolution through fossils?",
                             choices: ["Paleoanthropology", "Ethnology", "Sociolinguistics", "Medical anthropology"], correct: 0,
                             explanation: "Paleoanthropology reads evolution from fossilized remains."),
            GeneratedProblem(kind: .multipleChoice, prompt: "How do anthropologists define material culture?",
                             choices: ["Objects people make and give meaning to", "Money and trade", "Language", "Fossils"], correct: 0,
                             explanation: "Material culture is made or shaped by people and given meaning by cultural practice."),
        ]
    }

    func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] {
        if isEvolution(noteContext) {
            return [
                GeneratedTestQuestion(prompt: "In one sentence, why did Darwin treat variation as the starting condition of life?",
                                      correctAnswer: "Because individuals differ, and different variants leave different numbers of offspring.",
                                      explanation: "Variation gives selection something to act on."),
                GeneratedTestQuestion(prompt: "What did Mendel's pea experiments show about inheritance?",
                                      correctAnswer: "That inheritance is particulate rather than blending."),
                GeneratedTestQuestion(prompt: "Which of the following describes an adaptation?", correctAnswer: "A useful feature shaped by selection for its current function."),
            ]
        }
        return [
            GeneratedTestQuestion(prompt: "What is the difference between ethnography and ethnology?",
                                  correctAnswer: "Ethnography describes one society from fieldwork; ethnology compares societies.",
                                  explanation: "One describes, the other compares."),
            GeneratedTestQuestion(prompt: "What does an informant do in fieldwork?",
                                  correctAnswer: "Helps the anthropologist explain the society from the inside."),
        ]
    }

    /// The second opinion agrees with the key, except for one question, so
    /// one draft fails its check.
    func solveMultipleChoice(prompt: String, choices: [String]) async -> Int? {
        if prompt.contains("fitness") { return 0 }
        if prompt.contains("heterozygous") { return choices.firstIndex(of: "Different alleles from each parent") }
        return choices.firstIndex(of: choices.first { c in
            ["Field-based", "Paleoanthropology", "Objects people make and give meaning to",
             "Inheritance of acquired characteristics", "Reproductive success", "It is not defined in the notes"].contains(c)
        } ?? "")
    }
}
