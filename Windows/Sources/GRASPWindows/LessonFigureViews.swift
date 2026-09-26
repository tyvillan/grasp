import Foundation
import GRASPCore
import SwiftCrossUI

// The lesson's figures, drawn with SwiftCrossUI shapes: row reductions,
// two lines stepped through row operations, a 2x2 matrix as the plane it
// deforms, "is / isn't" matrix pairs, step pictures, and the concept map.
// After the Mac's LessonFigures, MatrixFigures, StepVisualViews and
// ConceptDiagramView, simplified where SwiftCrossUI has no canvas.

/// A figure with its caption, on a raised panel.
struct FigureCard: View {
    let figure: RenderedFigure

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch figure {
            case .lines(let lines):
                LinesFigureView(figure: lines)
            case .transform(let transform):
                TransformFigureView(figure: transform)
            case .rowReduction(let walk):
                RowReductionView(reduction: RowReductionSteps(states: walk.states, steps: walk.steps,
                                                              fromNote: walk.stepsFromNote))
            }
            if let caption = figure.caption {
                Text(LessonText.clean(caption))
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
        }
        .padding(16)
        .background(GRASPColor.surface)
        .cornerRadius(10)
    }
}

// MARK: - Plot helpers

/// Maps figure coordinates (y up) into a view's bounds (y down), with the
/// same scale on both axes so angles and slopes read true.
nonisolated struct PlotWindow: Sendable {
    let minX: Double, maxX: Double, minY: Double, maxY: Double

    /// A square window around the origin wide enough for every point.
    static func around(_ points: [Point2], minimumHalfWidth: Double = 4) -> PlotWindow {
        let reach = points.reduce(minimumHalfWidth) { max($0, abs($1.x) + 1.5, abs($1.y) + 1.5) }
        let half = reach.rounded(.up)
        return PlotWindow(minX: -half, maxX: half, minY: -half, maxY: half)
    }

    func point(_ p: Point2, in bounds: Path.Rect) -> SIMD2<Double> {
        SIMD2(bounds.x + (p.x - minX) / (maxX - minX) * bounds.width,
              bounds.y + (maxY - p.y) / (maxY - minY) * bounds.height)
    }
}

/// Faint unit grid lines and darker axes.
private struct GridShape: Shape {
    let window: PlotWindow
    let axesOnly: Bool

    func path(in bounds: Path.Rect) -> Path {
        var path = Path()
        func line(_ a: Point2, _ b: Point2) {
            path = path.move(to: window.point(a, in: bounds)).addLine(to: window.point(b, in: bounds))
        }
        if axesOnly {
            line(Point2(x: window.minX, y: 0), Point2(x: window.maxX, y: 0))
            line(Point2(x: 0, y: window.minY), Point2(x: 0, y: window.maxY))
        } else {
            for x in stride(from: window.minX, through: window.maxX, by: 1) where x != 0 {
                line(Point2(x: x, y: window.minY), Point2(x: x, y: window.maxY))
            }
            for y in stride(from: window.minY, through: window.maxY, by: 1) where y != 0 {
                line(Point2(x: window.minX, y: y), Point2(x: window.maxX, y: y))
            }
        }
        return path
    }
}

/// a·x + b·y = c, clipped to the window.
private struct EquationLine: Shape {
    let row: [Double]
    let window: PlotWindow

    func path(in bounds: Path.Rect) -> Path {
        let (a, b, c) = (row[0], row[1], row[2])
        let ends: (Point2, Point2)
        if abs(b) > 1e-9 {
            ends = (Point2(x: window.minX, y: (c - a * window.minX) / b),
                    Point2(x: window.maxX, y: (c - a * window.maxX) / b))
        } else if abs(a) > 1e-9 {
            ends = (Point2(x: c / a, y: window.minY), Point2(x: c / a, y: window.maxY))
        } else {
            return Path()
        }
        return Path().move(to: window.point(ends.0, in: bounds)).addLine(to: window.point(ends.1, in: bounds))
    }
}

/// A filled dot.
private struct Dot: Shape {
    let at: Point2
    let window: PlotWindow
    let radius: Double

    func path(in bounds: Path.Rect) -> Path {
        Path().addCircle(center: window.point(at, in: bounds), radius: radius)
    }
}

/// Arrows from the origin (or tip to tail), with small heads.
private struct ArrowShape: Shape {
    let from: Point2
    let to: Point2
    let window: PlotWindow

