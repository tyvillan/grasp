import Foundation
import Testing
@testable import GRASPCore

private func m(_ rows: [[Int]], bar: Int = 0) -> RationalMatrix {
    RationalMatrix(rows: rows.map { $0.map(Rational.init) }, augmentedColumns: bar)!
}

/// The worked example from Matrix Theory lecture 2, as the note writes it.
private let lectureTwo = """
## Worked Example - Exercise 12, p. 23

Starting matrix (rows read left to right):

```
[ 1  -7   0   6 |  5 ]
[ 0   0   1  -2 | -3 ]
[ -1  7  -4   2 |  7 ]
```

**Step 1** - R₃ → R₃ + R₁ (his phrasing: *"I replaced row 3 with row 3 plus row 1"*), giving `0 0 -4 8 | 12`.

**Step 2** - R₃ → R₃ + 4·R₂, giving a zero row.

Result:

```
[ 1  -7   0   6 |  5 ]
[ 0   0   1  -2 | -3 ]
[ 0   0   0   0 |  0 ]
```

- **Pivot / basic variables:** x₁, x₃
- **Free variables:** x₂, x₄ (their columns hold no pivot)
"""

@Suite("Exact fractions")
struct RationalTests {
    @Test("reduces, keeps the sign on top, and prints like a whiteboard")
    func basics() {
        #expect(Rational(2, -4)?.description == "−1/2")
        #expect(Rational(6, 3) == Rational(2))
        #expect(Rational(1, 0) == nil)
        #expect(Rational(1, 3)!.adding(Rational(1, 6)!) == Rational(1, 2))
        #expect(Rational(-2, 3)!.multiplied(by: Rational(3, 4)!) == Rational(-1, 2))
    }

    @Test("recovers the fraction a stored multiplier came from")
    func approximating() {
        #expect(Rational(approximating: 1.0 / 3.0) == Rational(1, 3))
        #expect(Rational(approximating: -0.5) == Rational(-1, 2))
        #expect(Rational(approximating: 4) == Rational(4))
        #expect(Rational(approximating: -2.0 / 7.0) == Rational(-2, 7))
        #expect(Rational(approximating: .pi) == nil)
    }

    @Test("overflow is reported, not trapped")
    func overflow() {
        let big = Rational(Int.max / 2)
        #expect(big.multiplied(by: Rational(4)) == nil)
    }
}

@Suite("Row reduction")
struct RowReductionTests {
    @Test("echelon form: each rule's violation names the entry to fix")
    func echelonViolations() {
        #expect(m([[1, 2], [0, 3]]).isEchelon)
        #expect(m([[0, 0], [1, 2]]).echelonViolation?.rule == .zeroRowAboveNonzero)

        let start = m([[1, -7, 0, 6, 5], [0, 0, 1, -2, -3], [-1, 7, -4, 2, 7]], bar: 1)
        let violation = try! #require(start.echelonViolation)
        #expect(violation.rule == .nonzeroBelowLeadingEntry)
        #expect(violation.cells.first == RationalMatrix.Cell(row: 2, column: 0))
        #expect(violation.explanation.contains("−1"))
    }

    @Test("reduced form adds leading 1s and clear columns")
    func reducedViolations() {
        #expect(m([[2, 0], [0, 1]]).reducedEchelonViolation?.rule == .leadingEntryNotOne)
        #expect(m([[1, 3], [0, 1]]).reducedEchelonViolation?.rule == .nonzeroAboveLeadingOne)
        #expect(m([[1, 0, 2], [0, 1, 5]]).isReducedEchelon)
    }

    @Test("pivots, free variables and inconsistency read off an echelon matrix")
    func structure() {
        let result = m([[1, -7, 0, 6, 5], [0, 0, 1, -2, -3], [0, 0, 0, 0, 0]], bar: 1)
        #expect(result.pivotCells == [.init(row: 0, column: 0), .init(row: 1, column: 2)])
        #expect(result.variableKinds?.basic == [0, 2])
        #expect(result.variableKinds?.free == [1, 3])
        #expect(result.inconsistentRow == nil)
        #expect(m([[1, 2, 5], [0, 0, 4]], bar: 1).inconsistentRow == 1)
    }

