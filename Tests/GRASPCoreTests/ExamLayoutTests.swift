import Testing
import Foundation
@testable import GRASPCore

@Suite("Exam layout")
struct ExamLayoutTests {
    private func skill(_ text: String, _ n: Int = 0) -> StudyGuideActions.Skill {
        .init(guideId: "g", skillId: "s\(n)-\(text.count)", text: text, rating: nil)
    }

    private func part(_ title: String, skills: [String] = []) -> StudyGuideActions.PagePart {
        .init(number: nil, title: title, questionCount: nil, sources: [], deckIds: [],
              skills: skills.enumerated().map { skill($1, $0) }, traps: [], examples: [], terms: [],
              formulas: [], remember: [], notes: [])
    }

    @Test("skills land in their topic")
    func topics() {
        #expect(ExamLayout.topic(for: "loops (for, while, do/while)") == .control)
        #expect(ExamLayout.topic(for: "Functions: Pass by value and pass by reference parameters") == .functions)
        #expect(ExamLayout.topic(for: "Default and explicit value constructor") == .classes)
        #expect(ExamLayout.topic(for: "File input (ifstream)") == .structsFiles)
        #expect(ExamLayout.topic(for: "using cout and cin") == .dataIO)
        #expect(ExamLayout.topic(for: "Marginal cost curves") == .other)
    }

    @Test("a skill repeated across parts appears once")
    func dedupes() throws {
        let parts = [
            part("Skills", skills: ["loops (for, while)", "using cout and cin", "Default constructor", "File input (ifstream)"]),
            part("Assignment 2", skills: ["Loops (for, while)", "Using cout and cin"]),
        ]
        let buckets = try #require(ExamLayout.bucketSkills(parts))
        #expect(buckets.flatMap(\.skills).count == 4)
    }

    @Test("a subject the keywords don't know falls back to the parts as written")
    func unknownSubject() {
        let parts = [part("Demand", skills: ["Shift the demand curve", "Elasticity of supply", "Consumer surplus", "Deadweight loss"])]
        #expect(ExamLayout.bucketSkills(parts) == nil)
    }

    @Test("assignments and practice are split from topics")
    func bands() {
        #expect(ExamLayout.band(for: part("Assignment 3 - separate compilation")) == .assignments)
        #expect(ExamLayout.band(for: part("Midterm sample questions")) == .practice)
        #expect(ExamLayout.band(for: part("Call-by-reference")) == .topics)
    }
}

@Suite("Skill definitions")
struct SkillDefinitionTests {
    @Test("the guide's own term is used, longest match first")
    func matches() {
        let terms = [
            StudyGuideDocument.Term(term: "constructor", definition: "Runs when an object is made."),
            StudyGuideDocument.Term(term: "default constructor", definition: "A constructor with no parameters."),
        ]
        #expect(ExamLayout.definition(for: "Default constructor", terms: terms)?.term == "default constructor")
        #expect(ExamLayout.definition(for: "loops", terms: terms) == nil)
    }
}

private struct CannedTransport: ChatTransport {
    let reply: String
    func complete(prompt: String, json: Bool, maxTokens: Int?) async throws -> String { reply }
}

@Suite("Batched skill explanations")
struct BatchedExplanationTests {
    @Test("one reply explains every skill, in order, with LaTeX cleaned")
    func batch() async {
        let generator = OllamaGenerator(
            transport: CannedTransport(reply: #"{"meanings": ["A loop repeats code.", "Passing by reference lets $x_1$ change."]}"#),
            model: "m", wordBudget: 600)
        let result = await generator.explainSkills(["loops", "references"], subject: "COP", context: "")
        #expect(result["loops"] == "A loop repeats code.")
        #expect(result["references"] == "Passing by reference lets x₁ change.")
    }

    @Test("a reply with the wrong number of answers is ignored, not misaligned")
    func wrongCount() async {
        let generator = OllamaGenerator(transport: CannedTransport(reply: #"{"meanings": ["only one"]}"#),
                                        model: "m", wordBudget: 600)
        #expect(await generator.explainSkills(["a", "b"], subject: "s", context: "").isEmpty)
    }
}
