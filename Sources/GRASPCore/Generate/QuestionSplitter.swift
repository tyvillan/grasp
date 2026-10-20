import Foundation

/// One question as it was printed on a page, before anything has judged it:
/// the stem, any options, and the answer if the page gave one.
public struct RawQuestion: Sendable, Equatable {
    /// The number printed in front of it ("12" for "12."), if any.
    public var number: Int?
    /// Everything before the options, as one line of text.
    public var stem: String
    /// Options in printed order, without their letters.
    public var options: [String]
    /// The letter the page marks as right ("Answer: B"), if it says so.
    public var answerLetter: Character?
    /// An answer printed in words ("Answer: the mitochondria"), if it says so.
    public var answerText: String?

    public init(number: Int? = nil, stem: String, options: [String] = [], answerLetter: Character? = nil, answerText: String? = nil) {
        self.number = number; self.stem = stem; self.options = options
        self.answerLetter = answerLetter; self.answerText = answerText
    }

    /// The question as plain text for a model, options on their own lines.
    public var fullText: String {
        var lines = [stem]
        for (index, option) in options.enumerated() {
            lines.append("\(Character(UnicodeScalar(65 + index)!))) \(option)")
        }
        if let answerLetter { lines.append("Answer: \(answerLetter)") }
        if let answerText { lines.append("Answer: \(answerText)") }
        return lines.joined(separator: "\n")
    }
}

/// Cuts the text read from a page of an exam or worksheet into its separate
/// questions. It works on the printed numbering ("1.", "2)", "Q3", "Question
/// 4") and on option letters ("A)", "b."), and reads an answer printed under a
/// question or in an answer key at the end. Pure text in, so it is tested
/// without a camera.
public enum QuestionSplitter {
    private static let startPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:Q|Question|Problem)\s*\.?\s*)?(\d{1,3})\s*[\.\):]\s+(\S.*)$|^\s*(?:Q|Question|Problem)\s*(\d{1,3})\s*[\.\):]?\s*$"#,
        options: [.caseInsensitive])
    private static let optionPattern = try! NSRegularExpression(
        pattern: #"^\s*\(?([A-Ha-h])[\.\)]\s+(\S.*)$"#)
    private static let answerPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:correct\s+)?(?:answer|ans|key)\s*[:\.\-=]\s*\(?([A-Ha-h])\)?\s*[\.\)]?\s*(.*)$"#,
        options: [.caseInsensitive])
    private static let answerWordsPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:correct\s+)?(?:answer|ans)\s*[:\.\-=]\s*(\S.*)$"#, options: [.caseInsensitive])
    private static let keyHeaderPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:answer\s*key|answers|key)\s*:?\s*$"#, options: [.caseInsensitive])
    private static let keyEntryPattern = try! NSRegularExpression(
        pattern: #"(\d{1,3})\s*[\.\)\-:]?\s*\(?([A-Ha-h])\)?(?=\s|,|;|$)"#)

    private static func match(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
    }

    private static func group(_ result: NSTextCheckingResult, _ index: Int, in line: String) -> String? {
        guard index < result.numberOfRanges, let range = Range(result.range(at: index), in: line) else { return nil }
        return String(line[range])
    }

    /// The questions on a page, in order. Text with no numbering at all is
    /// read as one question.
    public static func split(_ text: String) -> [RawQuestion] {
        var lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // An answer key at the end ("Answer key: 1. B 2. D") is cut off first.
        var key: [Int: Character] = [:]
        if let header = lines.lastIndex(where: { match(keyHeaderPattern, $0) != nil }), header > 0 {
            let tail = lines[(header + 1)...].joined(separator: " ")
            let results = keyEntryPattern.matches(in: tail, range: NSRange(tail.startIndex..., in: tail))
            for result in results {
                if let number = group(result, 1, in: tail).flatMap({ Int($0) }),
                   let letter = group(result, 2, in: tail)?.uppercased().first { key[number] = letter }
            }
            if !key.isEmpty { lines = Array(lines[..<header]) }
        }

        var blocks: [(number: Int?, lines: [String])] = []
        for line in lines {
            if let result = match(startPattern, line), !looksLikeOption(line, blocks: blocks) {
                let number = (group(result, 1, in: line) ?? group(result, 3, in: line)).flatMap { Int($0) }
                let rest = group(result, 2, in: line) ?? ""
                blocks.append((number, rest.isEmpty ? [] : [rest]))
            } else if blocks.isEmpty {
                blocks.append((nil, [line]))
            } else {
                blocks[blocks.count - 1].lines.append(line)
            }
        }

        var questions = blocks.compactMap { parse($0.number, $0.lines) }
        for index in questions.indices where questions[index].answerLetter == nil {
            if let number = questions[index].number, let letter = key[number] { questions[index].answerLetter = letter }
        }
        return questions
    }

    /// "1) Paris" right after a question's stem is an option, not a new question,
    /// when the numbers are not running on from the question before.
    private static func looksLikeOption(_ line: String, blocks: [(number: Int?, lines: [String])]) -> Bool {
        guard let last = blocks.last, let lastNumber = last.number,
              let result = match(startPattern, line), let number = group(result, 1, in: line).flatMap({ Int($0) })
        else { return false }
        // The next question is the previous number plus one; anything else
        // inside a block with lettered options is more likely an option.
        return number != lastNumber + 1 && last.lines.contains { match(optionPattern, $0) != nil }
    }

    private static func parse(_ number: Int?, _ lines: [String]) -> RawQuestion? {
        var stem: [String] = []
        var options: [String] = []
        var answerLetter: Character?
        var answerText: String?
        for line in lines {
            if let result = match(answerPattern, line), let letter = group(result, 1, in: line)?.uppercased().first {
                let rest = (group(result, 2, in: line) ?? "").trimmingCharacters(in: .whitespaces)
                // "Answer: A" is a letter; "Answer: Atlanta" is words that start with one.
                if rest.isEmpty || !(rest.first?.isLetter ?? false) { answerLetter = letter; continue }
            }
            if let result = match(answerWordsPattern, line), let words = group(result, 1, in: line) {
                answerText = words.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let result = match(optionPattern, line), let text = group(result, 2, in: line) {
                options.append(text)
            } else if !options.isEmpty {
                // A wrapped line belongs to the option above it.
                options[options.count - 1] += " " + line
            } else {
                stem.append(line)
            }
        }
        let text = stem.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // One lettered line is not a list of options.
        if options.count == 1 { return RawQuestion(number: number, stem: text + " " + options[0], answerLetter: answerLetter, answerText: answerText) }
        return RawQuestion(number: number, stem: text, options: options, answerLetter: answerLetter, answerText: answerText)
    }
}
