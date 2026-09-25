import Foundation

/// "What it is, and what it isn't", drawn as two matrices, for the key
/// terms of linear algebra that are really statements about a matrix's
/// shape -- echelon form, reduced echelon form, pivots, free variables,
/// inconsistency.
///
/// A definition like "each leading entry is to the right of the one above
/// it" is hard to picture until you see a matrix that breaks it next to one
/// that doesn't. Both sides are checked here against the actual rules, never
/// taken on trust -- from a model or from this file's own defaults -- and
/// the offending entry is pointed out, with a sentence saying which rule it
/// breaks. The note's own matrices are preferred, so the contrast is usually
/// the lecture's example before and after it was reduced.
public enum MatrixContrasts {
    public struct Panel: Sendable, Equatable {
        public let matrix: RationalMatrix
        /// Entries that make it what it is -- pivots, circled -- or give the
        /// rule-breaker its context (the leading entry it sits under).
        public let highlights: [RationalMatrix.Cell]
        /// The entry that breaks the rule. Only this is drawn as wrong, so
        /// the eye goes straight to the one thing to fix.
        public let offending: [RationalMatrix.Cell]
        /// Whole columns to tint, for basic and free variables.
        public let highlightedColumns: [Int]
        /// A whole row to wash, for a row like 0 = 4.
        public let highlightedRow: Int?
        public let explanation: String
        /// Taken from the student's own notes rather than a stock example.
        public let fromNotes: Bool

        public init(matrix: RationalMatrix, highlights: [RationalMatrix.Cell] = [],
                    offending: [RationalMatrix.Cell] = [], highlightedColumns: [Int] = [],
                    highlightedRow: Int? = nil, explanation: String, fromNotes: Bool) {
            self.matrix = matrix
            self.highlights = highlights
            self.offending = offending
            self.highlightedColumns = highlightedColumns
            self.highlightedRow = highlightedRow
            self.explanation = explanation
            self.fromNotes = fromNotes
        }
    }

    public struct Contrast: Sendable, Equatable {
        public let concept: Concept
        public let isExample: Panel
        public let isNotExample: Panel
    }

    public enum Concept: String, Sendable, Equatable, CaseIterable {
        case echelonForm
        case reducedEchelonForm
        case pivot
        case freeVariable
        case basicVariable
        case inconsistent
        case consistent

        /// What "is" and "isn't" read as over each side.
        public var labels: (is: String, isNot: String) {
            switch self {
            case .echelonForm: return ("Echelon form", "Not echelon form")
            case .reducedEchelonForm: return ("Reduced echelon form", "Not reduced")
            case .pivot: return ("Pivot positions", "Not a pivot")
            case .freeVariable: return ("Free variables", "Not free (basic)")
            case .basicVariable: return ("Basic variables", "Not basic (free)")
            case .inconsistent: return ("Inconsistent", "Consistent")
            case .consistent: return ("Consistent", "Inconsistent")
            }
        }
    }

    /// Which concept a key term names, if it's one of these. Order matters:
    /// "reduced echelon form" contains "echelon form".
    public static func concept(forTerm term: String) -> Concept? {
        let t = term.lowercased()
        if t.contains("reduced") && t.contains("echelon") || t.contains("rref") { return .reducedEchelonForm }
        if t.contains("echelon") && !t.contains("theorem") { return .echelonForm }
        if t.contains("free variable") { return .freeVariable }
        if t.contains("basic variable") || t.contains("pivot variable") || t.contains("leading variable") { return .basicVariable }
        if t.contains("pivot") || t.contains("leading entry") || t.contains("leading entries") { return .pivot }
        if t.contains("inconsisten") { return .inconsistent }
        if t.contains("consistent") || t.contains("existence and uniqueness") { return .consistent }
        return nil
    }

