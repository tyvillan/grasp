import Foundation
import GRDB

/// A folder of exam material a professor posts -- a review sheet, a list of
/// topics by assignment, and numbered practice questions with and without
/// solutions -- read together into one study guide.
///
/// `StudyGuideParser` reads a guide that is one document laid out in parts
/// with skills. A review pack isn't that: its practice questions come as a
/// questions-only file and a questions-and-solutions file for the same set,
/// and the solutions file doesn't mark where a question ends and its answer
/// begins. The two copies tell it: the solution is what follows the
/// question's own text.
public enum ExamPack {
    public struct SourceFile: Sendable {
        public var title: String
        public var pages: [String]

        public init(title: String, pages: [String]) {
            self.title = title
            self.pages = pages
        }
        var text: String { pages.joined(separator: "\n") }
    }

    // MARK: - Which files belong to a pack

    private static func spaced(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    /// Numbered practice questions, with or without their solutions.
    public static func isPractice(title: String) -> Bool {
        let t = spaced(title)
        return t.contains("question") || t.contains("solution") || t.contains("practice")
    }

    static func isTopicList(title: String) -> Bool { spaced(title).contains("topics") && !isPractice(title: title) }
    static func isReviewSheet(title: String) -> Bool {
        let t = spaced(title)
        return t.contains("review") && !isPractice(title: title) && !isTopicList(title: title)
    }

    /// A batch is a pack when it holds practice questions beside at least
    /// one other file. A lone practice file, or a lone professor's guide,
    /// goes through the ordinary import.
    public static func packFiles<T>(in files: [T], title: (T) -> String) -> [T] {
        guard files.contains(where: { isPractice(title: title($0)) }) else { return [] }
        let pack = files.filter {
            let name = title($0)
            return isPractice(name: name) || isTopicList(title: name) || isReviewSheet(title: name)
        }
        return pack.count >= 2 ? pack : []
    }

    private static func isPractice(name: String) -> Bool { isPractice(title: name) }

    // MARK: - Building the guide

    /// The guide for these files, or nil when nothing in them is usable.
    public static func build(_ files: [SourceFile]) -> StudyGuideDocument? {
        var parts: [StudyGuideDocument.Part] = []
        var title: String?

        for file in files where isReviewSheet(title: file.title) {
            if title == nil { title = firstLine(of: file.text) }
            parts += reviewParts(file.text)
        }
        for file in files where isTopicList(title: file.title) {
            parts += assignmentParts(file.text)
        }
        parts += practiceParts(files)

        guard !parts.isEmpty else { return nil }
        for index in parts.indices { parts[index].number = index + 1 }
        return StudyGuideDocument(title: title ?? "Exam review", parts: parts)
    }

    private static func firstLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    // MARK: - Review sheet

    private static let bulletMarkers = ["•", "◦", "▪", "‣", "-", "–"]

    /// A bullet's text, or nil for a line that isn't one. "o" is how Word
    /// bullets come out of a PDF for a nested level.
    private static func bullet(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in bulletMarkers where trimmed.hasPrefix(marker + " ") {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.hasPrefix("o ") { return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    static func looksLikeCode(_ line: String) -> Bool {
        line.hasPrefix("//") || line.contains(";") || line.contains("{") || line.contains("}")
    }

    /// Groups of "heading, then its bullets", the rest being reference
    /// text (declarations, snippets) that stays in reading order.
    static func reviewParts(_ text: String) -> [StudyGuideDocument.Part] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var parts: [StudyGuideDocument.Part] = []
        var reference: [String] = []
        var heading: String?
        var bullets: [String] = []

        func flush() {
            defer { heading = nil; bullets = [] }
            guard let heading, !bullets.isEmpty else { return }
            let title = heading.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            var part = StudyGuideDocument.Part(title: title)
            let remember = bullets.filter { $0.lowercased().hasPrefix("remember") }
            part.remember = remember.map { $0.replacingOccurrences(of: #"^[Rr]emember\s*[–—-]?\s*"#, with: "",
                                                                  options: .regularExpression) }
            let rest = bullets.filter { !$0.lowercased().hasPrefix("remember") }
            if title.lowercased() == "skills" || title.lowercased().hasPrefix("playing computer") {
                part.skills = rest
                if title.lowercased() == "skills" { part.title = "Skills to be able to do" }
                else { part.title = "Kinds of exam question"; part.notes = [title] }
            } else {
                part.notes = rest
            }
            parts.append(part)
        }

        var previousWasBullet = false
        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            if let item = bullet(line) {
                bullets.append(item)
                previousWasBullet = true
                continue
            }
            // A wrapped bullet: the line after a bullet that starts in
            // lowercase continues it, and a line of code under one is its
            // example.
            if previousWasBullet, !bullets.isEmpty {
                if looksLikeCode(line) {
                    bullets[bullets.count - 1] += "\n" + line
                    continue
                }
                if let first = line.first, first.isLowercase {
                    bullets[bullets.count - 1] += " " + line
                    continue
                }
            }
            previousWasBullet = false
            let nextIsBullet = lines.dropFirst(index + 1).first(where: { !$0.isEmpty }).flatMap(bullet) != nil
            if nextIsBullet {
                flush()
                heading = line
            } else {
                flush()
                reference.append(line)
            }
        }
        flush()

        // The first line of reference text is the sheet's own title.
        let body = reference.dropFirst().joined(separator: "\n")
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.insert(StudyGuideDocument.Part(title: "Syntax and topics", notes: [body]), at: 0)
        }
        return parts
    }

    // MARK: - Topics by assignment

    static func assignmentParts(_ text: String) -> [StudyGuideDocument.Part] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var parts: [StudyGuideDocument.Part] = []
        var current: StudyGuideDocument.Part?
        var previousWasBullet = false
        for line in lines where !line.isEmpty {
            if line.range(of: #"^Assignment\s*\d+"#, options: .regularExpression) != nil {
                if let current { parts.append(current) }
                current = StudyGuideDocument.Part(title: line.replacingOccurrences(of: #"\s*-\s*"#, with: " – ",
                                                                                  options: .regularExpression))
                previousWasBullet = false
            } else if current != nil {
                if let item = bullet(line) {
                    current?.skills.append(item)
                    previousWasBullet = true
                } else if previousWasBullet, let first = line.first, first.isLowercase,
                          let last = current?.skills.indices.last {
                    current?.skills[last] += " " + line
                } else {
                    current?.notes.append(line)
                    previousWasBullet = false
                }
            }
        }
        if let current { parts.append(current) }
        return parts.filter { !$0.skills.isEmpty }
    }

