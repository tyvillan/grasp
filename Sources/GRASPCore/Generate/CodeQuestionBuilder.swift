import Foundation
import GRDB

/// Writes code questions for a deck and keeps only the ones that survive
/// being run. A model's code is often subtly wrong and its claimed output
/// worse, so nothing it says about a program is believed: the program is
/// compiled and run, and the answer is what it really did.
public enum CodeQuestionBuilder {
    public struct Outcome: Sendable, Equatable {
        public var saved = 0
        public var rejected = 0
        /// Why drafts were dropped, with how many for each.
        public var reasons: [String: Int] = [:]
        /// No compiler or interpreter for this language here.
        public var cannotRun = false
        /// Decks with no code in their notes, by name.
        public var notCodeDecks: [String] = []
        public var wasCancelled = false
        public init() {}
    }

    // MARK: - Verifying one question

    typealias Rejected = DraftRejected

    /// A question that has been run and held up, or nil.
    static func verify(_ draft: GeneratedCodeQuestion, language: CodeLanguage,
                       using executor: any CodeExecuting) async -> CodeQuestion? {
        try? await check(draft, language: language, using: executor)
    }

    /// The same, saying why when it fails.
    static func check(_ draft: GeneratedCodeQuestion, language: CodeLanguage,
                      using executor: any CodeExecuting) async throws -> CodeQuestion {
        switch draft.kind {
        case .codeBlanks: return try await verifyBlanks(draft, language: language, using: executor)
        case .predictOutput: return try await verifyOutput(draft, language: language, using: executor)
        case .findBug: return try await verifyBug(draft, language: language, using: executor)
        case .completeFunction: return try await verifyFunction(draft, language: language, using: executor)
        }
    }

    private static func blankNumbers(in code: String) -> [Int] {
        CodeQuestion.blankPattern.matches(in: code, range: NSRange(location: 0, length: (code as NSString).length))
            .compactMap { Int((code as NSString).substring(with: $0.range(at: 1))) }
    }

    /// Output a student can reasonably be asked to type or compare.
    private static func usable(_ output: String) -> Bool {
        let lines = CodeAnswerGrading.normalizedOutput(output)
        return !lines.isEmpty && lines.count <= 15 && lines.allSatisfy { $0.count <= 120 }
    }

    /// First line of the compiler's complaint, for the reason.
    private static func firstProblem(_ result: CodeRunResult) -> String {
        if !result.compiled {
            let line = result.stderr.components(separatedBy: "\n").first { $0.contains("error") || $0.contains("Error") || $0.contains("Not run") }
            return "did not compile" + (line.map { ": " + String($0.suffix(90)) } ?? "")
        }
        if result.timedOut { return "ran too long" }
        if result.exitCode != 0 { return "crashed (exit \(result.exitCode))" }
        return "printed nothing usable"
    }

    /// Run twice: a program whose output changes is not a question.
    private static func steadyRun(_ source: String, language: CodeLanguage,
                                  using executor: any CodeExecuting) async throws -> CodeRunResult {
        if CodeSafety.readsInput(source) {
            throw Rejected(reason: "the program asks for typed input, which a question can't give it")
        }
        let first = await executor.run(source, language: language)
        guard first.succeeded else { throw Rejected(reason: "the program " + firstProblem(first)) }
        guard usable(first.stdout) else { throw Rejected(reason: "the program's output was empty or too long") }
        let second = await executor.run(source, language: language)
        guard second.succeeded, second.stdout == first.stdout else {
            throw Rejected(reason: "the program's output changed between runs")
        }
        return first
    }

