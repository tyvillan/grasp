import Foundation

/// A problem as a model wrote it, before it has been checked.
public struct GeneratedProblem: Sendable, Equatable {
    public var kind: ProblemKind
    public var prompt: String
    public var choices: [String]
    /// Multiple choice: which option the model says is right (0-based).
    public var correct: Int?
    /// Number or matrix: the answer as the model wrote it.
    public var claimedAnswer: String
    public var unit: String?
    /// A short Python program that prints the answer, for the checker to run.
    public var script: String?
    public var explanation: String?

    public init(kind: ProblemKind, prompt: String, choices: [String] = [], correct: Int? = nil,
                claimedAnswer: String = "", unit: String? = nil, script: String? = nil, explanation: String? = nil) {
        self.kind = kind; self.prompt = prompt; self.choices = choices; self.correct = correct
        self.claimedAnswer = claimedAnswer; self.unit = unit; self.script = script; self.explanation = explanation
    }
}

extension OllamaGenerator {
    static func problemsPrompt(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String],
        subject: ProblemSubject, kinds: [ProblemKind], count: Int
    ) -> String {
        let terms = cardTerms.prefix(20).joined(separator: "; ")
        let kindList = kinds.map(\.rawValue).joined(separator: ", ")
        let style: String
        switch subject {
        case .math:
            style = """
            Write calculation problems of the kind a linear algebra or algebra exam asks, with small whole-number \
            entries so the work is doable by hand: determinants, inverses, matrix products, row reduction, solving \
            a system, rank, a dot product, eigenvalues of a 2x2 matrix with whole-number eigenvalues. Write a matrix as \
            bracketed rows on their own lines, for example:
            A = [ 1  2 ]
                [ 3  4 ]
            """
        case .economics:
            style = """
            Write calculation and scenario problems of the kind a microeconomics exam asks, with concrete numbers: \
            equilibrium price and quantity from linear demand and supply, price elasticity of demand, consumer or \
            producer surplus, opportunity cost, comparative advantage, the effect of a tax, price, or shift on a market. \
            Every number a problem needs must be in its statement.
            """
        default:
            style = """
            Write scenario questions that make the student apply an idea from the notes to a new case, not repeat a \
            definition. Every fact a question needs must be in its statement or in the notes.
            """
        }
        return """
        You write practice problems for a student studying \(courseName), on the topic: \(deckName). Use only the \
        ideas in the notes below. Write exactly \(count) problems, mixing these kinds: \(kindList).

        \(style)

        Kinds:
        - multipleChoice: four options A) to D), exactly one correct. ANSWER is the correct letter.
        - number: the answer is one number. ANSWER is that number only (a fraction like 3/4 is fine); put its unit, \
        if any, in UNIT. SCRIPT is a short Python 3 program, standard library only (fractions, math), with no input, \
        that works the answer out from the problem's own numbers and prints just the number.
        - matrix: the answer is a matrix or vector. ANSWER is its rows on separate lines, entries separated by \
        spaces. SCRIPT is a short Python 3 program, standard library only, with no input, that works it out and prints \
        the rows the same way. Use fractions.Fraction for exact arithmetic.

        Write each problem in exactly this layout, with no other text:
        ### PROBLEM
        KIND: one of the kinds above
        PROMPT: the full problem, over as many lines as needed
        CHOICES:
        A) first option
        B) second option
        (CHOICES only for multipleChoice)
        ANSWER: the answer
        UNIT: unit, or leave out
        SCRIPT:
        python lines (number and matrix only)
        EXPLANATION: one or two sentences showing how to get the answer
        ### END

        Terms the student already has cards for: \(terms.isEmpty ? "(none)" : terms)

        Notes:
        \(noteContext)
        """
    }

    private static let problemSections = ["KIND", "PROMPT", "CHOICES", "ANSWER", "UNIT", "SCRIPT", "EXPLANATION"]

    static func parseProblems(_ raw: String) -> [GeneratedProblem] {
        var blocks: [[String]] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("### PROBLEM") {
                blocks.append([])
            } else if trimmed.hasPrefix("### END") {
                continue
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks.compactMap(parseProblemBlock)
    }

    private static func parseProblemBlock(_ lines: [String]) -> GeneratedProblem? {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            if let colon = stripped.firstIndex(of: ":") {
                let name = String(stripped[..<colon])
                if problemSections.contains(name) {
                    current = name
                    let rest = String(stripped[stripped.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    sections[name] = rest.isEmpty ? [] : [rest]
                    continue
                }
            }
            if let current { sections[current, default: []].append(line) }
        }
        func text(_ name: String) -> String {
            var lines = sections[name] ?? []
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
        guard let kindText = sections["KIND"]?.first?.trimmingCharacters(in: .whitespaces),
              let kind = ProblemKind.allCases.first(where: { $0.rawValue.lowercased() == kindText.lowercased() })
        else { return nil }
        let prompt = text("PROMPT")
        guard !prompt.isEmpty else { return nil }

        var choices: [String] = []
        var correct: Int?
        if kind == .multipleChoice {
            for line in sections["CHOICES"] ?? [] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let match = trimmed.range(of: #"^\(?([A-Da-d])[\)\.:]\s*"#, options: .regularExpression) {
                    choices.append(String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces))
                }
            }
            guard choices.count == 4, Set(choices).count == 4 else { return nil }
            if let letter = text("ANSWER").uppercased().first(where: { "ABCD".contains($0) }) {
                correct = "ABCD".distance(from: "ABCD".startIndex, to: "ABCD".firstIndex(of: letter)!)
            }
            guard correct != nil else { return nil }
        }
        let answer = text("ANSWER")
        if kind != .multipleChoice, answer.isEmpty { return nil }
        // A language name left on a line of its own where the fence was.
        var scriptLines = text("SCRIPT").components(separatedBy: "\n")
        if let first = scriptLines.first?.trimmingCharacters(in: .whitespaces).lowercased(),
           ["python", "python3", "py"].contains(first) {
            scriptLines.removeFirst()
        }
        let script = scriptLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = text("UNIT").trimmingCharacters(in: .whitespacesAndNewlines)
        return GeneratedProblem(
            kind: kind, prompt: prompt, choices: choices, correct: correct, claimedAnswer: answer,
            unit: unit.isEmpty || unit.lowercased() == "none" ? nil : unit,
            script: script.isEmpty ? nil : script,
            explanation: text("EXPLANATION").replacingOccurrences(of: "\n", with: " ").nilIfEmptyProblem
        )
    }

    public func generateProblems(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String],
        subject: ProblemSubject, kinds: [ProblemKind], count: Int
    ) async -> [GeneratedProblem] {
        guard !noteContext.isEmpty, count > 0, !kinds.isEmpty else { return [] }
        let prompt = Self.problemsPrompt(deckName: deckName, courseName: courseName, noteContext: noteContext,
                                         cardTerms: cardTerms, subject: subject, kinds: kinds, count: count)
        for attempt in 0..<2 {
            if Task.isCancelled { return [] }
            if let content = try? await chatText(prompt: prompt, maxTokens: 500 + 400 * count) {
                let parsed = Self.parseProblems(content)
                if !parsed.isEmpty { return parsed }
            }
            if attempt == 0 { AIProgress.current?.setNote("Trying \(deckName) once more") }
        }
        AIProgress.current?.setNote(nil)
        return []
    }

    /// Answers a multiple-choice problem cold, without being told which
    /// option the writer chose: a second opinion on the answer key.
    public func solveMultipleChoice(prompt: String, choices: [String]) async -> Int? {
        guard choices.count == 4 else { return nil }
        let options = zip("ABCD", choices).map { "\($0)) \($1)" }.joined(separator: "\n")
        let question = """
        Answer this multiple-choice question. Work it out, then end your reply with a line that reads exactly \
        "FINAL: X" where X is A, B, C or D.

        \(prompt)

        \(options)
        """
        guard let reply = try? await chatText(prompt: question, maxTokens: 1600) else { return nil }
        // The last "FINAL: X" (any markdown round it), else a lone letter
        // ending the reply.
        let patterns = [#"FINAL\s*:?\s*[\*\(\[]*\s*([A-D])\b"#, #"(?:answer|option|choice)\s*(?:is|:)?\s*[\*\(\[]*([A-D])\b"#]
        for pattern in patterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let ns = reply as NSString
            if let match = regex?.matches(in: reply, range: NSRange(location: 0, length: ns.length)).last,
               let letter = ns.substring(with: match.range(at: 1)).uppercased().first,
               let index = "ABCD".firstIndex(of: letter) {
                return "ABCD".distance(from: "ABCD".startIndex, to: index)
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmptyProblem: String? { isEmpty ? nil : self }
}
