import SwiftUI
import GRASPCore

// MARK: - Matrix grid

/// How one entry of a drawn matrix is marked.
enum MatrixMark: Equatable {
    /// The entry that breaks a rule.
    case violation
    /// A pivot: circled.
    case pivot
    /// Became zero in the step just taken -- the point of the step.
    case cleared
}

/// A matrix as it's written on a whiteboard -- brackets, an augmentation
/// bar, exact fractions -- with rows, columns and single entries marked.
///
/// Laid out on fixed metrics rather than a stack of stacks so the pivot
/// staircase can be drawn over it: every cell's position is arithmetic,
/// so the line can run exactly along the cells' edges.
struct MatrixGrid: View {
    let matrix: RationalMatrix
    var marks: [RationalMatrix.Cell: MatrixMark] = [:]
    /// A row to wash in the accent -- the row a step just changed.
    var changedRow: Int?
    /// A row to outline -- the row a step used as its source.
    var sourceRow: Int?
    var tintedColumns: Set<Int> = []
    var columnTint: Color = GRASPColor.success
    var rowTint: Color = GRASPColor.accent
    var showsStaircase = false
    var compact = false

    private var cellHeight: CGFloat { compact ? 22 : 28 }
    private var rowGap: CGFloat { compact ? 3 : 4 }
    private var columnGap: CGFloat { compact ? 4 : 6 }
    private var barGap: CGFloat { compact ? 10 : 14 }
    private var fontSize: CGFloat { compact ? 13 : 15 }
    private var bracketInset: CGFloat { 10 }

    /// Wide enough for the longest entry, so columns line up.
    private var cellWidth: CGFloat {
        let longest = matrix.rows.joined().map { $0.description.count }.max() ?? 1
        return max(compact ? 24 : 30, CGFloat(longest) * fontSize * 0.62 + 10)
    }

    private func x(_ column: Int) -> CGFloat {
        let bar: CGFloat = column >= matrix.coefficientColumns && matrix.augmentedColumns > 0 ? barGap : 0
        return bracketInset + CGFloat(column) * (cellWidth + columnGap) + bar
    }

    private func y(_ row: Int) -> CGFloat { 4 + CGFloat(row) * (cellHeight + rowGap) }

