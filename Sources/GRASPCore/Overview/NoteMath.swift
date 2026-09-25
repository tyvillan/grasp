import Foundation

/// Finds the math a note actually contains, so figures are built from the
/// student's own examples instead of from a model's recollection of them.
///
/// Asked to supply a figure's numbers, a 7B model tends to grab the first
/// example it sees -- or one it half-remembers -- rather than the one the
/// lecture was built around, and it rarely supplies the row operations at
/// all. Reading the equations straight out of the text and computing the
/// elimination steps here gets the right system every time and the right
/// arithmetic by construction, with no model call.
public enum NoteMath {
    /// One system of two equations found in a note, and where.
    public struct FoundSystem: Sendable, Equatable {
        public let system: LinearSystem2
        /// True when it was written as an augmented matrix. A lecture that
        /// bothers to write a system that way is almost always about to
        /// row-reduce it, so these are the best candidates for the figure.
        public let isAugmentedMatrix: Bool
        public let offset: Int
    }

    /// Two-variable systems in `text`, in the order they appear, with
    /// duplicates removed -- the same system written once as equations and
    /// once as a matrix is reported once, as the matrix.
    public static func systems(in text: String) -> [FoundSystem] {
        var found = augmentedMatrices(in: text) + equationPairs(in: text)
        found.sort { $0.offset < $1.offset }
        var result: [FoundSystem] = []
        for candidate in found {
            if let existing = result.firstIndex(where: { $0.system == candidate.system }) {
                if candidate.isAugmentedMatrix && !result[existing].isAugmentedMatrix {
                    result[existing] = candidate
                }
                continue
            }
            result.append(candidate)
        }
        return result
    }

    /// The system most worth drawing: an augmented matrix with a single
    /// solution if there is one, then any system with a single solution,
    /// then whatever came first. A system with no single solution is still
    /// a real figure (parallel lines are their own lesson), just a less
    /// central one.
    public static func primarySystem(in text: String) -> LinearSystem2? {
        let all = systems(in: text)
        return all.first(where: { $0.isAugmentedMatrix && $0.system.solution != nil })?.system
            ?? all.first(where: { $0.system.solution != nil })?.system
            ?? all.first?.system
    }

    // MARK: - Equations

