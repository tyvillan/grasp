import Foundation

/// The math behind the overview's figures.
///
/// A model only ever *specifies* a figure -- which two equations, which row
/// operations, which matrix. Every line, intersection, intermediate matrix
/// and determinant a reader sees is computed here instead of being taken
/// from the model, so a figure can only be as wrong as the numbers in the
/// student's own notes. A 7B model that fumbles the arithmetic of a row
/// reduction still gets a correct picture, because it was never asked to do
/// the arithmetic.
public enum OverviewFigures {
    /// Largest coefficient accepted. Anything bigger is almost certainly a
    /// model misreading the note, and would draw as a line so steep the
    /// figure is useless anyway.
    static let maximumMagnitude = 1_000.0
    static let maximumSteps = 6
    /// A transform with bigger entries throws the unit square far off any
    /// sensible view.
    public static let maximumMatrixEntry = 10.0

    /// A cleaned copy of `figure`, or nil when there is nothing drawable.
    /// Invalid row operations are dropped individually rather than costing
    /// the whole figure -- a system with one garbled step is still a good
    /// picture of the other steps.
    public static func validate(_ figure: OverviewFigure) -> OverviewFigure? {
        switch figure.kind {
        case .systemOfLines:
            guard let equations = figure.equations,
                  let system = LinearSystem2(rows: equations)
            else { return nil }
            var states = [system]
            var kept: [RowOperation] = []
            for step in (figure.steps ?? []).prefix(maximumSteps) {
                guard let next = states[states.count - 1].applying(step) else { continue }
                kept.append(step)
                states.append(next)
            }
            var cleaned = figure
            cleaned.equations = system.rows
            cleaned.steps = kept
            cleaned.matrix = nil
            return cleaned

        case .linearTransform:
            guard let rows = figure.matrix, let matrix = Matrix2(rows: rows),
                  [matrix.a, matrix.b, matrix.c, matrix.d].allSatisfy({ abs($0) <= maximumMatrixEntry })
            else { return nil }
            var cleaned = figure
            cleaned.matrix = matrix.rows
            cleaned.equations = nil
            cleaned.steps = nil
            return cleaned

        case .rowReduction:
            guard let rows = figure.matrix,
                  let start = RationalMatrix(doubles: rows, augmentedColumns: figure.augmentedColumns ?? 0)
            else { return nil }
            let walked = start.walk(Array((figure.steps ?? []).prefix(maximumRowReductionSteps)))
            guard !walked.steps.isEmpty else { return nil }
            var cleaned = figure
            cleaned.steps = walked.steps
            cleaned.equations = nil
            return cleaned
        }
    }

    /// A walkthrough longer than this is a page of matrices; lectures work
    /// examples that fit on a board.
    static let maximumRowReductionSteps = 12

    // MARK: - Formatting

