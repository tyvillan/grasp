import Foundation

/// Reads the matrices a note writes out -- any size -- and the row
/// operations it states, and turns them into row-reduction walkthroughs.
///
/// The general form of what `NoteMath` does for two-equation systems. A
/// lecture that works an example writes the starting matrix, names each
/// operation ("R₃ → R₃ + R₁"), and usually writes the result. Prose about
/// that ("notice R3 -> R3 + R1 turns the bottom -1 into a zero") is
/// unreadable without the matrices in front of you, so the overview shows
/// them: every intermediate state computed exactly here, never taken from a
/// model, and checked against the result the note itself wrote down.
public enum NoteMatrices {
    public struct Found: Sendable, Equatable {
        public let matrix: RationalMatrix
        /// UTF-16 offsets into the note, for ordering and for finding the
        /// operations written between one matrix and the next.
        public let start: Int
        public let end: Int
    }

    public struct FoundOperation: Sendable, Equatable {
        public let operation: RowOperation
        public let offset: Int
    }

    /// One worked example, ready to draw.
    public struct Walkthrough: Sendable, Equatable {
        public let start: RationalMatrix
        public let steps: [RowOperation]
        /// The operations are the note's own, not computed here.
        public let stepsFromNote: Bool
        /// Applying the note's operations reproduces the result the note
        /// wrote down -- the strongest possible grounding.
        public let matchesNoteResult: Bool
        public let offset: Int
    }

    // MARK: - Matrices

    /// Numbers as notes write them: `-7`, `−3`, `0.5`, `1/2`.
    private static let numberPattern = #"[+\-−–]?\d+(?:\.\d+)?(?:/\d+)?"#

    /// `[ 1  -7   0   6 |  5 ]` -- one bracketed row, whitespace- or
    /// comma-separated, with an optional augmentation bar.
    private static let bracketRow = try! NSRegularExpression(
        pattern: #"\[\s*((?:"# + numberPattern + #"[\s,]+)*"# + numberPattern + #")\s*(?:\|\s*((?:"# + numberPattern + #"[\s,]+)*"# + numberPattern + #"))?\s*\]"#
    )

    /// `\begin{bmatrix} 1 & 2 \\ 3 & 4 \end{bmatrix}`, pmatrix, or an array
    /// with a column spec like `{ccc|c}` for the bar.
    private static let latexMatrix = try! NSRegularExpression(
        pattern: #"\\begin\{(bmatrix|pmatrix|matrix|vmatrix|array)\}(\{[^}]*\})?(.*?)\\end\{\1\}"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Every matrix of at least two rows in `text`, in order.
    public static func matrices(in text: String) -> [Found] {
        (bracketMatrices(in: text) + latexMatrices(in: text)).sorted { $0.start < $1.start }
    }

    private static func bracketMatrices(in text: String) -> [Found] {
        let ns = text as NSString
        let matches = bracketRow.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result: [Found] = []
        var group: [(values: [Rational], bar: Int, range: NSRange)] = []

        func flush() {
            defer { group = [] }
            guard group.count >= 2, let width = group.first?.values.count,
                  group.allSatisfy({ $0.values.count == width && $0.bar == group[0].bar }),
                  let matrix = RationalMatrix(rows: group.map(\.values), augmentedColumns: group[0].bar),
                  let first = group.first, let last = group.last
            else { return }
            result.append(Found(matrix: matrix, start: first.range.location,
                                end: last.range.location + last.range.length))
        }

        for match in matches {
            let left = values(ns.substring(with: match.range(at: 1)))
            let right = match.range(at: 2).location == NSNotFound ? [] : values(ns.substring(with: match.range(at: 2)))
            guard let left, let right else { flush(); continue }
            let row = (values: left + right, bar: right.count, range: match.range)
            // Rows belong to one matrix when only whitespace (a line break,
            // code-fence indentation) separates them.
            if let previous = group.last {
                let gapStart = previous.range.location + previous.range.length
                let gap = ns.substring(with: NSRange(location: gapStart, length: max(0, match.range.location - gapStart)))
                if gap.count > 24 || gap.contains(where: { !$0.isWhitespace }) { flush() }
            }
            group.append(row)
        }
        flush()
        return result
    }

    private static func latexMatrices(in text: String) -> [Found] {
        let ns = text as NSString
        return latexMatrix.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let spec = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            let body = ns.substring(with: match.range(at: 3))
            let lines = body.components(separatedBy: #"\\"#)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != #"\hline"# }
            var rows: [[Rational]] = []
            for line in lines {
                let cells = line.replacingOccurrences(of: #"\hline"#, with: "")
                    .split(separator: "&").map { $0.trimmingCharacters(in: .whitespaces) }
                var row: [Rational] = []
                for cell in cells {
                    guard let value = rational(cell.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                        .replacingOccurrences(of: #"\frac"#, with: "")) else { return nil }
                    row.append(value)
                }
                rows.append(row)
            }
            guard rows.count >= 2 else { return nil }
            // `{ccc|c}`: columns after the bar are augmented.
            let bar = spec.contains("|") ? spec.split(separator: "|").last.map { $0.filter { "lcr".contains($0) }.count } ?? 0 : 0
            guard let matrix = RationalMatrix(rows: rows, augmentedColumns: bar) else { return nil }
            return Found(matrix: matrix, start: match.range.location, end: match.range.location + match.range.length)
        }
    }

    private static func values(_ raw: String) -> [Rational]? {
        let tokens = raw.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        var result: [Rational] = []
        for token in tokens {
            guard let value = rational(String(token)) else { return nil }
            result.append(value)
        }
        return result.isEmpty ? nil : result
    }

    static func rational(_ raw: String) -> Rational? {
        let cleaned = raw.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "+", with: "")
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: "/")
        if parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]) { return Rational(n, d) }
        if let whole = Int(cleaned) { return Rational(whole) }
        if let decimal = Double(cleaned) { return Rational(approximating: decimal) }
        return nil
    }

