import Foundation

/// Turns math a model wrote in plain text into something that reads like
/// math: `a11x1` becomes `a₁₁x₁`, `in R3` becomes `in ℝ³`, and -- where a
/// whole object is written out -- `(a11, a21, a31)` becomes a column vector
/// and `[a1 a2 a3 | b]` a bracketed matrix, to be drawn rather than spelled.
///
/// The prompt asks for plain text because a small model can't reliably
/// write LaTeX inside JSON, so this is where the plain text gets its
/// notation back. It only rewrites patterns it's sure of, and is only
/// applied to notes that are about math: in a business lecture "B12" is a
/// vitamin, not b sub twelve.
public enum MathNotation {
    public enum Piece: Sendable, Equatable {
        case text(String)
        /// A column vector, entries top to bottom.
        case vector([String])
        /// Rows of entries, with `bar` columns right of an augmentation bar.
        case matrix(rows: [[String]], bar: Int)
    }

    /// `text` split into prose and drawable objects, with the prose tidied.
    public static func pieces(from text: String) -> [Piece] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var objects: [(range: NSRange, piece: Piece)] = []

        for match in bracketObject.matches(in: text, range: whole) {
            if let piece = matrix(from: ns.substring(with: match.range(at: 1))) {
                objects.append((match.range, piece))
            }
        }
        for match in tupleObject.matches(in: text, range: whole)
        where !objects.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
            let entries = ns.substring(with: match.range(at: 1))
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard (2...6).contains(entries.count), entries.allSatisfy(isEntry) else { continue }
            objects.append((match.range, .vector(entries.map(prettify))))
        }
        objects.sort { $0.range.location < $1.range.location }

        var result: [Piece] = []
        var cursor = 0
        for object in objects {
            if object.range.location > cursor {
                result.append(.text(prettify(ns.substring(with: NSRange(location: cursor, length: object.range.location - cursor)))))
            }
            result.append(object.piece)
            cursor = object.range.location + object.range.length
        }
        if cursor < ns.length {
            result.append(.text(prettify(ns.substring(from: cursor))))
        }
        return result.filter { if case .text(let t) = $0 { return !t.isEmpty } else { return true } }
    }

    /// True when `pieces(from:)` would draw something rather than just
    /// retype it.
    public static func hasObjects(_ text: String) -> Bool {
        pieces(from: text).contains { if case .text = $0 { return false } else { return true } }
    }

    // MARK: - Prose

    /// Subscripts, superscripts, ℝⁿ and arrows, in running text.
    public static func prettify(_ text: String) -> String {
        var result = text
        // Arrows and comparisons first, so `->` isn't read as a minus.
        for (ascii, symbol) in [("<->", "↔"), ("->", "→"), ("<=", "≤"), (">=", "≥"), ("!=", "≠")] {
            result = result.replacingOccurrences(of: ascii, with: symbol)
        }
        result = replace(realSpace, in: result) { groups in "ℝ" + superscript(groups[1]) }
        result = replace(dimensions, in: result) { groups in "\(groups[1])×\(groups[2])" }
        result = replace(power, in: result) { groups in groups[1] + superscript(groups[2]) }
        result = replace(indexed, in: result) { groups in groups[1] + subscriptText(groups[2] + groups[3]) }
        // "x sub three": a model spelling notation out in words.
        result = replace(spelledIndex, in: result) { groups in
            groups[1] + subscriptText(spelledNumbers[groups[2].lowercased()] ?? groups[2])
        }
        return result
    }

    /// `R3`, `R^3`, `R^n` after "in"/"of"/"to" -- real space, not row 3.
    private static let realSpace = try! NSRegularExpression(
        pattern: #"(?<=\b(?:in|of|to|from|into|onto) )R\^?(\d|n|m)\b"#
    )
    /// `3x3`, `2 x 4` -- matrix dimensions.
    private static let dimensions = try! NSRegularExpression(pattern: #"\b(\d)\s?x\s?(\d)\b"#)
    /// `x^2`, `A^T`, `A^-1`.
    private static let power = try! NSRegularExpression(pattern: #"([A-Za-z0-9)])\^\{?(-?\d+|n|T)\}?"#)
    /// A single letter followed by an index: `a11`, `x1`, `x_2`, `b_{3}`.
    /// Not inside a word -- `word2vec`, `mp3` and `Python3` stay as they are.
    /// Letter indices need the underscore: bare `in`, `am`, `an` are words.
    private static let indexed = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])([A-Za-z])(?:_\{?(\d{1,2}|[ijkmn]{1,2})\}?|(\d{1,2}))(?![0-9])(?![A-Za-z]{2})"#
    )

    private static let spelledIndex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])([A-Za-z]) sub (\d{1,2}|one|two|three|four|five|six|seven|eight|nine|i|j|k|n)\b"#,
        options: [.caseInsensitive]
    )
    private static let spelledNumbers = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    private static func replace(_ regex: NSRegularExpression, in text: String, _ transform: ([String]) -> String) -> String {
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(groups))
        }
        return result
    }

    public static func subscriptText(_ text: String) -> String {
        let map: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "m": "ₘ", "n": "ₙ",
        ]
        return String(text.map { map[$0] ?? $0 })
    }

    static func superscript(_ text: String) -> String {
        let map: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "-": "⁻", "n": "ⁿ", "m": "ᵐ", "T": "ᵀ",
        ]
        return String(text.map { map[$0] ?? $0 })
    }

    // MARK: - Objects

    /// `[ ... ]` -- a matrix or a row, rows separated by `;`.
    private static let bracketObject = try! NSRegularExpression(pattern: #"\[([^\[\]]{2,120})\]"#)
    /// `( ... )` with commas -- a vector.
    private static let tupleObject = try! NSRegularExpression(pattern: #"\(([^()]{3,80})\)"#)

    /// One entry of a vector or matrix: a number, fraction, or short symbol
    /// like `a11`, `x_2`, `-b`, `...`. Anything wordier means the brackets
    /// held prose -- "(see p. 28)" -- and nothing is drawn.
    static func isEntry(_ raw: String) -> Bool {
        let entry = raw.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty, entry.count <= 8 else { return false }
        if entry == "..." || entry == "…" || entry == "*" { return true }
        return entry.range(of: #"^[+\-−–]?(?:\d+(?:\.\d+)?(?:/\d+)?|[A-Za-z](?:_?\{?\d{1,2}\}?|_?[ijkmn]{1,2})?|\d*[A-Za-z]\d{0,2})$"#,
                           options: .regularExpression) != nil
    }

    private static func matrix(from content: String) -> Piece? {
        let rowTexts = content.split(separator: ";").map(String.init)
        var rows: [[String]] = []
        var bar: Int?
        for rowText in rowTexts {
            let halves = rowText.split(separator: "|", omittingEmptySubsequences: false)
            guard halves.count <= 2 else { return nil }
            let split = { (s: Substring) in s.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init) }
            let left = split(halves[0])
            let right = halves.count == 2 ? split(halves[1]) : []
            let row = left + right
            guard !row.isEmpty, row.allSatisfy(isEntry) else { return nil }
            if let bar, bar != right.count { return nil }
            bar = right.count
            rows.append(row.map(prettify))
        }
        guard let width = rows.first?.count, rows.allSatisfy({ $0.count == width }),
              rows.count * width >= 2, rows.count <= 6, width <= 8
        else { return nil }
        return .matrix(rows: rows, bar: bar ?? 0)
    }
}

