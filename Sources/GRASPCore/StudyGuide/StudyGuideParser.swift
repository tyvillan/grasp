import Foundation

/// Reads an exam study guide into a `StudyGuideDocument` by fixed rules --
/// the same guide always gives the same document, like `PairParser` does
/// for cards.
///
/// Works on plain lines, because that's what arrives: a PDF's text layer
/// loses bold and puts each bullet glyph on its own line, and OCR of a
/// screenshot guide drops some bullets, turns a "▼" into "v", and says
/// nothing about which text sat in a question's header and which in its
/// folded-away answer. The rules below were tuned against two real guides:
///
/// - A professor's, OCR'd from screenshots: "Part 3 · Title (11 questions)",
///   "You should be able to" and "Traps the wrong answers are built on"
///   lists, and "Example 7 - <question>" followed straight by its answer.
/// - A student's, from a text layer: "PART 3 - TITLE", `Term: definition`
///   and `Term = formula` lines, "Example:" blocks with "Question:",
///   "Step N:", "Answer:" and "Why?" lines, and "★ REMEMBER:" callouts.
public enum StudyGuideParser {
    /// `pages` in reading order, one string per PDF page (a markdown file is
    /// one page). Page numbers are kept on parts and examples so a reader
    /// can open the page a table or figure is on.
    public static func parse(pages: [String]) -> StudyGuideDocument {
        var parser = Run(lines: lines(from: pages))
        return parser.run()
    }

    public static func parse(_ text: String) -> StudyGuideDocument {
        parse(pages: [text])
    }

    // MARK: - Lines

    struct Line: Equatable {
        var text: String
        var page: Int
        /// It began with a bullet glyph, now removed from `text`.
        var bullet: Bool
    }

    static let bulletGlyphs: Set<Character> = ["•", "●", "▪", "◦", "‣", "∙", "·", "○", "■", "□", "–", "-", "*"]

