import Foundation
import GRDB

public enum CodeQuestionKind: String, Codable, CaseIterable, Sendable {
    /// A program with blanks to fill in.
    case codeBlanks
    /// A short program; type what it prints.
    case predictOutput
    /// A program with one wrong line; pick the line.
    case findBug
    /// Code to write into one gap, graded by running the finished program.
    case completeFunction

    public var label: String {
        switch self {
        case .codeBlanks: return "Fill in the blanks"
        case .predictOutput: return "Predict the output"
        case .findBug: return "Find the bug"
        case .completeFunction: return "Complete the function"
        }
    }
}

public enum CodeLanguage: String, Codable, CaseIterable, Sendable {
    case cpp, python

    public var label: String { self == .cpp ? "C++" : "Python" }
    public var fileExtension: String { self == .cpp ? "cpp" : "py" }

    /// "c++", "cpp", "cc" and "python3" as notes spell them.
    public static func named(_ text: String?) -> CodeLanguage? {
        switch text?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "cpp", "c++", "cc", "cxx", "hpp", "h": return .cpp
        case "python", "python3", "py": return .python
        default: return nil
        }
    }
}

/// One code question, as shown and graded. Stored as JSON on
/// `TestQuestion.bodyJSON`, and copied onto `TestItem.payloadJSON` when a
/// test uses it, so a finished test can still show what it asked.
public struct CodeQuestion: Codable, Sendable, Equatable {
    public var kind: CodeQuestionKind
    public var language: CodeLanguage
    /// What to do: "Fill in the blanks so the program prints the sum."
    public var prompt: String
    /// The program as shown. Blanks are `[[1]]`, `[[2]]`... for
    /// `codeBlanks`; a buggy program for `findBug`.
    public var code: String
    /// `codeBlanks`: the accepted answers for each blank, the first being
    /// the one shown as the answer. `completeFunction`: one blank holding
    /// the reference code.
    public var blanks: [[String]]?
    /// What the finished program prints, from really running it. The
    /// answer for `predictOutput`, and what a `completeFunction` answer's
    /// program must print.
    public var expectedOutput: String?
    /// `findBug`: the 1-based line with the error, and how it should read.
    public var buggyLine: Int?
    public var fixedLine: String?
    public var explanation: String?

    public init(kind: CodeQuestionKind, language: CodeLanguage, prompt: String, code: String,
                blanks: [[String]]? = nil, expectedOutput: String? = nil, buggyLine: Int? = nil,
                fixedLine: String? = nil, explanation: String? = nil) {
        self.kind = kind; self.language = language; self.prompt = prompt; self.code = code
        self.blanks = blanks; self.expectedOutput = expectedOutput; self.buggyLine = buggyLine
        self.fixedLine = fixedLine; self.explanation = explanation
    }

    public var blankCount: Int { blanks?.count ?? 0 }

    public func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(_ json: String?) -> CodeQuestion? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CodeQuestion.self, from: data)
    }

    // MARK: Blanks

    static let blankPattern = try! NSRegularExpression(pattern: #"\[\[(\d{1,2})\]\]"#)

    /// The code with each `[[n]]` replaced by `fill(n)` (1-based).
    public func code(filling fill: (Int) -> String) -> String {
        Self.fill(code, with: fill)
    }

    static func fill(_ text: String, with fill: (Int) -> String) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in blankPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let number = Int(ns.substring(with: match.range(at: 1))) ?? 0
            result += fill(number)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// The code split at its blanks: text, blank 1, text, blank 2, ...
    public enum Piece: Equatable, Sendable {
        case text(String)
        case blank(Int)
    }

    public var pieces: [Piece] { Self.pieces(in: code) }

    /// One list of pieces per line, so each line can be laid out on its own.
    public var linePieces: [[Piece]] { code.components(separatedBy: "\n").map { Self.pieces(in: $0) } }

    static func pieces(in text: String) -> [Piece] {
        let ns = text as NSString
        var result: [Piece] = []
        var last = 0
        for match in blankPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > last {
                result.append(.text(ns.substring(with: NSRange(location: last, length: match.range.location - last))))
            }
            result.append(.blank(Int(ns.substring(with: match.range(at: 1))) ?? 0))
            last = match.range.location + match.range.length
        }
        if last < ns.length { result.append(.text(ns.substring(from: last))) }
        return result
    }

    /// This question as a test question: the prompt, with the answer text
    /// the run view and results show.
    public func roundQuestion(id: String = UUID().uuidString) -> LearnEngine.RoundQuestion {
        LearnEngine.RoundQuestion(id: id, cardId: nil, prompt: prompt, correctAnswer: answerText,
                                  type: .written, code: self)
    }

    /// What a student typed, in words, for the results screen.
    public func givenText(_ given: String) -> String {
        switch kind {
        case .codeBlanks:
            return CodeAnswers.decode(given).enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        default:
            return given
        }
    }

    /// What the answer is, in words, for the results screen.
    public var answerText: String {
        switch kind {
        case .codeBlanks:
            return (blanks ?? []).enumerated().map { "\($0.offset + 1): \($0.element.first ?? "")" }.joined(separator: "\n")
        case .predictOutput:
            return expectedOutput ?? ""
        case .findBug:
            return "Line \(buggyLine ?? 0)" + (fixedLine.map { ": \($0)" } ?? "")
        case .completeFunction:
            return blanks?.first?.first ?? ""
        }
    }
}