    @Test("computed steps always reach the form they promise")
    func computedStepsReachForm() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let rows = Int.random(in: 2...4, using: &generator)
            let columns = Int.random(in: 2...5, using: &generator)
            let matrix = m((0..<rows).map { _ in (0..<columns).map { _ in Int.random(in: -5...5, using: &generator) } })
            let toEchelon = matrix.walk(matrix.echelonSteps(maximum: 40))
            #expect(toEchelon.states.last!.isEchelon, "\(matrix.rows)")
            let toReduced = matrix.walk(matrix.reducedEchelonSteps(maximum: 60))
            #expect(toReduced.states.last!.isReducedEchelon, "\(matrix.rows)")
        }
    }

    @Test("an invalid operation is refused, not guessed at")
    func invalidOperations() {
        let matrix = m([[1, 2], [3, 4]])
        #expect(matrix.applying(RowOperation(kind: .replace, target: 1, source: 1, multiplier: 2)) == nil)
        #expect(matrix.applying(RowOperation(kind: .scale, target: 1, multiplier: 0)) == nil)
        #expect(matrix.applying(RowOperation(kind: .swap, target: 1, source: 5)) == nil)
    }
}

@Suite("Matrices in notes")
struct NoteMatricesTests {
    @Test("reads bracketed matrices with an augmentation bar, any width")
    func bracketed() {
        let found = NoteMatrices.matrices(in: lectureTwo)
        #expect(found.count == 2)
        #expect(found[0].matrix == m([[1, -7, 0, 6, 5], [0, 0, 1, -2, -3], [-1, 7, -4, 2, 7]], bar: 1))
        #expect(found[1].matrix.augmentedColumns == 1)
    }

    @Test("reads LaTeX matrices, including an array's bar")
    func latex() {
        let text = #"Take \begin{bmatrix} 1 & 2 \\ 3 & 4 \end{bmatrix} and \begin{array}{cc|c} 1 & 1/2 & 3 \\ 0 & 1 & -2 \end{array}."#
        let found = NoteMatrices.matrices(in: text)
        #expect(found.count == 2)
        #expect(found[0].matrix == m([[1, 2], [3, 4]]))
        #expect(found[1].matrix.augmentedColumns == 1)
        #expect(found[1].matrix[0, 1] == Rational(1, 2))
    }

    @Test("reads row operations however they're written")
    func operations() {
        let ops = NoteMatrices.operations(in: """
            R₃ → R₃ + R₁, then R3 -> R3 + 4·R2, R_2 = R_2 - (1/2)R_1, \
            R1 <-> R2, R₂ → 1/3 R₂, R3 -> -R3
            """).map(\.operation)
        #expect(ops == [
            RowOperation(kind: .replace, target: 3, source: 1, exact: Rational(1)),
            RowOperation(kind: .replace, target: 3, source: 2, exact: Rational(4)),
            RowOperation(kind: .replace, target: 2, source: 1, exact: Rational(-1, 2)!),
            RowOperation(kind: .swap, target: 1, source: 2),
            RowOperation(kind: .scale, target: 2, exact: Rational(1, 3)!),
            RowOperation(kind: .scale, target: 3, exact: Rational(-1)),
        ])
    }

    @Test("lecture 2's example: the note's own steps, checked against the note's own result")
    func lectureTwoWalkthrough() throws {
        let walk = try #require(NoteMatrices.walkthroughs(in: lectureTwo).first)
        #expect(walk.stepsFromNote)
        #expect(walk.matchesNoteResult)
        #expect(walk.steps.count == 2)
        let states = walk.start.walk(walk.steps).states
        #expect(states[1].rows[2] == [0, 0, -4, 8, 12].map(Rational.init))
        #expect(states[2].isReducedEchelon)
        #expect(states[2].variableKinds?.free == [1, 3])
    }

    @Test("with no steps written, GRASP computes them; a matrix already reduced isn't an example")
    func computedWalkthrough() throws {
        let text = """
        Reduce this:
        [ 2  4  6 ]
        [ 1  3  5 ]
        And the identity [1 0] [0 1] is already reduced.
        """
        let walks = NoteMatrices.walkthroughs(in: text)
        #expect(walks.count == 1)
        let walk = try #require(walks.first)
        #expect(!walk.stepsFromNote)
        #expect(walk.start.walk(walk.steps).states.last!.isReducedEchelon)
    }

    @Test("a two-variable system is left to the lines figure")
    func twoVariableSystemsSkipped() {
        #expect(NoteMatrices.walkthroughs(in: "[1 2 | 3]\n[4 5 | 6]").isEmpty)
    }

    @Test("prose with bracketed citations or lists isn't mistaken for a matrix")
    func notMatrices() {
        #expect(NoteMatrices.matrices(in: "See [1] and [2]. Items [a b] [c d].").isEmpty)
        #expect(NoteMatrices.matrices(in: "A single row [1 2 3] is a vector, not a walkthrough.").isEmpty)
    }
}

