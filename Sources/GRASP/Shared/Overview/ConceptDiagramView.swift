import SwiftUI
import GRASPCore

/// Draws a laid-out concept diagram with SwiftUI's `Canvas`.
///
/// Deliberately has no pan and no zoom. This is the first drawing surface in
/// the app and the first gesture code would come with it -- trackpad
/// momentum, bounds clamping, a reset affordance, all of which can get a
/// reader stuck. Instead the diagram fits the column it's given, and an
/// "Open Larger" sheet covers the case where it genuinely needs more room.
struct ConceptDiagramView: View {
    let diagram: LaidOutDiagram
    /// Node ids that resolve to a flashcard. Only these highlight on hover
    /// and respond to a click -- pretending every box is actionable would
    /// be worse than none being.
    var linkedNodeIds: Set<String> = []
    var onSelectNode: ((String) -> Void)?

    @State private var hoveredNodeId: String?
    /// Read but not used directly. `Canvas` caches its drawing, and the
    /// palette's dynamic `NSColor`s resolve at draw time -- reading the
    /// scheme here is what guarantees a redraw when the system appearance
    /// changes while a diagram is on screen.
    @Environment(\.colorScheme) private var colorScheme
    /// The drawn size, for mapping a pointer back into diagram coordinates.
    @State private var viewSize: CGSize = .zero

    private var aspect: CGFloat {
        guard diagram.bounds.height > 0 else { return 1 }
        return CGFloat(diagram.bounds.width / diagram.bounds.height)
    }

    var body: some View {
        Canvas { context, size in
            let scale = fitScale(for: size)
            context.scaleBy(x: scale, y: scale)
            for edge in diagram.edges { draw(edge, in: &context) }
            for node in diagram.nodes { draw(node, in: &context) }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active(let point) = phase else { hoveredNodeId = nil; return }
            hoveredNodeId = node(at: point)?.id
        }
        .gesture(SpatialTapGesture().onEnded { value in
            guard let node = node(at: value.location), linkedNodeIds.contains(node.id) else { return }
            onSelectNode?(node.id)
        })
        .accessibilityLabel(accessibilityDescription)
    }

    private func fitScale(for size: CGSize) -> CGFloat {
        min(
            size.width / max(CGFloat(diagram.bounds.width), 1),
            size.height / max(CGFloat(diagram.bounds.height), 1)
        )
    }

    /// Hit-testing runs in the view's own coordinate space, so the point
    /// has to come back through the same fit the canvas drew with. (It
    /// didn't: a wide diagram drawn at 40% size tested the raw pointer
    /// against full-size frames, and hovers and clicks hit the wrong node.)
    private func node(at viewPoint: CGPoint) -> LaidOutDiagram.PlacedNode? {
        let scale = fitScale(for: viewSize)
        guard scale > 0 else { return nil }
        let point = CGPoint(x: viewPoint.x / scale, y: viewPoint.y / scale)
        return diagram.nodes.last { placed in
            let frame = CGRect(
                x: CGFloat(placed.center.x - placed.size.width / 2),
                y: CGFloat(placed.center.y - placed.size.height / 2),
                width: CGFloat(placed.size.width),
                height: CGFloat(placed.size.height)
            )
            return frame.contains(point)
        }
    }

    private var accessibilityDescription: String {
        let names = diagram.nodes.map { $0.lines.joined(separator: " ") }
        return "Concept diagram with \(diagram.nodes.count) concepts: \(names.joined(separator: ", "))"
    }

    // MARK: - Nodes

    private func draw(_ node: LaidOutDiagram.PlacedNode, in context: inout GraphicsContext) {
        let frame = CGRect(
            x: CGFloat(node.center.x - node.size.width / 2),
            y: CGFloat(node.center.y - node.size.height / 2),
            width: CGFloat(node.size.width),
            height: CGFloat(node.size.height)
        )
        let isLinked = linkedNodeIds.contains(node.id)
        let isHot = hoveredNodeId == node.id && isLinked
        let path = shapePath(for: node.shape, in: frame)

        // `surfaceRaised` is reserved for the one element per screen that
        // should sit forward -- inside a `surface` card on the `canvas`
        // ground, a diagram node is exactly that.
        context.fill(path, with: .color(isHot ? GRASPColor.accentSoft : GRASPColor.surfaceRaised))
        context.stroke(
            path,
            with: .color(isHot || isLinked ? GRASPColor.accent : GRASPColor.hairlineStrong),
            lineWidth: isHot ? 1.5 : 1
        )

        var label = context.resolve(
            Text(node.lines.joined(separator: "\n"))
                .font(DiagramTextMeasurer.drawFont)
        )
        label.shading = .color(GRASPColor.textPrimary)
        context.draw(label, in: frame.insetBy(dx: 6, dy: 4))
    }