    // MARK: - Practice questions

    /// The name that questions-only and with-solutions copies share.
    static func pairKey(_ title: String) -> String {
        spaced(title)
            .replacingOccurrences(of: #"\b(and|with)\s+solutions?\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "solutions", with: "")
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func hasSolutions(_ title: String) -> Bool { spaced(title).contains("solution") }

    /// "COP 3275C Midterm sample questions and solutions PART 2" reads as
    /// "Midterm sample questions PART 2".
    static func practiceTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"(?i)\s*\b(and|with)\s+solutions?\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[A-Za-z]{3}\s?\d{4}[A-Za-z]?\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: #"(?i)\bpart\b"#, with: "Part", options: .regularExpression)
        if let first = t.first { t = first.uppercased() + t.dropFirst() }
        return t
    }

    static func practiceParts(_ files: [SourceFile]) -> [StudyGuideDocument.Part] {
        let practice = files.filter { isPractice(title: $0.title) }
        let grouped = Dictionary(grouping: practice, by: { pairKey($0.title) })
        var parts: [(order: Int, part: StudyGuideDocument.Part)] = []
        for (_, group) in grouped {
            let withSolutions = group.first { hasSolutions($0.title) }
            let questionsOnly = group.first { !hasSolutions($0.title) }
            guard let primary = withSolutions ?? questionsOnly else { continue }
            let solutionBlocks = numberedBlocks(primary.text)
            let questionBlocks = withSolutions != nil && questionsOnly != nil ? numberedBlocks(questionsOnly!.text) : []

            var examples: [StudyGuideDocument.Example] = []
            for (index, block) in solutionBlocks.enumerated() {
                let label = "Question \(index + 1)"
                if withSolutions == nil {
                    examples.append(.init(label: label, question: block.joined(separator: "\n")))
                } else if index < questionBlocks.count {
                    let (question, answer) = split(solution: block, question: questionBlocks[index])
                    examples.append(.init(label: label, question: question, answer: answer))
                } else {
                    examples.append(.init(label: label, question: block.joined(separator: "\n")))
                }
            }
            guard !examples.isEmpty else { continue }
            let order = practice.firstIndex { $0.title == primary.title } ?? 0
            parts.append((order, StudyGuideDocument.Part(title: practiceTitle(primary.title), examples: examples)))
        }
        func rank(_ title: String) -> Int {
            let t = title.lowercased()
            return t.contains("midterm") || t.contains("exam") || t.contains("sample") ? 0 : 1
        }
        return parts.sorted {
            if rank($0.part.title) != rank($1.part.title) { return rank($0.part.title) < rank($1.part.title) }
            return NaturalOrder.isOrdered($0.part.title, before: $1.part.title)
        }.map(\.part)
    }

    /// The text of each numbered question, in order. Numbers have to run
    /// 1, 2, 3...: a "5." inside a code sample or a printed result isn't a
    /// new question unless the count is at 4.
    static func numberedBlocks(_ text: String) -> [[String]] {
        var blocks: [[String]] = []
        var expected = 1
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .init(charactersIn: " \t"))
            if let match = line.range(of: #"^(\d{1,2})\.\s+"#, options: .regularExpression),
               Int(line[line.startIndex..<line.index(before: match.upperBound)]
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))) == expected {
                blocks.append([String(line[match.upperBound...])])
                expected += 1
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks.map { trimmingBlankEdges($0) }
    }

