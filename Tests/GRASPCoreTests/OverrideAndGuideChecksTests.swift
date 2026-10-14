import Testing
import Foundation
@testable import GRASPCore

@Suite("Override on code questions and guide-question checks")
struct OverrideAndGuideChecksTests {
    private func code(_ kind: CodeQuestionKind) -> LearnEngine.RoundQuestion {
        let q = CodeQuestion(kind: kind, language: .python, prompt: "p", code: "print(1)",
                             expectedOutput: "1", buggyLine: 1)
        return .init(cardId: nil, prompt: "p", correctAnswer: "1", type: .written, code: q)
    }

    @Test("an exactly graded code question cannot be marked correct by hand")
    func deterministicKindsHideOverride() {
        #expect(!code(.predictOutput).allowsMarkCorrect)
        #expect(!code(.codeBlanks).allowsMarkCorrect)
        #expect(!code(.findBug).allowsMarkCorrect)
    }

    @Test("a function the student writes, and plain written questions, keep the override")
    func otherKindsKeepOverride() {
        #expect(code(.completeFunction).allowsMarkCorrect)
        let plain = LearnEngine.RoundQuestion(cardId: "c", prompt: "Define x", correctAnswer: "y", type: .written)
        #expect(plain.allowsMarkCorrect)
        let mc = LearnEngine.RoundQuestion(cardId: "c", prompt: "?", correctAnswer: "a", type: .multipleChoice,
                                           choices: ["a", "b"])
        #expect(!mc.allowsMarkCorrect)
    }

    @Test("guide sample questions that are refusals, option-less or headings are dropped")
    func guideQuestionsAreChecked() throws {
        let raw = """
        {"skills": ["Compute elasticity"],
         "questions": [
           {"question": "What is elasticity?", "answer": "Elasticity is not explicitly defined in the provided notes."},
           {"question": "Which of the following is elastic?", "answer": "Luxury goods"},
           {"question": "HOMEWORK 2", "answer": "Do the problems"},
           {"question": "What does elasticity measure?", "answer": "How much quantity responds to a price change."}],
         "problems": [
           {"question": "Find the elasticity.", "steps": [], "answer": "The notes do not contain this information."},
           {"question": "Price goes 4 to 5, quantity 100 to 80. Elasticity?", "steps": ["-20% / 25%"], "answer": "0.8"}]}
        """
        let part = try #require(OllamaGenerator.parseStudyGuidePart(raw, title: "T", problemLimit: 5))
        #expect(part.examples.map(\.label) == ["Practice 1", "Sample question 1"])
        #expect(part.examples[0].answer == "0.8")
        #expect(part.examples[1].answer == "How much quantity responds to a price change.")
    }

    @Test("a part whose every question fails the checks and has no skills is no part")
    func allBadGivesNothing() {
        let raw = #"{"skills": [], "questions": [{"question": "Q?", "answer": "Not covered in the notes."}]}"#
        #expect(OllamaGenerator.parseStudyGuidePart(raw, title: "T", problemLimit: 3) == nil)
    }

    @Test("the guide prompt carries the skip rule")
    func promptHasSkipRule() {
        let p = OllamaGenerator.studyGuidePartPrompt(deckName: "D", courseName: "C", noteContext: "n",
                                                     cardTerms: [], problemCount: 3)
        #expect(p.contains(CardQuality.skipRule))
    }
}
