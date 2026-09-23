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

    // Verbatim from real cards: each pair differs by a sign, a mark or a
    // digit, and each used to be graded correct.
    @Test("a different sign, complement mark or digit is a different answer")
    func significantSymbols() {
        #expect(AnswerGrading.grade(given: "sin(a+b)=sin a cos b+cos a sin b",
                                    correct: "sin(a-b)=sin a cos b-cos a sin b") == .incorrect)
        #expect(AnswerGrading.grade(given: "Q = AB + AB", correct: "Q = AB' + A'B") == .incorrect)
        #expect(AnswerGrading.grade(given: "1946", correct: "1945") == .incorrect)
        #expect(AnswerGrading.grade(given: "Output is 0 when both inputs are 1",
                                    correct: "Output is 1 when both inputs are 1") == .incorrect)
    }

    @Test("the same math written with different spacing or a Unicode minus is still correct")
    func mathSpacing() {
        #expect(AnswerGrading.grade(given: "x=3", correct: "x = 3") == .correct)
        #expect(AnswerGrading.grade(given: "x - 2y = 7", correct: "x \u{2212} 2y = 7") == .correct)
        #expect(AnswerGrading.grade(given: "Q = AB' + A'B", correct: "Q = AB′ + A′B") == .correct)
    }

    @Test("word-joining hyphens and apostrophes aren't signs")
    func joiningPunctuation() {
        #expect(AnswerGrading.grade(given: "self esteem", correct: "self-esteem") == .correct)
        #expect(AnswerGrading.grade(given: "newtons law", correct: "Newton's law") == .correct)
    }

    @Test("a short answer one letter off is wrong, not close")
    func shortAnswersAreStrict() {
        #expect(AnswerGrading.grade(given: "car", correct: "cat") == .incorrect)
    }

    @Test("a line break reads as a space")
    func lineBreaks() {
        #expect(AnswerGrading.grade(given: "cell wall", correct: "cell\nwall") == .correct)
    }
}
