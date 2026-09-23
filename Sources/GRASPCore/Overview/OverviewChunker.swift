import Foundation

/// Cuts a note into pieces small enough for a generator to summarise in
/// one call.
///
/// Every other prompt in this codebase caps its context with a bare
/// `String.prefix(n)`, and for those it is the right call: a per-card
/// refinement that sees 2,000 of a note's 5,000 characters produces a
/// slightly worse card. A *whole-note overview* that sees the same 2,000
/// produces an overview of the first third of a lecture, presented as an
/// overview of the lecture -- a confidently wrong artifact with nothing on
/// screen to indicate it. That is a different class of defect, which is why
/// this is the one place the truncation convention is broken rather than
/// followed.
///
/// Nothing here ever cuts mid-sentence. Sections are preferred, then
/// paragraphs, then sentence boundaries, and a chunk that would still be
/// over budget is left over budget rather than split somewhere that would
/// hand the model half a thought.
public enum OverviewChunker {
    /// Below this a note is its own overview. `isStudyWorthy` already
    /// requires 30 words; between 30 and 60 the takeaways would just be the
    /// note restated, which is worse than nothing because it looks like the
    /// feature ran and found this little.
    public static let minimumWords = 60

    /// Above this, one lecture's notes have become reference material and
    /// an overview stops being a study aid. Deliberately NOT reusing
    /// `VaultScanner`'s 8,000-word card-generation cap: that number was
    /// tuned for a different failure (a textbook yields table-of-contents
    /// "definitions"), and a long document is exactly where an overview is
    /// most useful, so it earns a higher ceiling. Past 12,000 words -- ten
    /// sequential local-model calls, one to two minutes -- the wall-clock
    /// cost alone makes it a bad interaction, not merely an expensive one.
    public static let maximumWords = 12_000

    /// Never more than this many calls for one note, whatever the heading
    /// distribution does. 12,000 words at a 1,200-word budget is ten; the
    /// slack absorbs a note whose sections pack badly.
    public static let maximumChunks = 12

    /// LaTeX inflates tokens per word badly, and words are the only proxy
    /// available -- there is no tokenizer anywhere in this codebase and
    /// adding one for this isn't worth a dependency.
    public static let mathBudgetFactor = 0.75

    public enum Plan: Sendable, Equatable {
        case tooShort(wordCount: Int)
        case tooLong(wordCount: Int)
        /// One chunk per element, in document order. A single-element array
        /// is the ordinary short-note case -- there is no separate "whole
        /// note" path to keep in sync with this one.
        case chunks([Chunk])
    }

    public struct Chunk: Sendable, Equatable {
        public let text: String
        /// The heading this chunk opens under, when it had one. Becomes the
        /// merged outline's part title, so a long note's outline reads as
        /// its own structure rather than "Part 1, Part 2".
        public let heading: String?
        public let wordCount: Int

        public init(text: String, heading: String?, wordCount: Int) {
            self.text = text
            self.heading = heading
            self.wordCount = wordCount
        }
    }

    /// `wordBudget` comes from the generator, so the same note is cut
    /// differently for a local 7B than for Apple's on-device model.
    public static func plan(
        reflowed: String, wordCount: Int, hasMath: Bool, wordBudget: Int
    ) -> Plan {
        if wordCount < minimumWords { return .tooShort(wordCount: wordCount) }
        if wordCount > maximumWords { return .tooLong(wordCount: wordCount) }

        let budget = max(1, hasMath ? Int(Double(wordBudget) * mathBudgetFactor) : wordBudget)
        if wordCount <= budget {
            // The whole note, byte for byte. No truncation on this path,
            // which is the common one.
            return .chunks([Chunk(text: reflowed, heading: nil, wordCount: wordCount)])
        }

        let sections = split(intoSections: reflowed)
        var chunks = pack(sections, budget: budget)
        chunks = collapse(chunks, toAtMost: maximumChunks)
        return .chunks(chunks)
    }

    // MARK: - Sectioning

    private struct Section {
        var heading: String?
        var lines: [String]

        var text: String { lines.joined(separator: "\n") }
        var wordCount: Int { OverviewChunker.words(in: text) }
    }

    /// Splits on markdown headings, which survive `Reflow` untouched --
    /// `Reflow.isStructuralLine` stops a `#` line from being joined into the
    /// paragraph above it, so the reflowed text the rest of the pipeline
    /// already uses is directly chunkable. A note with no headings (most
    /// PDF- and pptx-derived text) comes back as one section and falls
    /// through to paragraph packing.
    private static func split(intoSections text: String) -> [Section] {
        var sections: [Section] = []
        var current = Section(heading: nil, lines: [])

        for line in text.components(separatedBy: "\n") {
            if let heading = headingText(line) {
                if !current.lines.isEmpty || current.heading != nil {
                    sections.append(current)
                }
                current = Section(heading: heading, lines: [line])
            } else {
                current.lines.append(line)
            }
        }
        if !current.lines.isEmpty || current.heading != nil { sections.append(current) }
        return sections.isEmpty ? [Section(heading: nil, lines: [text])] : sections
    }