@Suite("Is / isn't contrasts")
struct MatrixContrastTests {
    @Test("every stock example is what it claims to be")
    func defaultsAreTrue() {
        typealias D = MatrixContrasts.Defaults
        #expect(D.echelon.isEchelon && !D.echelon.isReducedEchelon)
        #expect(!D.notEchelon.isEchelon)
        #expect(D.reduced.isReducedEchelon)
        #expect(D.echelonNotReduced.isEchelon && !D.echelonNotReduced.isReducedEchelon)
        #expect(D.withFreeVariables.variableKinds?.free.isEmpty == false)
        #expect(D.inconsistent.inconsistentRow != nil)
        #expect(D.consistent.isEchelon && D.consistent.inconsistentRow == nil)
    }

    @Test("terms map to the right concept, the more specific one first")
    func concepts() {
        #expect(MatrixContrasts.concept(forTerm: "Reduced echelon form") == .reducedEchelonForm)
        #expect(MatrixContrasts.concept(forTerm: "Echelon form (EF / REF)") == .echelonForm)
        #expect(MatrixContrasts.concept(forTerm: "Pivot position") == .pivot)
        #expect(MatrixContrasts.concept(forTerm: "Free variable") == .freeVariable)
        #expect(MatrixContrasts.concept(forTerm: "Inconsistency signature") == .inconsistent)
        #expect(MatrixContrasts.concept(forTerm: "Opportunity cost") == nil)
    }

    @Test("the lecture's own matrices are used: start as the non-example, result as the example")
    func fromNotes() throws {
        let walk = try #require(NoteMatrices.walkthroughs(in: lectureTwo).first)
        let pool = NoteMatrices.matrices(in: lectureTwo).map(\.matrix) + walk.start.walk(walk.steps).states
        let contrast = try #require(MatrixContrasts.contrast(forTerm: "Echelon form", noteMatrices: pool))
        #expect(contrast.isExample.fromNotes && contrast.isExample.matrix.isEchelon)
        #expect(contrast.isNotExample.fromNotes && !contrast.isNotExample.matrix.isEchelon)
        #expect(contrast.isNotExample.offending == [RationalMatrix.Cell(row: 2, column: 0)])

        let free = try #require(MatrixContrasts.contrast(forTerm: "Free variable", noteMatrices: pool))
        #expect(free.isExample.highlightedColumns == [1, 3])
        #expect(free.isNotExample.highlightedColumns == [0, 2])
    }

    @Test("every concept yields a checked contrast even with no matrices in the note")
    func everyConceptWithoutNotes() {
        for concept in MatrixContrasts.Concept.allCases {
            let term: String = switch concept {
            case .echelonForm: "echelon form"
            case .reducedEchelonForm: "reduced echelon form"
            case .pivot: "pivot"
            case .freeVariable: "free variable"
            case .basicVariable: "basic variable"
            case .inconsistent: "inconsistent system"
            case .consistent: "consistent system"
            }
            let contrast = MatrixContrasts.contrast(forTerm: term, noteMatrices: [])
            #expect(contrast?.concept == concept)
            #expect(contrast?.isExample.fromNotes == false)
        }
    }
}

