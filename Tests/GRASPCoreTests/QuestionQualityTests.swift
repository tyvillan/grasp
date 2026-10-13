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

    @Test("praise is dropped and a short explanation is kept as written")
    func explanationClean() {
        let text = "Great job! The loop stops at n. A common mistake is using <=. That runs once too often."
        #expect(QuestionExplanation.clean(text) == "The loop stops at n. A common mistake is using <=. That runs once too often.")
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
        #expect(text.contains("What they chose or typed:\n4"))
        #expect(text.contains("print(1 + 2)"))
    }
}

/// The model calls, against a stand-in transport (no local model needed).
@Suite("Question quality, model calls")
struct QuestionQualityModelTests {
    private struct Canned: ChatTransport {
        var reply: String?
        func complete(prompt: String, json: Bool, maxTokens: Int?) async throws -> String {
            guard let reply else { throw URLError(.cannotConnectToHost) }
            return reply
        }
    }

    @Test("test questions come back with their explanation, and a model that omits it still gives a question")
    func testQuestionsWithExplanation() async {
        let json = """
        {"items": [
          {"prompt": "What does a destructor do?", "answer": "Cleans up the object",
           "explanation": "It runs when the object is destroyed. People often confuse it with the constructor."},
          {"prompt": "Name a smart pointer", "answer": "unique_ptr"}
        ]}
        """
        let generator = OllamaGenerator(transport: Canned(reply: json), model: "stub", wordBudget: 1000)
        let questions = await generator.generateTestQuestions(
            existing: [], noteContext: "Destructors run when an object dies.", maxCount: 3)
        #expect(questions.count == 2)
        #expect(questions[0].explanation?.contains("destroyed") == true)
        #expect(questions[1].explanation == nil)
    }

    @Test("Explain this returns the model's short explanation, and nil when the model can't be reached")
    func explainThis() async {
        let ok = OllamaGenerator(transport: Canned(reply: "Sure!\nThe loop runs three times. You counted four."),
                                 model: "stub", wordBudget: 1000)
        let text = await ok.explainWrongAnswer(prompt: "How many times?", correctAnswer: "3", givenAnswer: "4", context: "")
        #expect(text == "The loop runs three times. You counted four.")
        let down = OllamaGenerator(transport: Canned(reply: nil), model: "stub", wordBudget: 1000)
        #expect(await down.explainWrongAnswer(prompt: "p", correctAnswer: "a", givenAnswer: "b", context: "") == nil)
    }

    @Test("a saved question that predates the checks is skipped when a test picks from the bank")
    func bankSkipsLeakedQuestions() async throws {
        let db = try GRASPDatabase.inMemory()
        let leaked = CodeQuestion(kind: .codeBlanks, language: .python, prompt: "Fill in the blank.",
                                  code: QuestionQualityTests.employee, blanks: [["self.__name = name"]],
                                  expectedOutput: "Ana")
        let good = CodeQuestion(kind: .codeBlanks, language: .python, prompt: "Fill in the blank.",
                                code: "total = [[1]]\nprint(total)", blanks: [["2 + 3"]], expectedOutput: "5")
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "C"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "D"); try deck.insert(conn)
            for question in [leaked, good] {
                try TestQuestion(courseId: course.id, deckId: deck.id, kind: .codeBlanks, language: .python,
                                 bodyJSON: question.encoded()!, verifiedBy: "test").insert(conn)
            }
            return deck.id
        }
        let picked = try await db.queue.read { db -> [LearnEngine.RoundQuestion] in
            var rng = SystemRandomNumberGenerator()
            return try CodeQuestionBank.pickRound(count: 5, inDecks: [deckId], allowWritten: true, using: &rng, db: db)
        }
        #expect(picked.count == 1)
        #expect(picked.first?.code?.code.contains("total") == true)
    }
}

// MARK: - The House / Room example

/// A "Which code fills the blank" question: class Room takes a name and
/// stores it, class House takes no argument. The answer is Room; the
/// student chose House.
@Suite("Explanation style")
struct ExplanationStyleTests {
    static let bad = "The student's response \"1: House\" does not match the string printed. Your answer provided a class name and an index instead."
    static let good = "`House.__init__` takes no arguments, so `House(\"bedroom\")` raises a TypeError, and a House has no name attribute anyway. Room.__init__ takes name and stores it, so Room(\"bedroom\").name prints bedroom."
    static let goodTwoSpans = "House.__init__ takes no arguments, so `House(\"bedroom\")` raises a TypeError, and a House has no name attribute anyway. Room.__init__ takes name and stores it, so `Room(\"bedroom\").name` prints bedroom."

    @Test("the bad House explanation is rejected, with the reason")
    func badRejected() {
        #expect(QuestionExplanation.problem(in: Self.bad) != nil)
        #expect(QuestionExplanation.clean(Self.bad) == nil)
        #expect(QuestionExplanation.cleanLong(Self.bad) == nil)
    }