// MARK: - The saved question bank

/// A verified question saved against a deck (see `CodeQuestionBuilder`).
public struct TestQuestion: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "testQuestion"
    public var id: String
    public var courseId: String
    public var deckId: String
    public var materialId: String?
    public var kind: String
    public var language: String
    public var bodyJSON: String
    /// The note's `contentHash` when this was written, so an edited note
    /// shows its questions as out of date.
    public var sourceContentHash: String?
    /// How it was checked: "clang++ 17 run" and the like.
    public var verifiedBy: String
    public var model: String?
    public var createdAt: Date
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, courseId: String, deckId: String, materialId: String? = nil,
                kind: CodeQuestionKind, language: CodeLanguage, bodyJSON: String, sourceContentHash: String? = nil,
                verifiedBy: String, model: String? = nil, createdAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.courseId = courseId; self.deckId = deckId; self.materialId = materialId
        self.kind = kind.rawValue; self.language = language.rawValue; self.bodyJSON = bodyJSON
        self.sourceContentHash = sourceContentHash; self.verifiedBy = verifiedBy; self.model = model
        self.createdAt = createdAt; self.deletedAt = deletedAt
    }

    /// A bank row for a non-code problem; `language` holds its subject.
    public init(id: String = UUID().uuidString, courseId: String, deckId: String, materialId: String? = nil,
                problem: ProblemQuestion, bodyJSON: String, sourceContentHash: String? = nil,
                verifiedBy: String, model: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.courseId = courseId; self.deckId = deckId; self.materialId = materialId
        self.kind = problem.kind.rawValue; self.language = problem.subject.rawValue; self.bodyJSON = bodyJSON
        self.sourceContentHash = sourceContentHash; self.verifiedBy = verifiedBy; self.model = model
        self.createdAt = createdAt; self.deletedAt = nil
    }

    public var question: CodeQuestion? { CodeQuestionKind(rawValue: kind) == nil ? nil : CodeQuestion.decode(bodyJSON) }
    public var problem: ProblemQuestion? { ProblemKind(rawValue: kind) == nil ? nil : ProblemQuestion.decode(bodyJSON) }

    /// One line saying what this is, for the bank list.
    public var summary: String {
        if let question { return "\(question.kind.label) · \(question.language.label)" }
        if let problem { return "\(problem.kind.label) · \(problem.subject.label)" }
        return kind
    }

    /// The question text, whichever kind it is.
    public var promptText: String { question?.prompt ?? problem?.prompt ?? "" }
}

// MARK: - Grading (no compiler needed)

public enum CodeAnswerGrading {
    /// Code compared the way a student would write it: spacing doesn't
    /// matter, spelling and case do. "i<n" equals "i < n".
    public static func normalizedCode(_ text: String) -> String {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init).joined()
    }

    /// One mark per blank, in order. A missing answer is wrong.
    public static func gradeBlanks(_ given: [String], against blanks: [[String]]) -> [Bool] {
        blanks.enumerated().map { index, accepted in
            guard index < given.count else { return false }
            let answer = normalizedCode(given[index])
            guard !answer.isEmpty else { return false }
            return accepted.contains { normalizedCode($0) == answer }
        }
    }

    /// Lines compared one by one, ignoring trailing spaces and blank lines
    /// at the end -- what a program's output looks like on the terminal.
    public static func normalizedOutput(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    public static func gradeOutput(_ given: String, expected: String) -> Bool {
        normalizedOutput(given) == normalizedOutput(expected)
    }

    /// "Line 4", "4" or "line4" all mean line 4.
    public static func lineNumber(from text: String) -> Int? {
        Int(text.filter(\.isNumber))
    }

    /// Whether `given` answers `question`, for the kinds that can be graded
    /// without running anything. `completeFunction` is graded by running
    /// it (see `CodeExecuting`), or by the student on a device that can't.
    public static func grade(_ question: CodeQuestion, given: String) -> Bool? {
        switch question.kind {
        case .codeBlanks:
            let answers = CodeAnswers.decode(given)
            let marks = gradeBlanks(answers, against: question.blanks ?? [])
            return !marks.isEmpty && marks.allSatisfy { $0 }
        case .predictOutput:
            return gradeOutput(given, expected: question.expectedOutput ?? "")
        case .findBug:
            return lineNumber(from: given) == question.buggyLine
        case .completeFunction:
            return nil
        }
    }
}

/// Several blanks' answers in the one string a `TestItem` stores.
public enum CodeAnswers {
    public static func encode(_ answers: [String]) -> String {
        (try? JSONEncoder().encode(answers)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    public static func decode(_ text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let answers = try? JSONDecoder().decode([String].self, from: data) else { return [text] }
        return answers
    }
}
