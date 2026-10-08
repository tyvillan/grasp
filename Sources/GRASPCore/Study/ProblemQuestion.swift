import Foundation

/// What a deck is about, for choosing what kind of practice to write.
public enum ProblemSubject: String, Codable, CaseIterable, Sendable {
    case code, math, economics, concepts

    public var label: String {
        switch self {
        case .code: return "Code"
        case .math: return "Math (matrices, algebra)"
        case .economics: return "Economics calculations"
        case .concepts: return "Concepts"
        }
    }

    /// Read from the notes: code if they hold any, then matrices or
    /// equations, then supply-and-demand vocabulary, else concepts.
    public static func detect(notes: String, courseName: String, deckName: String) -> ProblemSubject {
        let text = (notes + " " + courseName + " " + deckName).lowercased()
        if text.contains("#include") || text.contains("int main") || (text.contains("def ") && text.contains("print(")) {
            return .code
        }
        func hits(_ words: [String]) -> Int { words.filter { text.contains($0) }.count }
        let math = hits(["matrix", "matrices", "determinant", "eigen", "vector", "linear algebra", "row reduction",
                         "rref", "inverse", "linear system", "bmatrix", "span", "basis", "transpose", "rank"])
        let econ = hits(["demand", "supply", "elasticity", "surplus", "marginal", "equilibrium", "opportunity cost",
                         "comparative advantage", "price", "tariff", "gdp", "inflation", "utility"])
        if math >= 3 && math >= econ { return .math }
        if econ >= 3 { return .economics }
        if math >= 2 { return .math }
        return .concepts
    }
}

public enum ProblemKind: String, Codable, CaseIterable, Sendable {
    case multipleChoice, number, matrix

    public var label: String {
        switch self {
        case .multipleChoice: return "Multiple choice"
        case .number: return "Type a number"
        case .matrix: return "Type a matrix"
        }
    }
}

/// A worked problem that isn't code: a scenario with options, a number to
/// work out, or a matrix or vector to write. Saved in the same bank as code
/// questions (`TestQuestion`), with `kind` one of `ProblemKind`.
public struct ProblemQuestion: Codable, Sendable, Equatable {
    public var kind: ProblemKind
    public var subject: ProblemSubject
    /// The problem, which may span lines; a matrix is written as bracketed rows.
    public var prompt: String
    /// `multipleChoice`: the options, and which one is right.
    public var choices: [String]?
    public var correct: Int?
    /// `number`: the value, and its unit when it has one ("%", "dollars").
    public var number: Double?
    public var unit: String?
    /// `matrix`: rows of entries (a vector is one column or one row).
    public var matrix: [[Double]]?
    /// How to get there, a sentence or two.
    public var explanation: String?

    public init(kind: ProblemKind, subject: ProblemSubject, prompt: String, choices: [String]? = nil,
                correct: Int? = nil, number: Double? = nil, unit: String? = nil, matrix: [[Double]]? = nil,
                explanation: String? = nil) {
        self.kind = kind; self.subject = subject; self.prompt = prompt; self.choices = choices
        self.correct = correct; self.number = number; self.unit = unit; self.matrix = matrix
        self.explanation = explanation
    }

    public func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(_ json: String?) -> ProblemQuestion? {
        guard let data = json?.data(using: .utf8),
              var problem = try? JSONDecoder().decode(ProblemQuestion.self, from: data) else { return nil }
        // Problems saved before the model was told to avoid LaTeX.
        problem.prompt = PlainMath.clean(problem.prompt)
        problem.choices = problem.choices.map(PlainMath.clean)
        problem.explanation = problem.explanation.map(PlainMath.clean)
        return problem
    }

    /// The right answer in words, for the results screen.
    public var answerText: String {
        switch kind {
        case .multipleChoice:
            guard let choices, let correct, choices.indices.contains(correct) else { return "" }
            return choices[correct]
        case .number:
            return (number.map(ProblemAnswerGrading.format) ?? "") + (unit.map { " " + $0 } ?? "")
        case .matrix:
            return (matrix ?? []).map { "[ " + $0.map(ProblemAnswerGrading.format).joined(separator: "  ") + " ]" }
                .joined(separator: "\n")
        }
    }

