import Foundation

/// Pictures a note already contains, found in its own text and drawn beside
/// the overview section that talks about them. The programming counterpart
/// of the row-reduction figure: nothing here is written by a model, so
/// nothing in it can be invented, and it costs no request. Worked out when
/// an overview is shown, not stored, so a lesson written before this
/// existed gets them too.
///
/// What is found:
/// - a pipeline: an arrow chain, "source → compile → link → run", in a code
///   block or a sentence;
/// - a table: a markdown table;
/// - annotated code: a listing whose lines carry `//` comments, shown with
///   each comment beside its line;
/// - memory boxes: the variables a listing declares, as labelled boxes.
///
/// It is the same for a slide deck's text, which arrives as plain lines.
/// A syllabus gets none: its tables are grade weights and dates, not ideas.
public struct NoteVisual: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Stages in order, left to right.
        case pipeline(stages: [String])
        case table(header: [String], rows: [[String]])
        /// Every line of the listing, with its trailing comment if it has one.
        case annotatedCode(lines: [CodeLine])
        case memory(boxes: [Box])
    }

    public struct CodeLine: Sendable, Equatable {
        public let code: String
        public let note: String?
    }

    /// A variable a listing declares. `value` is nil until the note gives one.
    public struct Box: Sendable, Equatable {
        public let type: String
        public let name: String
        public let value: String?
    }

    public let kind: Kind
    /// The note's own heading above it ("The Compilation Pipeline").
    public let title: String?
    /// Words that say what it is about, to find the section that discusses it.
    let words: Set<String>
    /// The listing it came from, so the plain code is not shown twice.
    public let sourceCode: String?

    public var id: String {
        switch kind {
        case .pipeline(let stages): return "pipeline:" + stages.joined(separator: ">")
        case .table(let header, let rows): return "table:" + header.joined(separator: "|") + "\(rows.count)"
        case .annotatedCode(let lines): return "code:" + (lines.first?.code ?? "") + "\(lines.count)"
        case .memory(let boxes): return "memory:" + boxes.map(\.name).joined(separator: ",")
        }
    }
}

public enum NoteVisuals {
    /// The most pictures one note gets: a lesson with one in every
    /// paragraph is a slideshow.
    public static let limit = 5

    // MARK: - Finding them