    private var size: CGSize {
        CGSize(width: x(matrix.columnCount - 1) + cellWidth + bracketInset,
               height: y(matrix.rowCount - 1) + cellHeight + 4)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Row and column washes go under everything.
            ForEach(Array(tintedColumns), id: \.self) { column in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(columnTint.opacity(0.14))
                    .frame(width: cellWidth + 4, height: size.height - 4)
                    .offset(x: x(column) - 2, y: 2)
            }
            if let changedRow {
                rowBand(changedRow).fill(rowTint.opacity(0.16))
            }
            if let sourceRow {
                rowBand(sourceRow).stroke(GRASPColor.textTertiary.opacity(0.6),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            ForEach(0..<matrix.rowCount, id: \.self) { row in
                ForEach(0..<matrix.columnCount, id: \.self) { column in
                    cell(row: row, column: column)
                        .frame(width: cellWidth, height: cellHeight)
                        .offset(x: x(column), y: y(row))
                }
            }

            Canvas { context, _ in
                if matrix.augmentedColumns > 0 {
                    let barX = x(matrix.coefficientColumns) - barGap / 2 - columnGap / 2
                    var bar = Path()
                    bar.move(to: CGPoint(x: barX, y: 2))
                    bar.addLine(to: CGPoint(x: barX, y: size.height - 2))
                    context.stroke(bar, with: .color(GRASPColor.hairlineStrong), lineWidth: 1)
                }
                context.stroke(brackets, with: .color(GRASPColor.textTertiary), lineWidth: 1.5)
                if showsStaircase { drawStaircase(in: &context) }
            }
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func rowBand(_ row: Int) -> Path {
        Path(roundedRect: CGRect(x: 4, y: y(row) - 1, width: size.width - 8, height: cellHeight + 2),
             cornerRadius: 4, style: .continuous)
    }

    @ViewBuilder
    private func cell(row: Int, column: Int) -> some View {
        let value = matrix[row, column]
        let mark = marks[RationalMatrix.Cell(row: row, column: column)]
        Text(value.description)
            .font(.system(size: fontSize, weight: mark == nil ? .regular : .semibold, design: .monospaced))
            .foregroundStyle(color(for: mark, value: value))
            .frame(width: cellWidth, height: cellHeight)
            .background {
                switch mark {
                case .pivot:
                    Circle().stroke(GRASPColor.accent, lineWidth: 1.5)
                        .frame(width: min(cellWidth, cellHeight) + 2, height: min(cellWidth, cellHeight) + 2)
                case .violation:
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(GRASPColor.rejectedSoft)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(GRASPColor.rejected, lineWidth: 1.5))
                case .cleared:
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(GRASPColor.successSoft)
                case nil:
                    EmptyView()
                }
            }
    }

    private func color(for mark: MatrixMark?, value: Rational) -> Color {
        switch mark {
        case .violation: return GRASPColor.rejected
        case .pivot: return GRASPColor.accent
        case .cleared: return GRASPColor.success
        case nil: return value.isZero ? GRASPColor.textTertiary : GRASPColor.textPrimary
        }
    }

    private var brackets: Path {
        var path = Path()
        let top: CGFloat = 1, bottom = size.height - 1, arm: CGFloat = 5
        path.move(to: CGPoint(x: arm + 1, y: top))
        path.addLine(to: CGPoint(x: 1, y: top))
        path.addLine(to: CGPoint(x: 1, y: bottom))
        path.addLine(to: CGPoint(x: arm + 1, y: bottom))
        let right = size.width - 1
        path.move(to: CGPoint(x: right - arm, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right - arm, y: bottom))
        return path
    }

    /// The "stair step": down the left of each pivot, then along under its
    /// row to the next pivot's column. Its shape *is* the echelon condition
    /// -- it only ever moves right as it goes down, and every entry below
    /// it is zero.
    private func drawStaircase(in context: inout GraphicsContext) {
        let pivots = matrix.pivotCells
        guard !pivots.isEmpty else { return }
        var path = Path()
        for (index, pivot) in pivots.enumerated() {
            let left = x(pivot.column) - columnGap / 2
            let top = y(pivot.row) - rowGap / 2
            let bottom = y(pivot.row) + cellHeight + rowGap / 2
            if index == 0 { path.move(to: CGPoint(x: left, y: top)) } else { path.addLine(to: CGPoint(x: left, y: top)) }
            path.addLine(to: CGPoint(x: left, y: bottom))
            let nextLeft = index + 1 < pivots.count
                ? x(pivots[index + 1].column) - columnGap / 2
                : x(matrix.columnCount - 1) + cellWidth + columnGap / 2
            path.addLine(to: CGPoint(x: nextLeft, y: bottom))
        }
        context.stroke(path, with: .color(GRASPColor.accent.opacity(0.75)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private var accessibilityText: String {
        matrix.rows.enumerated().map { index, row in
            "Row \(index + 1): " + row.map(\.description).joined(separator: ", ")
        }.joined(separator: ". ")
    }
}

// MARK: - Row reduction

/// A matrix reduced one row operation at a time.
///
/// Three kinds of stop: the start, with whatever keeps it out of echelon
/// form marked -- the problem the first step exists to fix; each step as a
/// before-and-after pair with the changed row washed, its source row
/// outlined and the entries it zeroed marked; and the result, with the
/// pivots circled, the staircase drawn and the variables read off. That
/// last stop is the paragraph "this staircase tells us which variables are
/// basic and which are free" drawn instead of described.
struct RowReductionView: View {
    let figure: RowReductionFigure
    @State private var stop: Int

    init(figure: RowReductionFigure, initialStop: Int = 0) {
        self.figure = figure
        _stop = State(initialValue: initialStop)
    }

    private var stepCount: Int { figure.steps.count }
    /// Start, each step, then the result.
    private var lastStop: Int { stepCount + 1 }
    private var result: RationalMatrix { figure.states[stepCount] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.2), value: stop)
            Text(narration)
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            controls
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(stopTitle)
                .graspType(.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(GRASPColor.textTertiary)
            if stop >= 1 && stop <= stepCount {
                Text(OverviewFigures.label(figure.steps[stop - 1]))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GRASPColor.accent)
            }
            Spacer(minLength: 0)
            PreviewChip(
                text: figure.stepsFromNote ? "Steps from your notes" : "Steps by GRASP",
                tint: figure.stepsFromNote ? GRASPColor.success : GRASPColor.textSecondary,
                tintSoft: figure.stepsFromNote ? GRASPColor.successSoft : GRASPColor.inset,
                icon: figure.stepsFromNote ? "doc.text" : "function"
            )
        }
    }

    private var stopTitle: String {
        switch stop {
        case 0: return "Start"
        case lastStop: return "Result"
        default: return "Step \(stop) of \(stepCount)"
        }
    }

    @ViewBuilder
    private var content: some View {
        if stop == 0 {
            let start = figure.states[0]
            let violation = start.echelonViolation
            MatrixGrid(matrix: start, marks: marks(violation?.cells ?? [], as: .violation, first: true))
        } else if stop == lastStop {
            MatrixGrid(matrix: result, marks: marks(result.pivotCells, as: .pivot),
                       tintedColumns: Set(result.variableKinds?.free ?? []),
                       columnTint: GRASPColor.textTertiary, showsStaircase: result.isEchelon)
        } else {
            let before = figure.states[stop - 1]
            let after = figure.states[stop]
            let step = figure.steps[stop - 1]
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) { pair(before, after, step) }
                VStack(alignment: .leading, spacing: 10) { pair(before, after, step, vertical: true) }
            }
        }
    }