    private func shapePath(for shape: MermaidGraph.NodeShape, in frame: CGRect) -> Path {
        switch shape {
        case .rectangle:
            return Path(roundedRect: frame, cornerRadius: 8, style: .continuous)
        case .rounded:
            return Path(roundedRect: frame, cornerRadius: 14, style: .continuous)
        case .stadium:
            return Path(roundedRect: frame, cornerRadius: frame.height / 2, style: .continuous)
        case .circle:
            return Path(ellipseIn: frame)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: frame.midX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.midY))
            path.closeSubpath()
            return path
        }
    }

    // MARK: - Edges

    private func draw(_ edge: LaidOutDiagram.PlacedEdge, in context: inout GraphicsContext) {
        guard edge.waypoints.count >= 2 else { return }
        let start = point(edge.waypoints[0])
        let end = point(edge.waypoints[edge.waypoints.count - 1])

        // Curved, not orthogonal. An orthogonal router that doesn't do
        // obstacle avoidance draws lines straight through unrelated boxes,
        // which reads as a bug; a Bezier bowed along the layout's own flow
        // axis never does, and is four lines instead of four hundred.
        var path = Path()
        path.move(to: start)
        switch diagram.flow {
        case .topDown, .bottomTop:
            let bow = (end.y - start.y) * 0.45
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x, y: start.y + bow),
                control2: CGPoint(x: end.x, y: end.y - bow)
            )
        case .leftRight, .rightLeft:
            let bow = (end.x - start.x) * 0.45
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + bow, y: start.y),
                control2: CGPoint(x: end.x - bow, y: end.y)
            )
        }

        let style = StrokeStyle(
            lineWidth: edge.style == .thick ? 2 : 1.25,
            lineCap: .round,
            dash: edge.style == .dotted ? [3, 3] : []
        )
        context.stroke(path, with: .color(GRASPColor.hairlineStrong), style: style)

        if edge.style != .open {
            let angle = atan2(end.y - start.y, end.x - start.x)
            context.fill(arrowHead(at: end, angle: angle), with: .color(GRASPColor.hairlineStrong))
        }

        if let text = edge.label {
            var resolved = context.resolve(Text(text).font(.system(size: 10, weight: .medium)))
            resolved.shading = .color(GRASPColor.textSecondary)
            let middle = point(edge.waypoints[edge.waypoints.count / 2])
            let size = resolved.measure(in: CGSize(width: 140, height: 40))
            // A filled plate under the label, or the edge runs through it.
            let plate = CGRect(
                x: middle.x - size.width / 2 - 4, y: middle.y - size.height / 2 - 2,
                width: size.width + 8, height: size.height + 4
            )
            context.fill(
                Path(roundedRect: plate, cornerRadius: 4, style: .continuous),
                with: .color(GRASPColor.canvas)
            )
            context.draw(resolved, at: middle, anchor: .center)
        }
    }

    private func point(_ value: DiagramPoint) -> CGPoint {
        CGPoint(x: CGFloat(value.x), y: CGFloat(value.y))
    }

    private func arrowHead(at tip: CGPoint, angle: CGFloat) -> Path {
        var path = Path()
        let length: CGFloat = 7
        let spread: CGFloat = .pi / 7
        path.move(to: tip)
        path.addLine(to: CGPoint(
            x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)
        ))
        path.addLine(to: CGPoint(
            x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)
        ))
        path.closeSubpath()
        return path
    }
}

/// The diagram section of a note's overview: the canvas when the source
/// parsed, the source itself when it didn't.
struct DiagramSection: View {
    let overview: RenderedOverview
    var onOpenCards: (([String]) -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Concept map")
                    .graspType(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(GRASPColor.textTertiary)
                Spacer(minLength: 8)
                if overview.diagram != nil {
                    Button {
                        isExpanded = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .help("Open larger")
                }
            }

            if let diagram = overview.diagram, !diagram.isEmpty {
                ConceptDiagramView(
                    diagram: diagram,
                    linkedNodeIds: linkedIds(diagram),
                    onSelectNode: { nodeId in
                        guard let node = diagram.nodes.first(where: { $0.id == nodeId }) else { return }
                        let label = node.lines.joined(separator: " ")
                        if let ids = overview.linkedNodes[label], !ids.isEmpty {
                            onOpenCards?(ids)
                        }
                    }
                )
                .frame(maxHeight: 420)
            } else if let source = overview.mermaidSource {
                // Not an error state. A diagram the parser couldn't lay out
                // is still something the student can read, and the model
                // wrote it about their own notes -- throwing it away loses
                // real content.
                Text(source)
                    .graspType(.mono)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        GRASPColor.inset,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sheet(isPresented: $isExpanded) {
            if let diagram = overview.diagram {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(overview.title)
                            .font(.system(size: 18, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(GRASPColor.textPrimary)
                        Spacer()
                        Button("Done") { isExpanded = false }
                            .buttonStyle(GRASPQuietButton())
                            .keyboardShortcut(.defaultAction)
                    }
                    ConceptDiagramView(diagram: diagram, linkedNodeIds: linkedIds(diagram))
                }
                .padding(24)
                .frame(minWidth: 720, minHeight: 560)
                .background(GRASPColor.canvas)
            }
        }
    }

    private func linkedIds(_ diagram: LaidOutDiagram) -> Set<String> {
        Set(diagram.nodes.compactMap { node in
            let label = node.lines.joined(separator: " ")
            guard let ids = overview.linkedNodes[label], !ids.isEmpty else { return nil }
            return node.id
        })
    }
}
