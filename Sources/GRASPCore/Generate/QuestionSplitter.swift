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
    /// Which printed lines of the page it came from (counting the page's non-empty lines
    /// from 0), so the picture can be cut down to it. Not part of what the question says.
    public var lineRange: ClosedRange<Int>?

    public init(number: Int? = nil, stem: String, options: [String] = [], answerLetter: Character? = nil, answerText: String? = nil,
                lineRange: ClosedRange<Int>? = nil) {
        self.number = number; self.stem = stem; self.options = options
        self.answerLetter = answerLetter; self.answerText = answerText; self.lineRange = lineRange
    }

    public static func == (a: RawQuestion, b: RawQuestion) -> Bool {
        a.number == b.number && a.stem == b.stem && a.options == b.options
            && a.answerLetter == b.answerLetter && a.answerText == b.answerText
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
            .map { latinized($0.trimmingCharacters(in: .whitespaces)) }
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

        var blocks: [(number: Int?, lines: [String], first: Int)] = []
        for (position, line) in lines.enumerated() {
            if let result = match(startPattern, line), !looksLikeOption(line, blocks: blocks) {
                let number = (group(result, 1, in: line) ?? group(result, 3, in: line)).flatMap { Int($0) }
                let rest = group(result, 2, in: line) ?? ""
                blocks.append((number, rest.isEmpty ? [] : [rest], position))
            } else if blocks.isEmpty {
                blocks.append((nil, [line], position))
            } else {
                blocks[blocks.count - 1].lines.append(line)
            }
        }

        // A page title or instructions above the first numbered question are not a question.
        if blocks.contains(where: { $0.number != nil }), blocks.first?.number == nil { blocks.removeFirst() }
        var questions: [RawQuestion] = []
        for (index, block) in blocks.enumerated() {
            let last = (index + 1 < blocks.count ? blocks[index + 1].first : lines.count) - 1
            if var question = parse(block.number, block.lines) {
                question.lineRange = block.first...max(block.first, last)
                questions.append(question)
            }
        }
        // Several sentences of notes with no numbering and no question in them are not a question.
        if questions.count == 1, questions[0].number == nil, looksLikeProse(questions[0]) { return [] }
        for index in questions.indices where questions[index].answerLetter == nil {
            if let number = questions[index].number, let letter = key[number] { questions[index].answerLetter = letter }
        }
        return questions
    }

    private static let lookalikes: [Character: Character] = [
        "А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "К": "K", "М": "M", "О": "O", "Р": "P", "Т": "T", "Х": "X",
        "а": "a", "с": "c", "е": "e", "о": "o", "р": "p", "х": "x", "у": "y", "і": "i",
        "Α": "A", "Β": "B", "Ε": "E", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Χ": "X", "Υ": "Y", "ο": "o",
    ]

    /// A reader sometimes returns a Cyrillic or Greek letter that looks exactly like a Latin one
    /// ("Answer: А"). On a line that is mostly Latin, those are put back to Latin so "A" is still "A".
    static func latinized(_ line: String) -> String {
        guard line.contains(where: { lookalikes[$0] != nil }) else { return line }
        let latin = line.filter { $0.isASCII && $0.isLetter }.count
        let other = line.filter { !$0.isASCII && $0.isLetter }.count
        guard latin > other else { return line }
        return String(line.map { lookalikes[$0] ?? $0 })
    }

    /// "1) Paris" right after a question's stem is an option, not a new question,
    /// when the numbers are not running on from the question before.
    private static func looksLikeOption(_ line: String, blocks: [(number: Int?, lines: [String], first: Int)]) -> Bool {
        guard let last = blocks.last, let lastNumber = last.number,
              let result = match(startPattern, line), let number = group(result, 1, in: line).flatMap({ Int($0) })
        else { return false }
        // The next question is the previous number plus one; anything else
        // inside a block with lettered options is more likely an option.
        return number != lastNumber + 1 && last.lines.contains { match(optionPattern, $0) != nil }
    }

    private static func looksLikeProse(_ question: RawQuestion) -> Bool {
        guard question.options.count < 2, question.answerLetter == nil, question.answerText == nil,
              !question.stem.contains("?") else { return false }
        let sentences = question.stem.split(whereSeparator: { ".!".contains($0) }).count
        return sentences >= 3 || question.stem.count > 300
    }

    /// Whether the page begins partway through a question: its first line is an option or an
    /// answer, so the question it belongs to is on the photo before it.
    public static func startsMidQuestion(_ text: String) -> Bool {
        guard let first = text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return false }
        return match(optionPattern, first) != nil || match(answerPattern, first) != nil || match(answerWordsPattern, first) != nil
    }

    /// The printed lines at the top of a page that finish a question begun on the photo before
    /// it: everything above its first numbered question. Empty when the page starts on a new one.
    public static func continuation(of text: String) -> [String] {
        guard startsMidQuestion(text) else { return [] }
        let lines = text.components(separatedBy: .newlines).map { latinized($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
        let end = lines.firstIndex { match(startPattern, $0) != nil } ?? lines.count
        return Array(lines[..<end])
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
