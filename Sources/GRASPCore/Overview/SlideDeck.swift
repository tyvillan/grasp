import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// A lecture's slide deck, saved beside its note as `STEM.slides.pdf` (a
/// second deck as `STEM.slides-2.pdf`). The deck is not a note: its text is
/// the instructor's outline, and its pages are the pictures. So a scan does
/// not import it, an overview writer reads its slide titles as an outline,
/// and the reader shows the slide that matches each section.
public enum SlideDeck {
    static let extensions: Set<String> = ["pdf", "pptx", "ppt", "key"]

    /// Whether a file name is a lecture's deck: "...slides.pdf", "...slides-2.pdf".
    public static func isDeckFile(_ fileName: String) -> Bool {
        let name = fileName as NSString
        guard extensions.contains(name.pathExtension.lowercased()) else { return false }
        let stem = name.deletingPathExtension.lowercased()
        return stem.hasSuffix(".slides") || stem.range(of: #"\.slides-\d+$"#, options: .regularExpression) != nil
    }

    /// Where a note's decks would be: the note's own name, then `.slides.pdf`.
    public static func candidatePaths(forNote notePath: String) -> [String] {
        let stem = (notePath as NSString).deletingPathExtension
        return [".slides.pdf", ".slides-2.pdf", ".slides-3.pdf"].map { stem + $0 }
    }

    /// The decks that exist, in order. Empty for a note with none.
    public static func existingDecks(forNote notePath: String) -> [String] {
        candidatePaths(forNote: notePath).filter { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Slides

    public struct Slide: Sendable, Equatable, Identifiable {
        /// 1-based page number in its deck.
        public let page: Int
        /// The first line of the slide, read as its title.
        public let title: String
        public let text: String
        public var id: Int { page }
    }

    /// Titles the outline leaves out: they head a slide, not an idea.
    private static let skippedTitles: Set<String> = ["references", "questions", "questions?", "thank you", "agenda", "outline",
                                                    "objectives", "summary", "review", "contents", "table of contents"]

    /// Each page as a slide, skipping the ones with nothing to match or say.
    public static func slides(from pages: [String]) -> [Slide] {
        pages.enumerated().compactMap { index, text in
            let lines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = lines.first, looksLikeTitle(first) else { return nil }
            let title = readable(first)
            let body = lines.dropFirst().joined(separator: " ")
            // A title page or a divider ("REFERENCES") has no idea on it.
            guard body.split(whereSeparator: \.isWhitespace).count >= 4,
                  !skippedTitles.contains(title.lowercased()) else { return nil }
            return Slide(page: index + 1, title: title, text: body)
        }
    }

    /// A slide's first line is its title when it is short and starts a
    /// phrase. A slide with no title line begins mid-sentence ("unable to
    /// meet the deadline"), and a deck exported with letter-spacing reads
    /// "Va r i a b l e s": neither can be matched or listed, so neither is.
    static func looksLikeTitle(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: \.isWhitespace)
        guard (1...9).contains(tokens.count), let first = line.first, first.isUppercase || first.isNumber else { return false }
        if line.hasSuffix(",") || line.hasSuffix(";") { return false }
        return tokens.filter { $0.count == 1 && $0.first?.isLetter == true }.count < 3
    }

    /// "ARRAY INDEXED VARIABLES" read as "Array indexed variables".
    static func readable(_ title: String) -> String {
        let letters = title.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy(\.isUppercase), letters.count > 3 else { return title }
        let lower = title.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    #if canImport(PDFKit)
    /// The pages of a deck's text, one entry per page. Only the text layer:
    /// a slide with none is skipped rather than read by OCR, which would
    /// make opening a lesson wait on it.
    public static func pages(ofDeckAt path: String) -> [String] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }
    #endif

    // MARK: - For the overview writer

    /// The deck's slide titles, in order, as one block to put after the
    /// note's text: the instructor's own outline of the lecture. nil when
    /// there are too few to say anything.
    public static func outline(of slides: [Slide], limit: Int = 40) -> String? {
        var titles: [String] = []
        for slide in slides where titles.last?.lowercased() != slide.title.lowercased() {
            if slide.title.split(separator: " ").count <= 10 { titles.append(slide.title) }
        }
        guard titles.count >= 3 else { return nil }
        return outlineMarker + "\n" + titles.prefix(limit).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// Starts the outline block, so a prompt can tell it is there.
    public static let outlineMarker = "The lecture's slide titles, in the order the instructor showed them:"

    // MARK: - For the reader

    /// Which slides go beside which section: a slide goes with the section
    /// whose heading or text uses its title's words and most of its own.
    /// Each slide is shown once, at most three to a section, and a section
    /// that merely mentions a slide's topic gets nothing.
    public static func placements(of slides: [Slide], in sections: [OverviewSection]) -> [Int: [Slide]] {
        guard !slides.isEmpty, !sections.isEmpty else { return [:] }
        let sectionWords: [(heading: Set<String>, body: Set<String>)] = sections.map { section in
            var parts = section.paragraphs + section.terms.flatMap { [$0.term, $0.text, $0.example ?? ""] }
            if let example = section.example { parts += [example.title ?? ""] + example.steps.flatMap { [$0.action, $0.result ?? ""] } }
            return (Set(NoteVisuals.significantWords(section.heading).map(NoteVisuals.stem)),
                    Set(parts.flatMap(NoteVisuals.significantWords).map(NoteVisuals.stem)))
        }
        var scored: [(slide: Int, section: Int, score: Int)] = []
        for (s, slide) in slides.enumerated() {
            let title = Set(NoteVisuals.significantWords(slide.title).map(NoteVisuals.stem))
            let body = Set(NoteVisuals.significantWords(slide.text).map(NoteVisuals.stem)).subtracting(title)
            for (n, words) in sectionWords.enumerated() {
                let headingHits = title.filter { words.heading.contains($0) }.count
                let bodyHits = title.filter { words.body.contains($0) && !words.heading.contains($0) }.count
                // The section's own heading names the slide's topic, or its
                // text uses two of the title's words: one passing word is
                // not enough ("struct" in a section about streams).
                guard headingHits >= 1 || bodyHits >= 2 else { continue }
                let bodyScore = min(6, body.filter { words.heading.contains($0) || words.body.contains($0) }.count)
                let score = headingHits * 4 + bodyHits * 2 + bodyScore
                if score >= 5 { scored.append((s, n, score)) }
            }
        }
        var used: Set<Int> = []
        var result: [Int: [Slide]] = [:]
        for entry in scored.sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.slide < $1.slide })
        where !used.contains(entry.slide) && (result[entry.section]?.count ?? 0) < 3 {
            result[entry.section, default: []].append(slides[entry.slide])
            used.insert(entry.slide)
        }
        return result.mapValues { $0.sorted { $0.page < $1.page } }
    }
}
