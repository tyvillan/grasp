import Foundation

public struct DiagramPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct DiagramSize: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// Text metrics the *renderer* owns, handed in rather than guessed:
/// `GRASPCore` has no font to measure against, and on purpose -- keeping
/// AppKit out of this module is what lets the layout tests run as pure
/// functions with no view, no window and no appearance.
///
/// `measure` is the seam. Left nil, layout falls back to a character-width
/// estimate, which is what every test uses so results stay deterministic.
/// The view passes a closure backed by real font metrics, so what ships is
/// laid out against the type it's actually drawn in.
public struct DiagramMetrics: Sendable {
    public var characterWidth: Double = 7.5
    public var lineHeight: Double = 16
    public var horizontalPadding: Double = 16
    public var verticalPadding: Double = 10
    public var minNodeWidth: Double = 72
    public var maxNodeWidth: Double = 220
    public var layerGap: Double = 56
    public var siblingGap: Double = 24
    public var ringGap: Double = 120
    /// Measures one already-wrapped line of a node label.
    public var measure: (@Sendable (String) -> DiagramSize)?

    public init(measure: (@Sendable (String) -> DiagramSize)? = nil) {
        self.measure = measure
    }

    func size(ofLine line: String) -> DiagramSize {
        if let measure { return measure(line) }
        return DiagramSize(width: Double(line.count) * characterWidth, height: lineHeight)
    }
}

public struct LaidOutDiagram: Sendable, Equatable {
    public struct PlacedNode: Sendable, Equatable, Identifiable {
        public let id: String
        /// The label, already wrapped. The renderer draws these lines as
        /// given rather than re-wrapping, so what was measured is what's
        /// drawn.
        public let lines: [String]
        public let shape: MermaidGraph.NodeShape
        public let center: DiagramPoint
        public let size: DiagramSize
        public let depth: Int
    }

    public struct PlacedEdge: Sendable, Equatable, Identifiable {
        public let id: String
        public let from: String
        public let to: String
        /// Border anchor, midpoint, border anchor. The renderer decides
        /// whether to draw that straight, curved or elbowed; layout only
        /// says where the line has to start, pass through and end.
        public let waypoints: [DiagramPoint]
        public let label: String?
        public let style: MermaidGraph.EdgeStyle
        /// True when cycle-breaking flipped this edge to make the graph
        /// layerable. The arrowhead still belongs at the real target.
        public let isReversed: Bool
    }

    public let nodes: [PlacedNode]
    public let edges: [PlacedEdge]
    public let bounds: DiagramSize
    public let flow: MermaidGraph.Direction

    public var isEmpty: Bool { nodes.isEmpty }
}

public enum DiagramLayout {
    /// Above this many nodes a radial mindmap stops being readable -- the
    /// outer ring's labels start overlapping whatever the ring spacing --
    /// so it falls back to an indented tree, which stays legible at any size.
    static let radialNodeLimit = 20

    public static func layout(
        _ graph: MermaidGraph, metrics: DiagramMetrics = DiagramMetrics()
    ) -> LaidOutDiagram {
        guard !graph.nodes.isEmpty else {
            return LaidOutDiagram(
                nodes: [], edges: [], bounds: DiagramSize(width: 0, height: 0),
                flow: graph.direction
            )
        }
        switch graph.kind {
        case .flowchart:
            return layoutFlowchart(graph, metrics: metrics)
        case .mindmap:
            return graph.nodes.count <= radialNodeLimit
                ? layoutRadial(graph, metrics: metrics)
                : layoutIndented(graph, metrics: metrics)
        }
    }

    // MARK: - Sizing

    private struct Measured {
        var lines: [String]
        var size: DiagramSize
    }

    private static func measure(
        _ node: MermaidGraph.Node, metrics: DiagramMetrics
    ) -> Measured {
        let lines = wrap(node.label, metrics: metrics)
        var width = lines.map { metrics.size(ofLine: $0).width }.max() ?? 0
        width += metrics.horizontalPadding * 2
        width = min(max(width, metrics.minNodeWidth), metrics.maxNodeWidth)
        var height = Double(lines.count) * metrics.lineHeight + metrics.verticalPadding * 2
        // A rhombus needs more box than a rectangle to hold the same text:
        // its corners are empty.
        if node.shape == .diamond {
            width *= 1.3
            height *= 1.3
        }
        return Measured(lines: lines, size: DiagramSize(width: width, height: height))
    }

