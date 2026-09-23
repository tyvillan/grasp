import Testing
@testable import GRASPCore

/// The figures make one promise the student is meant to *see*: while a row
/// operation plays out, the lines move but the point where they cross does
/// not. That is only honest if it's true of the math, not just of the
/// animation, so it's the first thing pinned here -- at every point along
/// every step, not just at the ends.
@Suite("Overview figures")
struct OverviewFiguresTests {

    /// x + 5y = 7 and 2x + y = 5, which cross at (2, 1).
    private let system = LinearSystem2(rows: [[1, 5, 7], [2, 1, 5]])!

    private func satisfies(_ system: LinearSystem2, _ point: Point2, row: Int) -> Bool {
        let r = system.rows[row]
        return abs(r[0] * point.x + r[1] * point.y - r[2]) < 1e-9
    }

    // MARK: - Solving

    @Test("finds where two lines cross")
    func solves() throws {
        let solution = try #require(system.solution)
        #expect(abs(solution.x - 2) < 1e-9)
        #expect(abs(solution.y - 1) < 1e-9)
    }

    @Test("reports no single solution for parallel lines")
    func parallelHasNoSolution() throws {
        let parallel = try #require(LinearSystem2(rows: [[1, 1, 1], [2, 2, 5]]))
        #expect(parallel.solution == nil)
    }

    @Test("rejects anything that isn't two lines")
    func rejectsMalformedSystems() {
        #expect(LinearSystem2(rows: [[1, 1, 3]]) == nil)
        #expect(LinearSystem2(rows: [[1, 1], [1, -1]]) == nil)
        #expect(LinearSystem2(rows: [[0, 0, 3], [1, -1, 1]]) == nil)
        #expect(LinearSystem2(rows: [[.infinity, 1, 3], [1, -1, 1]]) == nil)
        #expect(LinearSystem2(rows: [[1e6, 1, 3], [1, -1, 1]]) == nil)
    }

    // MARK: - Row operations