    // MARK: - Row operations

    /// A row name: `R3`, `R₃`, `R_3`, `R_{3}`.
    private static let row = #"R_?\{?([1-9])\}?"#
    private static let arrow = #"\s*(?:→|->|=>|⟶|\\to|\\rightarrow|:=|=|←|<-|\\leftarrow)\s*"#
    private static let coefficient = #"\(?\s*([+\-−–]?\s*\d+(?:\.\d+)?(?:\s*/\s*\d+)?)?\s*\)?\s*(?:·|\*|⋅|\\cdot|×)?\s*"#

    private static let swapPattern = try! NSRegularExpression(
        pattern: row + #"\s*(?:↔|<->|<=>|⟷|⇄|\\leftrightarrow|\\longleftrightarrow)\s*"# + row
    )
    /// `R3 -> R3 + 4R2`, `R₂ → R₂ − 2·R₁`, `R3 = R3 - (1/2)R1`.
    private static let replacePattern = try! NSRegularExpression(
        pattern: row + arrow + row + #"\s*([+\-−–])\s*"# + coefficient + row
    )
    /// `R2 -> 1/2 R2`, `R₁ → (1/3)R₁`, `R2 -> -R2`.
    private static let scalePattern = try! NSRegularExpression(
        pattern: row + arrow + #"\(?\s*([+\-−–]?\s*\d*(?:\.\d+)?(?:\s*/\s*\d+)?)\s*\)?\s*(?:·|\*|⋅|\\cdot|×)?\s*"# + row + #"(?!\s*[+\-−–]\s*\(?\s*\d*\s*\)?\s*(?:·|\*|⋅)?\s*R)"#
    )

