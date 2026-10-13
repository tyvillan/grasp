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
    /// What the model is told to write in the same call as the question.
    public static let promptRule = """
        EXPLANATION: one to three sentences: why the correct answer is right, then the most common mistake \
        and why it is wrong. No praise, no filler, no restating the question.
        """

    /// A longer, personal explanation (the "Explain this" reply): kept as
    /// written so a small code snippet survives, trimmed and bounded.
    public static func cleanLong(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let openers = ["sure", "of course", "certainly", "great question", "no problem"]
        if let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first,
           first.count < 40, openers.contains(where: { first.lowercased().hasPrefix($0) }) {
            text = text.drop(while: { $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }
        if text.count > 1200 { text = String(text.prefix(1200)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
    }

    /// One to three sentences, trimmed. Nil when nothing usable is left
    /// (empty, or only praise such as "Great question!").
    public static func clean(_ text: String?) -> String? {
        guard var text = text?.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = PlainMath.clean(text)
        // Sentences, keeping a "." inside a number or a name like self.x.
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        for (index, char) in chars.enumerated() {
            current.append(char)
            guard ".!?".contains(char) else { continue }
            let next = index + 1 < chars.count ? chars[index + 1] : " "
            if next == " " { sentences.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }
        let praise = ["great", "good job", "well done", "nice", "excellent", "awesome", "congratulations"]
        sentences = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return !(sentence.count < 40 && praise.contains { lower.hasPrefix($0) })
        }
        guard !sentences.isEmpty else { return nil }
        var result = sentences.prefix(3).joined(separator: " ")
        if result.count > 480 {
            result = String(result.prefix(480)).trimmingCharacters(in: .whitespaces)
            if let cut = result.lastIndex(where: { ".!?".contains($0) }) { result = String(result[...cut]) }
        }
        return result.isEmpty ? nil : result
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

    public init?(explanation: String?) {
        guard let explanation, !explanation.isEmpty else { return nil }
        self.explanation = explanation
    }

    public func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(_ json: String?) -> PlainQuestionPayload? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlainQuestionPayload.self, from: data)
    }
}