    /// `2x + 5y = 7`, `x − y = 1`, `-x+y=3`: a linear equation in x and y,
    /// in that order, with implicit 1 coefficients and any of the minus
    /// signs a note or a PDF export uses. The lookbehind stops a word that
    /// happens to end in x -- "max + 2y" -- reading as an equation in x.
    private static let equation = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z_])([+\-−–]?\s*\d*\.?\d*)\s*x\s*([+\-−–])\s*(\d*\.?\d*)\s*y\s*=\s*([+\-−–]?\s*\d+(?:\.\d+)?)"#
    )

    /// Two equations count as one system when the second starts within
    /// this many characters of the first ending -- close enough to be the
    /// same example, rather than two unrelated equations in one note.
    private static let pairingWindow = 160

    private static func equationPairs(in text: String) -> [FoundSystem] {
        pairedEquations(in: text).map {
            FoundSystem(system: $0.system, isAugmentedMatrix: false, offset: $0.start)
        }
    }

    /// Consecutive equations close enough together to be one example,
    /// paired into systems, with where each starts and ends.
    private static func pairedEquations(
        in text: String
    ) -> [(system: LinearSystem2, start: Int, end: Int)] {
        let ns = text as NSString
        let matches = equation.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var rows: [(row: [Double], start: Int, end: Int)] = []
        for match in matches {
            guard let a = coefficient(ns.substring(with: match.range(at: 1))),
                  let b = coefficient(sign: ns.substring(with: match.range(at: 2)),
                                      magnitude: ns.substring(with: match.range(at: 3))),
                  let c = number(ns.substring(with: match.range(at: 4)))
            else { continue }
            rows.append(([a, b, c], match.range.location, match.range.location + match.range.length))
        }

        var result: [(system: LinearSystem2, start: Int, end: Int)] = []
        var index = 0
        while index + 1 < rows.count {
            let first = rows[index]
            let second = rows[index + 1]
            if second.start - first.end <= pairingWindow, first.row != second.row,
               let system = LinearSystem2(rows: [first.row, second.row]) {
                result.append((system, first.start, second.end))
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    /// The x coefficient: empty or a bare sign means 1.
    private static func coefficient(_ raw: String) -> Double? {
        let cleaned = normalizeMinus(raw).replacingOccurrences(of: " ", with: "")
        if cleaned.isEmpty || cleaned == "+" { return 1 }
        if cleaned == "-" { return -1 }
        return Double(cleaned)
    }

    private static func coefficient(sign: String, magnitude: String) -> Double? {
        let value = magnitude.trimmingCharacters(in: .whitespaces).isEmpty ? 1 : Double(magnitude)
        guard let value else { return nil }
        return normalizeMinus(sign).trimmingCharacters(in: .whitespaces) == "-" ? -value : value
    }

    // MARK: - Augmented matrices

    /// `[ 1  5 | 7 ]` -- one row of a two-variable augmented matrix.
    private static let augmentedRow = try! NSRegularExpression(
        pattern: #"\[\s*([+\-−–]?\d+(?:\.\d+)?)\s+([+\-−–]?\d+(?:\.\d+)?)\s*\|\s*([+\-−–]?\d+(?:\.\d+)?)\s*\]"#
    )

    private static func augmentedMatrices(in text: String) -> [FoundSystem] {
        let ns = text as NSString
        let matches = augmentedRow.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result: [FoundSystem] = []
        var index = 0
        while index + 1 < matches.count {
            let first = matches[index]
            let second = matches[index + 1]
            let gap = second.range.location - (first.range.location + first.range.length)
            let rows = [first, second].compactMap { match -> [Double]? in
                let values = (1...3).compactMap { number(ns.substring(with: match.range(at: $0))) }
                return values.count == 3 ? values : nil
            }
            // Adjacent rows only: two bracketed rows far apart belong to
            // different matrices.
            if gap <= 24, rows.count == 2, let system = LinearSystem2(rows: rows) {
                result.append(FoundSystem(system: system, isAugmentedMatrix: true, offset: first.range.location))
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    // MARK: - Checking a model's arithmetic

    /// `x = 3, y = 2`, `x = 9/5 and y = 4/5`, `x = -1; y = 0.5`.
    private static let solutionClaim = try! NSRegularExpression(
        pattern: #"x\s*=\s*([+\-−–]?\d+(?:\.\d+)?(?:\s*/\s*\d+)?)\s*(?:,|;|and)?\s*y\s*=\s*([+\-−–]?\d+(?:\.\d+)?(?:\s*/\s*\d+)?)"#
    )

    /// "the intersection gives the solution (3, 2)", "they cross at (1, 1)":
    /// a bare coordinate pair right after a word that says it's a
    /// solution. The pair itself is group 3, so only it gets replaced.
    private static let barePointClaim = try! NSRegularExpression(
        pattern: #"(?:solution|intersect\w*|cross\w*|meet\w*|point)[^.()]{0,40}?(\(\s*([+\-−–]?\d+(?:\.\d+)?(?:\s*/\s*\d+)?)\s*,\s*([+\-−–]?\d+(?:\.\d+)?(?:\s*/\s*\d+)?)\s*\))"#,
        options: [.caseInsensitive]
    )

    /// `(x, y) = (1, 1)` -- the other way a model states a solution.
    private static let pointClaim = try! NSRegularExpression(
        pattern: #"\(\s*x\s*,\s*y\s*\)\s*=\s*\(\s*([+\-−–]?\d+(?:\.\d+)?(?:\s*/\s*\d+)?)\s*,\s*([+\-−–]?\d+(?:\.\d+)?(?:\s*/\s*\d+)?)\s*\)"#
    )

    /// Corrects any stated solution of a two-variable system that doesn't
    /// actually solve it, in place, leaving the surrounding prose alone.
    ///
    /// A 7B model writing about a system will happily state its solution --
    /// and, measured on a real lesson, got it wrong about half the time
    /// ("x + 2y = 7 and x + y = 6 intersect at x = 3, y = 3"; the answer is
    /// x = 5, y = 1). In a study tool that teaches a wrong answer with full
    /// confidence. Each claim is checked against the nearest system stated
    /// before it in the same text; the numbers are replaced only when they
    /// are provably wrong, so a correct claim is left exactly as written.
    public static func correctingSolutions(in text: String) -> String {
        let ns = text as NSString
        let systems = pairedEquations(in: text)
        guard !systems.isEmpty else { return text }
        let whole = NSRange(location: 0, length: ns.length)
        // Each claim: where to replace, where its x and y are, and how to
        // write the corrected version back in the same form it was stated.
        typealias Claim = (replace: NSRange, x: NSRange, y: NSRange, form: (String, String) -> String)
        var claims: [Claim] = []
        for match in solutionClaim.matches(in: text, range: whole) {
            claims.append((match.range, match.range(at: 1), match.range(at: 2), { "x = \($0), y = \($1)" }))
        }
        for match in pointClaim.matches(in: text, range: whole) {
            claims.append((match.range, match.range(at: 1), match.range(at: 2), { "(x, y) = (\($0), \($1))" }))
        }
        for match in barePointClaim.matches(in: text, range: whole) {
            let pair = match.range(at: 1)
            // Already covered by the `(x, y) = (...)` form.
            guard !claims.contains(where: { NSIntersectionRange($0.replace, pair).length > 0 }) else { continue }
            claims.append((pair, match.range(at: 2), match.range(at: 3), { "(\($0), \($1))" }))
        }
        guard !claims.isEmpty else { return text }

        // Every equation's start, paired or not. A claim is only checked
        // against the system right before it when no other equation sits
        // in between: one that does means the text has moved on -- to a
        // changed system, or a lone equation that shifted the pairing --
        // and "correcting" against the old system rewrote right answers
        // into wrong ones.
        let equationStarts = equation.matches(in: text, range: whole).map(\.range.location)

        var result = text
        // Replaced back to front so earlier offsets stay valid.
        for claim in claims.sorted(by: { $0.replace.location > $1.replace.location }) {
            guard let nearest = systems.last(where: { $0.end <= claim.replace.location }),
                  !equationStarts.contains(where: { $0 >= nearest.end && $0 < claim.replace.location })
            else { continue }
            let system = nearest.system
            guard let solution = system.solution,
                  let statedX = fraction(ns.substring(with: claim.x)),
                  let statedY = fraction(ns.substring(with: claim.y))
            else { continue }
            if abs(statedX - solution.x) < 1e-6, abs(statedY - solution.y) < 1e-6 { continue }
            guard let range = Range(claim.replace, in: result) else { continue }
            result.replaceSubrange(range, with: claim.form(plain(solution.x), plain(solution.y)))
        }
        return result
    }

    private static func fraction(_ raw: String) -> Double? {
        let cleaned = normalizeMinus(raw).replacingOccurrences(of: " ", with: "")
        let parts = cleaned.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return n / d }
        return Double(cleaned)
    }

    /// Plain ASCII for prose -- the typographic minus `OverviewFigures.format`
    /// uses belongs in figures, not mid-sentence next to the model's hyphens.
    private static func plain(_ value: Double) -> String {
        OverviewFigures.format(value).replacingOccurrences(of: "−", with: "-")
    }

    // MARK: - Grounding

    /// Every number written in `text`, as magnitudes. Used to check that a
    /// figure a model proposed is made of numbers the note actually
    /// contains, rather than ones it invented.
    public static func numbers(in text: String) -> Set<Double> {
        // Not preceded by a letter or digit: the `7` in "word7" or "R2" is
        // part of a name, not a number the note wrote down, and counting
        // it let an invented figure pass. A letter *after* is fine -- that
        // is how a coefficient is written, as in `3x`.
        let pattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9.])\d+(?:\.\d+)?"#)
        let ns = text as NSString
        var result: Set<Double> = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let value = Double(ns.substring(with: match.range)) { result.insert(value) }
        }
        return result
    }

    // MARK: - Is there anything to draw?

    /// Which figure kinds this note could honestly support. Both kinds are
    /// linear algebra, so a note on anything else supports neither -- and
    /// the figures call is skipped entirely instead of asking a model to
    /// find a matrix in a lecture about AI agents. (It found one: "4.5
    /// minutes vs. 300 minutes" became the system x = 4.5, 300y = 300,
    /// every number grounded, the whole figure meaningless.)
    ///
    /// Lines need a system the note actually writes out. A transformation
    /// needs the note to talk about matrices or transformations more than
    /// in passing.
    public static func supportedFigureKinds(in text: String) -> Set<OverviewFigure.Kind> {
        var kinds: Set<OverviewFigure.Kind> = []
        if !systems(in: text).isEmpty { kinds.insert(.systemOfLines) }
        if matrixVocabularyCount(in: text) >= 2 { kinds.insert(.linearTransform) }
        if !NoteMatrices.walkthroughs(in: text).isEmpty { kinds.insert(.rowReduction) }
        return kinds
    }

    /// Whether the note is about math at all, which decides whether a
    /// lesson's concrete cases should be equations or the note's own
    /// examples. LaTeX alone isn't the signal -- a business lecture writing
    /// \(88\%\) is still a business lecture.
    public static func isMathematical(_ text: String) -> Bool {
        if !supportedFigureKinds(in: text).isEmpty { return true }
        let pattern = #"(?i)\b(equations?|theorem|proof|derivatives?|integrals?|vectors?|matri(x|ces)|polynomials?|functions? of|lemma|eigen\w*|determinants?|linear (system|combination|independence))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, range: range) >= 3
    }

    /// Whether the note is linear algebra enough that "pivot" means a
    /// matrix entry rather than a change of business plan.
    public static func isLinearAlgebra(_ text: String) -> Bool {
        matrixVocabularyCount(in: text) >= 2 || !NoteMatrices.matrices(in: text).isEmpty
    }

    private static func matrixVocabularyCount(in text: String) -> Int {
        let pattern = #"(?i)\b(matri(x|ces)|linear transformations?|transformation matri(x|ces))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// True when every coefficient of `figure` is written somewhere in the
    /// note. Zero and one are exempt: they're routinely implicit (`x + y`,
    /// a missing term), so requiring them in the text would reject real
    /// systems.
    public static func isGrounded(_ figure: OverviewFigure, in text: String) -> Bool {
        let available = numbers(in: text)
        let values: [Double]
        switch figure.kind {
        case .systemOfLines: values = (figure.equations ?? []).flatMap { $0 }
        case .linearTransform, .rowReduction: values = (figure.matrix ?? []).flatMap { $0 }
        }
        guard !values.isEmpty else { return false }
        return values.allSatisfy { value in
            let magnitude = abs(value)
            if magnitude < 1e-9 || abs(magnitude - 1) < 1e-9 { return true }
            return available.contains { abs($0 - magnitude) < 1e-9 }
        }
    }

    // MARK: - Parsing helpers

    private static func normalizeMinus(_ text: String) -> String {
        text.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "–", with: "-")
    }

    private static func number(_ raw: String) -> Double? {
        Double(normalizeMinus(raw).replacingOccurrences(of: " ", with: ""))
    }
}

extension LinearSystem2 {
    /// The row operations that take this system to reduced row echelon form
    /// -- the same sequence a lecture works through by hand: get a leading 1
    /// in the first row, clear below it, get a leading 1 in the second row,
    /// clear above it. Stops early if a row runs out of variables (a system
    /// with no single solution), because the rest of the procedure no
    /// longer applies.
    public func gaussJordanSteps() -> [RowOperation] {
        var steps: [RowOperation] = []
        var current = self

        func apply(_ operation: RowOperation) -> Bool {
            guard let next = current.applying(operation) else { return false }
            steps.append(operation)
            current = next
            return true
        }

        if abs(current.rows[0][0]) < 1e-9 {
            guard abs(current.rows[1][0]) > 1e-9,
                  apply(RowOperation(kind: .swap, target: 1, source: 2)) else { return steps }
        }
        let a1 = current.rows[0][0]
        if abs(a1 - 1) > 1e-9, !apply(RowOperation(kind: .scale, target: 1, multiplier: 1 / a1)) {
            return steps
        }
        let a2 = current.rows[1][0]
        if abs(a2) > 1e-9,
           !apply(RowOperation(kind: .replace, target: 2, source: 1, multiplier: -a2)) {
            return steps
        }
        let b2 = current.rows[1][1]
        guard abs(b2) > 1e-9 else { return steps }
        if abs(b2 - 1) > 1e-9, !apply(RowOperation(kind: .scale, target: 2, multiplier: 1 / b2)) {
            return steps
        }
        let b1 = current.rows[0][1]
        if abs(b1) > 1e-9 {
            _ = apply(RowOperation(kind: .replace, target: 1, source: 2, multiplier: -b1))
        }
        return steps
    }
}