    @Test("performs a replacement")
    func replacement() throws {
        let next = try #require(system.applying(
            RowOperation(kind: .replace, target: 2, source: 1, multiplier: -2)
        ))
        #expect(next.rows[1] == [0, -9, -9])
        #expect(next.rows[0] == system.rows[0])
    }

    @Test("performs a swap")
    func swap() throws {
        let next = try #require(system.applying(RowOperation(kind: .swap, target: 1, source: 2)))
        #expect(next.rows == [[2, 1, 5], [1, 5, 7]])
    }

    @Test("performs a scale")
    func scale() throws {
        let next = try #require(system.applying(RowOperation(kind: .scale, target: 1, multiplier: 2)))
        #expect(next.rows[0] == [2, 10, 14])
    }

    @Test("refuses operations that aren't elementary row operations")
    func rejectsInvalidOperations() {
        // Scaling by zero throws an equation away -- it's excluded from the
        // elementary operations for exactly that reason.
        #expect(system.applying(RowOperation(kind: .scale, target: 1, multiplier: 0)) == nil)
        #expect(system.applying(RowOperation(kind: .replace, target: 1, source: 1, multiplier: 2)) == nil)
        #expect(system.applying(RowOperation(kind: .replace, target: 3, source: 1, multiplier: 2)) == nil)
        #expect(system.applying(RowOperation(kind: .swap, target: 1, source: 1)) == nil)
        #expect(system.applying(RowOperation(kind: .replace, target: 2, source: 1)) == nil)
    }

    @Test("every row operation preserves the solution")
    func operationsPreserveSolution() throws {
        let solution = try #require(system.solution)
        let operations = [
            RowOperation(kind: .replace, target: 2, source: 1, multiplier: -2),
            RowOperation(kind: .swap, target: 1, source: 2),
            RowOperation(kind: .scale, target: 2, multiplier: -1.0 / 9),
        ]
        for operation in operations {
            let next = try #require(system.applying(operation))
            #expect(next.solution.map { abs($0.x - solution.x) < 1e-9 && abs($0.y - solution.y) < 1e-9 } == true)
        }
    }

    @Test("the crossing point holds still at every moment of a replacement")
    func intersectionIsFixedDuringAnimation() throws {
        // The whole visual argument of the figure. Every in-between system
        // is still a combination of the two original equations, so the
        // original solution must satisfy both rows at every t -- which
        // means the line pivots about that point rather than sliding.
        let solution = try #require(system.solution)
        let operation = RowOperation(kind: .replace, target: 2, source: 1, multiplier: -2)
        for step in 0...20 {
            let t = Double(step) / 20
            let midway = LinearSystem2.interpolate(from: system, applying: operation, progress: t)
            #expect(satisfies(midway, solution, row: 0))
            #expect(satisfies(midway, solution, row: 1))
        }
    }

    @Test("a replacement actually moves its line partway through")
    func replacementMoves() {
        let operation = RowOperation(kind: .replace, target: 2, source: 1, multiplier: -2)
        let midway = LinearSystem2.interpolate(from: system, applying: operation, progress: 0.5)
        #expect(midway.rows[1] != system.rows[1])
        #expect(midway.rows[0] == system.rows[0])
    }

    @Test("a swap and a scale leave every line exactly where it was")
    func swapAndScaleDoNotMove() {
        // Animating these as if something moved would teach the wrong
        // thing: they change how the system is written, not what it says.
        for operation in [
            RowOperation(kind: .swap, target: 1, source: 2),
            RowOperation(kind: .scale, target: 1, multiplier: 3),
        ] {
            let midway = LinearSystem2.interpolate(from: system, applying: operation, progress: 0.5)
            #expect(midway == system)
        }
    }

    @Test("builds one state per step, plus the start")
    func states() {
        let steps = [
            RowOperation(kind: .replace, target: 2, source: 1, multiplier: -2),
            RowOperation(kind: .scale, target: 2, multiplier: -1.0 / 9),
            RowOperation(kind: .replace, target: 1, source: 2, multiplier: -5),
        ]
        let states = LinearSystem2.states(from: system, steps: steps)
        #expect(states.count == 4)
        // Fully reduced: x = 2, y = 1.
        let last = states[3].rows
        #expect(abs(last[0][0] - 1) < 1e-9 && abs(last[0][1]) < 1e-9 && abs(last[0][2] - 2) < 1e-9)
        #expect(abs(last[1][0]) < 1e-9 && abs(last[1][1] - 1) < 1e-9 && abs(last[1][2] - 1) < 1e-9)
    }

    @Test("notices when elimination leaves a row with no x or y")
    func degenerateRowAfterElimination() throws {
        // Dependent system: the second equation is twice the first.
        let dependent = try #require(LinearSystem2(rows: [[1, 1, 2], [2, 2, 4]]))
        let next = try #require(dependent.applying(
            RowOperation(kind: .replace, target: 2, source: 1, multiplier: -2)
        ))
        #expect(next.isDegenerate(1))
        #expect(!next.isDegenerate(0))
    }

    // MARK: - Validation

    @Test("keeps the good steps of a figure and drops the bad ones")
    func validateDropsBadSteps() throws {
        let figure = OverviewFigure(
            kind: .systemOfLines, equations: [[1, 5, 7], [2, 1, 5]],
            steps: [
                RowOperation(kind: .replace, target: 2, source: 1, multiplier: -2),
                RowOperation(kind: .scale, target: 2, multiplier: 0),
                RowOperation(kind: .swap, target: 1, source: 2),
            ]
        )
        let valid = try #require(OverviewFigures.validate(figure))
        #expect(valid.steps?.count == 2)
        #expect(valid.steps?.map(\.kind) == [.replace, .swap])
    }

    @Test("drops a figure with no drawable numbers")
    func validateRejectsEmptyFigures() {
        #expect(OverviewFigures.validate(OverviewFigure(kind: .systemOfLines)) == nil)
        #expect(OverviewFigures.validate(OverviewFigure(kind: .linearTransform)) == nil)
        #expect(OverviewFigures.validate(OverviewFigure(
            kind: .linearTransform, matrix: [[50, 0], [0, 1]]
        )) == nil)
    }

    @Test("caps how many steps a figure can have")
    func validateCapsSteps() throws {
        let steps = (0..<20).map { _ in RowOperation(kind: .swap, target: 1, source: 2) }
        let figure = OverviewFigure(kind: .systemOfLines, equations: [[1, 5, 7], [2, 1, 5]], steps: steps)
        let valid = try #require(OverviewFigures.validate(figure))
        #expect(valid.steps?.count == OverviewFigures.maximumSteps)
    }

    // MARK: - Matrices

    @Test("reads a matrix's columns as where î and ĵ land")
    func matrixColumns() throws {
        let matrix = try #require(Matrix2(rows: [[2, 1], [0, 1]]))
        #expect(matrix.iHat == Point2(x: 2, y: 0))
        #expect(matrix.jHat == Point2(x: 1, y: 1))
        #expect(matrix.determinant == 2)
        #expect(Matrix2.columns(iHat: matrix.iHat, jHat: matrix.jHat) == matrix)
    }

    @Test("blends from doing nothing to the full transformation")
    func matrixBlend() throws {
        let matrix = try #require(Matrix2(rows: [[3, 0], [0, 1]]))
        #expect(matrix.blended(progress: 0) == .identity)
        #expect(matrix.blended(progress: 1) == matrix)
        #expect(matrix.blended(progress: 0.5).a == 2)
    }

    @Test("applies a matrix to a point")
    func matrixApply() throws {
        let matrix = try #require(Matrix2(rows: [[0, -1], [1, 0]]))
        #expect(matrix.apply(Point2(x: 1, y: 0)) == Point2(x: 0, y: 1))
    }

    // MARK: - Formatting

    @Test("writes numbers the way a whiteboard would")
    func formatting() {
        #expect(OverviewFigures.format(2) == "2")
        #expect(OverviewFigures.format(-9) == "−9")
        #expect(OverviewFigures.format(0.5) == "1/2")
        #expect(OverviewFigures.format(-1.0 / 9) == "−1/9")
        #expect(OverviewFigures.format(2.0 / 3) == "2/3")
        #expect(OverviewFigures.format(0) == "0")
        #expect(OverviewFigures.format(1e-12) == "0")
        #expect(OverviewFigures.format(0.123456) == "0.12")
    }

    @Test("labels row operations in standard notation")
    func labels() {
        #expect(OverviewFigures.label(RowOperation(kind: .replace, target: 2, source: 1, multiplier: -2)) == "R₂ → R₂ − 2R₁")
        #expect(OverviewFigures.label(RowOperation(kind: .replace, target: 1, source: 2, multiplier: 1)) == "R₁ → R₁ + R₂")
        #expect(OverviewFigures.label(RowOperation(kind: .swap, target: 1, source: 2)) == "R₁ ↔ R₂")
        #expect(OverviewFigures.label(RowOperation(kind: .scale, target: 2, multiplier: -1.0 / 9)) == "R₂ → −1/9 R₂")
    }
}