@Suite("Worked examples and figures in the lesson")
struct LessonExampleTests {
    @Test("a row-reduction figure lands beside the section that teaches it")
    func figurePlacement() {
        var document = OverviewDocument(sections: [
            OverviewSection(heading: "Linear systems have three possible outcomes", paragraphs: ["..."]),
            OverviewSection(heading: "Row reduction reaches a staircase called echelon form", paragraphs: ["pivot"]),
        ])
        OverviewComposer.attachExtractedFigures(to: &document, noteText: lectureTwo)
        #expect(document.sections[1].figure?.kind == .rowReduction)
        #expect(document.sections[1].figure?.stepsFromNote == true)
        #expect(document.sections[0].figure == nil)
    }

    @Test("the figure goes beside the section that names its operations, not just its vocabulary")
    func placementByOperations() {
        var document = OverviewDocument(sections: [
            OverviewSection(heading: "Reduced form is unique", paragraphs: ["pivot echelon row reduction reduce"]),
            OverviewSection(heading: "The staircase forms", paragraphs: ["We clear the -1."],
                            example: OverviewWorkedExample(steps: [
                                OverviewExampleStep(action: "Apply R₃ → R₃ + R₁"),
                                OverviewExampleStep(action: "Apply R3 -> R3 + 4R2"),
                            ])),
        ])
        OverviewComposer.attachExtractedFigures(to: &document, noteText: lectureTwo)
        #expect(document.sections[1].figure?.kind == .rowReduction)
    }

    @Test("matrix-row examples are recognised; other procedures are not")
    func matrixRowExamples() {
        let rows = OverviewWorkedExample(steps: [OverviewExampleStep(action: "Clear it", result: "0 0 -4 8 | 12"),
                                                 OverviewExampleStep(action: "Again")])
        let ops = OverviewWorkedExample(steps: [OverviewExampleStep(action: "R1 <-> R2"), OverviewExampleStep(action: "x")])
        let prose = OverviewWorkedExample(steps: [OverviewExampleStep(action: "Add (1, 2) and (3, 4)", result: "(4, 6)"),
                                                  OverviewExampleStep(action: "Scale by 2", result: "(8, 12)")])
        #expect(OverviewComposer.manipulatesMatrixRows(rows))
        #expect(OverviewComposer.manipulatesMatrixRows(ops))
        #expect(!OverviewComposer.manipulatesMatrixRows(prose))
    }

    @Test("an example whose numbers aren't in the note is dropped")
    func groundedExamples() {
        let real = OverviewWorkedExample(steps: [
            OverviewExampleStep(action: "Add row 1 to row 3", result: "0 0 -4 8 | 12"),
            OverviewExampleStep(action: "Add 4 times row 2 to row 3", result: "0 0 0 0 | 0"),
        ])
        let invented = OverviewWorkedExample(steps: [
            OverviewExampleStep(action: "Subtract 13 times row 1", result: "0 91 -4 | 57"),
            OverviewExampleStep(action: "Done"),
        ])
        let kept = OverviewComposer.groundedExample(
            in: OverviewSection(heading: "h", paragraphs: ["p"], example: real), noteText: lectureTwo)
        let dropped = OverviewComposer.groundedExample(
            in: OverviewSection(heading: "h", paragraphs: ["p"], example: invented), noteText: lectureTwo)
        #expect(kept.example != nil)
        #expect(dropped.example == nil)
    }

    @Test("a lesson written before these fields existed still decodes")
    func olderBodiesDecode() throws {
        let v3 = #"{"formulas":[],"objectives":[],"sections":[{"heading":"H","paragraphs":["P"],"terms":[{"term":"T","text":"D"}]}],"takeaways":[]}"#
        let document = try #require(OverviewCoding.decode(v3))
        #expect(document.sections[0].example == nil)
        #expect(document.sections[0].terms[0].nonExample == nil)
    }
}

