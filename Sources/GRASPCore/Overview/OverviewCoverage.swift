import Foundation

/// Three checks on a lesson that need no model: that the plan covers every
/// part of a long note, that code and file names read the way the note
/// writes them, and that the same question isn't asked twice.
///
/// Found on a real deck: the plan was told to write four or five sections,
/// so a lecture of twenty-seven slide topics came back covering the first
/// half. Quotation marks in code were stripped because the prompts forbid
/// them inside a string, and `main.cpp` once came back as `a.cpp`.
public enum OverviewCoverage {
    /// Headings a note carries for its own structure, not for its content.
    private static let generic: Set<String> = [
        "key terms", "key concepts", "slide summary", "summary", "contents", "references",
        "overview", "notes", "table of contents", "takeaways",
    ]

    /// The note's own headings, in order, with slide numbers and markdown
    /// removed: `### S7, S15 · Variables and data types` becomes
    /// `Variables and data types`.
    public static func noteHeadings(in note: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for line in note.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("##") else { continue }
            var text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            text = text.replacingOccurrences(of: "`", with: "")
            text = text.replacingOccurrences(of: #"^S\d+(?:\s*[,–\-]\s*S?\d+)*\s*[·•:\-–—]\s*"#, with: "",
                                             options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespaces)
            let key = text.lowercased()
            guard text.count >= 2, !generic.contains(key), seen.insert(key).inserted else { continue }
            result.append(text)
        }
        return result
    }

    /// How many sections to ask for. A note with few headings keeps the
    /// original four or five; one with many gets room to cover them.
    public static func sectionRange(headingCount: Int) -> String {
        switch headingCount {
        case ..<10: return "4 or 5"
        case 10..<16: return "5 to 7"
        default: return "6 to 8"
        }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "are", "its", "into", "how", "what", "why",
        "when", "your", "you", "use", "using", "used", "about", "than", "then", "can", "not", "all",
    ]

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) })
    }

    /// The note headings no planned section mentions. A heading counts as
    /// covered when at least 60% of its words appear in some section's
    /// heading or covers field.
    public static func missing(headings: [String], plannedText: [String]) -> [String] {
        let planned = plannedText.map(words)
        return headings.filter { heading in
            let needed = words(heading)
            guard !needed.isEmpty else { return false }
            let lowered = heading.lowercased()
            return !plannedText.indices.contains { index in
                plannedText[index].lowercased().contains(lowered)
                    || Double(needed.intersection(planned[index]).count) / Double(needed.count) >= 0.6
            }
        }
    }

    // MARK: - Writing the note's text back

    /// Puts back the quotation marks and capitals a model removed from code
    /// and file names. A line of the note that has quotation marks is found
    /// in `text` with them stripped, and replaced by the note's own line, whether the model dropped the marks or wrote single quotes.
    public static func restoringCode(in text: String, noteText: String) -> String {
        var result = text
        for line in noteText.split(separator: "\n") {
            let original = line.trimmingCharacters(in: .whitespaces)
            guard original.contains("\""), original.count >= 10, original.count <= 160 else { continue }
            guard !result.contains(original) else { continue }
            // Stripped of the marks, or with single quotes in their place.
            let candidates = [squash(original.replacingOccurrences(of: "\"", with: "")),
                              squash(original.replacingOccurrences(of: "\"", with: "'"))]
            for candidate in candidates where candidate.count >= 8 {
                if let range = result.range(of: candidate, options: [.caseInsensitive]) {
                    result.replaceSubrange(range, with: original)
                    break
                }
            }
        }
        return restoringFileNames(in: result, noteText: noteText)
    }

    private static func squash(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    private static let fileName = try! NSRegularExpression(
        pattern: #"\b[\w\-]+\.(?:cpp|hpp|cc|h|c|py|txt|md|java|js|swift|json|csv|exe|out)\b"#,
        options: [.caseInsensitive])

    /// A file name the note writes in one case and the lesson in another
    /// takes the note's.
    static func restoringFileNames(in text: String, noteText: String) -> String {
        let ns = noteText as NSString
        var known: [String: String] = [:]
        for match in fileName.matches(in: noteText, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range)
            if known[name.lowercased()] == nil { known[name.lowercased()] = name }
        }
        guard !known.isEmpty else { return text }
        let source = text as NSString
        var result = text
        for match in fileName.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range)
            if let right = known[name.lowercased()], right != name,
               let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: right)
            }
        }
        return result
    }

    /// `section` with the note's code and file names restored in every
    /// place a model writes them.
    static func restoringCode(in section: OverviewSection, noteText: String) -> OverviewSection {
        var section = section
        func fix(_ text: String) -> String { restoringCode(in: text, noteText: noteText) }
        section.paragraphs = section.paragraphs.map(fix)
        section.terms = section.terms.map {
            var term = $0
            term.text = fix(term.text)
            term.example = term.example.map(fix)
            term.nonExample = term.nonExample.map(fix)
            return term
        }
        if let check = section.check {
            section.check = OverviewCheck(question: fix(check.question), answer: fix(check.answer))
        }
        if var example = section.example {
            example.title = example.title.map(fix)
            example.setup = example.setup.map(fix)
            example.outcome = example.outcome.map(fix)
            for index in example.steps.indices {
                example.steps[index].action = fix(example.steps[index].action)
                example.steps[index].result = example.steps[index].result.map(fix)
            }
            section.example = example
        }
        return section
    }

    // MARK: - Filler and repeats

    private static let announcing = try! NSRegularExpression(
        pattern: #"^(?:this|the following|the next)\s+(?:section|lesson|part|passage|example)\s+(?:will\s+)?(?:explains?|covers?|shows?|describes?|introduces?|looks?\s+at|walks?\s+through|discusses?|outlines?)\b"#,
        options: [.caseInsensitive])

    /// A paragraph that only announces what the section does says nothing.
    public static func isAnnouncement(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
        return announcing.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil
    }

    /// `sections` without announcing paragraphs (a section keeps at least
    /// one paragraph) and without a check question that repeats an earlier
    /// one, which is judged by how many of its words an earlier one shares.
    static func withoutFiller(_ sections: [OverviewSection]) -> [OverviewSection] {
        var asked: [Set<String>] = []
        return sections.map { original in
            var section = original
            let kept = section.paragraphs.filter { !isAnnouncement($0) }
            if !kept.isEmpty { section.paragraphs = kept }
            if let check = section.check {
                let mine = words(check.question)
                let repeated = asked.contains { earlier in
                    // Shared words against the shorter question, so a long
                    // restatement of a short question still counts.
                    let shared = earlier.intersection(mine).count
                    let shorter = min(earlier.count, mine.count)
                    return shared >= 6 && shorter > 0 && Double(shared) / Double(shorter) >= 0.5
                }
                if repeated { section.check = nil } else { asked.append(mine) }
            }
            return section
        }
    }
}
