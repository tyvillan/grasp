import SwiftUI
import GRASPCore

// MARK: - Math text

/// Plain-text math drawn as math: subscripts and ℝⁿ in the prose, and any
/// vector or matrix written out inline drawn as a real one -- so
/// `x1(a11, a21, a31)` reads as x₁ times a column, not as a string of
/// symbols a student has to decode. Outside math notes it's plain text.
struct MathText: View {
    let text: String
    let isMath: Bool
    var style: GRASPType = .mono
    var color: Color = GRASPColor.textPrimary

    var body: some View {
        if !isMath {
            Text(overviewInline(text)).graspType(style).foregroundStyle(color)
        } else {
            let pieces = MathNotation.pieces(from: text)
            if pieces.allSatisfy({ if case .text = $0 { return true } else { return false } }) {
                Text(overviewInline(MathNotation.prettify(text))).graspType(style).foregroundStyle(color)
            } else {
                FlowLayout(spacing: 4, lineSpacing: 8) {
                    ForEach(Array(tokens(pieces).enumerated()), id: \.offset) { _, token in
                        switch token {
                        case .word(let word):
                            Text(word).graspType(style).foregroundStyle(color)
                        case .vector(let entries):
                            SymbolMatrixView(rows: entries.map { [$0] })
                        case .matrix(let rows, let bar):
                            SymbolMatrixView(rows: rows, bar: bar)
                        }
                    }
                }
            }
        }
    }

    private enum Token { case word(String), vector([String]), matrix([[String]], Int) }

    /// Words wrap individually; objects stay whole.
    private func tokens(_ pieces: [MathNotation.Piece]) -> [Token] {
        pieces.flatMap { piece -> [Token] in
            switch piece {
            case .text(let text): return text.split(separator: " ").map { .word(String($0)) }
            case .vector(let entries): return [.vector(entries)]
            case .matrix(let rows, let bar): return [.matrix(rows, bar)]
            }
        }
    }
}

/// Lays children out left to right, wrapping to a new line when the next
/// one won't fit, with each line's items centred vertically -- so a
/// column vector sits in the middle of the words around it, the way it
/// would on a whiteboard.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [Line()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = lines[lines.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if lines[lines.count - 1].width + extra > width, !lines[lines.count - 1].indices.isEmpty {
                lines.append(Line())
            }
            var line = lines[lines.count - 1]
            line.width += line.indices.isEmpty ? size.width : size.width + spacing
            line.height = max(line.height, size.height)
            line.indices.append(index)
            lines[lines.count - 1] = line
        }
        return lines
    }
}

// MARK: - Symbol matrix

/// A matrix or vector of symbols or numbers -- `a₁₁`, `x₂`, `−1/2` -- in
/// brackets, with an optional augmentation bar and highlighted rows or
/// columns. The symbolic sibling of `MatrixGrid`, for steps that talk about
/// a general matrix rather than one with numbers.
struct SymbolMatrixView: View {
    let rows: [[String]]
    var bar: Int = 0
    var highlightRows: Set<Int> = []
    var highlightColumns: Set<Int> = []
    var fontSize: CGFloat = 14

    private var width: Int { rows.first?.count ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            Bracket(left: true)
            Grid(horizontalSpacing: 0, verticalSpacing: 3) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<width, id: \.self) { column in
                            if bar > 0 && column == width - bar {
                                Rectangle().fill(GRASPColor.hairlineStrong).frame(width: 1, height: fontSize + 8)
                                    .padding(.horizontal, 4)
                            }
                            Text(MathNotation.prettify(rows[row][column]))
                                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                .foregroundStyle(isHighlighted(row, column) ? GRASPColor.accent : GRASPColor.textPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(isHighlighted(row, column) ? GRASPColor.accent.opacity(0.15) : .clear)
                        }
                    }
                }
            }
            .padding(.vertical, 3)
            Bracket(left: false)
        }
        .fixedSize()
    }

    private func isHighlighted(_ row: Int, _ column: Int) -> Bool {
        highlightRows.contains(row) || highlightColumns.contains(column)
    }
}