    private static func wrap(_ label: String, metrics: DiagramMetrics) -> [String] {
        let available = metrics.maxNodeWidth - metrics.horizontalPadding * 2
        var lines: [String] = []
        for hardLine in label.components(separatedBy: "\n") {
            var current = ""
            for word in hardLine.split(separator: " ", omittingEmptySubsequences: true) {
                let candidate = current.isEmpty ? String(word) : current + " " + word
                if metrics.size(ofLine: candidate).width > available, !current.isEmpty {
                    lines.append(current)
                    current = String(word)
                } else {
                    current = candidate
                }
            }
            lines.append(current)
        }
        let kept = lines.filter { !$0.isEmpty }
        return kept.isEmpty ? [""] : kept
    }

    // MARK: - Flowchart

    private static func layoutFlowchart(
        _ graph: MermaidGraph, metrics: DiagramMetrics
    ) -> LaidOutDiagram {
        let measured = graph.nodes.reduce(into: [String: Measured]()) {
            $0[$1.id] = measure($1, metrics: metrics)
        }
        let (acyclic, reversed) = breakCycles(graph)
        let layers = assignLayers(graph.nodes.map(\.id), edges: acyclic)
        let columns = orderWithinLayers(graph.nodes.map(\.id), layers: layers, edges: acyclic)

        let isVertical = graph.direction == .topDown || graph.direction == .bottomTop
        var centers: [String: DiagramPoint] = [:]

        // Layer axis: each layer sits past the deepest node of the one
        // before it, so a tall box never overlaps the next row.
        var layerOffsets: [Double] = []
        var running: Double = 0
        for column in columns {
            let extent = column
                .compactMap { measured[$0] }
                .map { isVertical ? $0.size.height : $0.size.width }
                .max() ?? 0
            layerOffsets.append(running + extent / 2)
            running += extent + metrics.layerGap
        }
        let layerExtent = max(0, running - metrics.layerGap)

        var crossExtent: Double = 0
        for (layerIndex, column) in columns.enumerated() {
            var cross: Double = 0
            for id in column {
                guard let node = measured[id] else { continue }
                let span = isVertical ? node.size.width : node.size.height
                let along = layerOffsets[layerIndex]
                let center = cross + span / 2
                centers[id] = isVertical
                    ? DiagramPoint(x: center, y: along)
                    : DiagramPoint(x: along, y: center)
                cross += span + metrics.siblingGap
            }
            crossExtent = max(crossExtent, max(0, cross - metrics.siblingGap))
        }

        // Centre each layer against the widest one, so a three-node row
        // sits under the middle of a five-node row rather than flush left.
        for column in columns {
            let span = column
                .compactMap { measured[$0] }
                .map { isVertical ? $0.size.width : $0.size.height }
                .reduce(0) { $0 + $1 + metrics.siblingGap }
            let width = max(0, span - metrics.siblingGap)
            let shift = (crossExtent - width) / 2
            guard shift > 0 else { continue }
            for id in column {
                guard var point = centers[id] else { continue }
                if isVertical { point.x += shift } else { point.y += shift }
                centers[id] = point
            }
        }

        // BT and RL are the forward layouts mirrored on the layer axis.
        if graph.direction == .bottomTop || graph.direction == .rightLeft {
            for (id, point) in centers {
                centers[id] = graph.direction == .bottomTop
                    ? DiagramPoint(x: point.x, y: layerExtent - point.y)
                    : DiagramPoint(x: layerExtent - point.x, y: point.y)
            }
        }

        let placed = graph.nodes.compactMap { node -> LaidOutDiagram.PlacedNode? in
            guard let center = centers[node.id], let size = measured[node.id] else { return nil }
            return LaidOutDiagram.PlacedNode(
                id: node.id, lines: size.lines, shape: node.shape,
                center: center, size: size.size, depth: layers[node.id] ?? 0
            )
        }

        let bounds = isVertical
            ? DiagramSize(width: crossExtent, height: layerExtent)
            : DiagramSize(width: layerExtent, height: crossExtent)

        return LaidOutDiagram(
            nodes: placed,
            edges: route(graph.edges, nodes: placed, reversed: reversed, direction: graph.direction),
            bounds: bounds,
            flow: graph.direction
        )
    }