@Suite("Math notation")
struct MathNotationTests {
    @Test("indices become subscripts; words, versions and dimensions don't")
    func prettify() {
        #expect(MathNotation.prettify("a11x1 + a12x2 = b1") == "a₁₁x₁ + a₁₂x₂ = b₁")
        #expect(MathNotation.prettify("x_2 and b_{3}, a_ij") == "x₂ and b₃, aᵢⱼ")
        #expect(MathNotation.prettify("a vector x in R3 and a 3x3 matrix") == "a vector x in ℝ³ and a 3×3 matrix")
        #expect(MathNotation.prettify("R2 -> R2 - 2R1") == "R₂ → R₂ - 2R₁")
        #expect(MathNotation.prettify("x^2 and A^T") == "x² and Aᵀ")
        #expect(MathNotation.prettify("I am in an mp3 of word2vec on Python3") == "I am in an mp3 of word2vec on Python3")
    }

    @Test("written-out vectors and matrices become drawable pieces")
    func pieces() {
        let pieces = MathNotation.pieces(from: "x1(a11, a21, a31) + x2(a12, a22, a32) = b.")
        #expect(pieces == [
            .text("x₁"), .vector(["a₁₁", "a₂₁", "a₃₁"]), .text(" + x₂"), .vector(["a₁₂", "a₂₂", "a₃₂"]), .text(" = b."),
        ])
        #expect(MathNotation.pieces(from: "[a1 a2 a3 | b] where the bar splits") == [
            .matrix(rows: [["a₁", "a₂", "a₃", "b"]], bar: 1), .text(" where the bar splits"),
        ])
        #expect(MathNotation.pieces(from: "[1 2; 3 4]") == [.matrix(rows: [["1", "2"], ["3", "4"]], bar: 0)])
    }

    @Test("prose in brackets is left as prose")
    func prose() {
        #expect(!MathNotation.hasObjects("(see p. 28, the green box)"))
        #expect(!MathNotation.hasObjects("[citation needed]"))
    }
}

@Suite("Step visuals")
struct StepVisualTests {
    @Test("a matrix of the note's numbers or symbols is kept; invented numbers aren't")
    func matrices() {
        let symbols = OverviewStepVisual(kind: .matrix, rows: [["a11", "a12"], ["a21", "a22"]], highlightColumns: [0, 5])
        let kept = StepVisuals.validate(symbols, noteText: "anything", isMath: true)
        #expect(kept?.highlightColumns == [0])
        let invented = OverviewStepVisual(kind: .matrix, rows: [["13", "2"], ["4", "97"]])
        #expect(StepVisuals.validate(invented, noteText: lectureTwoNumbers, isMath: true) == nil)
        #expect(StepVisuals.validate(symbols, noteText: "", isMath: false) == nil)
    }

    @Test("vectors must be the note's own, and flows fit any course")
    func vectorsAndFlows() {
        let vectors = OverviewStepVisual(kind: .vectors, vectors: [VisualVector(label: "u1", x: 2, y: 5)], combine: true)
        #expect(StepVisuals.validate(vectors, noteText: "u = (2, 5)", isMath: true)?.vectors?.first?.label == "u₁")
        #expect(StepVisuals.validate(vectors, noteText: "u = (3, 4)", isMath: true) == nil)
        let flow = OverviewStepVisual(kind: .flow, nodes: ["Request", " ", "Controller", "View"], highlight: 1)
        let cleaned = StepVisuals.validate(flow, noteText: "", isMath: false)
        #expect(cleaned?.nodes == ["Request", "Controller", "View"])
        #expect(StepVisuals.validate(OverviewStepVisual(kind: .flow, nodes: ["Only one"]), noteText: "", isMath: false) == nil)
    }
}

private let lectureTwoNumbers = "[ 1 -7 0 6 | 5 ] [ 0 0 1 -2 | -3 ]"