    func path(in bounds: Path.Rect) -> Path {
        let start = window.point(from, in: bounds)
        let end = window.point(to, in: bounds)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = 8.0, spread = Double.pi / 7
        return Path()
            .move(to: start).addLine(to: end)
            .move(to: end)
            .addLine(to: SIMD2(end.x - length * cos(angle - spread), end.y - length * sin(angle - spread)))
            .move(to: end)
            .addLine(to: SIMD2(end.x - length * cos(angle + spread), end.y - length * sin(angle + spread)))
    }
}

// MARK: - Two lines

/// Two equations as lines crossing at the solution, stepped through the
/// row operations that solve them. Each operation changes one line but
/// never the point where they cross -- which is the whole lesson.
struct LinesFigureView: View {
    let figure: LinesFigure
    @State var step = 0

    var body: some View {
        let system = figure.states[min(step, figure.states.count - 1)]
        let window = PlotWindow.around(figure.states.compactMap(\.solution))
        let side = 300.0
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Rectangle().fill(GRASPColor.canvas)
                GridShape(window: window, axesOnly: false).stroke(GRASPColor.hairline)
                GridShape(window: window, axesOnly: true).stroke(GRASPColor.hairlineStrong, style: StrokeStyle(width: 1.5))
                EquationLine(row: system.rows[0], window: window)
                    .stroke(GRASPColor.figureBlue, style: StrokeStyle(width: 2.5))
                EquationLine(row: system.rows[1], window: window)
                    .stroke(GRASPColor.figureAmber, style: StrokeStyle(width: 2.5))
                if let solution = system.solution {
                    Dot(at: solution, window: window, radius: 5).fill(GRASPColor.textPrimary)
                }
            }
            .frame(width: side, height: side)
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(equation(system.rows[0])).font(LessonFont.formula).foregroundColor(GRASPColor.figureBlue)
                Text(equation(system.rows[1])).font(LessonFont.formula).foregroundColor(GRASPColor.figureAmber)
                if let solution = system.solution {
                    Text("They cross at (\(OverviewFigures.format(solution.x)), \(OverviewFigures.format(solution.y)))")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textSecondary)
                }
            }

            if !figure.steps.isEmpty {
                Text(step == 0 ? "The system as written" : "After step \(step): \(OverviewFigures.label(figure.steps[step - 1]))")
                    .font(GRASPFont.rowTitle)
                    .foregroundColor(GRASPColor.textPrimary)
                HStack(spacing: 8) {
                    Button("Previous") { step -= 1 }.disabled(step == 0).fixedSize()
                    Button("Next") { step += 1 }.disabled(step >= figure.steps.count).fixedSize()
                }
            }
        }
    }

    private func equation(_ row: [Double]) -> String {
        func term(_ value: Double, _ name: String, first: Bool) -> String {
            if value == 0 { return "" }
            let sign = value < 0 ? (first ? "−" : " − ") : (first ? "" : " + ")
            let magnitude = abs(value) == 1 ? "" : OverviewFigures.format(abs(value))
            return sign + magnitude + name
        }
        let x = term(row[0], "x", first: true)
        let y = term(row[1], "y", first: x.isEmpty)
        return "\(x)\(y) = \(OverviewFigures.format(row[2]))"
    }
}

// MARK: - A 2x2 matrix as a transformation

/// Where a 2x2 matrix sends the plane: the unit grid, the grid after the
/// matrix, and where î and ĵ land (the matrix's columns).
struct TransformFigureView: View {
    let figure: TransformFigure

    var body: some View {
        let m = figure.matrix
        let window = PlotWindow.around([m.iHat, m.jHat, m.apply(Point2(x: 1, y: 1))], minimumHalfWidth: 3)
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Rectangle().fill(GRASPColor.canvas)
                GridShape(window: window, axesOnly: false).stroke(GRASPColor.hairline)
                GridShape(window: window, axesOnly: true).stroke(GRASPColor.hairlineStrong)
                TransformedGrid(matrix: m, window: window).stroke(GRASPColor.figureBlue.opacity(0.45))
                ArrowShape(from: Point2(x: 0, y: 0), to: m.iHat, window: window)
                    .stroke(GRASPColor.success, style: StrokeStyle(width: 2.5))
                ArrowShape(from: Point2(x: 0, y: 0), to: m.jHat, window: window)
                    .stroke(GRASPColor.rejected, style: StrokeStyle(width: 2.5))
            }
            .frame(width: 280.0, height: 280.0)
            .cornerRadius(6)
            HStack(spacing: 16) {
                Text("î → (\(OverviewFigures.format(m.a)), \(OverviewFigures.format(m.c)))")
                    .font(LessonFont.formula).foregroundColor(GRASPColor.success)
                Text("ĵ → (\(OverviewFigures.format(m.b)), \(OverviewFigures.format(m.d)))")
                    .font(LessonFont.formula).foregroundColor(GRASPColor.rejected)
            }
            Text("Area scales by det = \(OverviewFigures.format(m.determinant))"
                 + (m.determinant < 0 ? " (the plane is flipped)" : m.determinant == 0 ? " (the plane collapses onto a line)" : ""))
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textSecondary)
        }
    }
}

