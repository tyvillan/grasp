import SwiftUI
import GRASPCore

// MARK: - Palette

/// Colours that *encode* something -- which equation a line is, which basis
/// vector an arrow is -- and so have to be told apart at a glance. The app's
/// own palette has one accent on purpose; a figure needs several distinct
/// hues, so these live here rather than in `GRASPColor`. The pairing
/// follows 3Blue1Brown's convention because it's the one a student who has
/// watched those videos already reads fluently: î green, ĵ red, the grid a
/// quiet blue, the thing to watch in yellow.
enum FigurePalette {
    static let ground = dynamic(light: 0xFAF9F6, dark: 0x0B0C10)
    static let grid = dynamic(light: 0xD5DCE8, dark: 0x1C2A3C)
    static let gridMoved = dynamic(light: 0x7FA3D6, dark: 0x3F74B8)
    static let axis = dynamic(light: 0x8C8A97, dark: 0x5B6272)
    static let iHat = dynamic(light: 0x2E8B57, dark: 0x83C167)
    static let jHat = dynamic(light: 0xC0392B, dark: 0xFC6255)
    static let area = dynamic(light: 0xE8B53F, dark: 0xFFFF00)
    static let lineOne = dynamic(light: 0x2F6FD0, dark: 0x58C4DD)
    static let lineTwo = dynamic(light: 0xC47A0B, dark: 0xF2B84B)
    static let highlight = dynamic(light: 0xC47A0B, dark: 0xFFFF00)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        GRASPColor.dynamic(light: light, dark: dark)
    }
}

// MARK: - Plane

/// Maps plane coordinates to canvas points for a square window centred on
/// `center` and reaching `halfSpan` units in each direction. y is flipped,
/// because a maths plane grows upward and a canvas grows downward.
struct PlaneFrame {
    let size: CGSize
    let center: Point2
    let halfSpan: Double

    var scale: CGFloat { min(size.width, size.height) / CGFloat(halfSpan * 2) }

    func point(_ p: Point2) -> CGPoint {
        CGPoint(
            x: size.width / 2 + CGFloat(p.x - center.x) * scale,
            y: size.height / 2 - CGFloat(p.y - center.y) * scale
        )
    }

    func plane(_ p: CGPoint) -> Point2 {
        Point2(
            x: center.x + Double((p.x - size.width / 2) / scale),
            y: center.y - Double((p.y - size.height / 2) / scale)
        )
    }

    var minX: Double { center.x - halfSpan * Double(size.width / max(size.height, 1)).clamped(1, 3) }
    var maxX: Double { center.x + halfSpan * Double(size.width / max(size.height, 1)).clamped(1, 3) }
    var minY: Double { center.y - halfSpan }
    var maxY: Double { center.y + halfSpan }

    /// Grid and axes, drawn the same way in every plane figure so they
    /// read as one visual language.
    func drawGrid(in context: inout GraphicsContext, step requested: Double = 1) {
        // Never more than about a dozen lines across. A fixed step of 1 or 2
        // drew hundreds of lines -- a solid fill -- for a word problem
        // solved at (300, 200), and an ill-conditioned system far out had
        // these loops running for billions of steps.
        let span = maxY - minY
        guard span.isFinite, span > 0 else { return }
        let rough = span / 12
        let magnitude = pow(10, (log10(rough)).rounded(.down))
        let nice = [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? 10 * magnitude
        let step = max(requested, nice)
        var grid = Path()
        var x = (minX / step).rounded(.down) * step
        while x <= maxX {
            grid.move(to: point(Point2(x: x, y: minY)))
            grid.addLine(to: point(Point2(x: x, y: maxY)))
            x += step
        }
        var y = (minY / step).rounded(.down) * step
        while y <= maxY {
            grid.move(to: point(Point2(x: minX, y: y)))
            grid.addLine(to: point(Point2(x: maxX, y: y)))
            y += step
        }
        context.stroke(grid, with: .color(FigurePalette.grid), lineWidth: 1)

        var axes = Path()
        axes.move(to: point(Point2(x: minX, y: 0)))
        axes.addLine(to: point(Point2(x: maxX, y: 0)))
        axes.move(to: point(Point2(x: 0, y: minY)))
        axes.addLine(to: point(Point2(x: 0, y: maxY)))
        context.stroke(axes, with: .color(FigurePalette.axis), lineWidth: 1.25)
    }
}

extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}

