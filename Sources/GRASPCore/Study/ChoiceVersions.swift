import Foundation

/// Multiple-choice versions of saved practice questions: the same question
/// with the answer picked from four instead of typed. Wrong options come
/// from the mistakes students actually make (an operator flipped, off by
/// one, a step skipped), never from the model, so they can be checked.
public enum ChoiceVersions {
    // MARK: - Code blanks

    private static let swaps: [(String, String)] = [
        ("<=", "<"), (">=", ">"), ("==", "!="), ("&&", "||"), ("++", "--"), ("+=", "-="), ("*=", "/="),
        ("<<", ">>"), ("cout", "cin"), ("true", "false"), ("endl", "\"\\n\""),
    ]
    private static let singleSwaps: [(Character, Character)] = [("<", ">"), ("+", "-"), ("*", "/")]

    /// Plausible wrong fills for one blank, before checking: operators
    /// flipped, numbers one off, the other blanks' answers, and names from
    /// the program in place of the one used. Never one of `accepted`.
    public static func blankCandidates(answer: String, accepted: [String], code: String,
                                       otherAnswers: [String]) -> [String] {
        var out: [String] = []
        func add(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.count <= 80 else { return }
            let key = CodeAnswerGrading.normalizedCode(trimmed)
            guard !accepted.contains(where: { CodeAnswerGrading.normalizedCode($0) == key }),
                  !out.contains(where: { CodeAnswerGrading.normalizedCode($0) == key }) else { return }
            out.append(trimmed)
        }
        // A comparison swapped for each of the others: the classic off-by-one
        // and wrong-direction mistakes.
        if let comparison = answer.range(of: #"<=|>=|==|!=|(?<![<>=!])[<>](?![<>=])"#, options: .regularExpression) {
            for other in ["<", "<=", ">", ">=", "==", "!="] where other != String(answer[comparison]) {
                add(answer.replacingCharacters(in: comparison, with: other))
            }
        }
        for (a, b) in swaps {
            if answer.contains(a) { add(answer.replacingOccurrences(of: a, with: b)) }
            else if answer.contains(b) { add(answer.replacingOccurrences(of: b, with: a)) }
        }
        // Single-character operators, only where they stand alone.
        for (a, b) in singleSwaps {
            for (from, to) in [(a, b), (b, a)] {
                let chars = Array(answer)
                for (i, c) in chars.enumerated() where c == from {
                    let before = i > 0 ? chars[i - 1] : " ", after = i + 1 < chars.count ? chars[i + 1] : " "
                    guard !"<>=+-*/&|".contains(before), !"<>=+-*/&|".contains(after) else { continue }
                    var copy = chars
                    copy[i] = to
                    add(String(copy))
                }
            }
        }
        // Numbers one off either way.
        let numberPattern = try! NSRegularExpression(pattern: #"(?<![\w.])\d+(?![\w.])"#)
        let ns = answer as NSString
        for match in numberPattern.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            guard let value = Int(ns.substring(with: match.range)) else { continue }
            for changed in [value + 1, value - 1, value + 2, value - 2, value * 2] where changed >= 0 && changed != value {
                add(ns.replacingCharacters(in: match.range, with: String(changed)))
            }
        }
        otherAnswers.forEach(add)
        // Another name from the program in place of each name in the answer.
        let identifier = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
        let keywords: Set<String> = ["int", "double", "char", "bool", "string", "void", "return", "if", "else", "for",
                                     "while", "do", "include", "using", "namespace", "std", "main", "def", "print",
                                     "in", "range", "and", "or", "not", "True", "False", "None", "const", "auto",
                                     "cout", "cin", "endl", "std", "include", "iostream", "self"]
        // Names only: what's inside quotes is text, not a name.
        let unquoted = code.replacingOccurrences(of: #""[^"\n]*"|'[^'\n]*'|//[^\n]*|/\*[\s\S]*?\*/|#include[^\n]*"#,
                                                 with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[\d+\]\]"#, with: " ", options: .regularExpression)
        let codeNames = Set(identifier.matches(in: unquoted, range: NSRange(location: 0, length: (unquoted as NSString).length))
            .map { (unquoted as NSString).substring(with: $0.range) }).subtracting(keywords).sorted()
        for match in identifier.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range)
            guard !keywords.contains(name) else { continue }
            // Same kind of name: a variable for a variable, a Type for a Type.
            for other in codeNames where other != name && other.count <= 20
                && other.first?.isUppercase == name.first?.isUppercase {
                add(ns.replacingCharacters(in: match.range, with: other))
            }
        }
        return out
    }

    // MARK: - Program output

    /// Wrong outputs a student might give: a number one off, the last line
    /// left out or doubled, the lines in the other order.
    public static func outputCandidates(_ expected: String) -> [String] {
        let lines = CodeAnswerGrading.normalizedOutput(expected)
        guard !lines.isEmpty else { return [] }
        var out: [String] = []
        func add(_ candidate: [String]) {
            guard !candidate.isEmpty, candidate != lines,
                  !out.contains(where: { CodeAnswerGrading.normalizedOutput($0) == candidate }) else { return }
            out.append(candidate.joined(separator: "\n"))
        }
        let numberPattern = try! NSRegularExpression(pattern: #"-?\d+"#)
        // The last number in the output, then the first, one off each way.
        let joined = lines.joined(separator: "\n") as NSString
        let matches = numberPattern.matches(in: joined as String, range: NSRange(location: 0, length: joined.length))
        for match in [matches.last, matches.first].compactMap({ $0 }) {
            guard let value = Int(joined.substring(with: match.range)) else { continue }
            for delta in [1, -1] {
                add(joined.replacingCharacters(in: match.range, with: String(value + delta)).components(separatedBy: "\n"))
            }
        }
        if lines.count > 1 {
            add(Array(lines.dropLast()))
            add(Array(lines.reversed()))
        }
        add(lines + [lines.last!])
        if lines.count == 1, matches.count > 1 {
            // Every number one higher: a loop that started a step late.
            var shifted = lines[0] as NSString
            for match in matches.reversed() {
                if let value = Int(shifted.substring(with: match.range)) {
                    shifted = shifted.replacingCharacters(in: match.range, with: String(value + 1)) as NSString
                }
            }
            add([shifted as String])
        }
        return out
    }

    // MARK: - Numbers and matrices

    /// Wrong values from typical slips: the sign, doubling or halving, one
    /// off, a factor of ten. Formatted the way the answer is.
    public static func numberCandidates(_ value: Double, unit: String?) -> [String] {
        let isWhole = abs(value - value.rounded()) < 1e-9
        var values: [Double] = [-value, value * 2, value / 2, value * 10, value / 10]
        if isWhole { values.insert(contentsOf: [value + 1, value - 1], at: 1) }
        var out: [String] = []
        var taken: [Double] = [value]
        for candidate in values where candidate.isFinite {
            guard !taken.contains(where: { ProblemAnswerGrading.isClose($0, to: candidate) || ProblemAnswerGrading.isClose(candidate, to: $0) })
            else { continue }
            taken.append(candidate)
            out.append(ProblemAnswerGrading.format(candidate) + (unit.map { " " + $0 } ?? ""))
        }
        return out
    }

    public static func matrixText(_ rows: [[Double]]) -> String {
        rows.map { "[ " + $0.map(ProblemAnswerGrading.format).joined(separator: "  ") + " ]" }.joined(separator: "\n")
    }

    /// Wrong matrices: transposed, rows swapped, one entry's sign flipped,
    /// every entry negated.
    public static func matrixCandidates(_ rows: [[Double]]) -> [String] {
        guard !rows.isEmpty, rows.allSatisfy({ $0.count == rows[0].count }) else { return [] }
        let correct = matrixText(rows)
        var out: [String] = []
        func add(_ candidate: [[Double]]) {
            let text = matrixText(candidate)
            guard text != correct, !out.contains(text) else { return }
            out.append(text)
        }
        let columns = rows[0].count
        add((0..<columns).map { c in rows.map { $0[c] } })
        if rows.count > 1 { var swapped = rows; swapped.swapAt(0, 1); add(swapped) }
        if let r = rows.indices.last, let c = rows[r].indices.last(where: { rows[r][$0] != 0 }) {
            var flipped = rows; flipped[r][c] = -flipped[r][c]; add(flipped)
        }
        if let c = rows[0].indices.first(where: { rows[0][$0] != 0 }) {
            var flipped = rows; flipped[0][c] = -flipped[0][c]; add(flipped)
        }
        add(rows.map { $0.map { -$0 } })
        add(rows.map { $0.map { $0 * 2 } })
        return out
    }

    // MARK: - The versions themselves

    /// Three wrong options, chosen at random from the candidates.
    private static func pickThree<R: RandomNumberGenerator>(_ candidates: [String], using rng: inout R) -> [String]? {
        guard candidates.count >= 3 else { return nil }
        // The first few are the most telling mistakes; keep them likelier.
        let head = Array(candidates.prefix(6)).shuffled(using: &rng)
        return Array(head.prefix(3))
    }

    /// `question` as multiple choice, or nil when it has no good version.
    public static func codeVersion<R: RandomNumberGenerator>(_ question: CodeQuestion, id: String = UUID().uuidString,
                                                             using rng: inout R) -> LearnEngine.RoundQuestion? {
        switch question.kind {
        case .codeBlanks:
            guard let blank = question.choiceBlank, let wrong = question.choices, wrong.count >= 3,
                  let blanks = question.blanks, blanks.indices.contains(blank - 1),
                  let answer = blanks[blank - 1].first else { return nil }
            var shown = question
            // The other blanks are filled in; only the one asked about stays open.
            shown.code = CodeQuestion.fill(question.code) { $0 == blank ? "[[\($0)]]" : (blanks[$0 - 1].first ?? "") }
            shown.prompt = question.expectedOutput.map { "Which code fills the blank so the program prints:\n" + $0 }
                ?? question.prompt.replacingOccurrences(of: "Fill in the missing piece of the answer.",
                                                        with: "Which code fills the blank?")
            let options = ([answer] + wrong.prefix(3)).shuffled(using: &rng)
            return LearnEngine.RoundQuestion(id: id, cardId: nil, prompt: shown.prompt, correctAnswer: answer,
                                             type: .multipleChoice, choices: options, code: shown)
        case .predictOutput:
            guard let expected = question.expectedOutput,
                  let wrong = pickThree(question.choices ?? outputCandidates(expected), using: &rng) else { return nil }
            let correct = CodeAnswerGrading.normalizedOutput(expected).joined(separator: "\n")
            return LearnEngine.RoundQuestion(id: id, cardId: nil, prompt: question.prompt, correctAnswer: correct,
                                             type: .multipleChoice, choices: ([correct] + wrong).shuffled(using: &rng),
                                             code: question)
        case .findBug, .completeFunction:
            return nil
        }
    }

    public static func problemVersion<R: RandomNumberGenerator>(_ problem: ProblemQuestion, id: String = UUID().uuidString,
                                                                using rng: inout R) -> LearnEngine.RoundQuestion? {
        let correct = problem.answerText
        let candidates: [String]
        switch problem.kind {
        case .multipleChoice:
            return problem.roundQuestion(id: id, using: &rng)
        case .number:
            guard let value = problem.number else { return nil }
            candidates = numberCandidates(value, unit: problem.unit)
        case .matrix:
            guard let rows = problem.matrix else { return nil }
            candidates = matrixCandidates(rows)
        }
        guard !correct.isEmpty, let wrong = pickThree(candidates, using: &rng) else { return nil }
        return LearnEngine.RoundQuestion(id: id, cardId: nil, prompt: problem.prompt, correctAnswer: correct,
                                         type: .multipleChoice, choices: ([correct] + wrong).shuffled(using: &rng),
                                         problem: problem)
    }
}
