import Foundation
import GRDB
import Testing
@testable import GRASPCore

/// Answers multiple-choice problems with a fixed option, and writes the
/// problems it was given.
private final class ProblemGenerator: CardGenerator, @unchecked Sendable {
    let solver: Int?
    var problems: [GeneratedProblem]
    init(solver: Int?, problems: [GeneratedProblem] = []) { self.solver = solver; self.problems = problems }

    var isAvailable: Bool { get async { true } }
    func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
    func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
    func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
    func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
    func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation {
        ContextValidation(.valid)
    }
    func generateOverview(noteTitle: String, courseName: String, noteContext: String,
                          includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview { .empty }
    func generateFigures(noteTitle: String, courseName: String, noteContext: String,
                         sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
    func generateProblems(deckName: String, courseName: String, noteContext: String, cardTerms: [String],
                          subject: ProblemSubject, kinds: [ProblemKind], count: Int) async -> [GeneratedProblem] { problems }
    func solveMultipleChoice(prompt: String, choices: [String]) async -> Int? { solver }
}

/// "Runs" a script by returning what the test says it prints.
private struct ScriptExecutor: CodeExecuting {
    var output: String
    func canRun(_ language: CodeLanguage) -> Bool { true }
    func run(_ source: String, language: CodeLanguage) async -> CodeRunResult {
        CodeRunResult(compiled: true, stdout: output)
    }
}

@Suite("Problems")
struct ProblemTests {
    @Test("typed numbers are read the way students write them")
    func parsesNumbers() {
        #expect(ProblemAnswerGrading.parseNumber("$1,200.50") == 1200.5)
        #expect(ProblemAnswerGrading.parseNumber("-3/4") == -0.75)
        #expect(ProblemAnswerGrading.parseNumber("= 7") == 7)
        #expect(ProblemAnswerGrading.parseNumber("about 3.2 units") == 3.2)
        #expect(ProblemAnswerGrading.parseNumber("12.5%") == 12.5)
        #expect(ProblemAnswerGrading.parseNumber("\u{2212}4") == -4)
        #expect(ProblemAnswerGrading.parseNumber("none") == nil)
    }

    @Test("whole-number answers must be exact; others allow rounding")
    func closeness() {
        #expect(ProblemAnswerGrading.gradeNumber("-12", expected: -12))
        #expect(!ProblemAnswerGrading.gradeNumber("-12.5", expected: -12))
        #expect(ProblemAnswerGrading.gradeNumber("0.33", expected: 1.0 / 3.0))
        #expect(ProblemAnswerGrading.gradeNumber("1/3", expected: 1.0 / 3.0))
        #expect(!ProblemAnswerGrading.gradeNumber("0.4", expected: 1.0 / 3.0))
    }

    @Test("matrices are read from brackets, rows or semicolons, and compared entry by entry")
    func matrices() {
        let expected: [[Double]] = [[1, 2], [3, 0.5]]
        #expect(ProblemAnswerGrading.gradeMatrix("[[1, 2], [3, 1/2]]", expected: expected))
        #expect(ProblemAnswerGrading.gradeMatrix("1 2\n3 0.5", expected: expected))
        #expect(ProblemAnswerGrading.gradeMatrix("[1 2; 3 .5]", expected: expected))
        #expect(ProblemAnswerGrading.gradeMatrix("| 1 2 |\n| 3 0.5 |", expected: expected))
        #expect(!ProblemAnswerGrading.gradeMatrix("1 2\n3 1", expected: expected))
        #expect(!ProblemAnswerGrading.gradeMatrix("1 2 3\n3 0.5", expected: expected))
        #expect(ProblemAnswerGrading.parseMatrix("1 2\n3") == nil)
    }

    @Test("the subject is read from the notes")
    func detectsSubject() {
        #expect(ProblemSubject.detect(notes: "```cpp\nint main(){}\n```", courseName: "X", deckName: "Y") == .code)
        #expect(ProblemSubject.detect(notes: "The determinant of a matrix; the inverse and rank of a matrix.",
                                      courseName: "Matrix Theory", deckName: "Lecture 4") == .math)
        #expect(ProblemSubject.detect(notes: "Demand and supply meet at equilibrium; elasticity and surplus.",
                                      courseName: "Microeconomic Principles", deckName: "Lecture 2") == .economics)
        #expect(ProblemSubject.detect(notes: "The Roman republic.", courseName: "History", deckName: "Rome") == .concepts)
    }

    @Test("the tagged layout is parsed for each kind")
    func parses() {
        let raw = """
        ### PROBLEM
        KIND: number
        PROMPT: A = [ 1 2 ]
            [ 3 4 ]
        What is det(A)?
        ANSWER: -2
        SCRIPT:
        ```python
        print(1*4 - 2*3)
        ```
        EXPLANATION: ad - bc.
        ### END
        ### PROBLEM
        KIND: multipleChoice
        PROMPT: Price rises. Quantity demanded?
        CHOICES:
        A) rises
        B) falls
        C) unchanged
        D) doubles
        ANSWER: B
        EXPLANATION: Law of demand.
        ### PROBLEM
        KIND: multipleChoice
        PROMPT: Only two options?
        CHOICES:
        A) x
        B) y
        ANSWER: A
        """
        let problems = OllamaGenerator.parseProblems(raw)
        #expect(problems.count == 2)
        #expect(problems[0].kind == .number)
        #expect(problems[0].prompt.contains("det(A)"))
        #expect(problems[0].script == "print(1*4 - 2*3)")
        #expect(problems[1].choices == ["rises", "falls", "unchanged", "doubles"])
        #expect(problems[1].correct == 1)
    }

    @Test("a language name left where the code fence was doesn't end up in the script")
    func stripsLanguageLine() {
        let raw = """
        ### PROBLEM
        KIND: number
        PROMPT: 2 + 2?
        ANSWER: 4
        SCRIPT:
        python
        print(2 + 2)
        EXPLANATION: Add.
        """
        #expect(OllamaGenerator.parseProblems(raw).first?.script == "print(2 + 2)")
    }

    @Test("notes with a fenced diagram or matrix aren't mistaken for code")
    func fencesAreNotCode() {
        #expect(ProblemSubject.detect(notes: "```\n1 2\n3 4\n```\nThe determinant of a matrix and its inverse and rank.",
                                      courseName: "Matrix Theory", deckName: "Lecture 3") == .math)
    }

    @Test("a number is kept only when the script agrees, and the script's value is the answer")
    func checksNumbers() async throws {
        let draft = GeneratedProblem(kind: .number, prompt: "What is the determinant of the matrix A?", claimedAnswer: "-2", script: "print(-2)")
        let generator = ProblemGenerator(solver: nil)
        let kept = try await ProblemBuilder.check(draft, subject: .math, using: generator, executor: ScriptExecutor(output: "-2\n"))
        #expect(kept.number == -2)

        await #expect(throws: DraftRejected.self) {
            _ = try await ProblemBuilder.check(draft, subject: .math, using: generator, executor: ScriptExecutor(output: "5\n"))
        }
        var noScript = draft
        noScript.script = nil
        await #expect(throws: DraftRejected.self) {
            _ = try await ProblemBuilder.check(noScript, subject: .math, using: generator, executor: ScriptExecutor(output: "-2\n"))
        }
    }

    @Test("a bare matrix with no question is dropped")
    func needsAQuestion() async {
        let draft = GeneratedProblem(kind: .number, prompt: "A = [ 2 1 ]\n    [ -1 3 ]", claimedAnswer: "7", script: "print(7)")
        await #expect(throws: DraftRejected.self) {
            _ = try await ProblemBuilder.check(draft, subject: .math, using: ProblemGenerator(solver: nil),
                                               executor: ScriptExecutor(output: "7\n"))
        }
    }

    @Test("a matrix is kept only when the script prints the same matrix")
    func checksMatrices() async throws {
        let draft = GeneratedProblem(kind: .matrix, prompt: "Find the matrix A squared for the given A.", claimedAnswer: "7 10\n15 22", script: "x")
        let generator = ProblemGenerator(solver: nil)
        let kept = try await ProblemBuilder.check(draft, subject: .math, using: generator, executor: ScriptExecutor(output: "7 10\n15 22\n"))
        #expect(kept.matrix == [[7, 10], [15, 22]])
        await #expect(throws: DraftRejected.self) {
            _ = try await ProblemBuilder.check(draft, subject: .math, using: generator, executor: ScriptExecutor(output: "7 10\n15 21\n"))
        }
    }

    @Test("multiple choice needs a second pass to pick the same option")
    func checksChoices() async throws {
        let draft = GeneratedProblem(kind: .multipleChoice, prompt: "Which option describes what happens to demand here?", choices: ["a", "b", "c", "d"], correct: 1)
        let agree = ProblemGenerator(solver: 1)
        let kept = try await ProblemBuilder.check(draft, subject: .economics, using: agree, executor: nil)
        #expect(kept.answerText == "b")
        await #expect(throws: DraftRejected.self) {
            _ = try await ProblemBuilder.check(draft, subject: .economics, using: ProblemGenerator(solver: 2), executor: nil)
        }
        await #expect(throws: DraftRejected.self) {
            _ = try await ProblemBuilder.check(draft, subject: .economics, using: ProblemGenerator(solver: nil), executor: nil)
        }
    }

    @Test("a multiple-choice problem becomes a shuffled choice question; typed ones stay written")
    func roundQuestions() {
        var rng = SystemRandomNumberGenerator()
        let mc = ProblemQuestion(kind: .multipleChoice, subject: .concepts, prompt: "p", choices: ["a", "b", "c", "d"], correct: 2)
        let q = mc.roundQuestion(using: &rng)
        #expect(q.type == .multipleChoice)
        #expect(q.correctAnswer == "c")
        #expect(Set(q.choices ?? []) == ["a", "b", "c", "d"])
        let number = ProblemQuestion(kind: .number, subject: .math, prompt: "p", number: 4.5, unit: "m")
        #expect(number.roundQuestion(using: &rng).type == .written)
        #expect(number.answerText == "4.5 m")
        #expect(ProblemAnswerGrading.grade(number, given: "4.5") == true)
    }

    @Test("a saved problem is stored with its subject and comes back into a test")
    func bank() async throws {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "C"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "D"); try deck.insert(conn)
            let problem = ProblemQuestion(kind: .number, subject: .economics, prompt: "p", number: 3)
            try TestQuestion(courseId: course.id, deckId: deck.id, problem: problem, bodyJSON: problem.encoded()!,
                             verifiedBy: "test").insert(conn)
            let code = CodeQuestion(kind: .predictOutput, language: .python, prompt: "p", code: "print(1)", expectedOutput: "1")
            try TestQuestion(courseId: course.id, deckId: deck.id, kind: .predictOutput, language: .python,
                             bodyJSON: code.encoded()!, verifiedBy: "test").insert(conn)
            return deck.id
        }
        let all = try await db.queue.read { try CodeQuestionBank.questions(inDecks: [deckId], db: $0) }
        #expect(all.count == 2)
        #expect(all.compactMap(\.problem).count == 1)
        #expect(all.compactMap(\.question).count == 1)
        #expect(all.map(\.summary).contains { $0.contains("Type a number") })
        let round = try await db.queue.read { conn -> [LearnEngine.RoundQuestion] in
            var rng = SystemRandomNumberGenerator()
            return try CodeQuestionBank.pickRound(count: 5, inDecks: [deckId], using: &rng, db: conn)
        }
        #expect(round.count == 2)
        #expect(round.filter { $0.problem != nil }.count == 1)
        #expect(round.filter { $0.code != nil }.count == 1)
    }
}
