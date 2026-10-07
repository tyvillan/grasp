import Foundation
import GRDB
import Testing
@testable import GRASPCore

/// A stand-in compiler: it "runs" a program by looking up what the test says
/// that exact text prints.
private struct FakeExecutor: CodeExecuting {
    var outputs: [String: CodeRunResult]
    func canRun(_ language: CodeLanguage) -> Bool { true }
    func run(_ source: String, language: CodeLanguage) async -> CodeRunResult {
        outputs[source] ?? CodeRunResult(compiled: false, stderr: "error")
    }
}

private func ok(_ out: String) -> CodeRunResult { CodeRunResult(compiled: true, stdout: out) }

@Suite("CodeQuestion")
struct CodeQuestionTests {
    @Test("blanks are found, filled and split into pieces")
    func blanks() {
        let q = CodeQuestion(kind: .codeBlanks, language: .cpp, prompt: "p",
                             code: "for (int i = [[1]]; i < [[2]]; i++)", blanks: [["0"], ["n"]])
        #expect(q.code(filling: { q.blanks![$0 - 1][0] }) == "for (int i = 0; i < n; i++)")
        #expect(q.pieces == [.text("for (int i = "), .blank(1), .text("; i < "), .blank(2), .text("; i++)")])
    }

    @Test("blank answers ignore spacing but not spelling, and every blank must be right")
    func gradesBlanks() {
        let q = CodeQuestion(kind: .codeBlanks, language: .cpp, prompt: "p", code: "[[1]] [[2]]",
                             blanks: [["i < n", "i<n"], ["count"]])
        #expect(CodeAnswerGrading.gradeBlanks(["i<n", "count"], against: q.blanks!) == [true, true])
        #expect(CodeAnswerGrading.gradeBlanks(["i <= n", "Count"], against: q.blanks!) == [false, false])
        #expect(CodeAnswerGrading.gradeBlanks(["i<n"], against: q.blanks!) == [true, false])
        #expect(CodeAnswerGrading.grade(q, given: CodeAnswers.encode(["i < n", "count"])) == true)
        #expect(CodeAnswerGrading.grade(q, given: CodeAnswers.encode(["i < n", ""])) == false)
    }

    @Test("output is compared line by line, ignoring trailing space and blank lines")
    func gradesOutput() {
        #expect(CodeAnswerGrading.gradeOutput("1 2 3  \n\n", expected: "1 2 3"))
        #expect(!CodeAnswerGrading.gradeOutput("1 2", expected: "1 2 3"))
        let bug = CodeQuestion(kind: .findBug, language: .cpp, prompt: "p", code: "a\nb", buggyLine: 2, fixedLine: "c")
        #expect(CodeAnswerGrading.grade(bug, given: "Line 2") == true)
        #expect(CodeAnswerGrading.grade(bug, given: "1") == false)
    }