    /// The contrast for `term`, built from `noteMatrices` where they fit and
    /// from checked defaults otherwise. nil when the term isn't one of the
    /// concepts above.
    public static func contrast(forTerm term: String, noteMatrices: [RationalMatrix]) -> Contrast? {
        guard let concept = concept(forTerm: term) else { return nil }
        // Walked states count too: a lecture's start matrix and its reduced
        // result are exactly the pair these contrasts want.
        let pool = noteMatrices.filter { !$0.isZero }
        return build(concept, pool: pool)
    }

    private static func build(_ concept: Concept, pool: [RationalMatrix]) -> Contrast? {
        switch concept {
        case .echelonForm:
            let yes = pick(pool, { $0.isEchelon && $0.pivotCells.count >= 2 }, default: Defaults.echelon)
            let no = pick(pool, { !$0.isEchelon }, default: Defaults.notEchelon)
            guard let violation = no.matrix.echelonViolation else { return nil }
            return Contrast(
                concept: concept,
                isExample: Panel(matrix: yes.matrix, highlights: yes.matrix.pivotCells,
                                 explanation: "Zero rows at the bottom, and the leading entries step down and to the right with zeros below each.",
                                 fromNotes: yes.fromNotes),
                isNotExample: panel(for: violation, in: no)
            )

        case .reducedEchelonForm:
            let yes = pick(pool, { $0.isReducedEchelon && $0.pivotCells.count >= 2 }, default: Defaults.reduced)
            // An echelon matrix that isn't reduced is the sharpest contrast:
            // it shows exactly the two extra rules and nothing else.
            let no = pick(pool, { $0.isEchelon && !$0.isReducedEchelon }, default: Defaults.echelonNotReduced)
            guard let violation = no.matrix.reducedEchelonViolation else { return nil }
            return Contrast(
                concept: concept,
                isExample: Panel(matrix: yes.matrix, highlights: yes.matrix.pivotCells,
                                 explanation: "Every leading entry is 1, and each is the only nonzero entry in its column.",
                                 fromNotes: yes.fromNotes),
                isNotExample: panel(for: violation, in: no)
            )

        case .pivot:
            let source = pick(pool, { $0.isEchelon && $0.pivotCells.count >= 2 && nonPivotEntry(in: $0) != nil },
                              default: Defaults.echelon)
            guard let other = nonPivotEntry(in: source.matrix) else { return nil }
            return Contrast(
                concept: concept,
                isExample: Panel(matrix: source.matrix, highlights: source.matrix.pivotCells,
                                 explanation: "Each is the first nonzero entry in its row.",
                                 fromNotes: source.fromNotes),
                isNotExample: Panel(matrix: source.matrix, offending: [other],
                                    explanation: "The \(source.matrix[other.row, other.column]) is nonzero, but it isn't the first nonzero entry in row \(other.row + 1), so it isn't a pivot.",
                                    fromNotes: source.fromNotes)
            )

        case .freeVariable, .basicVariable:
            let source = pick(pool, { m in
                guard let kinds = m.variableKinds else { return false }
                return !kinds.free.isEmpty && !kinds.basic.isEmpty && m.inconsistentRow == nil
            }, default: Defaults.withFreeVariables)
            guard let kinds = source.matrix.variableKinds else { return nil }
            let names = { (columns: [Int]) in columns.map { "x\(subscripted($0 + 1))" }.joined(separator: ", ") }
            let free = Panel(matrix: source.matrix, highlightedColumns: kinds.free,
                             explanation: "\(names(kinds.free)): no pivot in \(kinds.free.count == 1 ? "its column" : "their columns"), so \(kinds.free.count == 1 ? "it" : "they") can be anything.",
                             fromNotes: source.fromNotes)
            let basic = Panel(matrix: source.matrix, highlights: source.matrix.pivotCells.filter { kinds.basic.contains($0.column) },
                              highlightedColumns: kinds.basic,
                              explanation: "\(names(kinds.basic)): each column has a pivot, so each is solved for in terms of the free ones.",
                              fromNotes: source.fromNotes)
            return concept == .freeVariable
                ? Contrast(concept: concept, isExample: free, isNotExample: basic)
                : Contrast(concept: concept, isExample: basic, isNotExample: free)

        case .inconsistent, .consistent:
            let bad = pick(pool, { $0.inconsistentRow != nil }, default: Defaults.inconsistent)
            let good = pick(pool, { $0.augmentedColumns > 0 && $0.isEchelon && $0.inconsistentRow == nil },
                            default: Defaults.consistent)
            guard let badRow = bad.matrix.inconsistentRow else { return nil }
            let badPanel = Panel(
                matrix: bad.matrix,
                offending: [RationalMatrix.Cell(row: badRow, column: bad.matrix.columnCount - 1)],
                highlightedRow: badRow,
                explanation: "Row \(badRow + 1) reads 0 = \(bad.matrix[badRow, bad.matrix.columnCount - 1]): its leading entry is in the last column. No values of the variables can make that true.",
                fromNotes: bad.fromNotes
            )
            let goodPanel = Panel(
                matrix: good.matrix, highlights: good.matrix.pivotCells,
                explanation: "No leading entry in the last column, so there's at least one solution.",
                fromNotes: good.fromNotes
            )
            return concept == .inconsistent
                ? Contrast(concept: concept, isExample: badPanel, isNotExample: goodPanel)
                : Contrast(concept: concept, isExample: goodPanel, isNotExample: badPanel)
        }
    }