/// A square bracket that stretches to its neighbour's height.
private struct Bracket: View {
    let left: Bool
    var body: some View {
        BracketShape(left: left)
            .stroke(GRASPColor.textTertiary, lineWidth: 1.4)
            .frame(width: 5)
            .frame(maxHeight: .infinity)
    }
}

private nonisolated struct BracketShape: Shape {
    let left: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let (inner, outer) = left ? (rect.maxX, rect.minX + 0.7) : (rect.minX, rect.maxX - 0.7)
        path.move(to: CGPoint(x: inner, y: rect.minY + 0.7))
        path.addLine(to: CGPoint(x: outer, y: rect.minY + 0.7))
        path.addLine(to: CGPoint(x: outer, y: rect.maxY - 0.7))
        path.addLine(to: CGPoint(x: inner, y: rect.maxY - 0.7))
        return path
    }
}

// MARK: - Step visuals

/// The picture for one step, framed and captioned.
struct StepVisualView: View {
    let visual: OverviewStepVisual

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch visual.kind {
            case .matrix:
                if let rows = visual.rows {
                    SymbolMatrixView(rows: rows, bar: visual.bar ?? 0,
                                     highlightRows: Set(visual.highlightRows ?? []),
                                     highlightColumns: Set(visual.highlightColumns ?? []), fontSize: 15)
                }
            case .vectors:
                if let vectors = visual.vectors {
                    VectorPlotView(vectors: vectors, combine: visual.combine ?? false)
                }
            case .flow:
                if let nodes = visual.nodes {
                    FlowDiagramView(nodes: nodes, highlight: visual.highlight)
                }
            }
            if let caption = visual.caption {
                Text(overviewInline(caption))
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .textSelection(.disabled)
    }
}

/// Arrows from the origin, in the figure palette; with `combine`, each
/// vector scaled by its weight and laid tip to tail, ending at the sum --
/// what "b is a linear combination of the columns" looks like.
struct VectorPlotView: View {
    let vectors: [VisualVector]
    let combine: Bool

    private static let colors = [FigurePalette.iHat, FigurePalette.jHat, FigurePalette.lineOne, FigurePalette.lineTwo]

    private var scaled: [Point2] {
        vectors.map { Point2(x: $0.x * ($0.weight ?? 1), y: $0.y * ($0.weight ?? 1)) }
    }

    private var sum: Point2 {
        scaled.reduce(Point2(x: 0, y: 0)) { Point2(x: $0.x + $1.x, y: $0.y + $1.y) }
    }

    /// A square window around every point drawn, origin included.
    private var frameSpec: (center: Point2, halfSpan: Double) {
        var points = [Point2(x: 0, y: 0)] + vectors.map { Point2(x: $0.x, y: $0.y) }
        if combine {
            var tip = Point2(x: 0, y: 0)
            for v in scaled { tip = Point2(x: tip.x + v.x, y: tip.y + v.y); points.append(tip) }
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        let center = Point2(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
        let span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!, 2)
        return (center, span / 2 + 1)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Canvas { context, size in
                let spec = frameSpec
                let frame = PlaneFrame(size: size, center: spec.center, halfSpan: spec.halfSpan)
                frame.drawGrid(in: &context)
                if combine {
                    var tail = Point2(x: 0, y: 0)
                    for (index, v) in scaled.enumerated() {
                        let head = Point2(x: tail.x + v.x, y: tail.y + v.y)
                        arrow(from: tail, to: head, color: Self.colors[index % Self.colors.count].opacity(0.55),
                              dashed: true, frame: frame, in: &context)
                        tail = head
                    }
                    arrow(from: Point2(x: 0, y: 0), to: sum, color: FigurePalette.highlight, dashed: false,
                          frame: frame, in: &context, width: 3)
                }
                for (index, v) in vectors.enumerated() {
                    arrow(from: Point2(x: 0, y: 0), to: Point2(x: v.x, y: v.y),
                          color: Self.colors[index % Self.colors.count], dashed: false, frame: frame, in: &context)
                }
            }
            .frame(width: 180, height: 180)
            .background(FigurePalette.ground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(vectors.indices, id: \.self) { index in
                    let v = vectors[index]
                    HStack(spacing: 6) {
                        Circle().fill(Self.colors[index % Self.colors.count]).frame(width: 8, height: 8)
                        Text("\(MathNotation.prettify(v.label ?? "v\(index + 1)")) = (\(OverviewFigures.format(v.x)), \(OverviewFigures.format(v.y)))\(weightText(v.weight))")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(GRASPColor.textPrimary)
                    }
                }
                if combine {
                    HStack(spacing: 6) {
                        Circle().fill(FigurePalette.highlight).frame(width: 8, height: 8)
                        Text("sum = (\(OverviewFigures.format(sum.x)), \(OverviewFigures.format(sum.y)))")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(GRASPColor.textPrimary)
                    }
                }
            }
        }
    }