    @Test("each rule on its own")
    func rules() {
        #expect(QuestionExplanation.problem(in: "The student chose House, which has no name.")?.contains("student") == true)
        #expect(QuestionExplanation.problem(in: "The student's choice has no name attribute.") != nil)
        #expect(QuestionExplanation.problem(in: "You picked 1: House, which takes no argument.")?.contains("1: House") == true)
        #expect(QuestionExplanation.problem(in: "The user picked House.") != nil)
        #expect(QuestionExplanation.problem(in: "One. Two. Three. Four. Five. Six.")?.contains("five") == true)
        #expect(QuestionExplanation.problem(in: "One. Two. Three. Four. Five.") == nil)
        #expect(QuestionExplanation.problem(in: "") != nil)
        #expect(QuestionExplanation.problem(in: "   ") != nil)
        #expect(QuestionExplanation.problem(in: nil) != nil)
        // A time or a count with a colon is not an answer format.
        #expect(QuestionExplanation.problem(in: "At 12:30 the call returns.") == nil)
    }

    @Test("a good explanation passes untouched")
    func goodPasses() {
        #expect(QuestionExplanation.problem(in: Self.good) == nil)
        #expect(QuestionExplanation.clean(Self.good) == Self.good)
        #expect(QuestionExplanation.cleanLong(Self.good) == Self.good)
    }

    @Test("inline code renders as code spans with the backticks removed")
    func spans() {
        let segments = QuestionExplanation.segments(in: Self.goodTwoSpans)
        #expect(segments.filter(\.isCode).count == 2)
        #expect(segments.filter(\.isCode).map(\.text) == ["House(\"bedroom\")", "Room(\"bedroom\").name"])
        #expect(!segments.contains { $0.text.contains("`") })
        // A lone backtick is dropped, not shown.
        #expect(QuestionExplanation.segments(in: "stray ` tick").allSatisfy { !$0.text.contains("`") })
        // Plain text is one plain segment.
        #expect(QuestionExplanation.segments(in: "no code here") == [.init("no code here", isCode: false)])
    }

    @Test("the plain answer for a fill-in-the-blank never has the numbering")
    func plainAnswers() {
        let question = CodeQuestion(kind: .codeBlanks, language: .python, prompt: "Which code fills the blank?",
                                    code: "class Room:\n    def __init__(self, name):\n        self.name = name\n\nx = [[1]](\"bedroom\")\nprint(x.name)",
                                    blanks: [["Room"]], expectedOutput: "bedroom")
        #expect(question.plainAnswer == "Room")
        #expect(question.plainGiven(CodeAnswers.encode(["House"])) == "House")
        #expect(question.answerText == "1: Room")   // the results screen keeps its own format
    }

    // MARK: With a stubbed model

    private final class Sequence: ChatTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private var seen: [String] = []
        init(_ replies: [String]) { self.replies = replies }
        var prompts: [String] { lock.withLock { seen } }
        func complete(prompt: String, json: Bool, maxTokens: Int?) async throws -> String {
            lock.withLock {
                seen.append(prompt)
                return replies.isEmpty ? "" : replies.removeFirst()
            }
        }
    }

    @Test("a bad reply is asked for again once, and the good one is used")
    func regeneratesOnce() async {
        let transport = Sequence([Self.bad, Self.good])
        let generator = OllamaGenerator(transport: transport, model: "stub", wordBudget: 1000)
        let text = await generator.explainWrongAnswer(
            prompt: "Which code fills the blank?", correctAnswer: "Room", givenAnswer: "House", context: "class Room: ...")
        #expect(text == Self.good)
        #expect(transport.prompts.count == 2)
        #expect(transport.prompts[1].contains("broke the rules"))
    }

    @Test("two bad replies give no explanation rather than a wrong one")
    func givesUp() async {
        let transport = Sequence([Self.bad, Self.bad])
        let generator = OllamaGenerator(transport: transport, model: "stub", wordBudget: 1000)
        let text = await generator.explainWrongAnswer(
            prompt: "Which code fills the blank?", correctAnswer: "Room", givenAnswer: "House", context: "")
        #expect(text == nil)
        #expect(transport.prompts.count == 2)
    }

    @Test("the prompt says you, forbids the internal format and gives the plain answers")
    func promptText() {
        let prompt = OllamaGenerator.explainWrongAnswerPrompt(
            prompt: "Which code fills the blank?", correctAnswer: "Room", givenAnswer: "House", context: "class House: ...")
        #expect(prompt.contains("\"you\""))
        #expect(prompt.contains("the student"))   // named only to forbid it
        #expect(prompt.contains("1: House"))      // named only to forbid it
        #expect(prompt.contains("2 to 4 short sentences"))
        #expect(prompt.contains("backticks"))
        #expect(prompt.contains("Correct answer:\nRoom"))
        #expect(prompt.contains("What they chose or typed:\nHouse"))
    }

    @Test("an old stored question with a bad explanation shows none")
    func storedBadExplanationDropped() {
        let question = CodeQuestion(kind: .codeBlanks, language: .python, prompt: "p", code: "x = [[1]]",
                                    blanks: [["Room"]], explanation: Self.bad)
        let decoded = CodeQuestion.decode(question.encoded())
        #expect(decoded?.explanation == nil)
        let good = CodeQuestion(kind: .codeBlanks, language: .python, prompt: "p", code: "x = [[1]]",
                                blanks: [["Room"]], explanation: Self.good)
        #expect(CodeQuestion.decode(good.encoded())?.explanation == Self.good)
    }
}