/// The unit grid's lines, sent through the matrix.
private struct TransformedGrid: Shape {
    let matrix: Matrix2
    let window: PlotWindow

    func path(in bounds: Path.Rect) -> Path {
        var path = Path()
        let reach = 6.0
        for k in stride(from: -reach, through: reach, by: 1) {
            for (a, b) in [(Point2(x: k, y: -reach), Point2(x: k, y: reach)),
                           (Point2(x: -reach, y: k), Point2(x: reach, y: k))] {
                path = path.move(to: window.point(matrix.apply(a), in: bounds))
                    .addLine(to: window.point(matrix.apply(b), in: bounds))
            }
        }
        return path
    }
}

// MARK: - Is / isn't

/// Two matrices side by side: one that is the term and one that isn't,
/// with the entries that decide it marked. A definition is learned at its
/// boundary.
struct MatrixContrastView: View {
    let contrast: MatrixContrasts.Contrast

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            panel(contrast.isExample, label: contrast.concept.labels.is, tint: GRASPColor.success)
            panel(contrast.isNotExample, label: contrast.concept.labels.isNot, tint: GRASPColor.rejected)
        }
    }

    private func panel(_ panel: MatrixContrasts.Panel, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased()).font(GRASPFont.badge).foregroundColor(tint)
            CellMatrixView(matrix: panel.matrix, marked: Set(panel.highlights), wrong: Set(panel.offending),
                           columns: Set(panel.highlightedColumns), row: panel.highlightedRow, markTint: tint)
            Text(panel.explanation + (panel.fromNotes ? " (from your notes)" : ""))
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textSecondary)
                .frame(width: 200.0, alignment: .leading)
        }
        .padding(10)
        .background(GRASPColor.surface)
        .cornerRadius(8)
    }
}

/// A matrix with individual entries, a column or a row marked.
struct CellMatrixView: View {
    let matrix: RationalMatrix
    var marked: Set<RationalMatrix.Cell> = []
    var wrong: Set<RationalMatrix.Cell> = []
    var columns: Set<Int> = []
    var row: Int?
    var markTint: Color = GRASPColor.accent

    var body: some View {
        HStack(spacing: 3) {
            Bracket(opening: true).stroke(GRASPColor.textTertiary, style: StrokeStyle(width: 1.5)).frame(width: 6.0)
            VStack(spacing: 1) {
                ForEach(Array(0..<matrix.rowCount), id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(Array(0..<matrix.columnCount), id: \.self) { c in
                            cell(r, c)
                        }
                    }
                    .background(r == row ? markTint.opacity(0.14) : Color.clear)
                }
            }
            Bracket(opening: false).stroke(GRASPColor.textTertiary, style: StrokeStyle(width: 1.5)).frame(width: 6.0)
        }
    }

    private func cell(_ r: Int, _ c: Int) -> some View {
        let spot = RationalMatrix.Cell(row: r, column: c)
        let barBefore = matrix.augmentedColumns > 0 && c == matrix.coefficientColumns
        let tint: Color? = wrong.contains(spot) ? GRASPColor.rejected : marked.contains(spot) ? markTint : nil
        return HStack(spacing: 0) {
            Rectangle().fill(barBefore ? GRASPColor.textTertiary : Color.clear).frame(width: 1.0, height: 18.0)
            Text(matrix[r, c].description)
                .font(Font.system(size: 13, weight: tint == nil ? .regular : .bold))
                .foregroundColor(tint ?? GRASPColor.textPrimary)
                .frame(width: 32.0, height: 22.0)
                .background(tint.map { $0.opacity(0.16) } ?? (columns.contains(c) ? markTint.opacity(0.08) : Color.clear))
                .cornerRadius(4)
        }
    }
}

// MARK: - Step pictures