    private func weightText(_ weight: Double?) -> String {
        // After the vector, not before: "2·a₁ = (1, 2)" read as if the
        // scaled arrow were (1, 2).
        guard let weight, abs(weight - 1) > 1e-9 else { return "" }
        return ", taken \(OverviewFigures.format(weight))×"
    }

    private func arrow(from start: Point2, to end: Point2, color: Color, dashed: Bool,
                       frame: PlaneFrame, in context: inout GraphicsContext, width: CGFloat = 2.2) {
        let a = frame.point(start), b = frame.point(end)
        guard hypot(b.x - a.x, b.y - a.y) > 2 else { return }
        var line = Path()
        line.move(to: a)
        line.addLine(to: b)
        context.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dashed ? [5, 4] : []))
        let angle = atan2(b.y - a.y, b.x - a.x)
        var head = Path()
        head.move(to: b)
        head.addLine(to: CGPoint(x: b.x - 9 * cos(angle - .pi / 7), y: b.y - 9 * sin(angle - .pi / 7)))
        head.addLine(to: CGPoint(x: b.x - 9 * cos(angle + .pi / 7), y: b.y - 9 * sin(angle + .pi / 7)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

/// Stages joined by arrows, with the current one lit -- side by side when
/// there's room, stacked on a phone.
struct FlowDiagramView: View {
    let nodes: [String]
    let highlight: Int?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { content(vertical: false) }
            VStack(alignment: .leading, spacing: 4) { content(vertical: true) }
        }
    }

    @ViewBuilder
    private func content(vertical: Bool) -> some View {
        ForEach(nodes.indices, id: \.self) { index in
            if index > 0 {
                Image(systemName: vertical ? "arrow.down" : "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GRASPColor.textTertiary)
                    .padding(.leading, vertical ? 14 : 0)
            }
            let lit = index == highlight
            Text(nodes[index])
                .graspType(.body)
                .fontWeight(lit ? .semibold : .regular)
                .foregroundStyle(lit ? GRASPColor.accent : GRASPColor.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: !vertical, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(lit ? GRASPColor.accentSoft : GRASPColor.inset,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(lit ? GRASPColor.accent : GRASPColor.hairline, lineWidth: 1))
        }
    }
}

// MARK: - Step map

/// The whole procedure at a glance, above a worked example: one numbered
/// chip per step, joined by chevrons, the current step lit. Tapping a chip
/// reveals the example up to that step. Every course gets this -- it needs
/// nothing but the steps themselves.
struct StepMapView: View {
    let labels: [String]
    let current: Int
    let tint: Color
    var onSelect: (Int) -> Void

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 6) {
            ForEach(labels.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(GRASPColor.textTertiary)
                    }
                    Button { onSelect(index) } label: {
                        HStack(spacing: 5) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(index <= current ? GRASPColor.surface : tint)
                                .frame(width: 16, height: 16)
                                .background(index <= current ? tint : tint.opacity(0.15), in: Circle())
                            Text(labels[index])
                                .graspType(.meta)
                                .foregroundStyle(index == current ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.leading, 3)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3)
                        .background(index == current ? tint.opacity(0.12) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// A step's label: the model's own, else the first few words of the
    /// action.
    static func label(for step: OverviewExampleStep, isMath: Bool) -> String {
        let raw = step.label ?? {
            let words = step.action.split(separator: " ")
            return words.prefix(4).joined(separator: " ") + (words.count > 4 ? "…" : "")
        }()
        return isMath ? MathNotation.prettify(raw) : raw
    }
}

// MARK: - Code from the notes

/// A code block from the student's own notes, beside the section that
/// talks about it, with the lines that section mentions picked out.
/// Highlighting is a light, dependency-free pass -- keywords, strings,
/// comments, numbers -- enough to read structure at a glance, not an IDE.
struct CodeSnippetView: View {
    let snippet: NoteCode.Snippet
    /// The section's own text, to find which lines it talks about.
    let sectionText: String

    private var lines: [String] { snippet.code.components(separatedBy: "\n") }

    /// Lines containing a name the section mentions.
    private var focused: Set<Int> {
        var mentioned = snippet.identifiers.filter { sectionText.contains($0) }
        // The class's own name matches its header and every use of it;
        // the members the section names are the lines worth pointing at.
        let members = mentioned.filter { $0.first?.isUppercase == false }
        if !members.isEmpty { mentioned = members }
        guard !mentioned.isEmpty else { return [] }
        return Set(lines.indices.filter { index in mentioned.contains { lines[index].contains($0) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                Text((snippet.language ?? "code").uppercased())
                    .graspType(.eyebrow)
                Spacer(minLength: 0)
                Text("From your notes")
                    .graspType(.meta)
                Button {
                    Clipboard.copy(snippet.code)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .foregroundStyle(GRASPColor.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle().fill(GRASPColor.hairline).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(lines.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(GRASPColor.textTertiary.opacity(0.7))
                                .frame(minWidth: 18, alignment: .trailing)
                            Text(highlighted(lines[index]))
                                .font(.system(size: 13, design: .monospaced))
                                .fixedSize()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(focused.contains(index) ? GRASPColor.accent.opacity(0.10) : .clear)
                        .overlay(alignment: .leading) {
                            if focused.contains(index) {
                                Rectangle().fill(GRASPColor.accent).frame(width: 2)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(GRASPColor.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GRASPColor.hairline, lineWidth: 1))
        .textSelection(.enabled)
    }

    private static let keywords: Set<String> = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "import",
        "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda",
        "None", "True", "False", "self", "public", "private", "protected", "static", "void", "int", "double",
        "float", "char", "bool", "boolean", "new", "this", "extends", "implements", "interface", "abstract",
        "final", "const", "let", "var", "func", "function", "struct", "enum", "null", "true", "false", "super",
    ]

    private func highlighted(_ line: String) -> AttributedString {
        var result = AttributedString()
        func append(_ text: String, _ color: Color) {
            var piece = AttributedString(text)
            piece.foregroundColor = color
            result += piece
        }
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "#" || line[index...].hasPrefix("//") {
                append(String(line[index...]), GRASPColor.textTertiary)
                break
            }
            if character == "\"" || character == "'" {
                var end = line.index(after: index)
                while end < line.endIndex && line[end] != character { end = line.index(after: end) }
                if end < line.endIndex { end = line.index(after: end) }
                append(String(line[index..<end]), GRASPColor.success)
                index = end
                continue
            }
            if character.isLetter || character == "_" {
                var end = index
                while end < line.endIndex && (line[end].isLetter || line[end].isNumber || line[end] == "_") {
                    end = line.index(after: end)
                }
                let word = String(line[index..<end])
                let isCall = end < line.endIndex && line[end] == "("
                append(word, Self.keywords.contains(word) ? GRASPColor.accent
                       : isCall ? FigurePalette.lineOne : GRASPColor.textPrimary)
                index = end
                continue
            }
            if character.isNumber {
                var end = index
                while end < line.endIndex && (line[end].isNumber || line[end] == ".") { end = line.index(after: end) }
                append(String(line[index..<end]), FigurePalette.jHat)
                index = end
                continue
            }
            append(String(character), GRASPColor.textSecondary)
            index = line.index(after: index)
        }
        return result
    }
}
