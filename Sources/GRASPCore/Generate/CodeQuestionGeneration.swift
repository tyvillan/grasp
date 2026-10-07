import Foundation

/// A question as a model wrote it, before it has been run. Nothing here is
/// trusted: `CodeQuestionBuilder` runs the code and keeps only what works.
public struct GeneratedCodeQuestion: Sendable, Equatable {
    public var kind: CodeQuestionKind
    public var prompt: String
    public var code: String
    /// Accepted answers per blank (`[[n]]` in `code`).
    public var answers: [[String]]
    public var buggyLine: Int?
    public var fixedLine: String?
    public var explanation: String?

    public init(kind: CodeQuestionKind, prompt: String, code: String, answers: [[String]] = [],
                buggyLine: Int? = nil, fixedLine: String? = nil, explanation: String? = nil) {
        self.kind = kind; self.prompt = prompt; self.code = code; self.answers = answers
        self.buggyLine = buggyLine; self.fixedLine = fixedLine; self.explanation = explanation
    }
}

extension OllamaGenerator {
    static func codeQuestionsPrompt(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String],
        language: CodeLanguage, kinds: [CodeQuestionKind], count: Int
    ) -> String {
        let terms = cardTerms.prefix(20).joined(separator: "; ")
        let kindList = kinds.map(\.rawValue).joined(separator: ", ")
        let lang = language.label
        return """
        You write practice code questions for a student studying \(courseName), on the topic: \(deckName). \
        Use only the ideas in the notes below. Write exactly \(count) questions in \(lang), mixing these kinds: \(kindList).

        Every program must be complete and runnable on its own (with \(language == .cpp ? "#include lines and a main function" : "its print statements")), \
        print its result to the screen, never read input, never use files, the network or random numbers, and be \
        under 25 lines. Keep the code in the style of the notes.

        Kinds:
        - codeBlanks: a complete program with 1 to 3 parts replaced by [[1]], [[2]], [[3]]. ANSWERS gives what goes in each \
        blank, one per line as "1: answer". Add a second accepted way after " || " only when it is truly equivalent.
        - predictOutput: a complete program, no blanks. The student types what it prints. Leave ANSWERS empty.
        - findBug: a complete program with exactly one wrong line that still compiles but prints the wrong result, or \
        does not compile. BUGGY_LINE is that line's number counting from 1 in CODE; FIXED_LINE is that line corrected.
        - completeFunction: a complete program where the body of one function is replaced by [[1]]. ANSWERS is "1:" \
        followed by the missing body on the next lines. The program must print its result when the body is filled in.

        Write each question in exactly this layout, with no other text:
        ### QUESTION
        KIND: one of the kinds above
        PROMPT: one sentence telling the student what to do
        CODE:
        the program, as many lines as needed
        ANSWERS:
        1: answer
        BUGGY_LINE: number (findBug only)
        FIXED_LINE: corrected line (findBug only)
        EXPLANATION: one sentence on why the answer is right
        ### END

        Terms the student already has cards for: \(terms.isEmpty ? "(none)" : terms)

        Notes:
        \(noteContext)
        """
    }

    /// Reads the tagged layout, tolerating what models do to it: a code
    /// fence around the program, a missing `### END`, extra blank lines,
    /// "Answer:" for "ANSWERS:". A block that doesn't hold together is
    /// dropped rather than guessed at.
    static func parseCodeQuestions(_ raw: String) -> [GeneratedCodeQuestion] {
        var blocks: [[String]] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### QUESTION") || trimmed.uppercased().hasPrefix("### QUESTION") {
                blocks.append([])
            } else if trimmed.hasPrefix("### END") {
                continue
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks.compactMap(parseCodeQuestionBlock)
    }

    private static let sectionNames = ["KIND", "PROMPT", "CODE", "ANSWERS", "ANSWER", "BUGGY_LINE", "FIXED_LINE",
                                       "EXPLANATION", "OUTPUT"]

    private static func parseCodeQuestionBlock(_ lines: [String]) -> GeneratedCodeQuestion? {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let colon = trimmed.firstIndex(of: ":") {
                let name = trimmed[..<colon].uppercased().replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if sectionNames.contains(name) {
                    current = name == "ANSWER" ? "ANSWERS" : name
                    let rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    sections[current!, default: []] = rest.isEmpty ? [] : [rest]
                    continue
                }
            }
            if let current { sections[current, default: []].append(line) }
        }

        guard let kindText = sections["KIND"]?.first?.trimmingCharacters(in: .whitespaces),
              let kind = CodeQuestionKind(rawValue: kindText)
                ?? CodeQuestionKind.allCases.first(where: { $0.rawValue.lowercased() == kindText.lowercased() }),
              let prompt = sections["PROMPT"]?.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty
        else { return nil }

        let code = strippedFence(sections["CODE"] ?? [])
        guard !code.isEmpty else { return nil }

        var answers: [[String]] = []
        switch kind {
        case .codeBlanks:
            answers = blankAnswers(sections["ANSWERS"] ?? [])
        case .completeFunction:
            let body = strippedFence(Array((sections["ANSWERS"] ?? [])))
            let withoutLabel = body.replacingOccurrences(of: #"^\s*1\s*[:.)]\s*"#, with: "", options: .regularExpression)
            let cleaned = withoutLabel.trimmingCharacters(in: .newlines)
            guard !cleaned.isEmpty else { return nil }
            answers = [[cleaned]]
        case .predictOutput, .findBug:
            break
        }
        let buggy = sections["BUGGY_LINE"]?.first.flatMap { Int($0.filter(\.isNumber)) }
        let fixed = sections["FIXED_LINE"]?.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return GeneratedCodeQuestion(
            kind: kind, prompt: prompt, code: code, answers: answers, buggyLine: buggy,
            fixedLine: (fixed?.isEmpty ?? true) ? nil : fixed,
            explanation: sections["EXPLANATION"]?.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    /// "1: x" / "2: y || z" lines into per-blank accepted answers, in order.
    private static func blankAnswers(_ lines: [String]) -> [[String]] {
        var byNumber: [Int: [String]] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = trimmed.range(of: #"^(\d{1,2})\s*[:.)]\s*"#, options: .regularExpression),
                  let number = Int(trimmed[trimmed.startIndex..<match.upperBound].filter(\.isNumber))
            else { continue }
            let rest = String(trimmed[match.upperBound...])
            let options = rest.components(separatedBy: "||")
                .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "`"))) }
                .filter { !$0.isEmpty }
            if !options.isEmpty { byNumber[number] = options }
        }
        guard !byNumber.isEmpty else { return [] }
        return (1...(byNumber.keys.max() ?? 0)).map { byNumber[$0] ?? [] }
    }

    /// The lines as one string, without a code fence round them or blank
    /// lines at the ends. Indentation inside is kept.
    private static func strippedFence(_ lines: [String]) -> String {
        var lines = lines
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    public func generateCodeQuestions(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String],
        language: CodeLanguage, kinds: [CodeQuestionKind], count: Int
    ) async -> [GeneratedCodeQuestion] {
        guard !noteContext.isEmpty, count > 0, !kinds.isEmpty else { return [] }
        let prompt = Self.codeQuestionsPrompt(
            deckName: deckName, courseName: courseName, noteContext: noteContext, cardTerms: cardTerms,
            language: language, kinds: kinds, count: count
        )
        // Room for the programs and their answers; plain text, not JSON,
        // because code with line breaks and quotes is what JSON mode breaks.
        for attempt in 0..<2 {
            if Task.isCancelled { return [] }
            if let content = try? await chatText(prompt: prompt, maxTokens: 500 + 450 * count) {
                let parsed = Self.parseCodeQuestions(content)
                if !parsed.isEmpty { return parsed }
            }
            if attempt == 0 { AIProgress.current?.setNote("Trying \(deckName) once more") }
        }
        AIProgress.current?.setNote(nil)
        return []
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