    @ViewBuilder
    private func pair(_ before: RationalMatrix, _ after: RationalMatrix, _ step: RowOperation, vertical: Bool = false) -> some View {
        MatrixGrid(matrix: before, changedRow: nil, sourceRow: step.source.map { $0 - 1 },
                   compact: true)
            .opacity(0.8)
        Image(systemName: vertical ? "arrow.down" : "arrow.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(GRASPColor.accent)
        MatrixGrid(matrix: after, marks: marks(clearedCells(before, after, step), as: .cleared),
                   changedRow: step.kind == .swap ? nil : step.target - 1)
    }

    /// Entries a replacement turned into zero -- what the step was for.
    private func clearedCells(_ before: RationalMatrix, _ after: RationalMatrix, _ step: RowOperation) -> [RationalMatrix.Cell] {
        guard step.kind == .replace else { return [] }
        let row = step.target - 1
        return (0..<after.columnCount).compactMap { column in
            !before[row, column].isZero && after[row, column].isZero ? RationalMatrix.Cell(row: row, column: column) : nil
        }
    }

    private func marks(_ cells: [RationalMatrix.Cell], as mark: MatrixMark, first: Bool = false) -> [RationalMatrix.Cell: MatrixMark] {
        // For a violation only the first cell is the rule-breaker; the rest
        // are context (the leading entry it sits under).
        let chosen = first ? Array(cells.prefix(1)) : cells
        return Dictionary(uniqueKeysWithValues: chosen.map { ($0, mark) })
    }

    private var narration: String {
        if stop == 0 {
            let start = figure.states[0]
            if let violation = start.echelonViolation {
                return "\(violation.explanation) The steps below fix that."
            }
            return start.isReducedEchelon
                ? "This matrix is already in reduced echelon form."
                : "Already in echelon form. The steps below finish the job: leading 1s, with zeros above them too."
        }
        if stop == lastStop { return resultSummary }
        let before = figure.states[stop - 1]
        let after = figure.states[stop]
        let step = figure.steps[stop - 1]
        let target = "row \(step.target)"
        switch step.kind {
        case .swap:
            return "Swap row \(step.target) and row \(step.source ?? 0). The equations are the same, just listed in a different order."
        case .scale:
            let factor = OverviewFigures.format(step.multiplier ?? 1)
            return "Multiply \(target) by \(factor)\(after.leadingColumn(ofRow: step.target - 1).map { after[step.target - 1, $0] == .one ? " so its leading entry becomes 1" : "" } ?? ""). Scaling an equation doesn't change which values solve it."
        case .replace:
            let cleared = clearedCells(before, after, step)
            let source = "row \(step.source ?? 0)"
            let k = step.multiplier ?? 0
            let amount = abs(abs(k) - 1) < 1e-9 ? source : "\(OverviewFigures.format(abs(k))) × \(source)"
            let verb = k < 0 ? "Subtract \(amount) from \(target)" : "Add \(amount) to \(target)"
            if let first = cleared.first {
                let value = before[first.row, first.column]
                return "\(verb). The \(value) in column \(first.column + 1) cancels out and becomes 0 -- that's the whole point of this step."
            }
            return "\(verb). Replacing a row with itself plus a multiple of another never changes the solutions."
        }
    }

    private var resultSummary: String {
        var parts: [String] = []
        if result.isReducedEchelon {
            parts.append("Reduced echelon form: every leading entry is 1 and the only nonzero entry in its column.")
        } else if result.isEchelon {
            parts.append("Echelon form: the circled pivots step down and to the right, with zeros below each.")
        } else if let violation = result.echelonViolation {
            parts.append("Not yet in echelon form. \(violation.explanation)")
        }
        if let row = result.inconsistentRow {
            parts.append("Row \(row + 1) says 0 = \(result[row, result.columnCount - 1]), so the system has no solution.")
        } else if let kinds = result.variableKinds, result.augmentedColumns > 0 {
            let name = { (c: Int) in "x\(OverviewFigures.subscriptDigits(c + 1))" }
            if kinds.free.isEmpty {
                parts.append("Every variable column has a pivot, so there's exactly one solution.")
            } else {
                parts.append("Pivot columns make \(kinds.basic.map(name).joined(separator: ", ")) basic. "
                    + "\(kinds.free.map(name).joined(separator: ", ")) \(kinds.free.count == 1 ? "has" : "have") no pivot (shaded), "
                    + "so \(kinds.free.count == 1 ? "it's" : "they're") free and there are infinitely many solutions.")
            }
        }
        return parts.joined(separator: " ")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                stop = max(0, stop - 1)
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(stop == 0)

            HStack(spacing: 5) {
                ForEach(0...lastStop, id: \.self) { index in
                    Circle()
                        .fill(index == stop ? GRASPColor.accent : index < stop ? GRASPColor.accentMuted : GRASPColor.hairlineStrong)
                        .frame(width: 6, height: 6)
                        .onTapGesture { stop = index }
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                stop = min(lastStop, stop + 1)
            } label: {
                Label(stop == 0 ? "First step" : stop == stepCount ? "Result" : "Next", systemImage: "chevron.right")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .disabled(stop == lastStop)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(GRASPColor.accent)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

// MARK: - Worked example

/// A procedure as numbered steps, revealed one at a time by default:
/// seeing the move, then guessing its result before looking, is how a
/// worked example teaches rather than just being read. A step map above
/// shows the whole procedure at a glance; results are drawn as math in a
/// math note, and a step can carry its own small picture.
struct WorkedExampleView: View {
    let example: OverviewWorkedExample
    var isMath = false
    @State private var revealed: Int

    init(example: OverviewWorkedExample, isMath: Bool = false, initiallyRevealed: Int = 1) {
        self.example = example
        self.isMath = isMath
        _revealed = State(initialValue: initiallyRevealed)
    }

    private let tint = FigurePalette.lineOne

    private func tidy(_ text: String) -> String { isMath ? MathNotation.prettify(text) : text }

    var body: some View {
        Callout(label: "Worked example", tint: tint) {
            if let title = example.title {
                Text(overviewInline(tidy(title)))
                    .graspType(.prose)
                    .fontWeight(.semibold)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let setup = example.setup {
                MathText(text: setup, isMath: isMath, style: .prose, color: GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            StepMapView(
                labels: example.steps.map { StepMapView.label(for: $0, isMath: isMath) },
                current: revealed - 1, tint: tint
            ) { index in
                withAnimation(.easeOut(duration: 0.18)) { revealed = index + 1 }
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(example.steps.prefix(revealed).enumerated()), id: \.offset) { index, step in
                    stepRow(index: index, step: step)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, 4)

            if revealed >= example.steps.count, let outcome = example.outcome {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(GRASPColor.success)
                    Text(overviewInline(tidy(outcome)))
                        .graspType(.prose)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            if revealed < example.steps.count {
                HStack(spacing: 16) {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { revealed += 1 }
                    } label: {
                        Label("Next step", systemImage: "chevron.down")
                    }
                    Button("Show all") {
                        withAnimation(.easeOut(duration: 0.18)) { revealed = example.steps.count }
                    }
                    .foregroundStyle(GRASPColor.textTertiary)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            }
        }
    }

    private func stepRow(index: Int, step: OverviewExampleStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(overviewInline(tidy(step.action)))
                    .graspType(.prose)
                    .fontWeight(.medium)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let result = step.result {
                    MathText(text: result, isMath: isMath)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(GRASPColor.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let visual = step.visual {
                    StepVisualView(visual: visual)
                }
                if let why = step.why {
                    Text(overviewInline(tidy(why)))
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Is / isn't

/// A key term at its boundary: something that is it, and a near miss that
/// isn't, with what disqualifies it. Two matrices when the term describes a
/// matrix's shape, otherwise the lesson's own example and non-example.
struct TermContrastView: View {
    let term: LinkedDefinition

    var body: some View {
        if let contrast = term.matrixContrast {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { panels(contrast) }
                VStack(alignment: .leading, spacing: 12) { panels(contrast) }
            }
        } else if term.example != nil || term.nonExample != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let example = term.example { textRow(isExample: true, text: example) }
                if let nonExample = term.nonExample { textRow(isExample: false, text: nonExample) }
            }
        }
    }

    @ViewBuilder
    private func panels(_ contrast: MatrixContrasts.Contrast) -> some View {
        panel(contrast.isExample, label: contrast.concept.labels.is, isExample: true, concept: contrast.concept)
        panel(contrast.isNotExample, label: contrast.concept.labels.isNot, isExample: false, concept: contrast.concept)
    }

    private func panel(_ panel: MatrixContrasts.Panel, label: String, isExample: Bool,
                       concept: MatrixContrasts.Concept) -> some View {
        let tint = isExample ? GRASPColor.success : GRASPColor.rejected
        // Pivots and context circled, and only the actual rule-breaker in
        // red -- marking everything red made the pivots read as mistakes.
        var marks = Dictionary(uniqueKeysWithValues: panel.highlights.map { ($0, MatrixMark.pivot) })
        for cell in panel.offending { marks[cell] = .violation }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: isExample ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(tint)
                Text(label)
                    .graspType(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(tint)
                if panel.fromNotes {
                    Text("from your notes")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                }
            }
            MatrixGrid(matrix: panel.matrix, marks: marks,
                       changedRow: panel.highlightedRow,
                       tintedColumns: Set(panel.highlightedColumns),
                       columnTint: tint, rowTint: GRASPColor.rejected, compact: true)
            Text(overviewInline(panel.explanation))
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                // A modest ideal width, so side by side is judged on the
                // matrices -- measured at one long line, the explanation
                // always "needed" the whole row and forced a stack.
                .frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(tint.opacity(0.6)).frame(height: 2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .textSelection(.disabled)
    }

    private func textRow(isExample: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isExample ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isExample ? GRASPColor.success : GRASPColor.rejected)
            (Text(isExample ? "Is: " : "Isn't: ").fontWeight(.semibold)
                + Text(overviewInline(text)))
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