    private static func trimmingBlankEdges(_ lines: [String]) -> [String] {
        var lines = lines
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines
    }

    /// Letters and digits only, without a bullet marker: the same list is "o"
    /// in one PDF and "•" in the other.
    private static func normalized(_ line: String) -> String {
        let text = bullet(line) ?? line
        return text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// The solutions copy of a question starts with the question's own
    /// lines; what comes after them is the solution. Compared line by
    /// line, ignoring spacing and punctuation, so a changed line stops the
    /// match rather than hiding part of the answer.
    static func split(solution: [String], question: [String]) -> (question: String, answer: String?) {
        let whole = solution.joined(separator: "\n")
        let solutionLines = solution.map(normalized)
        let questionText = Array(question.map(normalized).joined())
        let solutionText = Array(solutionLines.joined())
        // Compared as text with no spacing or punctuation: the two PDFs
        // wrap their lines in different places. The questions file may
        // also open with a line the solutions copy leaves out, so the
        // comparison starts where the solutions copy begins.
        // Every place it could start is tried (the intro line may repeat
        // the first words), keeping the one that agrees the longest.
        let probe = Array(solutionText.prefix(20))
        guard probe.count >= 5 else { return (whole, nil) }
        var common = 0
        for start in occurrences(of: probe, in: questionText) {
            var length = 0
            while length < solutionText.count, start + length < questionText.count,
                  solutionText[length] == questionText[start + length] {
                length += 1
            }
            common = max(common, length)
        }
        guard common >= probe.count else { return (whole, nil) }
        // The lines the question wholly accounts for; the line where the
        // two differ starts the answer.
        var consumed = 0
        var lineCount = 0
        for line in solutionLines {
            if consumed + line.count > common { break }
            consumed += line.count
            lineCount += 1
        }
        var answerLines = Array(solution.dropFirst(lineCount))
        // "//sample solution" and "Answer:" lead-ins add nothing.
        while let head = answerLines.first,
              head.isEmpty || normalized(head) == "samplesolution" || normalized(head) == "answer" {
            answerLines.removeFirst()
        }
        let answer = answerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return (whole, nil) }
        return (question.joined(separator: "\n"), answer)
    }

    private static func occurrences(of needle: [Character], in haystack: [Character]) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        return (0...(haystack.count - needle.count)).filter { i in
            haystack[i] == needle[0] && Array(haystack[i..<(i + needle.count)]) == needle
        }
    }
}

// MARK: - Saving

extension StudyGuideActions {
    /// Saves a pack as one guide for the course, linked to `examEventId`
    /// (or the exam the matcher picks). The pack's own parts aren't
    /// lecture titles, so its first part -- the review sheet -- maps to the
    /// course's lecture-style decks; the student can re-map any part.
    /// Importing the same pack again replaces its content in place and
    /// keeps the exam link, skill ratings and hand-picked decks.
    @discardableResult
    public static func importExamPack(courseId: String, examEventId: String?, document: StudyGuideDocument,
                                      now: Date = Date(), db: Database) throws -> StudyGuide {
        let body = try StudyGuideCoding.encode(document)
        let title = (document.title ?? "Exam review").trimmingCharacters(in: .whitespaces)
        var guide = try StudyGuide
            .filter(Column("courseId") == courseId)
            .filter(Column("parser") == "pack")
            .fetchAll(db)
            .first { identity(ofTitle: $0.title) == identity(ofTitle: title) }
            ?? StudyGuide(courseId: courseId, title: title, bodyJSON: body, parser: "pack", createdAt: now)
        guide.bodyJSON = body
        guide.bodySchemaVersion = StudyGuideDocument.schemaVersion
        guide.title = title
        guide.updatedAt = now
        if let examEventId { guide.examEventId = examEventId }
        if guide.examEventId == nil {
            guide.examEventId = try StudyGuideMatcher.exam(
                for: document, guideTitle: title, courseId: courseId, now: now, db: db
            )?.id
        }
        try guide.save(db)

        let manual = Set(try Int.fetchAll(db, sql:
            "SELECT DISTINCT partIndex FROM studyGuidePartDeck WHERE guideId = ? AND isManual = 1",
            arguments: [guide.id]))
        try StudyGuidePartDeck.filter(Column("guideId") == guide.id).filter(Column("isManual") == false).deleteAll(db)
        if !manual.contains(0) {
            let lectureDecks = Deck.ordered(
                try Deck.filter(Column("courseId") == courseId).filter(Column("deletedAt") == nil).fetchAll(db)
            ).filter { $0.chapter != nil && $0.supportingRank == 0 }
            for deck in lectureDecks {
                try StudyGuidePartDeck(guideId: guide.id, partIndex: 0, deckId: deck.id).insert(db)
            }
        }
        return guide
    }
}