    /// A number the way it would be written on a whiteboard: whole numbers
    /// as whole numbers, simple fractions as fractions (`-1/9`, not
    /// `-0.1111`), and anything else to two places. Row reduction produces
    /// fractions constantly, and a matrix full of recurring decimals is
    /// much harder to read than the fractions it came from.
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        // One tolerance throughout. With a looser one for fractions than
        // for whole numbers, 2.0000004 came out as "4/2".
        let tolerance = 1e-6
        if abs(value) < tolerance { return "0" }
        let sign = value < 0 ? "−" : ""
        let magnitude = abs(value)
        // Past this, Int() traps; nothing a student wrote is this big.
        guard magnitude < 1e12 else { return sign + String(format: "%.3g", magnitude) }
        if abs(magnitude - magnitude.rounded()) < tolerance {
            return sign + String(Int(magnitude.rounded()))
        }
        for denominator in 2...12 {
            let numerator = magnitude * Double(denominator)
            if abs(numerator - numerator.rounded()) < tolerance {
                return sign + "\(Int(numerator.rounded()))/\(denominator)"
            }
        }
        return sign + String(format: "%.2f", magnitude)
    }

    /// The operation in standard notation: `R₂ → R₂ − 2R₁`, `R₁ ↔ R₂`,
    /// `R₁ → 1/2 R₁`.
    public static func label(_ operation: RowOperation) -> String {
        let target = "R\(subscriptDigits(operation.target))"
        switch operation.kind {
        case .swap:
            return "\(target) ↔ R\(subscriptDigits(operation.source ?? 0))"
        case .scale:
            let factor = operation.rationalMultiplier?.description ?? format(operation.multiplier ?? 1)
            return "\(target) → \(factor) \(target)"
        case .replace:
            let k = operation.multiplier ?? 0
            let source = "R\(subscriptDigits(operation.source ?? 0))"
            let magnitude = abs(k)
            let exact = operation.rationalMultiplier.map { $0.numerator < 0 ? $0.negated : $0 }
            let coefficient = abs(magnitude - 1) < 1e-9 ? "" : (exact?.description ?? format(magnitude))
            return "\(target) → \(target) \(k < 0 ? "−" : "+") \(coefficient)\(source)"
        }
    }

    public static func subscriptDigits(_ value: Int) -> String {
        let digits: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        ]
        return String(String(value).map { digits[$0] ?? $0 })
    }
}

public struct Point2: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Two linear equations in x and y, each stored as `[a, b, c]` for
/// a·x + b·y = c -- which is also exactly a row of the augmented matrix.
public struct LinearSystem2: Sendable, Equatable {
    public private(set) var rows: [[Double]]

    /// nil unless there are exactly two rows of three finite, sanely sized
    /// numbers, and neither row is `0x + 0y = c` (which isn't a line).
    public init?(rows: [[Double]]) {
        guard rows.count == 2, rows.allSatisfy({ $0.count == 3 }) else { return nil }
        guard rows.joined().allSatisfy({ $0.isFinite && abs($0) <= OverviewFigures.maximumMagnitude })
        else { return nil }
        self.rows = rows
        guard !isDegenerate(0), !isDegenerate(1) else { return nil }
    }

    private init(unchecked rows: [[Double]]) { self.rows = rows }

    /// True when row `index` has no x or y term left -- `0 = 0` after
    /// eliminating a dependent system, or `0 = 5` for an inconsistent one.
    /// Such a row is a real result of row reduction, just not a line.
    public func isDegenerate(_ index: Int) -> Bool {
        abs(rows[index][0]) < 1e-9 && abs(rows[index][1]) < 1e-9
    }

    public var determinant: Double { rows[0][0] * rows[1][1] - rows[1][0] * rows[0][1] }

    /// Where the two lines cross. nil when they're parallel or the same
    /// line -- no single solution to point at.
    public var solution: Point2? {
        let det = determinant
        guard abs(det) > 1e-9 else { return nil }
        let x = (rows[0][2] * rows[1][1] - rows[1][2] * rows[0][1]) / det
        let y = (rows[0][0] * rows[1][2] - rows[1][0] * rows[0][2]) / det
        return Point2(x: x, y: y)
    }

    /// The system after one elementary row operation, or nil when the
    /// operation doesn't make sense (a row that doesn't exist, a row added
    /// to itself, scaling by zero -- which isn't an elementary operation
    /// precisely because it throws an equation away).
    public func applying(_ operation: RowOperation) -> LinearSystem2? {
        let target = operation.target - 1
        guard (0...1).contains(target) else { return nil }
        var next = rows

        switch operation.kind {
        case .swap:
            guard let sourceRow = operation.source, (1...2).contains(sourceRow),
                  sourceRow - 1 != target else { return nil }
            next.swapAt(target, sourceRow - 1)
        case .scale:
            guard let k = operation.multiplier, k.isFinite, abs(k) > 1e-9 else { return nil }
            next[target] = rows[target].map { $0 * k }
        case .replace:
            guard let sourceRow = operation.source, (1...2).contains(sourceRow),
                  sourceRow - 1 != target,
                  let k = operation.multiplier, k.isFinite, abs(k) > 1e-9 else { return nil }
            let source = rows[sourceRow - 1]
            next[target] = zip(rows[target], source).map { $0 + k * $1 }
        }
        guard next.joined().allSatisfy({ $0.isFinite }) else { return nil }
        return LinearSystem2(unchecked: next)
    }