    /// The rule-breaker marked as wrong; the entry it's judged against
    /// (the leading entry above it) circled as context.
    private static func panel(
        for violation: RationalMatrix.FormViolation, in picked: (matrix: RationalMatrix, fromNotes: Bool)
    ) -> Panel {
        Panel(matrix: picked.matrix,
              highlights: violation.rule == .zeroRowAboveNonzero ? [] : Array(violation.cells.dropFirst()),
              offending: violation.rule == .zeroRowAboveNonzero ? violation.cells : Array(violation.cells.prefix(1)),
              explanation: violation.explanation, fromNotes: picked.fromNotes)
    }

    private static func pick(
        _ pool: [RationalMatrix], _ test: (RationalMatrix) -> Bool, default fallback: RationalMatrix
    ) -> (matrix: RationalMatrix, fromNotes: Bool) {
        if let own = pool.first(where: test) { return (own, true) }
        return (fallback, false)
    }

    /// A nonzero entry that isn't a pivot, to contrast with the pivots.
    private static func nonPivotEntry(in matrix: RationalMatrix) -> RationalMatrix.Cell? {
        let pivots = Set(matrix.pivotCells)
        for row in 0..<matrix.rowCount {
            for column in 0..<matrix.coefficientColumns where !matrix[row, column].isZero {
                let cell = RationalMatrix.Cell(row: row, column: column)
                if !pivots.contains(cell) { return cell }
            }
        }
        return nil
    }

    private static func subscripted(_ value: Int) -> String {
        OverviewFigures.subscriptDigits(value)
    }

    /// Stock examples, used only when the note has nothing that fits. Each
    /// is asserted in the tests to be (or not be) what it claims.
    enum Defaults {
        static func m(_ rows: [[Int]], bar: Int = 1) -> RationalMatrix {
            RationalMatrix(rows: rows.map { $0.map(Rational.init) }, augmentedColumns: bar)!
        }
        static let echelon = m([[2, -3, 1, 4], [0, 1, 5, -2], [0, 0, 0, 0]])
        static let notEchelon = m([[1, 4, 0, 2], [0, 0, 3, 1], [0, 2, 1, 5]])
        static let reduced = m([[1, 0, -2, 3], [0, 1, 4, 1], [0, 0, 0, 0]])
        static let echelonNotReduced = m([[1, 3, 0, 2], [0, 1, 4, 1], [0, 0, 0, 0]])
        static let withFreeVariables = m([[1, 2, 0, 3, 4], [0, 0, 1, -1, 2], [0, 0, 0, 0, 0]])
        static let inconsistent = m([[1, 2, 5], [0, 1, 3], [0, 0, 4]])
        static let consistent = m([[1, 2, 5], [0, 1, 3], [0, 0, 0]])
    }
}
