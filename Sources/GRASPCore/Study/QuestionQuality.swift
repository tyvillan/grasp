import Foundation
import GRDB
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// What makes an AI-written question worth asking, and what to do with one
// that isn't: the explanation it carries, the checks a fill-in-the-blank
// draft must pass, and the key used to remember a question the student
// flagged. Nothing here touches cards, scheduling or sync of existing data.

// MARK: - Explanations

public enum QuestionExplanation {
    /// The style every prompt that asks for an explanation shares.
    public static let styleRules = """
        Write to the reader as "you". Never say "the student" or "the user". \
        Never write an internal format such as "1: House" or an option number: refer to an option by its text. \
        Use 2 to 4 short sentences. First say why the correct answer is right (for code, trace it: what each name \
        refers to, what it returns or prints). Second say what specifically goes wrong with a wrong choice, naming \
        the exact error or behaviour (for example a TypeError because House.__init__ takes no argument). You may \
        add one last sentence with the idea to remember. Put code in backticks. Do not restate the question, \
        praise, apologise or add headings. Only claim what follows from the code and the correct answer given: \
        if you are not sure why a choice is wrong, say what is true (what the code needs) instead of inventing a reason.
        """

    /// The line a question-writing prompt uses for its EXPLANATION field.
    public static let promptRule = "EXPLANATION: " + styleRules