    /// Every state from the starting system through each step, so the
    /// figure can show "before" and "after" for any step without redoing
    /// the arithmetic. Steps that don't apply are skipped.
    public static func states(from initial: LinearSystem2, steps: [RowOperation]) -> [LinearSystem2] {
        var states = [initial]
        for step in steps {
            if let next = states[states.count - 1].applying(step) { states.append(next) }
        }
        return states
    }

    /// The picture partway through a step, for animation.
    ///
    /// Only a replacement changes the picture. Swapping two equations
    /// reorders them, and scaling one gives an equation with exactly the
    /// same solutions -- 2x + 2y = 2 is the same line as x + y = 1 -- so
    /// both leave every line where it was, and animating them as if they
    /// moved would teach the wrong thing. For a replacement the target row
    /// becomes `R + t·k·S`, which is itself a combination of the original
    /// two equations for every t. Any such combination is satisfied by the
    /// original solution, so the line rotates about the intersection and
    /// the intersection holds still for the whole animation. That isn't an
    /// effect added for the figure -- it is the theorem, drawn.
    public static func interpolate(
        from start: LinearSystem2, applying operation: RowOperation, progress t: Double
    ) -> LinearSystem2 {
        let t = min(max(t, 0), 1)
        guard operation.kind == .replace,
              let sourceRow = operation.source, let k = operation.multiplier,
              (1...2).contains(operation.target), (1...2).contains(sourceRow)
        else { return start }
        var rows = start.rows
        let source = start.rows[sourceRow - 1]
        rows[operation.target - 1] = zip(start.rows[operation.target - 1], source)
            .map { $0 + t * k * $1 }
        return LinearSystem2(unchecked: rows)
    }
}

/// A 2x2 matrix `[[a, b], [c, d]]`, read the way 3Blue1Brown teaches it:
/// the first column is where î lands, the second is where ĵ lands.
public struct Matrix2: Sendable, Equatable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double

    public init(a: Double, b: Double, c: Double, d: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d
    }

    public init?(rows: [[Double]]) {
        guard rows.count == 2, rows.allSatisfy({ $0.count == 2 }),
              rows.joined().allSatisfy({ $0.isFinite }) else { return nil }
        self.init(a: rows[0][0], b: rows[0][1], c: rows[1][0], d: rows[1][1])
    }

    public static let identity = Matrix2(a: 1, b: 0, c: 0, d: 1)

    public var rows: [[Double]] { [[a, b], [c, d]] }
    /// How much the transformation scales area -- negative when it flips
    /// the plane over.
    public var determinant: Double { a * d - b * c }
    public var iHat: Point2 { Point2(x: a, y: c) }
    public var jHat: Point2 { Point2(x: b, y: d) }

    public func apply(_ point: Point2) -> Point2 {
        Point2(x: a * point.x + b * point.y, y: c * point.x + d * point.y)
    }

    /// The straight-line blend from "do nothing" to this matrix, for
    /// animating the plane as it deforms. At t = 0 nothing has moved; at
    /// t = 1 it's the full transformation.
    public func blended(from start: Matrix2 = .identity, progress t: Double) -> Matrix2 {
        let t = min(max(t, 0), 1)
        return Matrix2(
            a: start.a + (a - start.a) * t, b: start.b + (b - start.b) * t,
            c: start.c + (c - start.c) * t, d: start.d + (d - start.d) * t
        )
    }

    /// Builds the matrix from where î and ĵ land -- which is how dragging
    /// their tips edits it.
    public static func columns(iHat: Point2, jHat: Point2) -> Matrix2 {
        Matrix2(a: iHat.x, b: jHat.x, c: iHat.y, d: jHat.y)
    }
}