    /// What the finished program prints, as the prompt shows it: the
    /// question's words come from the real run, not from the model, which
    /// often described a different program than the one it wrote.
    private static func printing(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func verifyBlanks(_ draft: GeneratedCodeQuestion, language: CodeLanguage,
                                     using executor: any CodeExecuting) async throws -> CodeQuestion {
        let numbers = blankNumbers(in: draft.code)
        guard !numbers.isEmpty, numbers.count <= 3, Set(numbers).count == numbers.count,
              numbers.sorted() == Array(1...numbers.count)
        else { throw Rejected(reason: "the blanks weren't numbered [[1]], [[2]]...") }
        guard draft.answers.count == numbers.count,
              draft.answers.allSatisfy({ !$0.isEmpty && $0[0].count <= 80 && !$0[0].contains("\n") })
        else { throw Rejected(reason: "the answers didn't match the blanks") }

        func program(_ answers: [String]) -> String { CodeQuestion.fill(draft.code) { answers[$0 - 1] } }
        let primary = draft.answers.map { $0[0] }
        let reference = try await steadyRun(program(primary), language: language, using: executor)

        // An alternative is accepted only if the program still prints the
        // same thing with it.
        var accepted: [[String]] = []
        for (index, options) in draft.answers.enumerated() {
            var kept = [options[0]]
            for alternative in options.dropFirst().prefix(2)
            where CodeAnswerGrading.normalizedCode(alternative) != CodeAnswerGrading.normalizedCode(options[0]) {
                var trial = primary
                trial[index] = alternative
                let result = await executor.run(program(trial), language: language)
                if result.succeeded, result.stdout == reference.stdout { kept.append(alternative) }
            }
            accepted.append(kept)
        }
        let output = printing(reference.stdout)
        return CodeQuestion(kind: .codeBlanks, language: language,
                            prompt: "Fill in the blanks so the program prints:\n" + output,
                            code: draft.code, blanks: accepted, expectedOutput: output, explanation: draft.explanation)
    }

    private static func verifyOutput(_ draft: GeneratedCodeQuestion, language: CodeLanguage,
                                     using executor: any CodeExecuting) async throws -> CodeQuestion {
        guard blankNumbers(in: draft.code).isEmpty else { throw Rejected(reason: "it had blanks in a predict-the-output question") }
        let run = try await steadyRun(draft.code, language: language, using: executor)
        return CodeQuestion(kind: .predictOutput, language: language, prompt: "What does this program print?",
                            code: draft.code, expectedOutput: printing(run.stdout), explanation: draft.explanation)
    }

    private static func verifyBug(_ draft: GeneratedCodeQuestion, language: CodeLanguage,
                                  using executor: any CodeExecuting) async throws -> CodeQuestion {
        var lines = draft.code.components(separatedBy: "\n")
        guard blankNumbers(in: draft.code).isEmpty,
              let buggy = draft.buggyLine, (1...lines.count).contains(buggy),
              let fixed = draft.fixedLine?.trimmingCharacters(in: .whitespaces), !fixed.isEmpty,
              !fixed.contains("\n"),
              fixed != lines[buggy - 1].trimmingCharacters(in: .whitespaces)
        else { throw Rejected(reason: "the buggy line or its fix was missing or unchanged") }
        let indent = String(lines[buggy - 1].prefix { $0 == " " || $0 == "\t" })
        lines[buggy - 1] = indent + fixed
        let correct = try await steadyRun(lines.joined(separator: "\n"), language: language, using: executor)
        // The bug has to be real: the original must break or print something else.
        let broken = await executor.run(draft.code, language: language)
        if broken.succeeded && broken.stdout == correct.stdout { throw Rejected(reason: "the \"bug\" didn't change anything") }
        let output = printing(correct.stdout)
        return CodeQuestion(kind: .findBug, language: language,
                            prompt: "One line of this program is wrong. It should print:\n" + output + "\nWhich line is the bug?",
                            code: draft.code, expectedOutput: output, buggyLine: buggy, fixedLine: fixed,
                            explanation: draft.explanation)
    }

    private static func verifyFunction(_ draft: GeneratedCodeQuestion, language: CodeLanguage,
                                       using executor: any CodeExecuting) async throws -> CodeQuestion {
        guard blankNumbers(in: draft.code) == [1], let body = draft.answers.first?.first,
              body.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
        else { throw Rejected(reason: "the missing code wasn't a single [[1]] with an answer") }
        let run = try await steadyRun(CodeQuestion.fillBlock(draft.code, with: body), language: language, using: executor)
        let output = printing(run.stdout)
        return CodeQuestion(kind: .completeFunction, language: language,
                            prompt: "Write the missing code so the program prints:\n" + output,
                            code: draft.code, blanks: [[body]], expectedOutput: output, explanation: draft.explanation)
    }

    // MARK: - Writing a deck's questions

    static func mostCommon(_ languages: [CodeLanguage]) -> CodeLanguage? {
        Dictionary(grouping: languages, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    static func guessLanguage(_ code: String) -> CodeLanguage? {
        if code.contains("#include") || code.contains("cout") || code.contains("std::") || code.contains("int main") {
            return .cpp
        }
        if code.contains("def ") || code.contains("print(") || code.contains("import ") { return .python }
        return nil
    }
}

// MARK: - The bank

public enum CodeQuestionBank {
    public static func questions(inDecks deckIds: [String], db: Database) throws -> [TestQuestion] {
        guard !deckIds.isEmpty else { return [] }
        return try TestQuestion
            .filter(deckIds.contains(Column("deckId")))
            .filter(Column("deletedAt") == nil)
            .order(Column("createdAt").desc)
            .fetchAll(db)
    }

    public static func count(inDecks deckIds: [String], db: Database) throws -> Int {
        guard !deckIds.isEmpty else { return 0 }
        return try TestQuestion.filter(deckIds.contains(Column("deckId"))).filter(Column("deletedAt") == nil).fetchCount(db)
    }

    /// Soft delete, like cards: a deleted question stays as a tombstone so
    /// it can't come back from another device's copy.
    public static func delete(_ id: String, now: Date = Date(), db: Database) throws {
        guard var question = try TestQuestion.fetchOne(db, key: id) else { return }
        question.deletedAt = now
        try question.save(db)
    }

    /// Whether the note this was written from has changed since.
    public static func isStale(_ question: TestQuestion, db: Database) throws -> Bool {
        guard let materialId = question.materialId, let material = try Material.fetchOne(db, key: materialId),
              let hash = material.contentHash, let written = question.sourceContentHash else { return false }
        return hash != written
    }

    /// Up to `count` saved questions of every kind, as test questions.
    public static func pickRound<R: RandomNumberGenerator>(
        count: Int, inDecks deckIds: [String], using rng: inout R, db: Database
    ) throws -> [LearnEngine.RoundQuestion] {
        var pool = try questions(inDecks: deckIds, db: db)
        pool.shuffle(using: &rng)
        var result: [LearnEngine.RoundQuestion] = []
        for record in pool {
            guard result.count < count else { break }
            if let code = record.question {
                result.append(code.roundQuestion())
            } else if let problem = record.problem {
                result.append(problem.roundQuestion(using: &rng))
            }
        }
        return result
    }

    /// Up to `count` questions for a test, drawn at random.
    public static func pick<R: RandomNumberGenerator>(
        count: Int, kinds: Set<CodeQuestionKind>? = nil, inDecks deckIds: [String], using rng: inout R, db: Database
    ) throws -> [CodeQuestion] {
        var pool = try questions(inDecks: deckIds, db: db).compactMap(\.question)
        if let kinds { pool = pool.filter { kinds.contains($0.kind) } }
        pool.shuffle(using: &rng)
        return Array(pool.prefix(max(0, count)))
    }
}

extension CodeQuestion {
    /// Fills the single multi-line gap `[[1]]` with a block of code:
    /// dedented, then indented to where the gap sits, so Python keeps its
    /// structure and C++ stays tidy.
    public static func fillBlock(_ code: String, with body: String) -> String {
        let marker = "\u{0}"
        let bodyLines = dedented(body).components(separatedBy: "\n")
        return fill(code) { _ in marker }.components(separatedBy: "\n").map { line -> String in
            guard let range = line.range(of: marker) else { return line }
            let indent = String(line[..<range.lowerBound].prefix { $0 == " " || $0 == "\t" })
            var out = [bodyLines[0]]
            out += bodyLines.dropFirst().map { $0.isEmpty ? $0 : indent + $0 }
            return String(line[..<range.lowerBound]) + out.joined(separator: "\n") + String(line[range.upperBound...])
        }.joined(separator: "\n")
    }

    static func dedented(_ text: String) -> String {
        let lines = text.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let common = indents.min() ?? 0
        return lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
            .joined(separator: "\n")
    }
}
