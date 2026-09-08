import Testing
@testable import GRASPCore

@Suite("AnswerGrading")
struct AnswerGradingTests {
    @Test("an exact match is correct")
    func exactMatch() {
        #expect(AnswerGrading.grade(given: "Permeability", correct: "Permeability") == .correct)
    }

    @Test("case, punctuation, and article differences still count as correct")
    func normalizedMatch() {
        #expect(AnswerGrading.grade(given: "the permeability", correct: "Permeability.") == .correct)
        #expect(AnswerGrading.grade(given: "AQUIFER", correct: "aquifer") == .correct)
    }

    @Test("a minor spelling slip is close, not a flat miss")
    func nearMiss() {
        let verdict = AnswerGrading.grade(given: "premeability", correct: "permeability")
        #expect(verdict == .close)
    }

    @Test("an unrelated answer is incorrect")
    func genuinelyWrong() {
        let verdict = AnswerGrading.grade(given: "photosynthesis", correct: "permeability")
        #expect(verdict == .incorrect)
    }

    @Test("an empty answer is incorrect, not close")
    func emptyAnswerIsIncorrect() {
        #expect(AnswerGrading.grade(given: "", correct: "permeability") == .incorrect)
    }
}