    /// Every row operation the note states, in order.
    public static func operations(in text: String) -> [FoundOperation] {
        // Subscript digits to plain ones, so one pattern reads both.
        let subscripts: [Character: Character] = [
            "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4",
            "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9",
        ]
        // Same length per character in UTF-16, so offsets still line up
        // with the matrices found in the original text.
        let normalized = String(text.map { subscripts[$0] ?? $0 })
        let ns = normalized as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var found: [FoundOperation] = []
        var claimed: [NSRange] = []

        for match in replacePattern.matches(in: normalized, range: whole) {
            guard let target = Int(ns.substring(with: match.range(at: 1))),
                  let same = Int(ns.substring(with: match.range(at: 2))), same == target,
                  let source = Int(ns.substring(with: match.range(at: 5))), source != target
            else { continue }
            let sign = ns.substring(with: match.range(at: 3))
            let magnitudeText = match.range(at: 4).location == NSNotFound ? "" : ns.substring(with: match.range(at: 4))
            let magnitude = magnitudeText.trimmingCharacters(in: .whitespaces).isEmpty ? Rational.one : rational(magnitudeText)
            guard let magnitude else { continue }
            let negative = ["-", "−", "–"].contains(sign.trimmingCharacters(in: .whitespaces))
            let k = negative ? magnitude.negated : magnitude
            found.append(FoundOperation(
                operation: RowOperation(kind: .replace, target: target, source: source, exact: k),
                offset: match.range.location
            ))
            claimed.append(match.range)
        }
        for match in swapPattern.matches(in: normalized, range: whole) {
            guard let a = Int(ns.substring(with: match.range(at: 1))),
                  let b = Int(ns.substring(with: match.range(at: 2))), a != b else { continue }
            found.append(FoundOperation(operation: RowOperation(kind: .swap, target: a, source: b), offset: match.range.location))
            claimed.append(match.range)
        }
        for match in scalePattern.matches(in: normalized, range: whole) {
            guard !claimed.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let target = Int(ns.substring(with: match.range(at: 1))),
                  let same = Int(ns.substring(with: match.range(at: 3))), same == target
            else { continue }
            let raw = ns.substring(with: match.range(at: 2)).replacingOccurrences(of: " ", with: "")
            let k: Rational?
            switch raw {
            case "", "+": k = nil          // R2 -> R2 is not an operation
            case "-", "−", "–": k = Rational(-1)
            default: k = rational(raw)
            }
            guard let k, !k.isZero, k != .one else { continue }
            found.append(FoundOperation(operation: RowOperation(kind: .scale, target: target, exact: k),
                                        offset: match.range.location))
        }
        return found.sorted { $0.offset < $1.offset }
    }

    // MARK: - Walkthroughs

    /// How far past the last matrix to look for the operations applied to
    /// it, when no later matrix bounds them.
    private static let trailingWindow = 1_200

    /// Row-reduction examples worth drawing, best first.
    ///
    /// Each matrix the note writes is a possible start. The operations
    /// stated after it are applied in order; when the note also wrote the
    /// resulting matrix, it's checked against what the operations really
    /// produce, and the chain carries on through it. A matrix with no
    /// operations after it gets computed elimination steps instead -- unless
    /// it's already fully reduced, in which case it's a result, not an
    /// example. 2x3 augmented systems are left to the lines figure, which
    /// shows them better.
    public static func walkthroughs(in text: String) -> [Walkthrough] {
        let found = matrices(in: text)
        guard !found.isEmpty else { return [] }
        let operations = operations(in: text)
        var consumed: Set<Int> = []
        var result: [Walkthrough] = []

        for (index, candidate) in found.enumerated() where !consumed.contains(index) {
            let start = candidate.matrix
            guard start.rowCount >= 2, start.columnCount >= 3, !start.isZero,
                  !(start.rowCount == 2 && start.columnCount == 3 && start.augmentedColumns == 1)
            else { continue }

            var current = start
            var steps: [RowOperation] = []
            var matched = false
            var cursor = candidate.end
            var nextIndex = index + 1
            while true {
                let bound = nextIndex < found.count ? found[nextIndex].start : cursor + trailingWindow
                let between = operations.filter { $0.offset >= cursor && $0.offset < bound }
                var applied = false
                for op in between {
                    guard let next = current.applying(op.operation) else { continue }
                    current = next
                    steps.append(op.operation)
                    applied = true
                }
                guard applied, nextIndex < found.count else { break }
                // The note wrote the matrix these operations lead to.
                if found[nextIndex].matrix.rows == current.rows {
                    matched = true
                    consumed.insert(nextIndex)
                    cursor = found[nextIndex].end
                    nextIndex += 1
                } else {
                    break
                }
            }

            if !steps.isEmpty {
                result.append(Walkthrough(start: start, steps: Array(steps.prefix(12)), stepsFromNote: true,
                                          matchesNoteResult: matched, offset: candidate.start))
            } else if !start.isReducedEchelon {
                let computed = start.reducedEchelonSteps()
                guard !computed.isEmpty else { continue }
                result.append(Walkthrough(start: start, steps: computed, stepsFromNote: false,
                                          matchesNoteResult: false, offset: candidate.start))
            }
        }
        // The note's own verified example first, then the note's own steps,
        // then computed ones; earlier in the note breaks ties.
        return result.sorted {
            let rank: (Walkthrough) -> Int = { $0.matchesNoteResult ? 0 : $0.stepsFromNote ? 1 : 2 }
            return rank($0) != rank($1) ? rank($0) < rank($1) : $0.offset < $1.offset
        }
    }
}