// MARK: - Playback

/// Play, scrub and step controls shared by every figure. `progress` runs
/// from 0 to `length`; for a stepped figure `length` is the number of
/// steps, so whole numbers are the moments between steps.
struct FigureTransport: View {
    @Binding var progress: Double
    let length: Double
    /// Whole-number stops for the step buttons and the scrubber's snap.
    let isStepped: Bool
    @State private var playTask: Task<Void, Never>?

    private var isPlaying: Bool { playTask != nil }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isPlaying ? stop() : play()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(GRASPColor.accent)
            .help(isPlaying ? "Pause" : "Play")

            if isStepped {
                Button { jump(by: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .disabled(progress <= 0)
                    .help("Previous step")
            }

            Slider(value: Binding(
                get: { progress },
                set: { stop(); progress = $0 }
            ), in: 0...max(length, 0.0001))
            .controlSize(.small)
            .tint(GRASPColor.accent)

            if isStepped {
                Button { jump(by: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .disabled(progress >= length)
                    .help("Next step")
            }
        }
        .onDisappear { stop() }
    }

    /// Animates from the current position to the end -- or from the start,
    /// if it's already at the end, so Play always shows something. Steps
    /// pause briefly at each whole number, the way a video lingers on a
    /// result before moving on.
    private func play() {
        if progress >= length - 0.001 { progress = 0 }
        playTask = Task { @MainActor in
            let secondsPerUnit = isStepped ? 1.4 : 2.2
            let frame = 1.0 / 60
            while !Task.isCancelled, progress < length {
                let before = progress
                progress = min(length, progress + frame / secondsPerUnit)
                if isStepped, before.rounded(.down) != progress.rounded(.down), progress < length {
                    progress = progress.rounded(.down)
                    try? await Task.sleep(for: .milliseconds(650))
                } else {
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            playTask = nil
        }
    }

    private func stop() {
        playTask?.cancel()
        playTask = nil
    }

    private func jump(by delta: Double) {
        stop()
        let target = delta > 0 ? progress.rounded(.down) + 1 : progress.rounded(.up) - 1
        progress = target.clamped(0, length)
    }
}

// MARK: - System of lines

/// Two equations as two lines, stepped through row operations.
///
/// The point of the figure is the thing that *doesn't* move. During a
/// replacement the changed row is `R + t·k·S` -- a combination of the
/// original equations for every t, so the intersection is satisfied the
/// whole way and the line visibly pivots around it. Swaps and scales leave
/// every line exactly where it was, which is its own lesson: those
/// operations change how the system is written, not what it says.
struct SystemOfLinesView: View {
    let figure: LinesFigure
    @State private var progress: Double = 0

    private var stepCount: Int { figure.steps.count }

    /// Which step is under way, and how far through it.
    private var position: (step: Int, t: Double) {
        guard stepCount > 0 else { return (0, 0) }
        let step = min(Int(progress.rounded(.down)), stepCount - 1)
        return (step, (progress - Double(step)).clamped(0, 1))
    }

    private var drawnSystem: LinearSystem2 {
        guard stepCount > 0 else { return figure.states[0] }
        let (step, t) = position
        if t >= 1 { return figure.states[step + 1] }
        return LinearSystem2.interpolate(
            from: figure.states[step], applying: figure.steps[step], progress: t
        )
    }

    /// The matrix shown beside the plot: the state reached so far. Mid-step
    /// it shows the "before" matrix with the row about to change marked,
    /// rather than a matrix full of fractional in-between values that no
    /// one would ever write down.
    private var shownStateIndex: Int {
        guard stepCount > 0 else { return 0 }
        let (step, t) = position
        return t >= 1 ? step + 1 : step
    }

    private var activeStep: RowOperation? {
        guard stepCount > 0 else { return nil }
        let (step, t) = position
        return (t > 0 && t < 1) || shownStateIndex == step ? figure.steps[step] : nil
    }

    /// The window is chosen from the *original* system's solution and held
    /// for the whole animation. Re-fitting per frame would make the camera
    /// move, and a moving camera is exactly what would hide the fact that
    /// the intersection holds still.
    private var frameCenter: Point2 { figure.states[0].solution ?? Point2(x: 0, y: 0) }
    private var halfSpan: Double {
        guard let solution = figure.states[0].solution else { return 6 }
        let reach = max(abs(solution.x), abs(solution.y), 1)
        return max(4, (reach * 0.8 + 3).rounded(.up))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    plot.frame(width: 360, height: 320)
                    readout.frame(minWidth: 220, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 14) {
                    plot.frame(height: 300)
                    readout
                }
            }
            if stepCount > 0 {
                FigureTransport(progress: $progress, length: Double(stepCount), isStepped: true)
            }
        }
    }

    private var plot: some View {
        Canvas { context, size in
            let frame = PlaneFrame(size: size, center: frameCenter, halfSpan: halfSpan)
            frame.drawGrid(in: &context, step: halfSpan > 8 ? 2 : 1)
            let system = drawnSystem
            for row in 0..<2 where !system.isDegenerate(row) {
                drawLine(system.rows[row], row: row, in: &context, frame: frame)
            }
            if let solution = figure.states[0].solution {
                let center = frame.point(solution)
                let dot = Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
                context.fill(dot, with: .color(FigurePalette.highlight))
                var label = context.resolve(
                    Text("(\(OverviewFigures.format(solution.x)), \(OverviewFigures.format(solution.y)))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                )
                label.shading = .color(FigurePalette.highlight)
                context.draw(label, at: CGPoint(x: center.x + 10, y: center.y - 14), anchor: .leading)
            }
        }
        .background(FigurePalette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(accessibilityText)
    }

    private func drawLine(
        _ row: [Double], row index: Int, in context: inout GraphicsContext, frame: PlaneFrame
    ) {
        let (a, b, c) = (row[0], row[1], row[2])
        var ends: [Point2] = []
        if abs(b) > 1e-9 {
            ends = [frame.minX, frame.maxX].map { Point2(x: $0, y: (c - a * $0) / b) }
        } else {
            let x = c / a
            ends = [Point2(x: x, y: frame.minY), Point2(x: x, y: frame.maxY)]
        }
        var path = Path()
        path.move(to: frame.point(ends[0]))
        path.addLine(to: frame.point(ends[1]))
        let isChanging = activeStep?.kind == .replace && activeStep?.target == index + 1
            && position.t > 0 && position.t < 1
        context.stroke(
            path,
            with: .color(index == 0 ? FigurePalette.lineOne : FigurePalette.lineTwo),
            lineWidth: isChanging ? 3 : 2.25
        )
    }

    private var readout: some View {
        let state = figure.states[shownStateIndex]
        return VStack(alignment: .leading, spacing: 12) {
            if stepCount > 0 {
                Text(stepCaption)
                    .graspType(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            AugmentedMatrixView(
                rows: state.rows,
                highlightedRow: activeStep.map { $0.target - 1 },
                rowColors: [FigurePalette.lineOne, FigurePalette.lineTwo]
            )
            if let step = activeStep {
                Text(OverviewFigures.label(step))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(FigurePalette.highlight)
            }
            Text(consequence)
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepCaption: String {
        let reached = shownStateIndex
        if reached == 0 && position.t == 0 { return "Start · \(stepCount) step\(stepCount == 1 ? "" : "s")" }
        if reached == stepCount { return "Done" }
        return "Step \(position.step + 1) of \(stepCount)"
    }

    /// What the student should notice right now. Deliberately specific to
    /// the operation, because the lesson differs: a replacement moves a line
    /// but not the crossing; a swap or a scale doesn't move anything.
    private var consequence: String {
        let solution = figure.states[0].solution
        let crossing = solution.map {
            "(\(OverviewFigures.format($0.x)), \(OverviewFigures.format($0.y)))"
        }
        let final = figure.states[shownStateIndex]
        if final.isDegenerate(0) || final.isDegenerate(1) {
            return "One row has no x or y left. Row reduction has shown this system has no "
                 + "single crossing point."
        }
        guard let step = activeStep else {
            if let crossing {
                return shownStateIndex == stepCount && stepCount > 0
                    ? "Every step changed the equations, yet the solution is still \(crossing)."
                    : "The two lines cross at \(crossing). That point is the solution."
            }
            return "These lines never meet at a single point, so there's no single solution."
        }
        switch step.kind {
        case .replace:
            return "Watch the \(step.target == 1 ? "blue" : "gold") line pivot. It turns, but it "
                 + "keeps passing through \(crossing ?? "the same point")."
        case .swap:
            return "Nothing on the plot moves. Swapping only changes the order the equations "
                 + "are written in."
        case .scale:
            return "The line doesn't move at all. Multiplying an equation by a nonzero number "
                 + "gives the same line."
        }
    }

    private var accessibilityText: String {
        let lines = figure.states[0].rows.map {
            "\(OverviewFigures.format($0[0]))x + \(OverviewFigures.format($0[1]))y = \(OverviewFigures.format($0[2]))"
        }
        return "Two lines, \(lines.joined(separator: " and ")), stepped through \(stepCount) row operations."
    }
}

/// An augmented matrix as it's written on a whiteboard: brackets, a bar
/// before the constants, each row tinted in its line's colour so the matrix
/// and the plot read as the same object.
struct AugmentedMatrixView: View {
    let rows: [[Double]]
    let highlightedRow: Int?
    let rowColors: [Color]

    var body: some View {
        HStack(spacing: 0) {
            bracket(left: true)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 14) {
                        ForEach(0..<2, id: \.self) { column in
                            cell(rows[index][column])
                        }
                        Rectangle()
                            .fill(GRASPColor.hairlineStrong)
                            .frame(width: 1, height: 18)
                        cell(rows[index][2])
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(rowColors[index % rowColors.count])
                    .background(
                        highlightedRow == index ? FigurePalette.highlight.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
                }
            }
            .padding(.vertical, 4)
            bracket(left: false)
        }
        .fixedSize()
    }

    private func cell(_ value: Double) -> some View {
        Text(OverviewFigures.format(value))
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .frame(minWidth: 34, alignment: .trailing)
    }

    private func bracket(left: Bool) -> some View {
        Path { path in
            let width: CGFloat = 6
            let height: CGFloat = 64
            if left {
                path.move(to: CGPoint(x: width, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: height))
                path.addLine(to: CGPoint(x: width, y: height))
            } else {
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: width, y: 0))
                path.addLine(to: CGPoint(x: width, y: height))
                path.addLine(to: CGPoint(x: 0, y: height))
            }
        }
        .stroke(GRASPColor.textTertiary, lineWidth: 1.5)
        .frame(width: 6, height: 64)
    }
}

// MARK: - Linear transformation

/// A 2x2 matrix shown the 3Blue1Brown way: as what it does to the plane.
///
/// Play morphs the grid from "do nothing" into the transformation, so the
/// student sees a matrix as motion. Dragging the tip of î or ĵ edits the
/// matrix directly -- its columns *are* where those two arrows land, and
/// feeling that is the whole idea. The shaded square is the unit square
/// carried along, so the determinant reads as the area it ends up with.
struct LinearTransformView: View {
    let figure: TransformFigure
    @State private var progress: Double = 0
    /// Starts as the note's matrix; dragging edits it. Reset restores it.
    @State private var working: Matrix2?
    @State private var dragging: Handle?
    /// The window held still for the length of a drag. Re-fitting it to the
    /// matrix being dragged fed back into the drag itself: with the tip far
    /// out, each mouse event widened the window and moved the tip further,
    /// until the grid had millions of lines and the app hung.
    @State private var dragSpan: Double?

    private enum Handle { case iHat, jHat }

    private var target: Matrix2 { working ?? figure.matrix }
    private var current: Matrix2 { target.blended(progress: progress) }

    private var halfSpan: Double {
        if let dragSpan { return dragSpan }
        let reach = [target.a, target.b, target.c, target.d, 1].map(abs).max() ?? 1
        return max(3, (reach * 1.6).rounded(.up))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    plane.frame(width: 360, height: 320)
                    readout.frame(minWidth: 200, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 14) {
                    plane.frame(height: 300)
                    readout
                }
            }
            FigureTransport(progress: $progress, length: 1, isStepped: false)
        }
    }

    private var plane: some View {
        GeometryReader { proxy in
            let frame = PlaneFrame(size: proxy.size, center: Point2(x: 0, y: 0), halfSpan: halfSpan)
            Canvas { context, _ in
                frame.drawGrid(in: &context)
                drawTransformedGrid(in: &context, frame: frame)
                drawUnitSquare(in: &context, frame: frame)
                drawArrow(to: current.iHat, color: FigurePalette.iHat, label: "î", in: &context, frame: frame)
                drawArrow(to: current.jHat, color: FigurePalette.jHat, label: "ĵ", in: &context, frame: frame)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(frame: frame))
        }
        .background(FigurePalette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("The plane transformed by a matrix. î lands at "
            + "(\(OverviewFigures.format(target.a)), \(OverviewFigures.format(target.c))) and ĵ at "
            + "(\(OverviewFigures.format(target.b)), \(OverviewFigures.format(target.d))).")
    }

    private func drawTransformedGrid(in context: inout GraphicsContext, frame: PlaneFrame) {
        let reach = Int(halfSpan * 2)
        var path = Path()
        for k in -reach...reach {
            let v = Double(k)
            path.move(to: frame.point(current.apply(Point2(x: v, y: Double(-reach)))))
            path.addLine(to: frame.point(current.apply(Point2(x: v, y: Double(reach)))))
            path.move(to: frame.point(current.apply(Point2(x: Double(-reach), y: v))))
            path.addLine(to: frame.point(current.apply(Point2(x: Double(reach), y: v))))
        }
        context.stroke(path, with: .color(FigurePalette.gridMoved.opacity(0.75)), lineWidth: 1)
    }

    private func drawUnitSquare(in context: inout GraphicsContext, frame: PlaneFrame) {
        var square = Path()
        square.move(to: frame.point(Point2(x: 0, y: 0)))
        square.addLine(to: frame.point(current.iHat))
        square.addLine(to: frame.point(Point2(x: current.a + current.b, y: current.c + current.d)))
        square.addLine(to: frame.point(current.jHat))
        square.closeSubpath()
        context.fill(square, with: .color(FigurePalette.area.opacity(0.22)))
        context.stroke(square, with: .color(FigurePalette.area.opacity(0.6)), lineWidth: 1)
    }

    private func drawArrow(
        to tip: Point2, color: Color, label: String,
        in context: inout GraphicsContext, frame: PlaneFrame
    ) {
        let start = frame.point(Point2(x: 0, y: 0))
        let end = frame.point(tip)
        var shaft = Path()
        shaft.move(to: start)
        shaft.addLine(to: end)
        context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 12
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 7), y: end.y - length * sin(angle - .pi / 7)))
        head.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 7), y: end.y - length * sin(angle + .pi / 7)))
        head.closeSubpath()
        context.fill(head, with: .color(color))

