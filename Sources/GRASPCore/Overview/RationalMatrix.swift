import Foundation

/// An exact fraction. Row reduction by hand is done in fractions, and a
/// figure that showed `0.3333` where the student's notes say `1/3` would be
/// teaching a different (and slightly wrong) matrix.
///
/// Arithmetic that would overflow returns nil rather than trapping -- a
/// matrix copied out of a note is never that large, so an overflow means a
/// misread and the step is simply dropped.
public struct Rational: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let numerator: Int
    /// Always positive; the sign lives on the numerator.
    public let denominator: Int

    public static let zero = Rational(0)
    public static let one = Rational(1)

    public init(_ value: Int) {
        numerator = value
        denominator = 1
    }

    /// nil for a zero denominator or an unreducible overflow.
    public init?(_ numerator: Int, _ denominator: Int) {
        guard denominator != 0, numerator != .min, denominator != .min else { return nil }
        let divisor = Self.gcd(abs(numerator), abs(denominator))
        let sign = denominator < 0 ? -1 : 1
        self.numerator = sign * numerator / max(divisor, 1)
        self.denominator = abs(denominator) / max(divisor, 1)
    }

    /// The nearest simple fraction to `value`, when there is one within
    /// rounding error -- how a stored `Double` multiplier like 0.333…
    /// becomes the 1/3 it was computed from. nil for anything that isn't a
    /// fraction with a denominator of at most `maximumDenominator`.
    public init?(approximating value: Double, maximumDenominator: Int = 1_000) {
        guard value.isFinite, abs(value) < 1e9 else { return nil }
        // Continued-fraction convergents.
        var (h0, h1) = (0, 1)
        var (k0, k1) = (1, 0)
        var x = value
        for _ in 0..<32 {
            let a = x.rounded(.down)
            guard abs(a) < 1e9 else { break }
            let ai = Int(a)
            let (h2, k2) = (ai * h1 + h0, ai * k1 + k0)
            guard k2 <= maximumDenominator, k2 != 0 else { break }
            (h0, h1, k0, k1) = (h1, h2, k1, k2)
            if abs(Double(h1) / Double(k1) - value) < 1e-9 { break }
            let fractional = x - a
            guard fractional > 1e-12 else { break }
            x = 1 / fractional
        }
        guard k1 != 0, abs(Double(h1) / Double(k1) - value) < 1e-9 else { return nil }
        self.init(h1, k1)
    }

    public var isZero: Bool { numerator == 0 }
    public var doubleValue: Double { Double(numerator) / Double(denominator) }

    public func adding(_ other: Rational) -> Rational? {
        let (a, o1) = numerator.multipliedReportingOverflow(by: other.denominator)
        let (b, o2) = other.numerator.multipliedReportingOverflow(by: denominator)
        let (d, o3) = denominator.multipliedReportingOverflow(by: other.denominator)
        let (n, o4) = a.addingReportingOverflow(b)
        guard !(o1 || o2 || o3 || o4) else { return nil }
        return Rational(n, d)
    }

    public func multiplied(by other: Rational) -> Rational? {
        // Cross-reduce first so products stay small.
        let g1 = Self.gcd(abs(numerator), other.denominator)
        let g2 = Self.gcd(abs(other.numerator), denominator)
        let (n, o1) = (numerator / max(g1, 1)).multipliedReportingOverflow(by: other.numerator / max(g2, 1))
        let (d, o2) = (denominator / max(g2, 1)).multipliedReportingOverflow(by: other.denominator / max(g1, 1))
        guard !(o1 || o2) else { return nil }
        return Rational(n, d)
    }

    public var negated: Rational { Rational(unchecked: -numerator, denominator) }

    public var reciprocal: Rational? { Rational(denominator, numerator) }

    private init(unchecked numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public static func < (lhs: Rational, rhs: Rational) -> Bool {
        lhs.doubleValue < rhs.doubleValue
    }

    /// Whiteboard style: `7`, `−3`, `−1/3`, with a typographic minus.
    public var description: String {
        let sign = numerator < 0 ? "−" : ""
        return denominator == 1 ? "\(sign)\(abs(numerator))" : "\(sign)\(abs(numerator))/\(denominator)"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}

/// A matrix of exact fractions -- any size a lecture writes by hand -- with
/// an optional augmentation bar. Everything a row-reduction figure shows is
/// computed here: each intermediate matrix, which forms a matrix is in and
/// *why* it isn't in one, pivots, and which variables are free.
public struct RationalMatrix: Hashable, Sendable {
    public private(set) var rows: [[Rational]]
    /// How many columns sit right of the bar: 1 for an augmented matrix,
    /// 0 for a plain one.
    public let augmentedColumns: Int

    /// Bigger than anything written out by hand, and bigger than a figure
    /// can lay out legibly.
    public static let maximumRows = 6
    public static let maximumColumns = 8

    public init?(rows: [[Rational]], augmentedColumns: Int = 0) {
        guard (1...Self.maximumRows).contains(rows.count),
              let width = rows.first?.count, (1...Self.maximumColumns).contains(width),
              rows.allSatisfy({ $0.count == width }),
              (0..<width).contains(augmentedColumns)
        else { return nil }
        self.rows = rows
        self.augmentedColumns = augmentedColumns
    }

    public init?(doubles: [[Double]], augmentedColumns: Int = 0) {
        var converted: [[Rational]] = []
        for row in doubles {
            var out: [Rational] = []
            for value in row {
                guard let rational = Rational(approximating: value) else { return nil }
                out.append(rational)
            }
            converted.append(out)
        }
        self.init(rows: converted, augmentedColumns: augmentedColumns)
    }

    public var rowCount: Int { rows.count }
    public var columnCount: Int { rows.first?.count ?? 0 }
    /// Columns left of the bar -- one per variable.
    public var coefficientColumns: Int { columnCount - augmentedColumns }
    public var doubles: [[Double]] { rows.map { $0.map(\.doubleValue) } }

    public subscript(row: Int, column: Int) -> Rational { rows[row][column] }

    // MARK: - Row operations

    /// The matrix after one elementary row operation (1-based rows), or nil
    /// when it isn't one: a row that doesn't exist, a row combined with
    /// itself, scaling by zero, or arithmetic that overflows.
    public func applying(_ operation: RowOperation) -> RationalMatrix? {
        let target = operation.target - 1
        guard rows.indices.contains(target) else { return nil }
        var next = rows
        switch operation.kind {
        case .swap:
            guard let source = operation.source.map({ $0 - 1 }), rows.indices.contains(source),
                  source != target else { return nil }
            next.swapAt(target, source)
        case .scale:
            guard let k = operation.rationalMultiplier, !k.isZero else { return nil }
            var scaled: [Rational] = []
            for value in rows[target] {
                guard let product = value.multiplied(by: k) else { return nil }
                scaled.append(product)
            }
            next[target] = scaled
        case .replace:
            guard let source = operation.source.map({ $0 - 1 }), rows.indices.contains(source),
                  source != target,
                  let k = operation.rationalMultiplier, !k.isZero
            else { return nil }
            var combined: [Rational] = []
            for (value, sourceValue) in zip(rows[target], rows[source]) {
                guard let product = sourceValue.multiplied(by: k), let sum = value.adding(product)
                else { return nil }
                combined.append(sum)
            }
            next[target] = combined
        }
        var result = self
        result.rows = next
        return result
    }

    // MARK: - Structure

    /// The column of a row's first nonzero entry, nil for a zero row.
    public func leadingColumn(ofRow row: Int) -> Int? {
        rows[row].firstIndex { !$0.isZero }
    }

    public struct Cell: Hashable, Sendable {
        public let row: Int
        public let column: Int
        public init(row: Int, column: Int) { self.row = row; self.column = column }
    }

    /// Why a matrix isn't in a form: which rule it breaks, where, and a
    /// sentence saying so in the lecture's own terms.
    public struct FormViolation: Hashable, Sendable {
        public enum Rule: String, Sendable {
            case zeroRowAboveNonzero
            case nonzeroBelowLeadingEntry
            case leadingEntryNotRightOfAbove
            case leadingEntryNotOne
            case nonzeroAboveLeadingOne
        }
        public let rule: Rule
        /// The entries to point at.
        public let cells: [Cell]
        public let explanation: String
    }

    /// nil when the matrix is in echelon form; otherwise the first of the
    /// three conditions it breaks, checked in the order lectures state them.
    public var echelonViolation: FormViolation? {
        let leads = rows.indices.map(leadingColumn(ofRow:))
        // 1. Zero rows at the bottom.
        if let zero = leads.firstIndex(where: { $0 == nil }),
           let below = leads.indices.first(where: { $0 > zero && leads[$0] != nil }) {
            return FormViolation(
                rule: .zeroRowAboveNonzero,
                cells: (0..<columnCount).map { Cell(row: zero, column: $0) },
                explanation: "Row \(zero + 1) is all zeros but sits above row \(below + 1), which isn't. Zero rows belong at the bottom."
            )
        }
        // 3. Zeros below each leading entry -- checked before the staircase
        // rule because it names the entry a student actually has to fix.
        for (row, lead) in leads.enumerated() {
            guard let lead else { continue }
            if let below = rows.indices.first(where: { $0 > row && !rows[$0][lead].isZero }) {
                return FormViolation(
                    rule: .nonzeroBelowLeadingEntry,
                    cells: [Cell(row: below, column: lead), Cell(row: row, column: lead)],
                    explanation: "The \(rows[below][lead]) in row \(below + 1) sits below row \(row + 1)'s leading entry. Every entry below a leading entry must be zero."
                )
            }
        }
        // 2. Each leading entry right of the one above.
        for row in 1..<max(rowCount, 1) {
            guard let lead = leads[row], let above = leads[row - 1], lead <= above else { continue }
            return FormViolation(
                rule: .leadingEntryNotRightOfAbove,
                cells: [Cell(row: row, column: lead), Cell(row: row - 1, column: above)],
                explanation: "Row \(row + 1)'s leading entry isn't to the right of row \(row)'s. The leading entries have to step down and to the right."
            )
        }
        return nil
    }

    /// nil when the matrix is in reduced echelon form; otherwise the rule
    /// it breaks -- one of echelon form's three, or one of the two extra.
    public var reducedEchelonViolation: FormViolation? {
        if let violation = echelonViolation { return violation }
        for row in rows.indices {
            guard let lead = leadingColumn(ofRow: row) else { continue }
            if rows[row][lead] != .one {
                return FormViolation(
                    rule: .leadingEntryNotOne,
                    cells: [Cell(row: row, column: lead)],
                    explanation: "Row \(row + 1)'s leading entry is \(rows[row][lead]), not 1."
                )
            }
            if let above = rows.indices.first(where: { $0 < row && !rows[$0][lead].isZero }) {
                return FormViolation(
                    rule: .nonzeroAboveLeadingOne,
                    cells: [Cell(row: above, column: lead), Cell(row: row, column: lead)],
                    explanation: "The \(rows[above][lead]) in row \(above + 1) sits above row \(row + 1)'s leading 1. In reduced form a leading 1 is the only nonzero entry in its column."
                )
            }
        }
        return nil
    }

    public var isEchelon: Bool { echelonViolation == nil }
    public var isReducedEchelon: Bool { reducedEchelonViolation == nil }
    public var isZero: Bool { rows.allSatisfy { $0.allSatisfy(\.isZero) } }

    /// Each nonzero row's leading entry -- the pivots, once the matrix is in
    /// echelon form. Empty when it isn't, since "pivot" means nothing yet.
    public var pivotCells: [Cell] {
        guard isEchelon else { return [] }
        return rows.indices.compactMap { row in
            leadingColumn(ofRow: row).map { Cell(row: row, column: $0) }
        }
    }

    /// For an augmented matrix in echelon form: a leading entry in the
    /// augmented column, which says 0 = (something nonzero).
    public var inconsistentRow: Int? {
        guard augmentedColumns > 0, isEchelon else { return nil }
        return pivotCells.first { $0.column >= coefficientColumns }?.row
    }

    /// For a matrix in echelon form: which variable columns hold a pivot
    /// (basic) and which don't (free). 0-based column indices.
    public var variableKinds: (basic: [Int], free: [Int])? {
        guard isEchelon else { return nil }
        let pivotColumns = Set(pivotCells.map(\.column))
        let variables = Array(0..<coefficientColumns)
        return (variables.filter { pivotColumns.contains($0) }, variables.filter { !pivotColumns.contains($0) })
    }

    // MARK: - Reducing it

    /// Ordinary elimination to echelon form, the way it's done by hand:
    /// work left to right, swap only when the pivot spot is zero, and clear
    /// each entry below a pivot with one replacement.
    public func echelonSteps(maximum: Int = 12) -> [RowOperation] {
        var steps: [RowOperation] = []
        var current = self
        var pivotRow = 0
        for column in 0..<columnCount where pivotRow < rowCount {
            guard let found = (pivotRow..<rowCount).first(where: { !current[$0, column].isZero }) else { continue }
            if found != pivotRow {
                let swap = RowOperation(kind: .swap, target: pivotRow + 1, source: found + 1)
                guard let next = current.applying(swap) else { return steps }
                steps.append(swap)
                current = next
            }
            let pivot = current[pivotRow, column]
            for row in (pivotRow + 1)..<rowCount {
                let entry = current[row, column]
                guard !entry.isZero, let ratio = pivot.reciprocal.flatMap({ entry.multiplied(by: $0) }) else { continue }
                let replace = RowOperation(kind: .replace, target: row + 1, source: pivotRow + 1,
                                           exact: ratio.negated)
                guard let next = current.applying(replace) else { return steps }
                steps.append(replace)
                current = next
                if steps.count >= maximum { return steps }
            }
            pivotRow += 1
        }
        return Array(steps.prefix(maximum))
    }

    /// Elimination all the way to reduced echelon form: echelon form first,
    /// then each pivot scaled to 1 and the entries above it cleared, working
    /// from the bottom pivot up -- the order that creates the fewest
    /// fractions.
    public func reducedEchelonSteps(maximum: Int = 12) -> [RowOperation] {
        var steps = echelonSteps(maximum: maximum)
        var current = self
        for step in steps { current = current.applying(step) ?? current }
        for pivot in current.pivotCells.reversed() {
            guard steps.count < maximum else { break }
            let value = current[pivot.row, pivot.column]
            if value != .one, let factor = value.reciprocal {
                let scale = RowOperation(kind: .scale, target: pivot.row + 1, exact: factor)
                guard let next = current.applying(scale) else { break }
                steps.append(scale)
                current = next
            }
            for row in 0..<pivot.row where steps.count < maximum {
                let entry = current[row, pivot.column]
                guard !entry.isZero else { continue }
                let replace = RowOperation(kind: .replace, target: row + 1, source: pivot.row + 1,
                                           exact: entry.negated)
                guard let next = current.applying(replace) else { break }
                steps.append(replace)
                current = next
            }
        }
        return Array(steps.prefix(maximum))
    }

    /// Every state from this matrix through each step. Steps that don't
    /// apply are skipped, so `states.count - 1` can be less than
    /// `steps.count` -- use `applicableSteps` to keep them paired.
    public func walk(_ steps: [RowOperation]) -> (states: [RationalMatrix], steps: [RowOperation]) {
        var states = [self]
        var kept: [RowOperation] = []
        for step in steps {
            guard let next = states[states.count - 1].applying(step) else { continue }
            states.append(next)
            kept.append(step)
        }
        return (states, kept)
    }
}
