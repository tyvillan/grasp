import Foundation

/// Test questions made from a study guide's own worked examples -- the
/// sample exam questions and their answer key -- so a guide's test asks
/// what the exam will ask:
/// - an example whose answer is code becomes fill-in-the-blank: the answer
///   key's code with one important piece (a condition, a loop header, a
///   return) taken out;
/// - "what is the output" examples become predict-the-output;
/// - the rest are asked as written, with the answer key as the answer.
public enum GuideExamples {
    /// Curly quotes from a word processor, so typed answers can match.
    static func straightQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
    }

    static func looksLikeCode(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if t.hasPrefix("#include") || t.hasPrefix("//") || t == "{" || t == "}" || t.hasPrefix("}") { return true }
        let starts = ["int ", "double ", "char ", "bool ", "string ", "void ", "for", "while", "if", "else", "do",
                      "return", "cout", "cin", "class ", "struct ", "public:", "private:", "using "]
        return t.hasSuffix(";") || t.hasSuffix("{") || starts.contains { t.hasPrefix($0) } && (t.contains("(") || t.contains(";"))
    }

    /// The words of a question, and the code it shows, if any.
    public static func split(_ text: String) -> (prose: String, code: String?) {
        let lines = straightQuotes(text).components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: looksLikeCode) else { return (text, nil) }
        let prose = lines[..<first].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let code = lines[first...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (prose, code)
    }

    /// Whether an answer is code rather than words.
    static func isCode(_ answer: String) -> Bool {
        let lines = answer.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return false }
        return Double(lines.filter(looksLikeCode).count) / Double(lines.count) >= 0.5
    }

    /// The answer key's code with one piece taken out as `[[1]]`, and that
    /// piece. Prefers what the question is really about: a condition, then
    /// a loop header's test, then what is returned, then what is assigned.
    public static func blanking(_ code: String) -> (code: String, answer: String)? {
        let patterns = [
            #"\b(?:if|while)\s*\((.+)\)\s*\{?\s*;?\s*$"#,      // if (...) / while (...)
            #"\bfor\s*\([^;]*;\s*([^;]+?)\s*;"#,                // for (...; test; ...)
            #"\breturn\s+(.+?)\s*;"#,                           // return ...;
            #"\bfor\s*\(\s*([^;]+?)\s*;"#,                      // for (start; ...)
            #"[^=!<>]=\s*([^=;][^;]*?)\s*;"#,                   // x = ...;
        ]
        var lines = code.components(separatedBy: "\n")
        // An answer key often ends with "sample call, NOT part of the
        // answer": the blank belongs in the answer itself.
        if let cut = lines.firstIndex(where: {
            let lower = $0.lowercased()
            return lower.contains("//") && (lower.contains("not part of the answer") || lower.contains("sample function call"))
        }), cut > 0 {
            lines = Array(lines[..<cut])
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        }
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            for (index, line) in lines.enumerated() {
                let ns = line as NSString
                guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                let answer = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                // A list of declarations ("15, num2 = 20, ...") isn't one piece.
                guard answer.count >= 2, answer.count <= 60, !(answer.contains(",") && !answer.contains("(")) else { continue }
                lines[index] = ns.replacingCharacters(in: match.range(at: 1), with: "[[1]]")
                return (lines.joined(separator: "\n"), answer)
            }
        }
        return nil
    }

    public enum Item: Sendable {
        case code(CodeQuestion)
        /// A question answered in words, graded against the answer key.
        case recall(prompt: String, answer: String)
    }

    /// Every worked example with an answer, as a test item.
    public static func items(from page: StudyGuideActions.ExamPage) -> [Item] {
        var items: [Item] = []
        for example in page.parts.flatMap(\.examples).map(\.example) {
            guard let rawAnswer = example.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !rawAnswer.isEmpty
            else { continue }
            let answer = straightQuotes(rawAnswer)
            let (prose, shownCode) = split(example.question)
            let asksOutput = prose.lowercased().contains("output")
            if asksOutput, let shownCode {
                let output = answer.replacingOccurrences(of: #"^\s*output\s*:\s*"#, with: "",
                                                         options: [.regularExpression, .caseInsensitive])
                items.append(.code(CodeQuestion(kind: .predictOutput, language: .cpp, prompt: prose, code: shownCode,
                                                expectedOutput: output)))
            } else if isCode(answer), let (blanked, missing) = blanking(answer) {
                // The whole question, header and postcondition included:
                // they say what the missing piece has to do.
                var question = CodeQuestion(kind: .codeBlanks, language: .cpp,
                                            prompt: straightQuotes(example.question).trimmingCharacters(in: .whitespacesAndNewlines)
                                                + "\n\nFill in the missing piece of the answer.",
                                            code: blanked, blanks: [[missing]])
                let wrong = ChoiceVersions.blankCandidates(answer: missing, accepted: [missing], code: blanked,
                                                           otherAnswers: [])
                if wrong.count >= 3 {
                    question.choiceBlank = 1
                    question.choices = Array(wrong.prefix(3))
                }
                items.append(.code(question))
            } else if !isCode(answer), answer.count <= 200 {
                items.append(.recall(prompt: straightQuotes(example.question), answer: answer))
            }
        }
        return items
    }

    /// Up to `count` items as test questions: typed or multiple choice per
    /// what the test allows (a mix when both are).
    public static func round<R: RandomNumberGenerator>(_ items: [Item], count: Int, allowWritten: Bool,
                                                       allowMultipleChoice: Bool, using rng: inout R) -> [LearnEngine.RoundQuestion] {
        var result: [LearnEngine.RoundQuestion] = []
        for item in items.shuffled(using: &rng) {
            guard result.count < count else { break }
            switch item {
            case .code(let question):
                let choice = allowMultipleChoice ? ChoiceVersions.codeVersion(question, using: &rng) : nil
                let typed = allowWritten ? question.roundQuestion() : nil
                if let typed, let choice { result.append(Bool.random(using: &rng) ? typed : choice) }
                else if let question = typed ?? choice { result.append(question) }
            case .recall(let prompt, let answer):
                guard allowWritten else { continue }
                result.append(LearnEngine.RoundQuestion(cardId: nil, prompt: prompt, correctAnswer: answer, type: .written))
            }
        }
        return result
    }
}