/// A small picture for one step of a worked example.
struct StepVisualView: View {
    let visual: OverviewStepVisual

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch visual.kind {
            case .matrix:
                if let rows = visual.rows {
                    SymbolMatrixView(rows: rows, bar: visual.bar ?? 0,
                                     highlightRows: Set(visual.highlightRows ?? []),
                                     highlightColumns: Set(visual.highlightColumns ?? []))
                }
            case .vectors:
                if let vectors = visual.vectors {
                    VectorPlotView(vectors: vectors, combine: visual.combine ?? false)
                }
            case .flow:
                if let nodes = visual.nodes {
                    FlowStripView(nodes: nodes, highlight: visual.highlight)
                }
            }
            if let caption = visual.caption {
                Text(LessonText.clean(caption)).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
            }
        }
        .padding(12)
        .background(GRASPColor.surface)
        .cornerRadius(8)
    }
}

/// A matrix of symbols as written ("a11", "x1", "-1/2").
private struct SymbolMatrixView: View {
    let rows: [[String]]
    let bar: Int
    let highlightRows: Set<Int>
    let highlightColumns: Set<Int>

    var body: some View {
        let columnCount = rows.map(\.count).max() ?? 0
        HStack(spacing: 3) {
            Bracket(opening: true).stroke(GRASPColor.textTertiary, style: StrokeStyle(width: 1.5)).frame(width: 6.0)
            VStack(spacing: 1) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    HStack(spacing: 0) {
                        ForEach(Array(0..<columnCount), id: \.self) { c in
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(bar > 0 && c == columnCount - bar ? GRASPColor.textTertiary : Color.clear)
                                    .frame(width: 1.0, height: 18.0)
                                Text(c < row.count ? MathNotation.prettify(row[c]) : "")
                                    .font(Font.system(size: 14))
                                    .foregroundColor(GRASPColor.textPrimary)
                                    .frame(width: 40.0, height: 24.0)
                                    .background(highlightColumns.contains(c) ? GRASPColor.figureBlue.opacity(0.12) : Color.clear)
                            }
                        }
                    }
                    .background(highlightRows.contains(r) ? GRASPColor.figureAmber.opacity(0.16) : Color.clear)
                    .cornerRadius(4)
                }
            }
            Bracket(opening: false).stroke(GRASPColor.textTertiary, style: StrokeStyle(width: 1.5)).frame(width: 6.0)
        }
    }
}

/// Vectors from the origin; with `combine`, each scaled by its weight and
/// laid tip to tail, ending at the sum.
private struct VectorPlotView: View {
    let vectors: [VisualVector]
    let combine: Bool

    private static let colors = [GRASPColor.success, GRASPColor.rejected, GRASPColor.figureBlue, GRASPColor.figureAmber]

    var body: some View {
        let scaled = vectors.map { Point2(x: $0.x * ($0.weight ?? 1), y: $0.y * ($0.weight ?? 1)) }
        let tips: [Point2] = combine
            ? scaled.reduce(into: [Point2]()) { tips, v in
                let last = tips.last ?? Point2(x: 0, y: 0)
                tips.append(Point2(x: last.x + v.x, y: last.y + v.y))
            }
            : scaled
        let window = PlotWindow.around(tips + vectors.map { Point2(x: $0.x, y: $0.y) }, minimumHalfWidth: 3)
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(GRASPColor.canvas)
                GridShape(window: window, axesOnly: false).stroke(GRASPColor.hairline)
                GridShape(window: window, axesOnly: true).stroke(GRASPColor.hairlineStrong)
                ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
                    ArrowShape(from: combine && index > 0 ? tips[index - 1] : Point2(x: 0, y: 0), to: tip, window: window)
                        .stroke(Self.colors[index % Self.colors.count], style: StrokeStyle(width: 2.5))
                }
                if combine, let sum = tips.last, tips.count > 1 {
                    ArrowShape(from: Point2(x: 0, y: 0), to: sum, window: window)
                        .stroke(GRASPColor.textPrimary, style: StrokeStyle(width: 2))
                }
            }
            .frame(width: 220.0, height: 220.0)
            .cornerRadius(6)
            ForEach(Array(vectors.enumerated()), id: \.offset) { index, v in
                Text("\(MathNotation.prettify(v.label ?? "v\(index + 1)")) = (\(OverviewFigures.format(v.x)), \(OverviewFigures.format(v.y)))"
                     + (v.weight.map { $0 == 1 ? "" : ", × \(OverviewFigures.format($0))" } ?? ""))
                    .font(GRASPFont.meta)
                    .foregroundColor(Self.colors[index % Self.colors.count])
            }
        }
    }
}

