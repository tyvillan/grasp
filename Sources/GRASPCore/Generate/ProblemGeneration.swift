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
    /// Photo import: whether the page itself printed the answer (true), or the
    /// model worked it out (false). Nil for problems written from notes.
    public var answerGiven: Bool?

    public init(kind: ProblemKind, prompt: String, choices: [String] = [], correct: Int? = nil,
                claimedAnswer: String = "", unit: String? = nil, script: String? = nil, explanation: String? = nil,
                answerGiven: Bool? = nil) {
        self.kind = kind; self.prompt = prompt; self.choices = choices; self.correct = correct
        self.claimedAnswer = claimedAnswer; self.unit = unit; self.script = script; self.explanation = explanation
        self.answerGiven = answerGiven
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
        EXPLANATION: \(QuestionExplanation.styleRules)
        ### END

        Terms the student already has cards for: \(terms.isEmpty ? "(none)" : terms)

        Notes:
        \(noteContext)
        """
    }

    private static let problemSections = ["KIND", "PROMPT", "CHOICES", "ANSWER", "UNIT", "SCRIPT", "EXPLANATION", "GIVEN"]

    static func parseProblems(_ raw: String, choiceCounts: ClosedRange<Int> = 4...4) -> [GeneratedProblem] {
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
        return blocks.compactMap { parseProblemBlock($0, choiceCounts: choiceCounts) }
    }

    private static func parseProblemBlock(_ lines: [String], choiceCounts: ClosedRange<Int> = 4...4) -> GeneratedProblem? {
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
                if let match = trimmed.range(of: #"^\(?([A-Fa-f])[\)\.:]\s*"#, options: .regularExpression) {
                    choices.append(String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces))
                }
            }
            guard choiceCounts.contains(choices.count), Set(choices).count == choices.count else { return nil }
            let letters = String("ABCDEF".prefix(choices.count))
            if let letter = text("ANSWER").uppercased().first(where: { letters.contains($0) }) {
                correct = letters.distance(from: letters.startIndex, to: letters.firstIndex(of: letter)!)
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
            explanation: QuestionExplanation.clean(text("EXPLANATION").replacingOccurrences(of: "\n", with: " ")),
            answerGiven: sections["GIVEN"].map { $0.joined(separator: " ").lowercased().contains("yes") }
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

    /// Photo import: one question as the page printed it (text read by the
    /// device, so it may carry odd spacing or a misread character), written out
    /// clean. Nil when the text is not a question or no usable question came back.
    public func structurePhotoQuestion(text: String, courseName: String) async -> GeneratedProblem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prompt = Self.photoQuestionPrompt(text: String(trimmed.prefix(2500)), courseName: courseName)
        for _ in 0..<2 {
            if Task.isCancelled { return nil }
            if let content = try? await chatText(prompt: prompt, maxTokens: 900),
               let problem = Self.parseProblems(content, choiceCounts: 2...6).first { return problem }
        }
        return nil
    }

    static func photoQuestionPrompt(text: String, courseName: String) -> String {
        """
        Below is the text read by a scanner from a photo of one question on a \(courseName) exam or worksheet. It may \
        have odd spacing or a misread character. Write it out as one clean question. Keep the original wording and \
        every number; fix only obvious scanning mistakes. Do not invent a different question.

        Kinds: multipleChoice (the options as printed, 2 to 6, A) to F)), written (the answer is a word, a number or a \
        short phrase), trueFalse (a statement; ANSWER is True or False).
        If the question has no printed options, write it as written or trueFalse. If the page prints the answer, copy it \
        and set GIVEN: yes. If it does not, work out the answer yourself and set GIVEN: no.

        Reply in exactly this layout, with no other text:
        ### PROBLEM
        KIND: one of the kinds above
        PROMPT: the full question
        CHOICES:
        A) first option
        B) second option
        (CHOICES only for multipleChoice)
        ANSWER: the letter for multipleChoice, otherwise the answer
        GIVEN: yes or no
        EXPLANATION: \(QuestionExplanation.styleRules)
        ### END

        Text from the photo:
        \(text)
        """
    }

    /// What a study-guide skill means, in two or three plain sentences.
    public func explainSkill(_ skill: String, subject: String, context: String) async -> String? {
        let prompt = """
        A student is checking whether they are ready for an exam in "\(subject)". The study guide says they should be able to:
        "\(skill)"

        Explain in two short, plain sentences what that means: define the idea in basic terms, then say what \
        they would be asked to do on the exam. No headings, no bullet points, no preamble.\(context.isEmpty ? "" : "\n\nMaterial from the guide, for context:\n\(context.prefix(1500))")
        """
        guard let reply = try? await chatText(prompt: prompt, maxTokens: 220) else { return nil }
        let text = PlainMath.clean(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        return text.isEmpty || text.count > 900 ? nil : text
    }

    /// Why this answer was wrong, written for this answer rather than for
    /// the question in general. Asked again once if the first reply breaks
    /// the style rules; nil when neither does.
    public func explainWrongAnswer(prompt: String, correctAnswer: String, givenAnswer: String, context: String) async -> String? {
        var note = ""
        for attempt in 0..<2 {
            let text = Self.explainWrongAnswerPrompt(prompt: prompt, correctAnswer: correctAnswer,
                                                     givenAnswer: givenAnswer, context: context) + note
            if let reply = try? await chatText(prompt: text, maxTokens: 400),
               let cleaned = QuestionExplanation.cleanLong(reply) {
                return cleaned
            }
            if attempt == 0 {
                note = "\n\nYour last reply broke the rules. Write to \"you\", never \"the student\", and never show "
                    + "an option number or a format like \"1: House\"."
            }
        }
        return nil
    }

    /// Judges a typed answer by meaning. The prompt carries the question,
    /// the card's answer and the student's answer, and nothing else.
    public func judgeAnswer(question: String, expected: String, given: String) async -> AIAnswerVerdict? {
        let prompt = Self.judgeAnswerPrompt(question: question, expected: expected, given: given)
        guard let reply = try? await chat(prompt: prompt) else { return nil }
        return Self.parseJudgement(reply)
    }

    static func judgeAnswerPrompt(question: String, expected: String, given: String) -> String {
        """
        You grade a student's typed answer to a flashcard.

        Question: \(question.prefix(600))
        Expected answer: \(expected.prefix(600))
        Student's answer: \(given.prefix(600))

        Be lenient about wording, synonyms, word order and grammar. Be strict about facts, numbers, negation \
        and opposites. Accept an answer that contains the key idea even if it is shorter or longer than the \
        expected answer.

        Reply with JSON only: {"verdict": "correct" | "closeEnough" | "notQuite", "reason": "one short sentence"}. \
        Use "correct" for the same words, "closeEnough" for the same idea in different words, "notQuite" when \
        a fact is wrong or missing.
        """
    }

    static func parseJudgement(_ reply: String) -> AIAnswerVerdict? {
        struct DTO: Decodable { let verdict: String; let reason: String? }
        guard let data = salvageJSON(reply).data(using: .utf8),
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else { return nil }
        let reason = dto.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = (reason?.isEmpty ?? true) || (reason?.count ?? 0) > 200 ? nil : reason
        switch dto.verdict.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "") {
        case "correct": return AIAnswerVerdict(outcome: .correct, reason: short)
        case "closeenough", "close": return AIAnswerVerdict(outcome: .closeEnough, reason: short)
        case "notquite", "incorrect", "wrong": return AIAnswerVerdict(outcome: .notQuite, reason: short)
        default: return nil
        }
    }

    static func explainWrongAnswerPrompt(prompt: String, correctAnswer: String, givenAnswer: String, context: String) -> String {
        """
        Someone answered a question wrong. Explain it to them.

        Question:
        \(prompt.prefix(1500))

        Correct answer:
        \(correctAnswer.prefix(600))

        What they chose or typed:
        \(givenAnswer.isEmpty ? "(nothing)" : String(givenAnswer.prefix(600)))
        \(context.isEmpty ? "" : "\nCode or notes the question refers to:\n\(context.prefix(1200))\n")
        \(QuestionExplanation.styleRules)
        Reply with the explanation only.
        """
    }

    /// Explains a handful of skills in one request. Anything the reply
    /// doesn't cover is left for the caller to ask about one at a time.
    public func explainSkills(_ skills: [String], subject: String, context: String) async -> [String: String] {
        guard !skills.isEmpty else { return [:] }
        let list = skills.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        let prompt = """
        A student is checking whether they are ready for an exam in "\(subject)". The study guide says they should be able to do each of these:
        \(list)

        For each one, write two short, plain sentences: define the idea in basic terms, then say what they would be asked \
        to do on the exam. Reply with JSON only: {"meanings": ["...", "..."]} with exactly \(skills.count) strings, in the \
        same order as the list.\(context.isEmpty ? "" : "\n\nMaterial from the guide, for context:\n\(context.prefix(1200))")
        """
        guard let reply = try? await chat(prompt: prompt, maxTokens: 260 * skills.count),
              let data = Self.salvageJSON(reply).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meanings = object["meanings"] as? [Any], meanings.count == skills.count
        else { return [:] }
        var result: [String: String] = [:]
        for (skill, meaning) in zip(skills, meanings) {
            guard let text = (meaning as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= 900 else { continue }
            result[skill] = PlainMath.clean(text)
        }
        return result
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
