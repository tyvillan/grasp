import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Study guide tests")
struct GuideTestTests {
    @Test("a guide's unfinished test is kept apart from a deck test over the same decks")
    func scoped() async throws {
        let db = try GRASPDatabase.inMemory()
        let question = LearnEngine.RoundQuestion(id: "q1", cardId: nil, prompt: "p", correctAnswer: "a", type: .written)
        let other = LearnEngine.RoundQuestion(id: "q2", cardId: nil, prompt: "p2", correctAnswer: "b", type: .written)
        let attempt = try await db.queue.write {
            try Study.startRetry(questions: [question, other], deckIds: [], scopeKey: "guide:x", db: $0)
        }
        #expect(try await db.queue.read { try Study.unfinishedTest(forDecks: [], scopeKey: "guide:x", db: $0) }?.attemptId == attempt)
        #expect(try await db.queue.read { try Study.unfinishedTest(forDecks: [], db: $0) } == nil)
    }
}

@Suite("Guide example questions")
struct GuideExampleTests {
    private func page(_ examples: [StudyGuideDocument.Example]) -> StudyGuideActions.ExamPage {
        let part = StudyGuideActions.PagePart(
            number: 1, title: "Sample questions", questionCount: nil, sources: [], deckIds: [], skills: [], traps: [],
            examples: examples.enumerated().map { .init(id: "e\($0.offset)", guideId: "g", example: $0.element) },
            terms: [], formulas: [], remember: [], notes: [])
        return StudyGuideActions.ExamPage(exam: CalendarEvent(title: "Midterm", startsAt: Date()), guides: [],
                                          questionCount: nil, format: [], notes: [], parts: [part], unreadGuides: [],
                                          isPracticeSet: false)
    }

    @Test("the loop's test is blanked, not the sample call after the answer")
    func blanking() throws {
        let code = "int CountVowels(int num)\n{\nfor (int i = 0; i < num; i++)\ncount++;\nreturn count;\n}\n//sample function call, NOT part of the answer\nif (IsVowel(x))\n{\n}"
        let result = try #require(GuideExamples.blanking(code))
        #expect(result.answer == "i < num")
        #expect(result.code.contains("for (int i = 0; [[1]]; i++)"))
        #expect(!result.code.contains("IsVowel"))
    }

    @Test("code answers become fill-in-the-blank, output questions predict-the-output, words stay written")
    func items() {
        let items = GuideExamples.items(from: page([
            .init(label: "Q1", question: "Use a while loop to print 97 asterisks.",
                  steps: [], answer: "k = 0;\nwhile (k < 97){\ncout << \u{201C}*\u{201D};\nk ++;\n}"),
            .init(label: "Q2", question: "What is the output of the following code?\nint main()\n{\ncout << 5;\n}",
                  steps: [], answer: "Output:\n5"),
            .init(label: "Q3", question: "Does this divide by zero?", steps: [], answer: "No, because of short circuit evaluation"),
            .init(label: "Q4", question: "Illustration only", steps: [], answer: nil),
        ]))
        #expect(items.count == 3)
        guard items.count == 3, case .code(let blanks) = items[0], case .code(let output) = items[1],
              case .recall(_, let answer) = items[2] else { Issue.record("wrong kinds"); return }
        #expect(blanks.kind == .codeBlanks && blanks.blanks == [["k < 97"]])
        #expect(blanks.code.contains("\"*\""))
        #expect(blanks.choices?.count == 3)
        #expect(output.kind == .predictOutput && output.expectedOutput == "5" && output.code.hasPrefix("int main()"))
        #expect(answer == "No, because of short circuit evaluation")

        var rng = SystemRandomNumberGenerator()
        let choiceOnly = GuideExamples.round(items, count: 10, allowWritten: false, allowMultipleChoice: true, using: &rng)
        #expect(choiceOnly.count == 2)
        #expect(choiceOnly.allSatisfy { $0.type == .multipleChoice && $0.cardId == nil })
    }
}