    /// DFS from the declared roots, then from anything still unvisited, in
    /// declaration order -- which is what makes the result deterministic.
    /// An edge pointing at a node currently on the stack is a back edge;
    /// flipping it is what lets the layering pass assume a DAG.
    private static func breakCycles(
        _ graph: MermaidGraph
    ) -> (edges: [(from: String, to: String)], reversed: Set<String>) {
        var outgoing: [String: [MermaidGraph.Edge]] = [:]
        for edge in graph.edges { outgoing[edge.from, default: []].append(edge) }

        var colour: [String: Int] = [:]   // 0 unseen, 1 on stack, 2 done
        var reversed: Set<String> = []
        var result: [(from: String, to: String)] = []

        func visit(_ id: String) {
            colour[id] = 1
            for edge in outgoing[id] ?? [] {
                switch colour[edge.to] ?? 0 {
                case 1:
                    reversed.insert(edge.id)
                    result.append((from: edge.to, to: edge.from))
                case 0:
                    result.append((from: edge.from, to: edge.to))
                    visit(edge.to)
                default:
                    result.append((from: edge.from, to: edge.to))
                }
            }
            colour[id] = 2
        }

        for node in graph.roots where (colour[node.id] ?? 0) == 0 { visit(node.id) }
        for node in graph.nodes where (colour[node.id] ?? 0) == 0 { visit(node.id) }
        return (result, reversed)
    }

    /// Longest-path layering: a node sits one past its deepest predecessor.
    /// Simple and deterministic, and at the dozen nodes these diagrams hold
    /// the extra compactness of a smarter algorithm isn't worth the code.
    private static func assignLayers(
        _ ids: [String], edges: [(from: String, to: String)]
    ) -> [String: Int] {
        var predecessors: [String: [String]] = [:]
        var successors: [String: [String]] = [:]
        for edge in edges {
            predecessors[edge.to, default: []].append(edge.from)
            successors[edge.from, default: []].append(edge.to)
        }
        var layer: [String: Int] = [:]
        for id in ids where (predecessors[id] ?? []).isEmpty { layer[id] = 0 }
        if layer.isEmpty, let first = ids.first { layer[first] = 0 }

        var queue = ids.filter { layer[$0] != nil }
        var guardCounter = 0
        let limit = ids.count * ids.count + ids.count
        while let id = queue.first, guardCounter < limit {
            queue.removeFirst()
            guardCounter += 1
            let next = (layer[id] ?? 0) + 1
            for successor in successors[id] ?? [] where (layer[successor] ?? -1) < next {
                layer[successor] = next
                queue.append(successor)
            }
        }
        for id in ids where layer[id] == nil { layer[id] = 0 }
        return layer
    }