    public static func visuals(in raw: String, noteTitle: String? = nil) -> [NoteVisual] {
        guard !OverviewOrientation.isOrientation(noteTitle: noteTitle, noteContext: raw) else { return [] }
        var found: [NoteVisual] = []
        var heading: String?
        var lines = raw.components(separatedBy: "\n")[...]
        // Front matter is not content.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines = lines.dropFirst()
            while let line = lines.first {
                lines = lines.dropFirst()
                if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            }
        }
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var block: [String] = []
                index += 1
                while index < lines.endIndex, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    block.append(lines[index]); index += 1
                }
                index += 1
                found += fenced(block, language: language, title: heading)
                continue
            }
            if trimmed.hasPrefix("#"), let title = headingText(trimmed) { heading = title }
            if trimmed.hasPrefix("|"), let table = table(from: lines, at: index, title: heading) {
                found.append(table.visual)
                index = table.end
                continue
            }
            if let chain = pipeline(inLine: trimmed, title: heading) { found.append(chain) }
            index += 1
        }
        return Array(dedupedPipelines(found).prefix(limit))
    }

    // MARK: Headings

    private static func headingText(_ line: String) -> String? {
        let text = line.drop(while: { $0 == "#" })
        guard text.first == " " else { return nil }
        let cleaned = plain(String(text))
        // "2026-08-25 · Module 1" reads better as "Module 1".
        let undated = cleaned.replacingOccurrences(
            of: #"^\d{4}-\d{2}-\d{2}\s*[·:\-–—|]?\s*"#, with: "", options: .regularExpression)
        return undated.isEmpty ? nil : undated
    }

    /// Markdown emphasis, code ticks and links removed.
    static func plain(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`", "*"] { t = t.replacingOccurrences(of: mark, with: "") }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Pipelines

    private static let arrows: [Character] = ["\u{2192}", "\u{21D2}"]

    /// Stages of "a → b → c", or nil when it is not a chain of three or more
    /// short stages.
    static func stages(in text: String, allowingAsciiArrow: Bool = false) -> [String]? {
        var work = text
        if allowingAsciiArrow { work = work.replacingOccurrences(of: "->", with: "\u{2192}") }
        guard work.filter({ arrows.contains($0) }).count >= 2 else { return nil }
        var parts = [work]
        for arrow in arrows { parts = parts.flatMap { $0.split(separator: arrow, omittingEmptySubsequences: false).map(String.init) } }
        let cleaned = parts.map(stageLabel).filter { !$0.isEmpty }
        guard cleaned.count >= 3, cleaned.count <= 8,
              cleaned.allSatisfy({ $0.split(separator: " ").count <= 7 }) else { return nil }
        return cleaned
    }

    private static func stageLabel(_ raw: String) -> String {
        var t = plain(raw)
        // "- " or "1. " from a list, a lead-in like "Compiled language —", and a trailing full stop.
        t = t.replacingOccurrences(of: #"^(?:[-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        if let dash = t.range(of: " \u{2014} ") ?? t.range(of: " - ") { t = String(t[dash.upperBound...]) }
        t = t.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        while t.hasSuffix(".") || t.hasSuffix(",") || t.hasSuffix(";") { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func pipeline(inLine line: String, title: String?) -> NoteVisual? {
        guard let stages = stages(in: line) else { return nil }
        return NoteVisual(kind: .pipeline(stages: stages), title: title, words: words(from: stages), sourceCode: nil)
    }

    /// The same pipeline written twice (a code block and a bullet) is one
    /// picture, the one with the shorter, plainer stage names.
    private static func dedupedPipelines(_ visuals: [NoteVisual]) -> [NoteVisual] {
        var result: [NoteVisual] = []
        for visual in visuals {
            guard case .pipeline(let stages) = visual.kind else { result.append(visual); continue }
            if let existing = result.firstIndex(where: { other in
                guard case .pipeline = other.kind else { return false }
                let a = Set(other.words.map(stem)), b = Set(visual.words.map(stem))
                return Double(a.intersection(b).count) / Double(max(1, min(a.count, b.count))) >= 0.5
            }) {
                if case .pipeline(let old) = result[existing].kind, averageWords(stages) < averageWords(old) {
                    result[existing] = visual
                }
                continue
            }
            result.append(visual)
        }
        return result
    }

    /// Enough of a stem that "compile" and "compiler", "file" and "files" agree.
    private static func stem(_ word: String) -> String {
        var w = word
        if w.hasSuffix("s"), w.count > 3 { w.removeLast() }
        if w.hasSuffix("er"), w.count > 4 { w.removeLast(2) }
        if w.hasSuffix("e"), w.count > 3 { w.removeLast() }
        return w
    }

    private static func averageWords(_ stages: [String]) -> Double {
        Double(stages.map { $0.split(separator: " ").count }.reduce(0, +)) / Double(max(1, stages.count))
    }

    // MARK: Fenced blocks

    private static func fenced(_ block: [String], language: String, title: String?) -> [NoteVisual] {
        let code = block.joined(separator: "\n").trimmingCharacters(in: .newlines)
        guard !code.isEmpty else { return [] }
        let isCode = NoteCode.looksLikeCode(code, declared: !language.isEmpty && language.lowercased() != "text")
        if !isCode {
            // A plain block with an arrow chain in it: a pipeline, written line by line.
            let joined = block.joined(separator: " ")
            if let stages = stages(in: joined, allowingAsciiArrow: true) {
                return [NoteVisual(kind: .pipeline(stages: stages), title: title, words: words(from: stages), sourceCode: nil)]
            }
            return []
        }
        guard code.split(separator: "\n").count <= 40 else { return [] }
        var result: [NoteVisual] = []
        // A banner of stars is decoration, not part of the listing.
        let parsed = block.map(splitComment).filter { $0.code.range(of: #"^\s*/?\*+/?\s*$"#, options: .regularExpression) == nil }
        // Two notes in a few lines is a snippet, not a listing worth annotating.
        if parsed.filter({ $0.note != nil }).count >= 2,
           parsed.filter({ !$0.code.trimmingCharacters(in: .whitespaces).isEmpty }).count >= 5 {
            let lines = parsed.map { NoteVisual.CodeLine(code: $0.code, note: $0.note) }
            // What the comments say and what the lines name, so a section that
            // talks about `numPies` finds the listing that declares it.
            let words = Set(parsed.compactMap(\.note).flatMap { significantWords($0) })
                .union(parsed.flatMap { significantWords($0.code) }.filter { !codeKeywords.contains($0) })
            result.append(NoteVisual(kind: .annotatedCode(lines: lines), title: title, words: words, sourceCode: code))
        }
        let boxes = declarations(in: block)
        if boxes.count >= 2 {
            let words = Set(boxes.flatMap { [$0.name.lowercased(), $0.type.lowercased()] })
            result.append(NoteVisual(kind: .memory(boxes: Array(boxes.prefix(6))), title: title, words: words, sourceCode: code))
        }
        return result
    }

    /// `code // comment` into its two halves; a `//` inside a string stays code.
    static func splitComment(_ line: String) -> (code: String, note: String?) {
        var inString = false
        var previous: Character = " "
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" && previous != "\\" { inString.toggle() }
            if !inString, c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                let note = String(chars[(i + 2)...]).trimmingCharacters(in: .whitespaces)
                let code = String(chars[..<i]).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                // A comment on a line by itself is a note about what follows, not about this line.
                return (code, code.trimmingCharacters(in: .whitespaces).isEmpty || note.isEmpty ? nil : note)
            }
            previous = c
            i += 1
        }
        return (line, nil)
    }

    private static let declaration = try! NSRegularExpression(
        pattern: #"^\s*(?:const\s+)?(int|double|float|char|bool|string|long|short|unsigned(?:\s+int)?)\s+([^;(){}]+);"#)

    /// Variables declared in a listing: `int a, b = 3;` is two boxes.
    static func declarations(in block: [String]) -> [NoteVisual.Box] {
        var boxes: [NoteVisual.Box] = []
        for line in block {
            let code = splitComment(line).code
            guard let parts = StudyGuideParser.match(declaration, code), let type = parts[0], let rest = parts[1] else { continue }
            for piece in rest.split(separator: ",") {
                let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let name = pair.first, name.range(of: #"^[A-Za-z_]\w*$"#, options: .regularExpression) != nil else { continue }
                boxes.append(NoteVisual.Box(type: type, name: name, value: pair.count == 2 ? pair[1] : nil))
            }
        }
        return boxes
    }

    // MARK: Tables

    private static func table(from lines: ArraySlice<String>, at start: Int, title: String?) -> (visual: NoteVisual, end: Int)? {
        var rows: [[String]] = []
        var index = start
        while index < lines.endIndex {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { break }
            rows.append(cells(of: trimmed))
            index += 1
        }
        guard rows.count >= 3, rows[1].allSatisfy({ $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }) else { return nil }
        let header = rows[0].map(plain)
        let body = rows.dropFirst(2).map { row in row.map(plain) }.filter { !$0.allSatisfy(\.isEmpty) }
        guard header.count >= 2, header.count <= 5, !body.isEmpty, body.count <= 12,
              body.allSatisfy({ $0.count == header.count }) else { return nil }
        let words = Set(header.flatMap(significantWords)).union(body.flatMap { $0.prefix(1).flatMap(significantWords) })
        return (NoteVisual(kind: .table(header: header, rows: Array(body)), title: title, words: words, sourceCode: nil), index)
    }

    private static func cells(of row: String) -> [String] {
        var cells = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    // MARK: Words

    private static let ignored: Set<String> = ["the", "and", "for", "you", "your", "that", "this", "with", "from", "are", "not", "but",
                                               "has", "have", "was", "were", "what", "when", "into", "every", "each", "can", "will",
                                               "notes", "type", "program", "class", "code"]

    private static let codeKeywords: Set<String> = ["include", "using", "namespace", "std", "main", "return", "cout", "cin", "endl",
                                                    "int", "double", "char", "bool", "string", "void", "const", "for", "while"]

    static func significantWords(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !ignored.contains($0) }
    }

    private static func words(from stages: [String]) -> Set<String> { Set(stages.flatMap(significantWords)) }

    // MARK: - Placing them

    /// Which visuals go under which section, and which are left over. A
    /// visual goes under the section whose text uses the most of its words
    /// (at least two, or one in the heading), never one that only
    /// mentions it in passing. The rest are shown together after the lesson.
    public static func placements(of visuals: [NoteVisual], in sections: [OverviewSection])
        -> (bySection: [Int: [NoteVisual]], rest: [NoteVisual]) {
        var by: [Int: [NoteVisual]] = [:]
        var rest: [NoteVisual] = []
        for visual in visuals {
            var best: (index: Int, score: Int)?
            for (index, section) in sections.enumerated() {
                let heading = Set(significantWords(section.heading))
                var parts = section.paragraphs + section.terms.flatMap { [$0.term, $0.text] }
                if let example = section.example { parts += example.steps.flatMap { [$0.action, $0.result ?? ""] } }
                let body = Set(parts.flatMap(significantWords))
                let score = visual.words.reduce(0) { $0 + (heading.contains($1) ? 2 : (body.contains($1) ? 1 : 0)) }
                if score > (best?.score ?? 0) { best = (index, score) }
            }
            if let best, best.score >= 2, (by[best.index]?.count ?? 0) < 2 { by[best.index, default: []].append(visual) }
            else { rest.append(visual) }
        }
        return (by, rest)
    }
}