    @Test("a block of code is dedented and indented to where its gap sits")
    func fillsBlock() {
        let code = "def f(n):\n    [[1]]\nprint(f(3))"
        #expect(CodeQuestion.fillBlock(code, with: "    total = 0\n    for i in range(n):\n        total += i\n    return total")
                == "def f(n):\n    total = 0\n    for i in range(n):\n        total += i\n    return total\nprint(f(3))")
    }

    @Test("the model's tagged layout is parsed, with fences and alternatives")
    func parses() {
        let raw = """
        Here are your questions:
        ### QUESTION
        KIND: codeBlanks
        PROMPT: Fill in the loop.
        CODE:
        ```cpp
        #include <iostream>
        int main() { for (int i = [[1]]; i < [[2]]; i++) std::cout << i; }
        ```
        ANSWERS:
        1: 0
        2: 3 || 3 + 0
        EXPLANATION: It counts up.
        ### END
        ### QUESTION
        KIND: findBug
        PROMPT: Which line is wrong?
        CODE:
        int x = 1;
        int y = x +;
        BUGGY_LINE: 2
        FIXED_LINE: int y = x + 1;
        EXPLANATION: Missing operand.
        ### QUESTION
        KIND: nonsense
        PROMPT: x
        CODE:
        y
        """
        let questions = OllamaGenerator.parseCodeQuestions(raw)
        #expect(questions.count == 2)
        #expect(questions[0].kind == .codeBlanks)
        #expect(questions[0].code.hasPrefix("#include <iostream>"))
        #expect(!questions[0].code.contains("```"))
        #expect(questions[0].answers == [["0"], ["3", "3 + 0"]])
        #expect(questions[1].buggyLine == 2)
        #expect(questions[1].fixedLine == "int y = x + 1;")
    }

    @Test("a question is kept only when running it works, and its answer comes from the run")
    func verifiesAgainstRunning() async throws {
        let blanks = GeneratedCodeQuestion(kind: .codeBlanks, prompt: "p", code: "print([[1]])", answers: [["1 + 1", "2", "3"]])
        let executor = FakeExecutor(outputs: [
            "print(1 + 1)": ok("2\n"), "print(2)": ok("2\n"), "print(3)": ok("3\n"),
        ])
        let kept = try #require(await CodeQuestionBuilder.verify(blanks, language: .python, using: executor))
        // "3" prints something else, so it isn't an accepted alternative.
        #expect(kept.blanks == [["1 + 1", "2"]])
        #expect(kept.expectedOutput == "2")

        let wrong = GeneratedCodeQuestion(kind: .codeBlanks, prompt: "p", code: "print([[1]])", answers: [["oops"]])
        #expect(await CodeQuestionBuilder.verify(wrong, language: .python, using: executor) == nil)

        // The model's claimed output doesn't matter: the run decides it.
        let output = GeneratedCodeQuestion(kind: .predictOutput, prompt: "p", code: "print(1 + 1)")
        let predicted = try #require(await CodeQuestionBuilder.verify(output, language: .python, using: executor))
        #expect(predicted.expectedOutput == "2")
    }

    @Test("a program whose output changes between runs is dropped")
    func rejectsUnsteadyPrograms() async {
        final class Counter: @unchecked Sendable { var n = 0 }
        struct Flaky: CodeExecuting {
            let counter: Counter
            func canRun(_ language: CodeLanguage) -> Bool { true }
            func run(_ source: String, language: CodeLanguage) async -> CodeRunResult {
                counter.n += 1
                return CodeRunResult(compiled: true, stdout: "\(counter.n)\n")
            }
        }
        let draft = GeneratedCodeQuestion(kind: .predictOutput, prompt: "p", code: "x")
        #expect(await CodeQuestionBuilder.verify(draft, language: .python, using: Flaky(counter: Counter())) == nil)
    }

    @Test("a bug question needs a real bug: the broken line must change what happens")
    func verifiesBugs() async throws {
        let draft = GeneratedCodeQuestion(kind: .findBug, prompt: "p", code: "a = 1\nprint(a + )", buggyLine: 2,
                                          fixedLine: "print(a + 1)")
        let executor = FakeExecutor(outputs: ["a = 1\nprint(a + 1)": ok("2\n")])
        let kept = try #require(await CodeQuestionBuilder.verify(draft, language: .python, using: executor))
        #expect(kept.buggyLine == 2)
        #expect(kept.expectedOutput == "2")
        // A "bug" that behaves the same is no bug.
        let same = GeneratedCodeQuestion(kind: .findBug, prompt: "p", code: "a = 1\nprint(a + 1)", buggyLine: 2,
                                         fixedLine: "print(1 + a)")
        let both = FakeExecutor(outputs: ["a = 1\nprint(a + 1)": ok("2\n"), "a = 1\nprint(1 + a)": ok("2\n")])
        #expect(await CodeQuestionBuilder.verify(same, language: .python, using: both) == nil)
    }

    @Test("a program that waits for typed input is dropped")
    func refusesInput() async {
        #expect(CodeSafety.readsInput("int n; cin >> n;"))
        #expect(CodeSafety.readsInput("x = input('n? ')"))
        #expect(!CodeSafety.readsInput("cout << \"cinema\";"))
        let draft = GeneratedCodeQuestion(kind: .predictOutput, prompt: "p", code: "int n; cin >> n; cout << n;")
        let executor = FakeExecutor(outputs: ["int n; cin >> n; cout << n;": ok("0\n")])
        #expect(await CodeQuestionBuilder.verify(draft, language: .cpp, using: executor) == nil)
    }

    @Test("unsafe code is refused before anything runs")
    func refusesUnsafeCode() {
        #expect(CodeSafety.violation(in: "system(\"rm -rf /\");") != nil)
        #expect(CodeSafety.violation(in: "import os\nos.remove('x')") != nil)
        #expect(CodeSafety.violation(in: "std::ofstream out(\"a\");") != nil)
        #expect(CodeSafety.violation(in: "items.remove(3)\nint x = a.connect(b);") == nil)
        #expect(CodeSafety.violation(in: "#include <iostream>\nint main() { std::cout << 1; }") == nil)
    }

    @Test("saved questions can be listed, deleted and picked for a test")
    func bank() async throws {
        let db = try GRASPDatabase.inMemory()
        let (deckId) = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "C"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "D"); try deck.insert(conn)
            for index in 0..<3 {
                let q = CodeQuestion(kind: .predictOutput, language: .python, prompt: "p\(index)", code: "print(\(index))",
                                     expectedOutput: "\(index)")
                try TestQuestion(courseId: course.id, deckId: deck.id, kind: .predictOutput, language: .python,
                                 bodyJSON: q.encoded()!, verifiedBy: "test").insert(conn)
            }
            return deck.id
        }
        let picked = try await db.queue.read { conn -> [CodeQuestion] in
            var rng = SystemRandomNumberGenerator()
            return try CodeQuestionBank.pick(count: 2, inDecks: [deckId], using: &rng, db: conn)
        }
        #expect(picked.count == 2)
        let first = try await db.queue.read { try CodeQuestionBank.questions(inDecks: [deckId], db: $0) }.first!
        try await db.queue.write { try CodeQuestionBank.delete(first.id, db: $0) }
        #expect(try await db.queue.read { try CodeQuestionBank.count(inDecks: [deckId], db: $0) } == 2)
    }
}