/// Stages of a process in a row, with the current one lit.
private struct FlowStripView: View {
    let nodes: [String]
    let highlight: Int?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                if index > 0 {
                    Text("→").font(GRASPFont.body).foregroundColor(GRASPColor.textTertiary)
                }
                Text(node)
                    .font(GRASPFont.meta.weight(index == highlight ? .semibold : .regular))
                    .foregroundColor(index == highlight ? GRASPColor.accent : GRASPColor.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(index == highlight ? GRASPColor.accentSoft : GRASPColor.surfaceRaised)
                    .cornerRadius(6)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Concept map

/// The lesson's concept map, drawn where `DiagramLayout` placed each box.
/// Wider than the column scrolls sideways rather than shrinking the text.
struct ConceptMapView: View {
    let diagram: LaidOutDiagram

    var body: some View {
        let width = diagram.bounds.width
        let height = diagram.bounds.height
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(GRASPColor.surface).frame(width: width, height: height)
                DiagramEdges(diagram: diagram)
                    .stroke(GRASPColor.hairlineStrong, style: StrokeStyle(width: 1.25))
                    .frame(width: width, height: height)
                ForEach(diagram.nodes, id: \.id) { node in
                    nodeBox(node)
                }
                ForEach(diagram.edges.filter { $0.label != nil }, id: \.id) { edge in
                    edgeLabel(edge)
                }
            }
            .frame(width: width, height: height)
            .padding(12)
        }
        .frame(height: height + 24 + 12)
        .background(GRASPColor.surface)
        .cornerRadius(10)
    }

    private func nodeBox(_ node: LaidOutDiagram.PlacedNode) -> some View {
        let radius: Int = switch node.shape {
        case .stadium, .circle: Int(node.size.height / 2)
        case .rounded: 14
        default: 8
        }
        return VStack(spacing: 0) {
            ForEach(Array(node.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Font.system(size: 12, weight: .medium))
                    .foregroundColor(GRASPColor.textPrimary)
                    .fixedSize()
            }
        }
        .frame(width: node.size.width, height: node.size.height)
        .background(node.depth == 0 ? GRASPColor.accentSoft : GRASPColor.surfaceRaised)
        .cornerRadius(radius)
        .padding(.leading, Int((node.center.x - node.size.width / 2).rounded()))
        .padding(.top, Int((node.center.y - node.size.height / 2).rounded()))
    }

    private func edgeLabel(_ edge: LaidOutDiagram.PlacedEdge) -> some View {
        let middle = edge.waypoints[edge.waypoints.count / 2]
        let text = edge.label ?? ""
        let width = Double(text.count) * 6 + 10
        return Text(text)
            .font(Font.system(size: 10, weight: .medium))
            .foregroundColor(GRASPColor.textSecondary)
            .fixedSize()
            .padding(.horizontal, 4)
            .background(GRASPColor.surface)
            .cornerRadius(4)
            .padding(.leading, max(0, Int(middle.x - width / 2)))
            .padding(.top, max(0, Int(middle.y - 8)))
    }
}

/// Every edge as a curve bowed along the layout's flow, with an arrowhead
/// at the target -- the Mac's rule: curved lines never cut straight through
/// an unrelated box the way unrouted straight ones do.
private struct DiagramEdges: Shape {
    let diagram: LaidOutDiagram

    func path(in bounds: Path.Rect) -> Path {
        var path = Path()
        for edge in diagram.edges where edge.waypoints.count >= 2 {
            let start = SIMD2(edge.waypoints[0].x + bounds.x, edge.waypoints[0].y + bounds.y)
            let last = edge.waypoints[edge.waypoints.count - 1]
            let end = SIMD2(last.x + bounds.x, last.y + bounds.y)
            let (c1, c2): (SIMD2<Double>, SIMD2<Double>)
            switch diagram.flow {
            case .topDown, .bottomTop:
                let bow = (end.y - start.y) * 0.45
                (c1, c2) = (SIMD2(start.x, start.y + bow), SIMD2(end.x, end.y - bow))
            case .leftRight, .rightLeft:
                let bow = (end.x - start.x) * 0.45
                (c1, c2) = (SIMD2(start.x + bow, start.y), SIMD2(end.x - bow, end.y))
            }
            path = path.move(to: start).addCubicCurve(control1: c1, control2: c2, to: end)
            if edge.style != .open {
                // Along the curve's last tangent, which points from the
                // second control point to the end.
                let angle = atan2(end.y - c2.y, end.x - c2.x)
                let length = 7.0, spread = Double.pi / 7
                path = path
                    .move(to: end)
                    .addLine(to: SIMD2(end.x - length * cos(angle - spread), end.y - length * sin(angle - spread)))
                    .move(to: end)
                    .addLine(to: SIMD2(end.x - length * cos(angle + spread), end.y - length * sin(angle + spread)))
            }
        }
        return path
    }
}
