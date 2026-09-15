import Foundation

/// A candidate term/definition pair extracted deterministically from a
/// reflowed note body, before any card generator (LLM or manual review)
/// touches it.
public struct CandidatePair: Sendable, Equatable {
    public let front: String
    public let back: String
    /// 1-based line number in the reflowed text this pair was found at,
    /// so a card can always be traced back to its source note.
    public let sourceLine: Int

    public init(front: String, back: String, sourceLine: Int) {
        self.front = front
        self.back = back
        self.sourceLine = sourceLine
    }
}

/// Deterministic term/definition extraction over reflowed note text.
/// Recognizes four shapes, matching the corpus:
///   1. A short bare term line followed by a longer definition paragraph
///      (the dominant shape in the older courses -- slide definition dumps).
///   2. "Term: definition" on a single line.
///   3. "**Term** - definition", as a bullet or a paragraph.
///   4. A heading whose next line is a blockquote stating the idea.
///
/// Shapes 1 and 2 were ported and validated against the original vault
/// corpus (857 pairs, spot-checked for quality). Shapes 3 and 4 were added
/// for the Fall 2026 notes, which are written prose rather than slide
/// dumps: nearly every definition there is a markdown bullet with a bold
/// term, which shapes 1 and 2 discarded outright as structural markup.
/// Measured on that corpus: 154 bold-term bullets and 63 heading/quote
/// pairs that were previously producing roughly one card per note.
public enum PairParser {
    private static let inlineTermRegex = try! NSRegularExpression(
        pattern: #"^([A-Z][A-Za-z0-9 /'\-]{2,45}):\s+(.{25,})$"#
    )
    private static let numberedListRegex = try! NSRegularExpression(pattern: #"^\d+[.)]"#)

    /// `- **Term** - definition` / `**Term**: definition`. The bullet marker
    /// is optional so the same rule catches a paragraph that opens with a
    /// bold term. `TextCleaning` has already folded en/em dashes to "-", so
    /// only "-" and ":" need matching here.
    private static let boldTermRegex = try! NSRegularExpression(
        pattern: #"^(?:[-*+]\s+)?\*\*([^*]{2,60}?)\*\*\s*[-:]\s+(.{20,})$"#
    )
    private static let headingRegex = try! NSRegularExpression(pattern: #"^#{2,6}\s+(.+)$"#)
    private static let quoteRegex = try! NSRegularExpression(pattern: #"^>\s*(.+)$"#)

    public static func parse(_ reflowedText: String) -> [CandidatePair] {
        let lines = reflowedText.components(separatedBy: "\n")
        var out: [CandidatePair] = []

        var i = 0
        while i < lines.count {
            let s = lines[i].trimmingCharacters(in: .whitespaces)
            defer { i += 1 }
            if s.isEmpty || s.hasPrefix("*Date:") { continue }

            // Bold-term pairs are checked before the structural filter,
            // because the marker that makes the line "structural" (a
            // leading bullet) is exactly where these definitions live.
            if let pair = boldTermPair(s, line: i + 1) {
                out.append(pair)
                continue
            }
            if let pair = headingQuotePair(lines, at: i) {
                out.append(pair)
                continue
            }
            if isStructural(s) { continue }

            let words = s.split(separator: " ")
            let isBareTermLine = (1...6).contains(words.count)
                && s.count < 55
                && !s.hasSuffix(".") && !s.hasSuffix(",") && !s.hasSuffix(":") && !s.hasSuffix("=")
                && s.first?.isUppercase == true

            if isBareTermLine {
                var j = i + 1
                while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count {
                    let d = lines[j].trimmingCharacters(in: .whitespaces)
                    let dWords = d.split(separator: " ")
                    if dWords.count >= 8, d.first?.isUppercase == true, !isStructural(d) {
                        out.append(CandidatePair(front: s, back: d, sourceLine: i + 1))
                        continue
                    }
                }
            }

            let range = NSRange(s.startIndex..., in: s)
            if let match = inlineTermRegex.firstMatch(in: s, range: range),
               let frontRange = Range(match.range(at: 1), in: s),
               let backRange = Range(match.range(at: 2), in: s) {
                let front = String(s[frontRange])
                let rawBack = String(s[backRange])
                if isUsableTerm(front), !isLinksOnly(rawBack) {
                    out.append(CandidatePair(
                        front: front, back: stripMarkdown(rawBack), sourceLine: i + 1
                    ))
                }
            }
        }

        // A single terminal quality gate rather than threading it through
        // every branch above: the bare-term-line branch (the dominant
        // shape in the older courses) never called `isUsableTerm` or
        // `stripMarkdown` on its own -- the only one of the four that
        // didn't -- so a section-locator "term" or a literal "**bold**"
        // front could slip through untouched. Running every pair through
        // the same gate here closes that for all four shapes at once.
        return out.compactMap { pair in
            // Must run on the *raw* back, before stripMarkdown -- the
            // wiki-link/markdown-link syntax `isLinksOnly` matches is
            // exactly what stripMarkdown removes.
            guard !isLinksOnly(pair.back) else { return nil }
            let front = stripMarkdown(pair.front)
            let back = stripMarkdown(pair.back)
            guard isUsableTerm(front), isSelfContained(back), !isAssignmentMetaText(back) else { return nil }
            return CandidatePair(front: front, back: back, sourceLine: pair.sourceLine)
        }
    }

    /// Course logistics, not a definition -- "Submit your answer as a PDF
    /// by Friday", "See rubric on page 3", "Late submissions lose 10% per
    /// day". These match the structural shapes above (a bold term line, a
    /// "Term: text" line) often enough in an assignment sheet or syllabus
    /// excerpt to slip past every other filter here, since nothing about
    /// their *shape* looks wrong -- only their content does.
    ///
    /// Deliberately biased toward multi-word phrases and sentence
    /// structure (an imperative opener, a page/point reference) over bare
    /// single-word keywords: a rejection here happens silently at parse
    /// time with no second look (unlike the AI-assisted context check,
    /// which runs later against the note's own text and can still recover
    /// a card that reaches it), so a single generic word is too blunt --
    /// "grade", "extension", and "PDF" are all also perfectly ordinary
    /// vocabulary a real course could define ("PDF: a portable document
    /// format...", "Extension: a browser add-on...", "Grade: a
    /// measurement of a slope's steepness..."). Kept narrow on purpose.
    private static let assignmentMetaPhrases: [String] = [
        "see the rubric", "see rubric", "grading rubric", "the rubric",
        "see the syllabus", "see syllabus", "the syllabus",
        "academic integrity", "plagiarism policy", "late penalty", "late penalties",
        "extra credit", "office hours", "due date", "due by",
        "gradescope", "moodle",
    ]
    private static let pageOrPointsRegex = try! NSRegularExpression(
        pattern: #"\b(?:page|pg\.?|pp\.?)\s*\d+\b|\b\d+\s*(?:points?|pts\.?)\b"#,
        options: [.caseInsensitive]
    )
    private static let assignmentMetaLeadRegex = try! NSRegularExpression(
        pattern: #"^(?:submit|resubmit|turn in|upload|hand in|see the|refer to the)\b"#,
        options: [.caseInsensitive]
    )

    private static func isAssignmentMetaText(_ back: String) -> Bool {
        let range = NSRange(back.startIndex..., in: back)
        if assignmentMetaLeadRegex.firstMatch(in: back, range: range) != nil { return true }
        if pageOrPointsRegex.firstMatch(in: back, range: range) != nil { return true }
        let normalized = AnswerGrading.normalize(back)
        return assignmentMetaPhrases.contains { normalized.contains($0) }
    }

    /// A bold term and its definition on one line. The definition must
    /// still read as a definition rather than a pointer -- a bare
    /// cross-reference ("see Chapter 4") or a bullet that is really a
    /// homework assignment ("§1.4 - every 4th of the first 20") makes a
    /// useless card, so terms that are only a section number are rejected.
    private static func boldTermPair(_ s: String, line: Int) -> CandidatePair? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = boldTermRegex.firstMatch(in: s, range: range),
              let frontRange = Range(m.range(at: 1), in: s),
              let backRange = Range(m.range(at: 2), in: s) else { return nil }

        let front = stripMarkdown(String(s[frontRange]))
        let rawBack = String(s[backRange])
        let back = stripMarkdown(rawBack)
        guard isUsableTerm(front), !isLinksOnly(rawBack),
              back.split(separator: " ").count >= 4 else { return nil }
        return CandidatePair(front: front, back: back, sourceLine: line)
    }

    /// A `###` heading immediately followed by a blockquote -- the shape the
    /// Fall 2026 notes use to state a principle under its own name, e.g.
    /// "### S - Single Responsibility Principle" over
    /// "> **A class should have only one responsibility.**".
    private static func headingQuotePair(_ lines: [String], at index: Int) -> CandidatePair? {
        let heading = lines[index].trimmingCharacters(in: .whitespaces)
        let hRange = NSRange(heading.startIndex..., in: heading)
        guard let hm = headingRegex.firstMatch(in: heading, range: hRange),
              let titleRange = Range(hm.range(at: 1), in: heading) else { return nil }

        var j = index + 1
        while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
        guard j < lines.count else { return nil }

        let quote = lines[j].trimmingCharacters(in: .whitespaces)
        let qRange = NSRange(quote.startIndex..., in: quote)
        guard let qm = quoteRegex.firstMatch(in: quote, range: qRange),
              let bodyRange = Range(qm.range(at: 1), in: quote) else { return nil }

        let front = stripMarkdown(String(heading[titleRange]))
        let rawBack = String(quote[bodyRange])
        let back = stripMarkdown(rawBack)
        guard isUsableTerm(front), !isLinksOnly(rawBack),
              back.split(separator: " ").count >= 5 else { return nil }
        return CandidatePair(front: front, back: back, sourceLine: index + 1)
    }

    /// Rejects "terms" that are really locators -- a bare section or
    /// chapter reference (`§1.4`, `Ch. 2`, `Week 3`) names where something
    /// is, not what it means, and pairs from those are course logistics
    /// rather than anything worth drilling.
    private static let locatorRegex = try! NSRegularExpression(
        pattern: #"^(§|Ch\.?|Chapter|Week|Module|Lecture|Lab|Section|Unit|Test|Exam)\s*[\d.\-–]*$"#,
        options: [.caseInsensitive]
    )

    /// Discourse leads, not terms. These open a *section* of a note ("Note:
    /// the Module 3 essay is on Chapter 5") rather than naming a concept,
    /// so the card they make asks "what is Note?" -- unanswerable, and one
    /// of them appears in most notes.
    private static let discourseLeads: Set<String> = [
        "related", "note", "notes", "reading", "readings", "assessment", "assessments",
        "homework", "office hours", "announcement", "announcements", "recap", "summary",
        "next", "deadline", "due", "reminder", "example", "examples", "source", "sources",
        "bad", "good", "todo", "warning", "tip", "important", "aside", "context",
    ]

    /// A back made of nothing but wiki-links and separators -- the
    /// `Related: [[_Course Index]] · [[...]]` footer every Fall 2026 note
    /// carries. It matches "Term: definition" perfectly and is pure
    /// navigation, so it would otherwise add one dead card per note.
    private static let linksOnlyRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:\[\[[^\]]+\]\]|\[[^\]]+\]\([^)]*\))\s*(?:[·|,;/•-]\s*(?:\[\[[^\]]+\]\]|\[[^\]]+\]\([^)]*\))\s*)*$"#
    )

    /// Bare pronouns/demonstratives with no antecedent -- "It", "This",
    /// "They" -- name nothing on their own, and are the same words
    /// `isSelfContained` rejects when they open a *back* instead of being
    /// the whole *front*.
    private static let danglingPronouns: Set<String> = [
        "it", "its", "they", "them", "their", "theirs",
        "he", "him", "his", "she", "her", "hers",
    ]
    private static let danglingDemonstratives: Set<String> = [
        "this", "that", "these", "those", "such", "there",
        "one", "some", "others", "both", "each",
    ]

    /// Verbs/adverbs that, immediately after a demonstrative, mean the
    /// sentence is restating something from its paragraph rather than
    /// defining it -- "This is the process by which..." vs. "This pattern
    /// decouples..." (a noun follows, so the term itself anchors it).
    private static let referentialFollowers: Set<String> = [
        "is", "are", "was", "were", "means", "refers", "allows", "makes",
        "provides", "has", "have", "can", "will", "also", "includes",
        "describes", "happens", "occurs", "becomes", "gives", "causes",
    ]

    private static func isUsableTerm(_ term: String) -> Bool {
        guard term.count >= 3, term.contains(where: { $0.isLetter }) else { return false }
        if discourseLeads.contains(term.lowercased()) { return false }
        let normalized = AnswerGrading.normalize(term)
        if danglingPronouns.contains(normalized) || danglingDemonstratives.contains(normalized) {
            return false
        }
        let range = NSRange(term.startIndex..., in: term)
        return locatorRegex.firstMatch(in: term, range: range) == nil
    }

    /// A back that opens on a dangling pronoun or demonstrative reads fine
    /// inside its paragraph but means nothing lifted onto a flashcard by
    /// itself -- "This is the process by which..." names nothing without
    /// the sentence before it. Deliberately conservative: it only rejects
    /// the specific pronoun-then-verb shape, not every sentence that
    /// happens to start with "This".
    private static func isSelfContained(_ back: String) -> Bool {
        let words = AnswerGrading.normalize(back).split(separator: " ").map(String.init)
        guard words.count >= 4 else { return false }
        guard let first = words.first else { return false }
        if danglingPronouns.contains(first) { return false }
        if danglingDemonstratives.contains(first), words.count >= 2,
           referentialFollowers.contains(words[1]) {
            return false
        }
        return true
    }

    private static func isLinksOnly(_ back: String) -> Bool {
        let range = NSRange(back.startIndex..., in: back)
        return linksOnlyRegex.firstMatch(in: back, range: range) != nil
    }

    /// Cards are shown as plain text, so markdown emphasis, code ticks and
    /// wiki-link brackets would otherwise be read out literally on the
    /// front of a flashcard.
    static func stripMarkdown(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(
            of: #"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#, with: "$1", options: .regularExpression
        )
        t = t.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression
        )
        t = t.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func isStructural(_ s: String) -> Bool {
        if s.hasPrefix("#") || s.hasPrefix(">") || s.hasPrefix("-") || s.hasPrefix("*")
            || s.hasPrefix("|") || s.hasPrefix("!") {
            return true
        }
        let range = NSRange(s.startIndex..., in: s)
        return numberedListRegex.firstMatch(in: s, range: range) != nil
    }
}