    private static func headingText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        // `#tag` is not a heading. ATX requires whitespace after the hashes.
        guard let first = rest.first, first == " " || first == "\t" else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    // MARK: - Packing

    /// Greedily fills chunks with whole sections. A section too big on its
    /// own is broken down further rather than truncated.
    private static func pack(_ sections: [Section], budget: Int) -> [Chunk] {
        var chunks: [Chunk] = []
        var pendingLines: [String] = []
        var pendingHeading: String?
        var pendingWords = 0

        func flush() {
            guard !pendingLines.isEmpty else { return }
            let text = pendingLines.joined(separator: "\n")
            chunks.append(Chunk(text: text, heading: pendingHeading, wordCount: pendingWords))
            pendingLines = []
            pendingHeading = nil
            pendingWords = 0
        }

        for section in sections {
            let sectionWords = section.wordCount
            if sectionWords > budget {
                flush()
                for piece in split(section.text, budget: budget) {
                    chunks.append(
                        Chunk(text: piece, heading: section.heading, wordCount: words(in: piece))
                    )
                }
                continue
            }
            if pendingWords + sectionWords > budget { flush() }
            if pendingLines.isEmpty { pendingHeading = section.heading }
            pendingLines.append(contentsOf: section.lines)
            pendingWords += sectionWords
        }
        flush()
        return chunks.isEmpty ? [] : chunks
    }

    /// Paragraph boundaries first (blank lines, which `Reflow` preserves),
    /// then sentence boundaries inside a paragraph that is itself over
    /// budget. A single sentence longer than the budget is emitted whole --
    /// there is no boundary below a sentence worth cutting at.
    private static func split(_ text: String, budget: Int) -> [String] {
        var pieces: [String] = []
        var pending: [String] = []
        var pendingWords = 0

        func flush() {
            guard !pending.isEmpty else { return }
            pieces.append(pending.joined(separator: "\n\n"))
            pending = []
            pendingWords = 0
        }

        for paragraph in paragraphs(of: text) {
            let count = words(in: paragraph)
            if count > budget {
                flush()
                pieces.append(contentsOf: splitIntoSentenceGroups(paragraph, budget: budget))
                continue
            }
            if pendingWords + count > budget { flush() }
            pending.append(paragraph)
            pendingWords += count
        }
        flush()
        return pieces
    }

    private static func paragraphs(of text: String) -> [String] {
        var result: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current.joined(separator: "\n")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
        return result
    }

    private static func splitIntoSentenceGroups(_ text: String, budget: Int) -> [String] {
        var groups: [String] = []
        var pending: [String] = []
        var pendingWords = 0

        for sentence in sentences(of: text) {
            let count = words(in: sentence)
            if pendingWords + count > budget, !pending.isEmpty {
                groups.append(pending.joined(separator: " "))
                pending = []
                pendingWords = 0
            }
            pending.append(sentence)
            pendingWords += count
        }
        if !pending.isEmpty { groups.append(pending.joined(separator: " ")) }
        return groups
    }

    /// Ends a sentence at `.`, `?` or `!` followed by whitespace and a
    /// character that can open one. Abbreviations ("Fig. 3", "e.g.") slip
    /// through as one longer sentence, which is the harmless direction to
    /// be wrong in -- the cost is a slightly larger chunk, never a cut in
    /// the middle of a thought.
    static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            current.append(character)
            if character == "." || character == "?" || character == "!" {
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead] == "\"" || characters[lookahead] == ")" {
                    current.append(characters[lookahead])
                    lookahead += 1
                }
                if lookahead < characters.count, characters[lookahead].isWhitespace {
                    var scan = lookahead
                    while scan < characters.count, characters[scan].isWhitespace { scan += 1 }
                    let opener = scan < characters.count ? characters[scan] : nil
                    let opensSentence = opener.map { $0.isUppercase || $0.isNumber } ?? true
                    if opensSentence {
                        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { result.append(trimmed) }
                        current = ""
                    }
                }
                index = lookahead
                continue
            }
            index += 1
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    // MARK: - Collapsing

    /// Merges the smallest adjacent pair until the count fits. Merging
    /// rather than dropping: a slightly over-budget chunk degrades
    /// gracefully, where a dropped chunk silently loses a third of the
    /// lecture with nothing to show for it.
    private static func collapse(_ chunks: [Chunk], toAtMost limit: Int) -> [Chunk] {
        var result = chunks
        while result.count > limit {
            var smallestIndex = 0
            var smallestTotal = Int.max
            for index in 0..<(result.count - 1) {
                let total = result[index].wordCount + result[index + 1].wordCount
                if total < smallestTotal {
                    smallestTotal = total
                    smallestIndex = index
                }
            }
            let first = result[smallestIndex]
            let second = result[smallestIndex + 1]
            result[smallestIndex] = Chunk(
                text: first.text + "\n\n" + second.text,
                heading: first.heading ?? second.heading,
                wordCount: first.wordCount + second.wordCount
            )
            result.remove(at: smallestIndex + 1)
        }
        return result
    }

    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