        // The drag handle: a ring at the tip, so it reads as grabbable.
        let ring = Path(ellipseIn: CGRect(x: end.x - 7, y: end.y - 7, width: 14, height: 14))
        context.stroke(ring, with: .color(color.opacity(0.7)), lineWidth: 1.5)

        var text = context.resolve(Text(label).font(.system(size: 15, weight: .bold)))
        text.shading = .color(color)
        context.draw(text, at: CGPoint(x: end.x + 12 * cos(angle), y: end.y + 12 * sin(angle) - 4))
    }

    private func dragGesture(frame: PlaneFrame) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragging == nil {
                    // Dragging edits the finished transformation, so jump
                    // there first -- editing a half-played blend would
                    // move the arrows somewhere they don't belong.
                    progress = 1
                    let iTip = frame.point(target.iHat)
                    let jTip = frame.point(target.jHat)
                    let di = hypot(value.startLocation.x - iTip.x, value.startLocation.y - iTip.y)
                    let dj = hypot(value.startLocation.x - jTip.x, value.startLocation.y - jTip.y)
                    guard min(di, dj) < 24 else { return }
                    dragging = di <= dj ? .iHat : .jHat
                    dragSpan = halfSpan
                }
                // Snapping to quarter units keeps the readout in clean
                // numbers a student would actually write, instead of
                // 1.8374 because the cursor was a pixel off.
                let raw = frame.plane(value.location)
                let limit = OverviewFigures.maximumMatrixEntry
                let snapped = Point2(
                    x: ((raw.x * 4).rounded() / 4).clamped(-limit, limit),
                    y: ((raw.y * 4).rounded() / 4).clamped(-limit, limit)
                )
                switch dragging {
                case .iHat: working = .columns(iHat: snapped, jHat: target.jHat)
                case .jHat: working = .columns(iHat: target.iHat, jHat: snapped)
                case nil: break
                }
            }
            .onEnded { _ in
                dragging = nil
                dragSpan = nil
            }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                MatrixView(matrix: current)
                if working != nil {
                    Button("Reset") {
                        working = nil
                        progress = 1
                    }
                    .buttonStyle(GRASPQuietButton())
                    .controlSize(.small)
                }
            }
            HStack(spacing: 14) {
                vectorLabel("î", current.iHat, FigurePalette.iHat)
                vectorLabel("ĵ", current.jHat, FigurePalette.jHat)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Area scales by \(OverviewFigures.format(current.determinant))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FigurePalette.area)
                Text(determinantNote)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Drag the tip of î or ĵ to change the matrix.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
        }
    }

    private var determinantNote: String {
        let det = current.determinant
        if abs(det) < 1e-9 { return "The plane is squashed flat onto a line -- this matrix can't be undone." }
        if det < 0 { return "Negative: the plane has been flipped over, so î and ĵ swap sides." }
        return "The yellow square started with area 1. It now has area \(OverviewFigures.format(det))."
    }

    private func vectorLabel(_ name: String, _ point: Point2, _ color: Color) -> some View {
        Text("\(name) → (\(OverviewFigures.format(point.x)), \(OverviewFigures.format(point.y)))")
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
    }
}