/// Decides whether a step's picture can be drawn honestly.
public enum StepVisuals {
    /// A cleaned copy of `visual`, or nil. Matrices and vectors only count
    /// in a math note, and their numbers must be the note's own -- a
    /// picture of numbers the model made up is worse than no picture.
    public static func validate(_ visual: OverviewStepVisual, noteText: String, isMath: Bool) -> OverviewStepVisual? {
        var cleaned = visual
        cleaned.caption = visual.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.caption?.isEmpty == true { cleaned.caption = nil }
        let available = NoteMath.numbers(in: noteText)
        func grounded(_ value: Double) -> Bool {
            let magnitude = abs(value)
            return magnitude < 1e-9 || abs(magnitude - 1) < 1e-9 || available.contains { abs($0 - magnitude) < 1e-9 }
        }

        switch visual.kind {
        case .matrix:
            guard isMath, let rows = visual.rows?.map({ $0.map { $0.trimmingCharacters(in: .whitespaces) } }),
                  (1...6).contains(rows.count), let width = rows.first?.count, (1...8).contains(width),
                  rows.allSatisfy({ $0.count == width }), rows.count * width >= 2,
                  rows.joined().allSatisfy(MathNotation.isEntry)
            else { return nil }
            let numbers = rows.joined().compactMap { NoteMatrices.rational($0)?.doubleValue }
            guard numbers.allSatisfy(grounded) else { return nil }
            cleaned.rows = rows
            cleaned.bar = visual.bar.flatMap { (1..<width).contains($0) ? $0 : nil }
            cleaned.highlightRows = visual.highlightRows?.filter { rows.indices.contains($0) }
            cleaned.highlightColumns = visual.highlightColumns?.filter { (0..<width).contains($0) }
            cleaned.vectors = nil
            cleaned.nodes = nil
            return cleaned

        case .vectors:
            guard isMath, let vectors = visual.vectors, (1...4).contains(vectors.count),
                  vectors.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 12 && abs($0.y) <= 12 }),
                  vectors.contains(where: { abs($0.x) > 1e-9 || abs($0.y) > 1e-9 }),
                  vectors.allSatisfy({ grounded($0.x) && grounded($0.y) && ($0.weight.map(grounded) ?? true) }),
                  vectors.allSatisfy({ ($0.weight.map { abs($0) <= 6 } ?? true) })
            else { return nil }
            cleaned.vectors = vectors.map { vector in
                var copy = vector
                copy.label = vector.label.map { MathNotation.prettify(String($0.prefix(8))) }
                return copy
            }
            cleaned.rows = nil
            cleaned.nodes = nil
            return cleaned

        case .flow:
            let nodes = (visual.nodes ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard (2...6).contains(nodes.count), nodes.allSatisfy({ $0.count <= 48 }) else { return nil }
            cleaned.nodes = nodes
            cleaned.highlight = visual.highlight.flatMap { nodes.indices.contains($0) ? $0 : nil }
            cleaned.rows = nil
            cleaned.vectors = nil
            return cleaned
        }
    }
}