    /// Why a piece of explanation text can't be shown, or nil when it can.
    public static func problem(in text: String?) -> String? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "it was empty"
        }
        let lower = raw.lowercased()
        for phrase in ["the student", "student's", "the user", "user's answer"] where lower.contains(phrase) {
            return "it talks about \"\(phrase)\" instead of \"you\""
        }
        if raw.range(of: #"(^|\s)\d{1,2}:\s"#, options: .regularExpression) != nil {
            return "it shows an internal answer format like \"1: House\""
        }
        let count = sentences(of: prose(raw)).count
        if count < 1 { return "it had no sentences" }
        if count > 5 { return "it ran past five sentences" }
        return nil
    }

    /// A longer, personal explanation (the "Explain this" reply): kept as
    /// written so a small code snippet survives, trimmed and bounded. Nil
    /// when it breaks the style rules, so the caller can ask again or say nothing.
    public static func cleanLong(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let openers = ["sure", "of course", "certainly", "great question", "no problem"]
        if let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first,
           first.count < 40, openers.contains(where: { first.lowercased().hasPrefix($0) }) {
            text = text.drop(while: { $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }
        if text.count > 1200 { text = String(text.prefix(1200)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return problem(in: text) == nil ? text : nil
    }

    /// The explanation that comes with a question: one to five sentences,
    /// trimmed, praise dropped. Nil when nothing usable is left or it breaks
    /// the style rules, so the question simply has no explanation.
    public static func clean(_ text: String?) -> String? {
        guard let collapsed = text?.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines), !collapsed.isEmpty else { return nil }
        let praise = ["great", "good job", "well done", "nice", "excellent", "awesome", "congratulations"]
        let kept = sentences(of: collapsed).filter { sentence in
            let lower = sentence.lowercased()
            return !(sentence.count < 40 && praise.contains { lower.hasPrefix($0) })
        }
        guard !kept.isEmpty else { return nil }
        var result = kept.joined(separator: " ")
        if result.count > 600 {
            result = String(result.prefix(600)).trimmingCharacters(in: .whitespaces)
            if let cut = result.lastIndex(where: { ".!?".contains($0) }) { result = String(result[...cut]) }
        }
        return problem(in: result) == nil ? result : nil
    }

    /// Sentences, keeping a "." inside a number or a name like self.x.
    static func sentences(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        var inCode = false
        for (index, char) in chars.enumerated() {
            current.append(char)
            if char == "`" { inCode.toggle() }
            guard !inCode, ".!?".contains(char) else { continue }
            let next = index + 1 < chars.count ? chars[index + 1] : " "
            if next == " " || next == "\n" {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { out.append(sentence) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// The text without fenced code blocks, which aren't sentences.
    private static func prose(_ text: String) -> String {
        text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
    }

    // MARK: Inline code

    public struct Segment: Equatable, Sendable {
        public var text: String
        public var isCode: Bool
        public init(_ text: String, isCode: Bool) { self.text = text; self.isCode = isCode }
    }

    /// The text split at its backticks, which are removed: plain stretches
    /// and code spans. An unmatched backtick is dropped.
    public static func segments(in text: String) -> [Segment] {
        var out: [Segment] = []
        var current = ""
        var inCode = false
        func flush() {
            if !current.isEmpty { out.append(Segment(current, isCode: inCode)) }
            current = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "`" {
                // A fence of three is a code block; skip the language word.
                var fence = 1
                var look = text.index(after: index)
                while look < text.endIndex, text[look] == "`" { fence += 1; look = text.index(after: look) }
                flush()
                inCode.toggle()
                index = look
                if fence >= 3, inCode {
                    // "```python\n": drop the language tag line.
                    if let newline = text[index...].firstIndex(of: "\n"),
                       text[index..<newline].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" }) {
                        index = text.index(after: newline)
                    }
                }
                continue
            }
            current.append(char)
            index = text.index(after: index)
        }
        if inCode {
            // Unbalanced: what followed the lone backtick reads as plain text.
            if !current.isEmpty { out.append(Segment(current, isCode: false)) }
        } else {
            flush()
        }
        return out.map { Segment($0.isCode ? $0.text.trimmingCharacters(in: .newlines) : $0.text, isCode: $0.isCode) }
    }
}

// MARK: - Fill-in-the-blank validation

public enum CodeQuestionValidator {
    /// Why a fill-in-the-blank draft can't be asked, or nil when it can.
    /// Static: nothing is run. `answers` are the accepted answers per blank,
    /// the first being the one shown.
    public static func problem(code: String, answers: [[String]], language: CodeLanguage) -> String? {
        let ns = code as NSString
        let matches = CodeQuestion.blankPattern.matches(in: code, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return "there were no blanks" }
        let commentMask = commentCharacters(in: code, language: language)

        // (c) Every blank has an answer a student could type.
        for number in matches.compactMap({ Int(ns.substring(with: $0.range(at: 1))) }) {
            guard number >= 1, number <= answers.count, let first = answers[number - 1].first,
                  usableAnswer(first) else {
                return "blank \(number) had no usable answer"
            }
        }

        // (b) A blank has to stand where code goes: not inside a comment,
        // where whatever is typed changes nothing.
        for match in matches {
            let start = code.utf16.index(code.startIndex, offsetBy: match.range.location)
            let offset = code.distance(from: code.startIndex, to: start)
            if offset < commentMask.count, commentMask[offset] {
                let number = ns.substring(with: match.range(at: 1))
                return "blank \(number) sits inside a comment, so it covers nothing the program needs"
            }
        }

        // (a) The answer must not be sitting in the code already.
        let outside = CodeQuestion.fill(code) { _ in "" }
        let visible = CodeAnswerGrading.normalizedCode(outside)
        let commentText = CodeAnswerGrading.normalizedCode(
            String(zip(code, commentMask).filter { $0.1 }.map(\.0)).replacingOccurrences(of: #"\[\[\d{1,2}\]\]"#, with: "", options: .regularExpression))
        for (index, options) in answers.enumerated() {
            guard let first = options.first else { continue }
            let answer = CodeAnswerGrading.normalizedCode(first)
            if answer.count >= 3, commentText.contains(answer) {
                return "the answer to blank \(index + 1) is written in a comment"
            }
            if answer.count >= 8, visible.contains(answer) {
                return "the answer to blank \(index + 1) is already visible in the code"
            }
        }
        return nil
    }

    /// The same checks for a saved question, for filtering a bank that
    /// predates them. Questions of other kinds always pass.
    public static func problem(in question: CodeQuestion) -> String? {
        switch question.kind {
        case .codeBlanks:
            return problem(code: question.code, answers: question.blanks ?? [], language: question.language)
        case .completeFunction:
            return problem(code: question.code, answers: question.blanks ?? [], language: question.language)
        case .predictOutput, .findBug:
            return nil
        }
    }

    static func usableAnswer(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let placeholders: Set<String> = ["...", "…", "???", "?", "answer", "blank", "todo", "tbd", "n/a", "none", "your code here"]
        if placeholders.contains(trimmed.lowercased()) { return false }
        return trimmed.contains { $0.isLetter || $0.isNumber || "+-*/%<>=!&|^~()[]{}".contains($0) }
    }

    /// One flag per character of `code`: true when it is part of a comment.
    /// Strings are respected, so a "#" inside quotes isn't a comment.
    static func commentCharacters(in code: String, language: CodeLanguage) -> [Bool] {
        let chars = Array(code)
        var mask = [Bool](repeating: false, count: chars.count)
        var index = 0
        var quote: Character?
        var inBlock = false
        while index < chars.count {
            let char = chars[index]
            if inBlock {
                mask[index] = true
                if char == "*", index + 1 < chars.count, chars[index + 1] == "/" {
                    mask[index + 1] = true
                    index += 2
                    inBlock = false
                    continue
                }
                index += 1
                continue
            }
            if let open = quote {
                if char == "\\" { index += 2; continue }
                if char == open || char == "\n" { quote = nil }
                index += 1
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                index += 1
                continue
            }
            let startsLineComment = language == .python ? char == "#"
                : (char == "/" && index + 1 < chars.count && chars[index + 1] == "/")
            if startsLineComment {
                while index < chars.count, chars[index] != "\n" { mask[index] = true; index += 1 }
                continue
            }
            if language == .cpp, char == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                inBlock = true
                mask[index] = true
                index += 1
                continue
            }
            index += 1
        }
        return mask
    }
}

// MARK: - Flagging

/// A flagged question is remembered by a hash of what it asks, never by
/// its text, so the same question isn't asked again.
public enum QuestionFlags {
    public static func key(prompt: String, code: String? = nil) -> String {
        func squash(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let material = squash(prompt) + "\u{1F}" + squash(code ?? "")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Retires the saved questions that match, the same soft delete the
    /// question list uses. Returns how many were retired.
    @discardableResult
    public static func retireSaved(key: String, now: Date = Date(), db: Database) throws -> Int {
        let rows = try TestQuestion.filter(Column("deletedAt") == nil).fetchAll(db)
        var count = 0
        for var row in rows {
            let rowKey: String
            if let question = row.question { rowKey = Self.key(prompt: question.prompt, code: question.code) }
            else if let problem = row.problem { rowKey = Self.key(prompt: problem.prompt) }
            else { continue }
            if rowKey == key {
                row.deletedAt = now
                try row.save(db)
                count += 1
            }
        }
        return count
    }
}

// MARK: - The explanation of a plain AI question

/// What a one-line AI question keeps in `TestItem.payloadJSON` (code and
/// problem questions keep a whole `CodeQuestion` or `ProblemQuestion`
/// there). Absent for a question with no explanation, so older rows and
/// older clients are unaffected.
public struct PlainQuestionPayload: Codable, Sendable, Equatable {
    public var explanation: String?
    /// A written question's other right wordings, kept with the test item so
    /// an unfinished test still grades them.
    public var accepted: [String]?

    public init?(explanation: String?) {
        guard let explanation, !explanation.isEmpty else { return nil }
        self.explanation = explanation
    }

    public init?(explanation: String?, accepted: [String]) {
        let why = (explanation?.isEmpty ?? true) ? nil : explanation
        guard why != nil || !accepted.isEmpty else { return nil }
        self.explanation = why
        self.accepted = accepted.isEmpty ? nil : accepted
    }

    public func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(_ json: String?) -> PlainQuestionPayload? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlainQuestionPayload.self, from: data)
    }
}