/// A plain 2x2 matrix with its columns tinted as î and ĵ.
struct MatrixView: View {
    let matrix: Matrix2

    var body: some View {
        HStack(spacing: 0) {
            bracket(left: true)
            HStack(spacing: 14) {
                column(matrix.a, matrix.c, FigurePalette.iHat)
                column(matrix.b, matrix.d, FigurePalette.jHat)
            }
            .padding(.horizontal, 6)
            bracket(left: false)
        }
        .fixedSize()
    }

    private func column(_ top: Double, _ bottom: Double, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(OverviewFigures.format(top))
            Text(OverviewFigures.format(bottom))
        }
        .font(.system(size: 15, weight: .medium, design: .monospaced))
        .foregroundStyle(color)
        .frame(minWidth: 30, alignment: .trailing)
    }

    private func bracket(left: Bool) -> some View {
        Path { path in
            let width: CGFloat = 6
            let height: CGFloat = 48
            if left {
                path.move(to: CGPoint(x: width, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: height))
                path.addLine(to: CGPoint(x: width, y: height))
            } else {
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: width, y: 0))
                path.addLine(to: CGPoint(x: width, y: height))
                path.addLine(to: CGPoint(x: 0, y: height))
            }
        }
        .stroke(GRASPColor.textTertiary, lineWidth: 1.5)
        .frame(width: 6, height: 48)
    }
}