    /// This problem as a test question. Multiple choice uses the ordinary
    /// choice list (shuffled); the others are typed answers.
    public func roundQuestion<R: RandomNumberGenerator>(id: String = UUID().uuidString,
                                                        using rng: inout R) -> LearnEngine.RoundQuestion {
        if kind == .multipleChoice, let choices, let correct, choices.indices.contains(correct) {
            return LearnEngine.RoundQuestion(id: id, cardId: nil, prompt: prompt, correctAnswer: choices[correct],
                                             type: .multipleChoice, choices: choices.shuffled(using: &rng),
                                             problem: self)
        }
        return LearnEngine.RoundQuestion(id: id, cardId: nil, prompt: prompt, correctAnswer: answerText,
                                         type: .written, problem: self)
    }
}

// MARK: - Grading

public enum ProblemAnswerGrading {
    /// "12", "12.50", "3.5" -- no trailing zeros.
    public static func format(_ value: Double) -> String {
        if abs(value - value.rounded()) < 1e-9 { return String(Int(value.rounded())) }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    private static let numberPattern = try! NSRegularExpression(pattern: #"[-+]?\d+(?:\.\d+)?(?:\s*/\s*[-+]?\d+(?:\.\d+)?)?|[-+]?\.\d+"#)

    /// A number as a student types it: "$1,200", "-3/4", "12.5%", "= 7",
    /// "about 3.2 units". The first number in the text.
    public static func parseNumber(_ text: String) -> Double? {
        var cleaned = text.replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "=", with: " ")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = cleaned as NSString
        guard let match = numberPattern.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let token = ns.substring(with: match.range).replacingOccurrences(of: " ", with: "")
        if let slash = token.firstIndex(of: "/") {
            guard let top = Double(token[..<slash]), let bottom = Double(token[token.index(after: slash)...]),
                  bottom != 0 else { return nil }
            return top / bottom
        }
        return Double(token)
    }

    /// Whether `given` is the expected value: exact for whole numbers,
    /// otherwise within a cent or half a percent, so 0.33 and 1/3 agree.
    public static func isClose(_ given: Double, to expected: Double) -> Bool {
        if abs(expected - expected.rounded()) < 1e-9 { return abs(given - expected) < 1e-6 }
        return abs(given - expected) <= max(0.011, 0.005 * abs(expected))
    }

    public static func gradeNumber(_ text: String, expected: Double) -> Bool {
        parseNumber(text).map { isClose($0, to: expected) } ?? false
    }

    /// Rows from "[[1, 2], [3, 4]]", "1 2\n3 4", "1,2;3,4" or "[1 2] [3 4]".
    public static func parseMatrix(_ text: String) -> [[Double]]? {
        var normalized = text.replacingOccurrences(of: "\u{2212}", with: "-")
        // Between rows: "], [", "] [", "];", or a line break.
        normalized = normalized.replacingOccurrences(of: #"\]\s*[,;]?\s*\["#, with: "\n", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: ";", with: "\n")
        for symbol in ["[", "]", "(", ")", "|", "{", "}"] {
            normalized = normalized.replacingOccurrences(of: symbol, with: " ")
        }
        var rows: [[Double]] = []
        for line in normalized.components(separatedBy: .newlines) {
            let tokens = line.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).map(String.init)
            guard !tokens.isEmpty else { continue }
            var row: [Double] = []
            for token in tokens {
                guard let value = parseNumber(token) else { return nil }
                row.append(value)
            }
            rows.append(row)
        }
        guard !rows.isEmpty, rows.allSatisfy({ $0.count == rows[0].count }) else { return nil }
        return rows
    }

    public static func gradeMatrix(_ text: String, expected: [[Double]]) -> Bool {
        guard let given = parseMatrix(text), given.count == expected.count else { return false }
        for (row, wanted) in zip(given, expected) {
            guard row.count == wanted.count else { return false }
            for (a, b) in zip(row, wanted) where !isClose(a, to: b) { return false }
        }
        return true
    }

    /// Whether `given` answers `problem`; multiple choice is graded by the
    /// choice list itself, so it has no verdict here.
    public static func grade(_ problem: ProblemQuestion, given: String) -> Bool? {
        switch problem.kind {
        case .number: return problem.number.map { gradeNumber(given, expected: $0) }
        case .matrix: return problem.matrix.map { gradeMatrix(given, expected: $0) }
        case .multipleChoice: return nil
        }
    }
}