    /// Four barycentre sweeps -- down, up, down, up. Each node moves toward
    /// the mean position of its neighbours in the adjacent layer, with ties
    /// broken by the previous index so the sort is stable and the result
    /// converges instead of oscillating.
    private static func orderWithinLayers(
        _ ids: [String], layers: [String: Int], edges: [(from: String, to: String)]
    ) -> [[String]] {
        let depth = (layers.values.max() ?? 0) + 1
        var columns: [[String]] = Array(repeating: [], count: depth)
        for id in ids { columns[layers[id] ?? 0].append(id) }

        var predecessors: [String: [String]] = [:]
        var successors: [String: [String]] = [:]
        for edge in edges {
            predecessors[edge.to, default: []].append(edge.from)
            successors[edge.from, default: []].append(edge.to)
        }

        func sweep(downward: Bool) {
            // A single-layer graph has no adjacent layer to average
            // against, and the upward sweep would reach past the last
            // column looking for one.
            guard depth > 1 else { return }
            let range = downward ? Array(1..<depth) : Array((0..<(depth - 1)).reversed())
            for index in range {
                let reference = downward ? columns[index - 1] : columns[index + 1]
                let position = Dictionary(
                    uniqueKeysWithValues: reference.enumerated().map { ($0.element, Double($0.offset)) }
                )
                let previous = Dictionary(
                    uniqueKeysWithValues: columns[index].enumerated().map { ($0.element, $0.offset) }
                )
                columns[index].sort { first, second in
                    let a = barycentre(first, position, downward ? predecessors : successors)
                        ?? Double(previous[first] ?? 0)
                    let b = barycentre(second, position, downward ? predecessors : successors)
                        ?? Double(previous[second] ?? 0)
                    if a == b { return (previous[first] ?? 0) < (previous[second] ?? 0) }
                    return a < b
                }
            }
        }

        for pass in 0..<4 { sweep(downward: pass % 2 == 0) }
        return columns
    }