#if os(macOS)
@Suite("CodeExecutor")
struct CodeExecutorTests {
    private let executor = ProcessCodeExecutor(compileTimeout: 90, runTimeout: 25)

    @Test("python runs and prints", .enabled(if: ProcessCodeExecutor().canRun(.python)))
    func python() async {
        let result = await executor.run("print(2 + 3)", language: .python)
        #expect(result.succeeded)
        #expect(result.stdout == "5\n")
    }

    @Test("C++ compiles and runs, and a compile error is reported", .enabled(if: ProcessCodeExecutor().canRun(.cpp)))
    func cpp() async {
        let good = await executor.run("#include <iostream>\nint main() { std::cout << 7 << std::endl; }", language: .cpp)
        #expect(good.succeeded)
        #expect(good.stdout == "7\n")
        let bad = await executor.run("int main() { return x; }", language: .cpp)
        #expect(!bad.compiled)
    }

    @Test("an endless program is stopped", .enabled(if: ProcessCodeExecutor().canRun(.python)))
    func timeout() async {
        let result = await ProcessCodeExecutor(compileTimeout: 10, runTimeout: 1).run("while True:\n    pass", language: .python)
        #expect(result.timedOut)
        #expect(!result.succeeded)
    }

    @Test("a program can't write outside its own folder or reach the network", .enabled(if: ProcessCodeExecutor().canRun(.python)))
    func sandbox() async {
        let path = "/tmp/grasp-sandbox-test-\(UUID().uuidString)"
        // `open(` is refused up front, so this one goes through a builtin
        // the deny-list doesn't name: the sandbox is the second wall.
        let source = """
        import io, builtins
        w = getattr(builtins, "op" + "en")
        try:
            w("\(path)", "w").write("x")
            print("wrote")
        except Exception as e:
            print("blocked")
        """
        let result = await executor.run(source, language: .python)
        #expect(result.stdout.contains("blocked"))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("a program that uses a variable before giving it a value is refused", .enabled(if: ProcessCodeExecutor().canRun(.cpp)))
    func uninitialized() async {
        let source = "#include <iostream>\nint main() { int x; std::cout << x << std::endl; }"
        let result = await executor.run(source, language: .cpp)
        #expect(!result.compiled)
        let fine = await executor.run("#include <iostream>\nint main() { int x = 4; std::cout << x << std::endl; }", language: .cpp)
        #expect(fine.succeeded)
    }

    @Test("unsafe code never reaches the compiler")
    func unsafe() async {
        let result = await executor.run("import os\nos.system('echo hi')", language: .python)
        #expect(!result.compiled)
        #expect(result.stderr.contains("Not run"))
    }
}
#endif