    static func lines(from pages: [String]) -> [Line] {
        var result: [Line] = []
        var pendingBullet = false
        for (index, page) in pages.enumerated() {
            for raw in page.components(separatedBy: .newlines) {
                var text = cleanOCR(raw).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                // A text layer puts the bullet glyph on a line of its own.
                if text.count == 1, let glyph = text.first, bulletGlyphs.contains(glyph) {
                    pendingBullet = true
                    continue
                }
                var bullet = pendingBullet
                pendingBullet = false
                if let first = text.first, bulletGlyphs.contains(first),
                   text.dropFirst().first == " " {
                    bullet = true
                    text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                result.append(Line(text: text, page: index + 1, bullet: bullet))
            }
        }
        return result
    }

    /// Repairs what OCR gets wrong in a screenshot guide:
    /// - a closing curly quote comes out as a run like "‚¿¿" or "‚¿‹", and
    ///   one before a lettered choice has swallowed its space and
    ///   parenthesis ("drive‚¿‹c)Safety");
    /// - a zero among numbers comes out as the letter o: "(o boats, 50
    ///   tons)", "(20, o)", "$20o". A lone o touching a digit, a "(" or a
    ///   ", " is never a word.
    static func cleanOCR(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"[‚¿‹›]{2,}"#, with: "”", options: .regularExpression)
        text = text.replacingOccurrences(of: #"”\s*([a-e])\)\s*"#, with: "” ($1) ", options: .regularExpression)
        for pattern in [#"(?<=\d)[oO](?=[\s,.;:)\]]|$)"#, #"(?<=\(|, |,)[oO](?=[\s,)])"#] {
            text = text.replacingOccurrences(of: pattern, with: "0", options: .regularExpression)
        }
        return text
    }

    // MARK: - Patterns

    static let partHeading = try! NSRegularExpression(
        pattern: #"^part\s+(\d{1,2})\s*[•·:\-–—.]\s*(.+?)\s*(?:\((\d{1,3})\s*(?:questions?|qs?)?\))?\s*\.?$"#,
        options: [.caseInsensitive]
    )
    static let exampleStart = try! NSRegularExpression(
        pattern: #"^(?:[v▼▶►]\s+)?example(?:\s+(\d{1,3}))?\s*([:\-–—.])\s*(.*)$"#,
        options: [.caseInsensitive]
    )
    static let rememberStart = try! NSRegularExpression(
        pattern: #"^★?\s*remember\b\s*:?\s*(.*)$"#, options: [.caseInsensitive]
    )
    static let subsectionPrefix = try! NSRegularExpression(pattern: #"^[A-H]\)\s+"#)
    static let monthDate = try! NSRegularExpression(
        pattern: #"\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2}),?\s+(\d{4})\b"#,
        options: [.caseInsensitive]
    )
    static let questionTotal = try! NSRegularExpression(
        pattern: #"\b(\d{1,3})\s+((?:multiple[- ]choice|short[- ]answer|true[/ -]false|free[- ]response|essay)\s+)?questions\b"#,
        options: [.caseInsensitive]
    )
    static let examRules = ["open note", "open-note", "closed note", "open book", "closed book",
                            "calculator allowed", "no calculator", "cumulative"]

    static let skillHeaders = ["you should be able to", "by the end you should", "skills tested", "what you should know"]
    static let trapHeaders = ["traps", "common mistakes", "mistakes to avoid", "watch out for", "common errors"]
    static let boilerplate = ["try it, then open the answer", "on this page"]

    /// First words that make a `Word: text` line a label inside an
    /// example, not a term being defined.
    static let notTerms: Set<String> = [
        "step", "option", "question", "answer", "why", "example", "examples", "note", "remember",
        "before", "after", "at", "part", "traps", "tip", "hint", "if", "when", "then", "so",
    ]

    static func match(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
    }

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " }).count
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        // "(b)" at the end of a line opens the next option, it ends nothing.
        if text.range(of: #"\([a-eA-E]\)$"#, options: .regularExpression) != nil { return false }
        return ".?!”\"')".contains(last)
    }

    static func startsLowercase(_ text: String) -> Bool {
        text.first?.isLowercase ?? false
    }

    static func startsWithAny(_ text: String, _ prefixes: [String]) -> Bool {
        let lower = text.lowercased()
        return prefixes.contains { lower.hasPrefix($0) }
    }

    static func withoutSubsection(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return subsectionPrefix.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// A short line naming what follows: "Understanding the PPF points",
    /// "C) Positive vs. Normative Statements".
    static func isHeading(_ line: Line) -> Bool {
        guard !line.bullet else { return false }
        if match(subsectionPrefix, line.text) != nil { return true }
        let text = line.text
        guard let first = text.first, first.isUppercase, words(text) <= 6, !endsSentence(text),
              !text.hasSuffix(":"), !text.contains("→"), !text.contains("="), !text.contains("$"),
              !text.contains(where: \.isNumber)
        else { return false }
        return true
    }

    enum Definition: Equatable {
        case term(String, String)
        case formula(String)
        /// "Prices help markets work by:" -- introduces a list, defines nothing.
        case lead(String)
    }

    /// `Term: definition`, `Term = definition`, or `Name = expression`.
    static func definition(_ raw: String) -> Definition? {
        let text = withoutSubsection(raw)
        // "B) Demand: Slide vs. Shift" names a section; "A) Full Cost: Money
        // paid + ..." defines something.
        if text != raw, !endsSentence(text), words(text) <= 6 { return nil }
        guard let first = text.first, first.isUppercase else { return nil }
        let firstWord = text.prefix { $0.isLetter }.lowercased()
        guard !notTerms.contains(firstWord) else { return nil }

        let colon = text.firstIndex(of: ":")
        let equals = text.range(of: " = ")
        if let equals, colon.map({ equals.lowerBound < $0 }) ?? true {
            let left = text[..<equals.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = text[equals.upperBound...].trimmingCharacters(in: .whitespaces)
            guard words(left) <= 5, !left.contains("$"), !left.contains(where: \.isNumber),
                  !right.isEmpty
            else { return nil }
            let mathy = right.contains { "×÷+−*/%".contains($0) } || right.first == "("
            if mathy || words(right) <= 4 { return .formula(text) }
            return .term(left, right)
        }
        if let colon {
            let term = text[..<colon].trimmingCharacters(in: .whitespaces)
            let body = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, !term.contains("→"), !term.contains("$"),
                  !term.contains(where: \.isNumber)
            else { return nil }
            if body.isEmpty {
                return words(term) <= 3 ? .term(term, "") : .lead(term)
            }
            guard words(term) <= 6, words(body) >= 2 else { return nil }
            return .term(term, body)
        }
        return nil
    }

    // MARK: - The run

    struct Run {
        let lines: [Line]
        var index = 0
        var document = StudyGuideDocument()
        var partIndex: Int?
        /// Paragraph being collected for `notes`.
        var paragraph: [String] = []
        /// What a following bullet or lowercase continuation belongs to.
        var attach: Attach = .none
        /// Table cells dropped since the last thing kept: the next example
        /// may be the question that reads that table.
        var debris: [String] = []

        enum Attach { case none, term, formula, paragraph }

        init(lines: [Line]) { self.lines = lines }

        mutating func run() -> StudyGuideDocument {
            readHeader()
            while index < lines.count {
                step()
            }
            flushParagraph()
            return document
        }

        // Title, exam date and format from the lines before the first part.
        mutating func readHeader() {
            let firstPart = lines.firstIndex { !$0.bullet && match(partHeading, $0.text) != nil } ?? lines.count
            if let first = lines.first, !first.bullet, match(partHeading, first.text) == nil {
                document.title = StudyGuideParser.displayTitle(first.text)
            }
            for line in lines[..<firstPart] {
                if document.examDate == nil, let date = match(monthDate, line.text),
                   let month = date[0], let day = date[1].flatMap(Int.init), let year = date[2].flatMap(Int.init),
                   let monthNumber = StudyGuideParser.monthNumber(month) {
                    document.examDate = String(format: "%04d-%02d-%02d", year, monthNumber, day)
                }
                if document.questionCount == nil, let total = match(questionTotal, line.text),
                   let count = total[0].flatMap(Int.init) {
                    document.questionCount = count
                    let kind = total[1]?.trimmingCharacters(in: .whitespaces)
                    document.format.append([String(count), kind, "questions"].compactMap { $0 }.joined(separator: " "))
                }
                let lower = line.text.lowercased()
                for rule in examRules where lower.contains(rule) {
                    let tidy = rule.replacingOccurrences(of: "-", with: " ")
                    if !document.format.contains(tidy) { document.format.append(tidy) }
                }
            }
            // The title line isn't a note.
            if document.title != nil { index = 1 }
        }

        mutating func edit(_ change: (inout StudyGuideDocument.Part) -> Void) {
            guard let partIndex else { return }
            change(&document.parts[partIndex])
        }

        mutating func addNote(_ text: String) {
            if partIndex != nil { edit { $0.notes.append(text) } } else { document.notes.append(text) }
        }

        mutating func flushParagraph() {
            defer { paragraph = [] }
            guard !paragraph.isEmpty else { return }
            // Table cells read out one per line ("Price", "$6", "2", "Worth
            // to the buyer") are debris: the text can't carry a table, the
            // page link can. Prose wraps at 15-20 words a line; cells don't.
            let text = paragraph.joined(separator: "\n")
            let total = StudyGuideParser.words(text)
            // One line alone has to be a sentence: "What Exam 1 Tests, and
            // How to Prepare" is a subtitle, not something to keep.
            let isProse = paragraph.count == 1
                ? total >= 6 && StudyGuideParser.endsSentence(text)
                : Double(total) / Double(paragraph.count) >= 8
            guard isProse else {
                debris.append(text)
                return
            }
            addNote(text)
            debris = []
        }

        mutating func step() {
            let line = lines[index]
            let lower = line.text.lowercased()

            // The date and format line is already in the header fields.
            if partIndex == nil, match(partHeading, line.text) == nil,
               match(monthDate, line.text) != nil || match(questionTotal, line.text) != nil,
               StudyGuideParser.words(line.text) <= 16 {
                flushParagraph()
                index += 1
                return
            }

            if boilerplate.contains(where: { lower.hasPrefix($0) }) {
                flushParagraph()
                index += 1
                // "On this page" is followed by a bulleted contents list.
                if lower.hasPrefix("on this page") {
                    while index < lines.count, lines[index].bullet { index += 1 }
                }
                return
            }

            if !line.bullet, let heading = match(partHeading, line.text), let title = heading[1] {
                flushParagraph()
                document.parts.append(StudyGuideDocument.Part(
                    number: heading[0].flatMap(Int.init),
                    title: StudyGuideParser.displayTitle(title),
                    questionCount: heading[2].flatMap(Int.init),
                    page: line.page
                ))
                partIndex = document.parts.count - 1
                attach = .none
                debris = []
                index += 1
                return
            }

            if !line.bullet, startsWithAny(line.text, skillHeaders) {
                flushParagraph()
                index += 1
                let items = readList()
                edit { $0.skills += items }
                debris = []
                return
            }
            if !line.bullet, startsWithAny(line.text, trapHeaders), words(line.text) <= 10 {
                flushParagraph()
                index += 1
                let items = readList()
                edit { $0.traps += items }
                debris = []
                return
            }

            if match(exampleStart, line.text) != nil {
                flushParagraph()
                var example = readExample()
                let previous = partIndex.flatMap { document.parts[$0].examples.last }
                if StudyGuideParser.usesFigure(example, debris: debris, previous: previous) {
                    example.usesFigure = true
                }
                debris = []
                if partIndex != nil { edit { $0.examples.append(example) } }
                attach = .none
                return
            }

            if !line.bullet, let remember = match(rememberStart, line.text) {
                flushParagraph()
                index += 1
                var items: [String] = []
                if let first = remember[0], !first.isEmpty { items.append(first) }
                items = readRemember(startingWith: items)
                edit { $0.remember += items }
                attach = .none
                return
            }
            if !line.bullet, line.text.hasPrefix("★") {
                flushParagraph()
                index += 1
                let text = line.text.dropFirst().trimmingCharacters(in: .whitespaces)
                let items = readRemember(startingWith: text.isEmpty ? [] : [text])
                edit { $0.remember += items }
                attach = .none
                return
            }

            // A bullet or a lowercase line carries on whatever came before.
            if line.bullet || startsLowercase(line.text) {
                index += 1
                let text = line.bullet ? "• " + line.text : line.text
                let separator = line.bullet ? "\n" : " "
                switch attach {
                case .term:
                    edit { part in
                        guard var last = part.terms.popLast() else { return }
                        last.definition = [last.definition, text].filter { !$0.isEmpty }
                            .joined(separator: separator)
                        part.terms.append(last)
                    }
                case .formula:
                    edit { part in
                        guard let last = part.formulas.popLast() else { return }
                        part.formulas.append(last + separator + text)
                    }
                case .paragraph, .none:
                    if line.bullet || paragraph.isEmpty {
                        paragraph.append(text)
                    } else {
                        paragraph[paragraph.count - 1] += " " + text
                    }
                    attach = .paragraph
                }
                return
            }

            if partIndex != nil, let definition = definition(line.text) {
                switch definition {
                case .term(let term, let body):
                    flushParagraph()
                    edit { $0.terms.append(.init(term: term, definition: body)) }
                    attach = .term
                    index += 1
                    return
                case .formula(let formula):
                    flushParagraph()
                    edit { $0.formulas.append(formula) }
                    attach = .formula
                    index += 1
                    return
                case .lead:
                    break // a note heading, below
                }
            }

            // Plain prose or a heading: part of a note paragraph.
            if isHeading(line) || (paragraph.last.map(endsSentence) ?? false && words(line.text) <= 3) {
                flushParagraph()
            }
            paragraph.append(withoutSubsection(line.text))
            attach = .paragraph
            index += 1
        }

        /// A skills or traps list. OCR drops some bullets, so a line with no
        /// bullet still starts an item when the last one ended a sentence
        /// and this one is long enough to be one; a lowercase line, or one
        /// after an unfinished line, continues the item.
        mutating func readList() -> [String] {
            var items: [String] = []
            while index < lines.count {
                let line = lines[index]
                if isStructural(line) { break }
                if line.bullet {
                    items.append(line.text)
                } else if let last = items.last, startsLowercase(line.text) || !endsSentence(last) {
                    items[items.count - 1] = last + " " + line.text
                } else if words(line.text) >= 5 {
                    items.append(line.text)
                } else {
                    break
                }
                index += 1
            }
            return items
        }

        /// A "REMEMBER" callout: its own text, then any bullets, arrow lines
        /// ("price falls → SLIDE") and lowercase continuations under it.
        mutating func readRemember(startingWith first: [String]) -> [String] {
            var items = first
            while index < lines.count {
                let line = lines[index]
                if isStructural(line) { break }
                if line.bullet || line.text.contains("→") {
                    items.append(line.text)
                } else if startsLowercase(line.text), let last = items.last {
                    items[items.count - 1] = last + " " + line.text
                } else {
                    break
                }
                index += 1
            }
            return items
        }

        func isStructural(_ line: Line) -> Bool {
            if match(exampleStart, line.text) != nil { return true }
            guard !line.bullet else { return false }
            return match(partHeading, line.text) != nil
                || startsWithAny(line.text, skillHeaders)
                || (startsWithAny(line.text, trapHeaders) && words(line.text) <= 10)
                || match(rememberStart, line.text) != nil
                || line.text.hasPrefix("★")
        }

        // MARK: Examples

        mutating func readExample() -> StudyGuideDocument.Example {
            let first = lines[index]
            let parts = match(exampleStart, first.text) ?? []
            let number = parts.first.flatMap { $0 }
            // "Example 7 - <question>" (a professor's guide) runs until the
            // next example or part: its answer lines can look like terms
            // ("Quantity: change 10, ..."). "Example: <setup>" (a student's
            // own) also ends at the next term, heading or lettered section.
            let dashed = parts.count > 1 && parts[1] != ":" && number != nil
            var body: [Line] = []
            if let rest = parts.last.flatMap({ $0 }), !rest.isEmpty {
                body.append(Line(text: rest, page: first.page, bullet: false))
            }
            index += 1
            while index < lines.count {
                let line = lines[index]
                if isStructural(line) { break }
                if !dashed, !line.bullet {
                    if match(subsectionPrefix, line.text) != nil { break }
                    if isHeading(line), !body.isEmpty { break }
                    if case .term = StudyGuideParser.definition(line.text) { break }
                }
                body.append(line)
                index += 1
            }
            return StudyGuideParser.example(
                label: number.map { "Example \($0)" }, body: body, page: first.page
            )
        }
    }

    // MARK: - Splitting an example

    static func isWhy(_ line: Line) -> Bool { !line.bullet && line.text.lowercased().hasPrefix("why?") }
    static func isAnswer(_ line: Line) -> Bool { !line.bullet && line.text.lowercased().hasPrefix("answer:") }
    static func isQuestion(_ line: Line) -> Bool { !line.bullet && line.text.lowercased().hasPrefix("question:") }
    static func isStep(_ line: Line) -> Bool {
        !line.bullet && line.text.range(of: #"^step\s+\d+\s*[:.]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func text(of line: Line) -> String { line.bullet ? "• " + line.text : line.text }

    /// Lines joined, a lowercase line or one after an unfinished formula
    /// ("... =" then "$30") carrying on the line before it.
    static func joinLines(_ lines: [Line]) -> [String] {
        mergeContinuations(lines).map(text(of:))
    }

    /// A line carries on the one before it when it starts lowercase, when
    /// the one before ends in "=" or "→" ("Surplus = $70 − $40 =" then
    /// "$30"), or when the one before is a full-width line that stops
    /// mid-sentence -- prose wrapped by the page, not a new thought.
    static func mergeContinuations(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        for line in lines {
            if var last = result.last, !line.bullet, !isWhy(line), !isStep(line),
               !isAnswer(line), !isQuestion(line),
               startsLowercase(line.text) || last.text.hasSuffix("=") || last.text.hasSuffix("→")
                || (words(last.text) >= 12 && !endsSentence(last.text) && !last.text.hasSuffix(":")
                    && !last.text.contains(" = ")) {
                last.text += " " + line.text
                result[result.count - 1] = last
            } else {
                result.append(line)
            }
        }
        return result
    }

    static func stripLabel(_ text: String, _ label: String) -> String {
        guard text.lowercased().hasPrefix(label) else { return text }
        return text.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
    }

    /// Where the question ends and the working begins. In order: an explicit
    /// "Question:" line; a line with a "?" (not "Why?"), running on to the
    /// first line that finishes a sentence; the first "Step N"; an
    /// "Answer:" line; the line a "Why?" explains. Nothing? Then it's an
    /// illustration: all question, no answer.
    static func example(label: String?, body: [Line], page: Int) -> StudyGuideDocument.Example {
        let answerAt = body.firstIndex(where: isAnswer)
        let whyAt = body.firstIndex(where: isWhy)
        let firstWorked = [answerAt, whyAt].compactMap { $0 }.min() ?? body.count

        var questionEnd: Int? // last index of the question, inclusive
        if let q = body.firstIndex(where: isQuestion) {
            var end = q
            while end + 1 < body.count, !body[end + 1].bullet, startsLowercase(body[end + 1].text) { end += 1 }
            questionEnd = end
        } else if let mark = body[..<firstWorked].firstIndex(where: { !isWhy($0) && $0.text.contains("?") }) {
            var end = mark
            // Runs on to the line that ends the sentence, within two lines.
            while !endsSentence(body[end].text), end + 1 < min(body.count, mark + 3), end + 1 < firstWorked {
                end += 1
            }
            questionEnd = endsSentence(body[end].text) ? end : mark
        } else if let step = body.firstIndex(where: isStep), step > 0 {
            questionEnd = step - 1
        } else if let answerAt, answerAt > 0 {
            questionEnd = answerAt - 1
        } else if let whyAt, whyAt >= 2 {
            questionEnd = whyAt - 2
        }

        guard let questionEnd else {
            return .init(label: label, question: joinLines(body).joined(separator: "\n"), page: page)
        }
        let question = tidyChoices(joinLines(Array(body[...questionEnd]))
            .map { stripLabel($0, "question:") }
            .joined(separator: "\n"))
        let rest = Array(body[(questionEnd + 1)...])
        guard !rest.isEmpty else {
            return .init(label: label, question: question, page: page)
        }

        var steps: [Line]
        var answer: [Line]
        if let a = rest.firstIndex(where: isAnswer) {
            steps = Array(rest[..<a])
            answer = Array(rest[a...])
        } else if let w = rest.firstIndex(where: isWhy) {
            let cut = max(0, w - 1)
            steps = Array(rest[..<cut])
            answer = Array(rest[cut...])
        } else if rest.contains(where: isStep) {
            let lastStep = rest.lastIndex(where: isStep) ?? 0
            steps = Array(rest[..<lastStep])
            answer = Array(rest[lastStep...])
        } else {
            steps = []
            answer = rest
        }

        let answerText = joinLines(answer)
            .map { stripLabel($0, "answer:") }
            .joined(separator: "\n")
        return .init(
            label: label, question: question, steps: groupSteps(steps),
            answer: answerText.isEmpty ? nil : answerText, page: page
        )
    }

    static let choiceMarker = try! NSRegularExpression(pattern: #"\(([a-e])\)\s*"#)

    /// "Which is positive? (a) "X." (b) Y” (c) Z”" -- a multiple-choice
    /// question the page ran together -- with each choice on its own line
    /// and its quotes whole again (OCR drops opening quotes). Only when the
    /// choices start at (a) and go on to (b): "(b)" alone is a reference,
    /// not a list.
    static func tidyChoices(_ question: String) -> String {
        let ns = question as NSString
        let markers = choiceMarker.matches(in: question, range: NSRange(location: 0, length: ns.length))
        let letters = markers.map { ns.substring(with: $0.range(at: 1)) }
        guard letters.count >= 2, letters[0] == "a", letters[1] == "b" else { return question }
        var lines = [ns.substring(to: markers[0].range.location).trimmingCharacters(in: .whitespaces)]
        for (i, marker) in markers.enumerated() {
            let start = marker.range.location + marker.range.length
            let end = i + 1 < markers.count ? markers[i + 1].range.location : ns.length
            var choice = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces)
            if choice.hasPrefix("\"") { choice = "“" + choice.dropFirst() }
            if choice.hasSuffix("\"") { choice = choice.dropLast() + "”" }
            if choice.hasSuffix("”"), !choice.hasPrefix("“") { choice = "“" + choice }
            if choice.hasPrefix("“"), !choice.contains("”") { choice += "”" }
            lines.append("(\(letters[i])) " + choice)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Tables and figures

    static let figureReference = try! NSRegularExpression(
        pattern: #"\b(?:the|this|that)\s+(?:table|figure|graph|chart|schedule|diagram)\b|\b(?:each|every)\s+(?:row|column)\b"#,
        options: [.caseInsensitive]
    )
    static let thirdPerson = try! NSRegularExpression(
        pattern: #"\b(?:he|his|him|she|her)\b"#, options: [.caseInsensitive]
    )
    /// Capitalized words that start sentences without naming anyone.
    static let sentenceStarters: Set<String> = [
        "at", "what", "the", "a", "an", "if", "how", "is", "are", "does", "do", "did", "which", "who",
        "why", "when", "where", "in", "on", "for", "with", "use", "back", "suppose", "imagine", "now",
        "then", "after", "before", "each", "he", "his", "she", "her", "it", "this", "that", "there",
        "one", "two", "three", "four", "five", "find", "compute", "say", "show", "explain",
    ]

    /// Whether a question names someone ("Priya's gas costs..."), so its
    /// "she" is its own and not the previous example's.
    static func namesSomeone(_ text: String) -> Bool {
        text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).contains { word in
            guard let first = word.first, first.isUppercase, word.count >= 3 else { return false }
            let bare = word.lowercased().replacingOccurrences(of: "'s", with: "")
            return !sentenceStarters.contains(bare)
        }
    }

    /// Whether an example needs its page open, because OCR couldn't carry
    /// what it reads. Any of:
    /// - it says so: "Use the table", "Add across each row";
    /// - it comes straight after table cells that were dropped, and shares
    ///   a word with them ("Smoothies per week" above "At $3 a smoothie,
    ///   what are his...");
    /// - it goes on about the same unnamed "he" as the example before it
    ///   on the page, which needed its figure ("At $4 he spends $12").
    static func usesFigure(_ example: StudyGuideDocument.Example, debris: [String],
                           previous: StudyGuideDocument.Example?) -> Bool {
        let all = ([example.question] + example.steps + [example.answer ?? ""]).joined(separator: " ")
        if match(figureReference, all) != nil { return true }
        // Cells, not stray headings: at least two of the dropped lines are
        // bare numbers ("$6", "2").
        let cells = debris.flatMap { $0.split(separator: "\n") }
            .filter { $0.range(of: #"^\$?\d[\d.,%]*$"#, options: .regularExpression) != nil }
        if cells.count >= 2,
           !contentWords(debris.joined(separator: " ")).isDisjoint(with: contentWords(example.question)) {
            return true
        }
        if let previous, previous.usesFigure == true, previous.page == example.page,
           match(thirdPerson, example.question) != nil, !namesSomeone(example.question) {
            return true
        }
        return false
    }

    static let commonWords: Set<String> = [
        "that", "this", "with", "from", "have", "what", "your", "than", "they", "them", "their",
        "then", "there", "were", "will", "would", "when", "which", "more", "most", "each", "only",
        "into", "also", "over", "same", "about", "just", "after", "before", "other", "these",
        "those", "while", "does", "much", "many", "total",
    ]

    /// Lowercased words of four letters or more, a plural's "s" dropped,
    /// common words left out: enough to tell whether two passages are
    /// about the same thing.
    static func contentWords(_ text: String) -> Set<String> {
        var result = Set<String>()
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count >= 4 {
            let stem = word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : String(word)
            if !commonWords.contains(stem) { result.insert(stem) }
        }
        return result
    }

    /// "Step 2: Find spending." with the line of working under it is one step.
    static func groupSteps(_ lines: [Line]) -> [String] {
        var groups: [[Line]] = []
        for line in mergeContinuations(lines) {
            if isStep(line) || groups.isEmpty || !(groups.last?.first.map(isStep) ?? false) {
                groups.append([line])
            } else {
                groups[groups.count - 1].append(line)
            }
        }
        return groups.map { joinLines($0).joined(separator: " ") }
    }

    // MARK: - Titles and dates

    static let smallWords: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or", "the", "to", "vs", "vs.", "with"]

    /// "THE ECONOMIC WAY OF THINKING" reads as "The Economic Way of
    /// Thinking"; a title already in mixed case is left alone, and short
    /// all-caps words ("ECO", "PPF") stay capitals.
    static func displayTitle(_ raw: String) -> String {
        let title = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let letters = title.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) else { return title }
        let words = title.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return words.enumerated().map { i, w in
            let lettersOnly = w.filter(\.isLetter)
            // A course code: a few letters before a 3- or 4-digit number.
            let beforeCourseNumber = i + 1 < words.count
                && words[i + 1].count >= 3 && words[i + 1].allSatisfy(\.isNumber)
            if lettersOnly.count <= 4, beforeCourseNumber { return w }
            let lower = w.lowercased()
            if i > 0, smallWords.contains(lower) { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    static func monthNumber(_ name: String) -> Int? {
        let months = ["january", "february", "march", "april", "may", "june", "july",
                      "august", "september", "october", "november", "december"]
        return months.firstIndex(of: name.lowercased()).map { $0 + 1 }
    }
}
