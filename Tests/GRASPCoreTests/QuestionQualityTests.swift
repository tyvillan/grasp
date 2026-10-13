import Foundation
import GRDB
import Testing
@testable import GRASPCore

/// A stand-in compiler that prints what the test says that exact text prints.
private struct Executor: CodeExecuting {
    var outputs: [String: String]
    /// Anything not listed still "runs" and prints this (a blank that
    /// changes nothing).
    var fallback: String?
    func canRun(_ language: CodeLanguage) -> Bool { true }
    func run(_ source: String, language: CodeLanguage) async -> CodeRunResult {
        if let out = outputs[source] ?? fallback { return CodeRunResult(compiled: true, stdout: out) }
        return CodeRunResult(compiled: false, stderr: "error")
    }
}

@Suite("Question quality")
struct QuestionQualityTests {
    // The question from the bug report: the answer is already on line 3,
    // and the blank sits on the comment after it.
    static let employee = """
    class Employee:
        def __init__(self, name):
            self.__name = name  # [[1]]

        def get_name(self):
            return self.__name

    e = Employee("Ana")
    print(e.get_name())
    """

    @Test("the Employee example: a blank on a trailing comment is refused")
    func employeeBlankOnComment() {
        let problem = CodeQuestionValidator.problem(
            code: Self.employee, answers: [["self.__name = name"]], language: .python)
        #expect(problem != nil)
        #expect(problem?.contains("comment") == true)
    }

    @Test("the Employee example with the blank moved still refuses a visible answer")
    func employeeAnswerVisible() {
        let code = """
        class Employee:
            def __init__(self, name):
                self.__name = name
                [[1]]
        """
        let problem = CodeQuestionValidator.problem(code: code, answers: [["self.__name = name"]], language: .python)
        #expect(problem?.contains("already visible") == true)
    }

    @Test("a proper blank passes")
    func properBlank() {
        let code = """
        class Employee:
            def __init__(self, name):
                [[1]]

            def get_name(self):
                return self.__name
        """
        #expect(CodeQuestionValidator.problem(code: code, answers: [["self.__name = name"]], language: .python) == nil)
    }

    @Test("a hash inside a string is not a comment, and a C++ comment is")
    func commentDetection() {
        let python = "print(\"# [[1]]\")"
        #expect(CodeQuestionValidator.problem(code: python, answers: [["hello"]], language: .python) == nil)
        let cpp = "int main() { // [[1]]\n return 0; }"
        #expect(CodeQuestionValidator.problem(code: cpp, answers: [["return 0;"]], language: .cpp)?.contains("comment") == true)
        let block = "/* [[1]] */ int x = 1;"
        #expect(CodeQuestionValidator.problem(code: block, answers: [["int y"]], language: .cpp)?.contains("comment") == true)
    }

    @Test("an answer written in a comment elsewhere is refused")
    func answerInComment() {
        let code = "x = [[1]]  # set x to len(items)\nprint(x)"
        #expect(CodeQuestionValidator.problem(code: code, answers: [["len(items)"]], language: .python)?.contains("comment") == true)
    }

    @Test("a blank with no usable answer is refused")
    func noUsableAnswer() {
        #expect(CodeQuestionValidator.problem(code: "x = [[1]]", answers: [["..."]], language: .python) != nil)
        #expect(CodeQuestionValidator.problem(code: "x = [[1]]", answers: [[""]], language: .python) != nil)
        #expect(CodeQuestionValidator.problem(code: "x = [[1]]", answers: [], language: .python) != nil)
        #expect(CodeQuestionValidator.problem(code: "x = [[1]]", answers: [["1"]], language: .python) == nil)
    }

    @Test("a short answer that appears elsewhere is fine; only long ones count as visible")
    func shortAnswersAllowed() {
        let code = "def f(name):\n    self.__name = [[1]]\n    return name"
        #expect(CodeQuestionValidator.problem(code: code, answers: [["name"]], language: .python) == nil)
    }

