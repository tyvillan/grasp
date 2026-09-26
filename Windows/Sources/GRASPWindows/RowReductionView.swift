import Foundation
import GRASPCore
import SwiftCrossUI

/// The row reduction from a deck's notes, one step at a time: the matrix
/// before, the operation, the matrix after with the changed row marked.
/// The Windows counterpart of the Mac overview's row-reduction figure,
/// drawn from native text and shapes.
struct RowReductionView: View {
    let reduction: RowReductionSteps
    @State var step = 0

    var body: some View {
        let stepCount = reduction.steps.count
        VStack(alignment: .leading, spacing: 12) {
            Text("ROW REDUCTION FROM YOUR NOTES").font(.caption).foregroundColor(.gray)
            if stepCount == 0 {
                MatrixGrid(matrix: reduction.states[0], changedRow: nil)
            } else {
                Text("Step \(step + 1) of \(stepCount): \(OverviewFigures.label(reduction.steps[step]))")
                    .font(.headline)
                HStack(spacing: 18) {
                    MatrixGrid(matrix: reduction.states[step], changedRow: nil)
                    Text("→").font(.title)
                    MatrixGrid(matrix: reduction.states[step + 1], changedRow: changedRow(reduction.steps[step]))
                }
                HStack(spacing: 8) {
                    // .fixedSize(): a row of buttons otherwise squeezes one to "N…".
                    Button("Previous") { step -= 1 }.disabled(step == 0).fixedSize()
                    Button("Next") { step += 1 }.disabled(step >= stepCount - 1).fixedSize()
                }
                if step == stepCount - 1, reduction.states[stepCount].isReducedEchelon {
                    Text("Reduced echelon form: every pivot is 1, alone in its column.")
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(18)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(10)
    }
}

/// The row a step rewrote, 0-based -- operations number rows from 1, as
/// written (R₁, R₂). A swap changes two rows, so it marks neither.
private func changedRow(_ step: RowOperation) -> Int? {
    step.kind == .swap ? nil : step.target - 1
}

/// A matrix in brackets, with the augmented column behind a bar and one
/// row optionally highlighted.
struct MatrixGrid: View {
    let matrix: RationalMatrix
    let changedRow: Int?

    private let cellWidth = 44.0

    var body: some View {
        HStack(spacing: 4) {
            Bracket(opening: true).stroke(.gray, style: StrokeStyle(width: 1.5)).frame(width: 7)
            VStack(spacing: 2) {
                ForEach(Array(0..<matrix.rowCount), id: \.self) { row in
                    rowView(row)
                }
            }
            Bracket(opening: false).stroke(.gray, style: StrokeStyle(width: 1.5)).frame(width: 7)
        }
    }
}

extension MatrixGrid {
    private func rowView(_ row: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(0..<matrix.columnCount), id: \.self) { column in
                cell(row: row, column: column)
            }
        }
        .background(row == changedRow ? Color.blue.opacity(0.18) : Color.clear)
        .cornerRadius(4)
    }

    /// One entry, with the augmented bar in front of the first column
    /// right of it.
    private func cell(row: Int, column: Int) -> some View {
        let barBefore = matrix.augmentedColumns > 0 && column == matrix.coefficientColumns
        return HStack(spacing: 0) {
            Rectangle().fill(barBefore ? Color.gray : Color.clear).frame(width: 1.0, height: 22.0)
            Text(matrix[row, column].description)
                .frame(width: cellWidth, height: 26.0)
        }
    }
}

/// One side of a matrix's square brackets.
struct Bracket: Shape {
    let opening: Bool

    func path(in bounds: Path.Rect) -> Path {
        let inner = opening ? bounds.maxX : bounds.x
        let outer = opening ? bounds.x + 1 : bounds.maxX - 1
        return Path()
            .move(to: SIMD2(inner, bounds.y + 1))
            .addLine(to: SIMD2(outer, bounds.y + 1))
            .addLine(to: SIMD2(outer, bounds.maxY - 1))
            .addLine(to: SIMD2(inner, bounds.maxY - 1))
    }
}
