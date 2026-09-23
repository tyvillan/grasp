import Testing
@testable import GRASPCore

/// Reading math out of a note, and checking a model's arithmetic against
/// it. Fixtures here are real lines from a Fall 2026 Matrix Theory note,
/// because the formats that matter are the ones notes actually use --
/// Unicode minus signs, implicit coefficients, a bar in an augmented matrix.
@Suite("Note math")
struct NoteMathTests {

    private let lecture = """
        - **Solution** - values making *every* equation true. For x + y = 5, x − y = 1 the \
        solution is x = 3, y = 2 (3 + 2 = 5 ✓, 3 − 2 = 1 ✓).
        - **Inconsistent** - no solution. Example: x + y = 1 and x + y = 5 can never both hold.
        Instead of writing
        ``` x + 5y = 7
        2x +  y = 5
        ```
        write
        [ 1  5 | 7 ]
        [ 2  1 | 5 ]
        """

    // MARK: - Extraction

    @Test("finds every two-variable system in a real note, in order")
    func findsSystems() {
        let systems = NoteMath.systems(in: lecture)
        #expect(systems.map(\.system.rows) == [
            [[1, 1, 5], [1, -1, 1]],
            [[1, 1, 1], [1, 1, 5]],
            [[1, 5, 7], [2, 1, 5]],
        ])
    }

    @Test("reports a system written both ways once, as the augmented matrix")
    func dedupesMatrixAndEquations() {
        let systems = NoteMath.systems(in: lecture)
        let main = systems.filter { $0.system.rows == [[1, 5, 7], [2, 1, 5]] }
        #expect(main.count == 1)
        #expect(main.first?.isAugmentedMatrix == true)
    }

    @Test("picks the augmented-matrix system as the one to draw")
    func primaryPrefersTheMatrix() {
        #expect(NoteMath.primarySystem(in: lecture)?.rows == [[1, 5, 7], [2, 1, 5]])
    }

    @Test("reads implicit coefficients and every minus sign a note uses")
    func coefficientForms() {
        let systems = NoteMath.systems(in: "Solve -x + y = 3 and 2x – 3y = −4 together.")
        #expect(systems.first?.system.rows == [[-1, 1, 3], [2, -3, -4]])
    }

    @Test("doesn't read a word ending in x as an equation")
    func wordsEndingInXAreNotEquations() {
        #expect(NoteMath.systems(in: "the max + 2y = 3 bound and the index + y = 1 case").isEmpty)
    }

    @Test("doesn't pair equations that are far apart")
    func distantEquationsAreSeparate() {
        let filler = String(repeating: "unrelated words here ", count: 20)
        #expect(NoteMath.systems(in: "x + y = 2 \(filler) x - y = 0").isEmpty)
    }

    @Test("finds nothing in a note without math")
    func noMath() {
        #expect(NoteMath.systems(in: "Mitosis has four phases.").isEmpty)
        #expect(NoteMath.primarySystem(in: "Mitosis has four phases.") == nil)
    }

    // MARK: - Elimination

    @Test("row-reduces the lecture's system in the order it's done by hand")
    func gaussJordan() throws {
        let system = try #require(LinearSystem2(rows: [[1, 5, 7], [2, 1, 5]]))
        let steps = system.gaussJordanSteps()
        #expect(steps.map(\.kind) == [.replace, .scale, .replace])
        #expect(OverviewFigures.label(steps[0]) == "R₂ → R₂ − 2R₁")
        let final = try #require(LinearSystem2.states(from: system, steps: steps).last)
        #expect(abs(final.rows[0][2] - 2) < 1e-9)
        #expect(abs(final.rows[1][2] - 1) < 1e-9)
    }

    @Test("swaps first when the top-left entry is zero")
    func gaussJordanSwapsFirst() throws {
        let system = try #require(LinearSystem2(rows: [[0, 1, 2], [1, 1, 3]]))
        #expect(system.gaussJordanSteps().first?.kind == .swap)
    }

    @Test("stops once a system turns out to have no single solution")
    func gaussJordanStopsOnParallelLines() throws {
        let parallel = try #require(LinearSystem2(rows: [[1, 1, 1], [1, 1, 5]]))
        let steps = parallel.gaussJordanSteps()
        let final = try #require(LinearSystem2.states(from: parallel, steps: steps).last)
        #expect(final.isDegenerate(1))
    }

    // MARK: - Grounding

    @Test("accepts a figure made of numbers the note contains")
    func groundedFigure() {
        let figure = OverviewFigure(kind: .systemOfLines, equations: [[1, 5, 7], [2, 1, 5]])
        #expect(NoteMath.isGrounded(figure, in: lecture))
    }

    @Test("rejects a figure with a number the note never wrote")
    func ungroundedFigure() {
        let figure = OverviewFigure(kind: .systemOfLines, equations: [[4, 5, 7], [2, 1, 5]])
        #expect(!NoteMath.isGrounded(figure, in: lecture))
    }

    @Test("doesn't count digits inside words or row names as numbers")
    func digitsInWordsDontCount() {
        let numbers = NoteMath.numbers(in: "word7 and R2 but 3x and 4.5")
        #expect(!numbers.contains(7))
        #expect(!numbers.contains(2))
        #expect(numbers.contains(3))
        #expect(numbers.contains(4.5))
    }

    // MARK: - Is there anything to draw?

    @Test("a note that writes out a system supports drawing its lines")
    func systemSupportsLines() {
        #expect(NoteMath.supportedFigureKinds(in: lecture) == [.systemOfLines])
        #expect(NoteMath.isMathematical(lecture))
    }

    @Test("a lecture that isn't math supports no figure, whatever numbers it has")
    func nonMathSupportsNothing() {
        // Real lines from a lecture on AI agents, LaTeX included.
        let workshop = """
            \\(88\\%\\) companies adopt AI, but only \\(6\\%\\) workers use agentic AI.
            AI completes in 4.5 minutes vs. 5 hours: t_AI = 4.5 min, t_human = 300 min.
            With 28 workflows running 36 times, proactive automation transforms daily operations.
            """
        #expect(NoteMath.supportedFigureKinds(in: workshop).isEmpty)
        #expect(!NoteMath.isMathematical(workshop))
    }

    @Test("a note about matrices supports a transformation figure")
    func matricesSupportTransforms() {
        let text = "A matrix is a linear transformation. Multiplying by the matrix [[2, 0], [0, 1]] stretches x."
        #expect(NoteMath.supportedFigureKinds(in: text).contains(.linearTransform))
    }

    // MARK: - Correcting a model's arithmetic

    @Test("corrects a wrong stated solution")
    func correctsWrongSolution() {
        // Verbatim from a real 7B run: the answer is x = 5, y = 1.
        let text = "What if we change the numbers to x + 2y = 7 and x + y = 6? The lines still intersect, at x = 3, y = 3."
        #expect(NoteMath.correctingSolutions(in: text)
            == "What if we change the numbers to x + 2y = 7 and x + y = 6? The lines still intersect, at x = 5, y = 1.")
    }

    @Test("corrects the (x, y) = (a, b) form too")
    func correctsPointForm() {
        let text = "Take x + 5y = 7 and 2x + y = 5. Notice the solution (x, y) = (1, 1) is unchanged."
        #expect(NoteMath.correctingSolutions(in: text).contains("(x, y) = (2, 1)"))
    }

    @Test("leaves a correct solution exactly as written")
    func keepsCorrectSolution() {
        let text = "For x + y = 5, x − y = 1 the solution is x = 3, y = 2."
        #expect(NoteMath.correctingSolutions(in: text) == text)
    }

    @Test("understands fractions in a stated solution")
    func fractionSolutions() {
        let text = "Solving 2x + 3y = 6 and x - y = 1 gives x = 9/5 and y = 4/5."
        #expect(NoteMath.correctingSolutions(in: text) == text)
    }

    @Test("checks each claim against the system just before it")
    func nearestSystemWins() {
        let text = "First x + y = 5 and x - y = 1 give x = 3, y = 2. Then x + 2y = 7 and x + y = 6 give x = 3, y = 3."
        let fixed = NoteMath.correctingSolutions(in: text)
        #expect(fixed.contains("give x = 3, y = 2."))
        #expect(fixed.contains("give x = 5, y = 1."))
    }

    @Test("leaves text alone when there's no system to check against")
    func nothingToCheck() {
        let text = "The answer is x = 3, y = 3."
        #expect(NoteMath.correctingSolutions(in: text) == text)
    }

    @Test("corrects a bare coordinate pair stated as the solution")
    func correctsBarePoint() {
        // Verbatim from a real 7B run: x + 5y = 7 and 2x + y = 5 cross at (2, 1).
        let text = "Consider the system x + 5y = 7 and 2x + y = 5. Their intersection gives the solution (3, 2)."
        #expect(NoteMath.correctingSolutions(in: text)
            == "Consider the system x + 5y = 7 and 2x + y = 5. Their intersection gives the solution (2, 1).")
    }

    @Test("leaves a coordinate pair alone when nothing says it's a solution")
    func leavesUnrelatedPairs() {
        let text = "Take x + 5y = 7 and 2x + y = 5, and compare them with the vector (3, 2)."
        #expect(NoteMath.correctingSolutions(in: text) == text)
    }

    @Test("doesn't correct a claim against a system the text has moved on from")
    func leavesClaimsAfterAChangedSystem() {
        // A lone equation shifts the pairing: the claim is right for the
        // system it follows, and must stay as written.
        let loneFirst = "Take 3x + 2y = 7 on its own. Now solve x + y = 5 and x - y = 1: the answer is x = 3, y = 2."
        #expect(NoteMath.correctingSolutions(in: loneFirst) == loneFirst)
        // The first equation is changed before the second claim.
        let changed = "x + y = 2 and x - y = 0 meet at (1, 1). Change the first to x + y = 4 and the new crossing point is (2, 2)."
        #expect(NoteMath.correctingSolutions(in: changed) == changed)
    }
}