    @Test("the builder refuses the Employee draft before running anything")
    func builderRefuses() async {
        let draft = GeneratedCodeQuestion(kind: .codeBlanks, prompt: "Fill in the blank.", code: Self.employee,
                                          answers: [["self.__name = name"]])
        let executor = Executor(outputs: [:])
        await #expect(throws: (any Error).self) {
            try await CodeQuestionBuilder.check(draft, language: .python, using: executor)
        }
    }

    @Test("the builder refuses a blank that can be left as nonsense without changing the output")
    func builderRefusesIneffectiveBlank() async throws {
        let code = "x = 1\nprint(x)\nif False:\n    y = [[1]]"
        let draft = GeneratedCodeQuestion(kind: .codeBlanks, prompt: "Fill in the blank.", code: code,
                                          answers: [["x + 41"]])
        // Every variant of the program prints "1": the blank never runs.
        let executor = Executor(outputs: [:], fallback: "1\n")
        do {
            _ = try await CodeQuestionBuilder.check(draft, language: .python, using: executor)
            Issue.record("expected a rejection")
        } catch let error as DraftRejected {
            #expect(error.reason.contains("nonsense"))
        }
    }

    @Test("the builder keeps a good question and cleans its explanation")
    func builderKeeps() async throws {
        let code = "total = [[1]]\nprint(total)"
        let draft = GeneratedCodeQuestion(
            kind: .codeBlanks, prompt: "Fill in the blank.", code: code, answers: [["2 + 3"]],
            explanation: "Great question! Addition gives 5. People often write 2 * 3 by mistake. It multiplies instead.")
        let executor = Executor(outputs: ["total = 2 + 3\nprint(total)": "5\n"])
        let question = try await CodeQuestionBuilder.check(draft, language: .python, using: executor)
        #expect(question.blanks == [["2 + 3"]])
        #expect(question.explanation?.hasPrefix("Great") == false)
    }

    @Test("an explanation is cut to three sentences and drops praise")
    func explanationClean() {
        let long = "Great job! The loop stops at n. A common mistake is using <=. That runs once too often. Extra sentence here."
        let cleaned = QuestionExplanation.clean(long)
        #expect(cleaned == "The loop stops at n. A common mistake is using <=. That runs once too often.")
        #expect(QuestionExplanation.clean("   ") == nil)
        #expect(QuestionExplanation.clean("Nice!") == nil)
        #expect(QuestionExplanation.clean("self.x stays 1.5 here. Done.") == "self.x stays 1.5 here. Done.")
    }

    @Test("a plain AI question keeps its explanation through a saved attempt, and none is fine")
    func explanationPersists() async throws {
        let db = try GRASPDatabase.inMemory()
        let questions = [
            LearnEngine.RoundQuestion(cardId: nil, prompt: "Why?", correctAnswer: "Because", type: .written,
                                      explanation: "It is how the note defines it."),
            LearnEngine.RoundQuestion(cardId: nil, prompt: "Old?", correctAnswer: "Yes", type: .written),
        ]
        let attemptId = try await db.queue.write { try Study.startRetry(questions: questions, deckIds: [], db: $0) }
        let resumed = try #require(try await db.queue.read { try Study.resumeTest(attemptId: attemptId, db: $0) })
        #expect(resumed.questions[0].explanation == "It is how the note defines it.")
        #expect(resumed.questions[0].whyText == "It is how the note defines it.")
        #expect(resumed.questions[1].explanation == nil)
        #expect(resumed.questions[1].whyText == nil)
    }

    @Test("a generated test question carries its explanation and a missing one is still a question")
    func testQuestionExplanationOptional() {
        let withWhy = GeneratedTestQuestion(prompt: "p", correctAnswer: "a", explanation: "why")
        #expect(withWhy.explanation == "why")
        #expect(GeneratedTestQuestion(prompt: "p", correctAnswer: "a").explanation == nil)
    }

    @Test("flagging retires the saved copy of a question and its key ignores spacing and case")
    func flags() async throws {
        #expect(QuestionFlags.key(prompt: "What  is X?") == QuestionFlags.key(prompt: "what is x?"))
        #expect(QuestionFlags.key(prompt: "a", code: "x") != QuestionFlags.key(prompt: "a", code: "y"))
        let db = try GRASPDatabase.inMemory()
        let question = CodeQuestion(kind: .predictOutput, language: .python, prompt: "What does this print?",
                                    code: "print(1)", expectedOutput: "1")
        let courseId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "C"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "D"); try deck.insert(conn)
            try TestQuestion(courseId: course.id, deckId: deck.id, kind: .predictOutput, language: .python,
                             bodyJSON: question.encoded()!, verifiedBy: "test").insert(conn)
            return course.id
        }
        _ = courseId
        let key = QuestionFlags.key(prompt: question.prompt, code: question.code)
        let retired = try await db.queue.write { try QuestionFlags.retireSaved(key: key, db: $0) }
        #expect(retired == 1)
        let live = try await db.queue.read { try TestQuestion.filter(Column("deletedAt") == nil).fetchCount($0) }
        #expect(live == 0)
    }

    @Test("a test item for an AI question can be discarded, a card's item cannot")
    func discardOnlyAIItems() async throws {
        let db = try GRASPDatabase.inMemory()
        let cardId = try await db.queue.write { conn -> String in
            let card = Card(materialId: nil, front: "F", back: "B", origin: .manual, status: .active)
            try card.insert(conn)
            return card.id
        }
        let questions = [
            LearnEngine.RoundQuestion(cardId: cardId, prompt: "F", correctAnswer: "B", type: .written),
            LearnEngine.RoundQuestion(cardId: nil, prompt: "AI?", correctAnswer: "yes", type: .written),
        ]
        let attemptId = try await db.queue.write { try Study.startRetry(questions: questions, deckIds: [], db: $0) }
        try await db.queue.write {
            try Study.discardTestItem(attemptId: attemptId, ordinal: 0, db: $0)
            try Study.discardTestItem(attemptId: attemptId, ordinal: 1, db: $0)
        }
        let remaining = try await db.queue.read { try TestItem.filter(Column("attemptId") == attemptId).fetchAll($0) }
        #expect(remaining.count == 1)
        #expect(remaining.first?.cardId == cardId)
    }

    @Test("the wrong-answer prompt carries the question, the right answer and the student's answer")
    func explainPrompt() {
        let text = OllamaGenerator.explainWrongAnswerPrompt(
            prompt: "What prints?", correctAnswer: "3", givenAnswer: "4", context: "print(1 + 2)")
        #expect(text.contains("What prints?"))
        #expect(text.contains("3"))
        #expect(text.contains("The student answered:\n4"))
        #expect(text.contains("print(1 + 2)"))
    }
}