    private static func barycentre(
        _ id: String, _ position: [String: Double], _ neighbours: [String: [String]]
    ) -> Double? {
        let values = (neighbours[id] ?? []).compactMap { position[$0] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func route(
        _ edges: [MermaidGraph.Edge], nodes: [LaidOutDiagram.PlacedNode],
        reversed: Set<String>, direction: MermaidGraph.Direction
    ) -> [LaidOutDiagram.PlacedEdge] {
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return edges.compactMap { edge in
            guard let from = byId[edge.from], let to = byId[edge.to] else { return nil }
            let start = anchor(on: from, towards: to.center)
            let end = anchor(on: to, towards: from.center)
            let middle = DiagramPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            return LaidOutDiagram.PlacedEdge(
                id: edge.id, from: edge.from, to: edge.to,
                waypoints: [start, middle, end], label: edge.label,
                style: edge.style, isReversed: reversed.contains(edge.id)
            )
        }
    }

    /// Where a line meets a node's border on the way to `target`. Stopping
    /// at the border rather than the centre is what keeps an arrowhead
    /// visible instead of buried under the box it points at.
    private static func anchor(
        on node: LaidOutDiagram.PlacedNode, towards target: DiagramPoint
    ) -> DiagramPoint {
        let dx = target.x - node.center.x
        let dy = target.y - node.center.y
        guard dx != 0 || dy != 0 else { return node.center }
        let halfWidth = node.size.width / 2
        let halfHeight = node.size.height / 2
        let scale = min(
            dx == 0 ? .greatestFiniteMagnitude : halfWidth / abs(dx),
            dy == 0 ? .greatestFiniteMagnitude : halfHeight / abs(dy)
        )
        return DiagramPoint(x: node.center.x + dx * scale, y: node.center.y + dy * scale)
    }

    // MARK: - Mindmap

    private static func children(of graph: MermaidGraph) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for edge in graph.edges { result[edge.from, default: []].append(edge.to) }
        return result
    }

    /// Leaves get an angular slot each and a parent sits at the mean of its
    /// children's, so a heavy branch claims proportionally more of the
    /// circle instead of every branch getting an equal slice regardless of
    /// what's in it.
    private static func layoutRadial(
        _ graph: MermaidGraph, metrics: DiagramMetrics
    ) -> LaidOutDiagram {
        let measured = graph.nodes.reduce(into: [String: Measured]()) {
            $0[$1.id] = measure($1, metrics: metrics)
        }
        let childMap = children(of: graph)
        let roots = graph.roots.map(\.id)

        var leafCount: [String: Int] = [:]
        func countLeaves(_ id: String) -> Int {
            let kids = childMap[id] ?? []
            let total = kids.isEmpty ? 1 : kids.reduce(0) { $0 + countLeaves($1) }
            leafCount[id] = total
            return total
        }
        let totalLeaves = max(1, roots.reduce(0) { $0 + countLeaves($1) })

        // Widen the rings if the busiest one can't fit its nodes at the
        // base spacing -- otherwise the outer labels overlap each other.
        var perRing: [Int: Int] = [:]
        for node in graph.nodes { perRing[node.depth ?? 0, default: 0] += 1 }
        let busiest = perRing.values.max() ?? 1
        let meanWidth = measured.values.map(\.size.width).reduce(0, +)
            / Double(max(1, measured.count))
        let ringGap = max(
            metrics.ringGap,
            Double(busiest) * (meanWidth + metrics.siblingGap) / (2 * Double.pi)
        )

        var centers: [String: DiagramPoint] = [:]
        func place(_ id: String, depth: Int, start: Double, sweep: Double) {
            let angle = start + sweep / 2
            let radius = ringGap * Double(depth)
            centers[id] = DiagramPoint(x: radius * cos(angle), y: radius * sin(angle))
            var cursor = start
            for child in childMap[id] ?? [] {
                let share = sweep * Double(leafCount[child] ?? 1) / Double(max(1, leafCount[id] ?? 1))
                place(child, depth: depth + 1, start: cursor, sweep: share)
                cursor += share
            }
        }

        var cursor: Double = -.pi
        for root in roots {
            let share = 2 * Double.pi * Double(leafCount[root] ?? 1) / Double(totalLeaves)
            place(root, depth: roots.count == 1 ? 0 : 1, start: cursor, sweep: share)
            cursor += share
        }

        return finish(graph, centers: centers, measured: measured, metrics: metrics)
    }

    private static func layoutIndented(
        _ graph: MermaidGraph, metrics: DiagramMetrics
    ) -> LaidOutDiagram {
        let measured = graph.nodes.reduce(into: [String: Measured]()) {
            $0[$1.id] = measure($1, metrics: metrics)
        }
        var centers: [String: DiagramPoint] = [:]
        var row: Double = 0
        let step = metrics.lineHeight + metrics.siblingGap
        // Source order is already pre-order for a mindmap, so the tree
        // reads top to bottom exactly as it was written.
        for node in graph.nodes {
            let size = measured[node.id]?.size ?? DiagramSize(width: 0, height: 0)
            let indent = Double(node.depth ?? 0) * 36
            centers[node.id] = DiagramPoint(x: indent + size.width / 2, y: row + size.height / 2)
            row += max(step, size.height + metrics.siblingGap / 2)
        }
        return finish(graph, centers: centers, measured: measured, metrics: metrics)
    }

    /// Translates everything to non-negative coordinates and routes edges.
    /// Radial layout works around an origin, so this is what turns it into
    /// something a canvas can draw at (0, 0).
    private static func finish(
        _ graph: MermaidGraph, centers: [String: DiagramPoint],
        measured: [String: Measured], metrics: DiagramMetrics
    ) -> LaidOutDiagram {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for node in graph.nodes {
            guard let center = centers[node.id], let size = measured[node.id]?.size else { continue }
            minX = min(minX, center.x - size.width / 2)
            minY = min(minY, center.y - size.height / 2)
            maxX = max(maxX, center.x + size.width / 2)
            maxY = max(maxY, center.y + size.height / 2)
        }
        guard minX < .greatestFiniteMagnitude else {
            return LaidOutDiagram(
                nodes: [], edges: [], bounds: DiagramSize(width: 0, height: 0),
                flow: graph.direction
            )
        }

        let placed = graph.nodes.compactMap { node -> LaidOutDiagram.PlacedNode? in
            guard let center = centers[node.id], let size = measured[node.id] else { return nil }
            return LaidOutDiagram.PlacedNode(
                id: node.id, lines: size.lines, shape: node.shape,
                center: DiagramPoint(x: center.x - minX, y: center.y - minY),
                size: size.size, depth: node.depth ?? 0
            )
        }

        return LaidOutDiagram(
            nodes: placed,
            edges: route(graph.edges, nodes: placed, reversed: [], direction: graph.direction),
            bounds: DiagramSize(width: maxX - minX, height: maxY - minY),
            flow: graph.direction
        )
    }
}
