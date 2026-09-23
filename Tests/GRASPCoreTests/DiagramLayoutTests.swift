import Testing
@testable import GRASPCore

/// Layout has one invariant that matters above all the others: two boxes
/// must never sit on top of each other. Everything else about a diagram can
/// be a bit ugly and still be readable; overlapping nodes cannot. Most of
/// what's here checks that under the shapes real generated diagrams take.
@Suite("Diagram layout")
struct DiagramLayoutTests {

    private func graph(_ source: String) throws -> MermaidGraph {
        try #require(MermaidParser.parse(source))
    }

    /// Nodes may touch but never overlap. A small tolerance absorbs the
    /// floating-point noise in the centring passes.
    private func noOverlaps(_ diagram: LaidOutDiagram) -> Bool {
        let tolerance = 0.5
        for (index, first) in diagram.nodes.enumerated() {
            for second in diagram.nodes.dropFirst(index + 1) {
                let dx = abs(first.center.x - second.center.x)
                let dy = abs(first.center.y - second.center.y)
                let overlapX = dx < (first.size.width + second.size.width) / 2 - tolerance
                let overlapY = dy < (first.size.height + second.size.height) / 2 - tolerance
                if overlapX && overlapY { return false }
            }
        }
        return true
    }

    @Test("lays a chain out one layer at a time, top to bottom")
    func linearChainTopDown() throws {
        let diagram = DiagramLayout.layout(try graph("graph TD\nA --> B --> C"))
        #expect(diagram.nodes.count == 3)
        let ys = diagram.nodes.map(\.center.y)
        #expect(ys[0] < ys[1] && ys[1] < ys[2])
        #expect(noOverlaps(diagram))
    }

    @Test("runs the same chain left to right for graph LR")
    func linearChainLeftRight() throws {
        let diagram = DiagramLayout.layout(try graph("graph LR\nA --> B --> C"))
        let xs = diagram.nodes.map(\.center.x)
        #expect(xs[0] < xs[1] && xs[1] < xs[2])
        #expect(noOverlaps(diagram))
    }

    @Test("bottom-up is the top-down layout mirrored")
    func bottomTopMirrors() throws {
        let diagram = DiagramLayout.layout(try graph("graph BT\nA --> B --> C"))
        let ys = diagram.nodes.map(\.center.y)
        #expect(ys[0] > ys[1] && ys[1] > ys[2])
    }

    @Test("puts the two arms of a diamond in the same layer and joins them below")
    func diamond() throws {
        let diagram = DiagramLayout.layout(try graph("""
            graph TD
            A --> B
            A --> C
            B --> D
            C --> D
            """))
        let byId = Dictionary(uniqueKeysWithValues: diagram.nodes.map { ($0.id, $0) })
        let b = try #require(byId["B"])
        let c = try #require(byId["C"])
        let d = try #require(byId["D"])
        #expect(b.depth == c.depth)
        #expect(d.depth > b.depth)
        #expect(b.center.y == c.center.y)
        #expect(noOverlaps(diagram))
    }

    @Test("a cycle terminates and marks the edge it had to flip")
    func cycleTerminates() throws {
        let diagram = DiagramLayout.layout(try graph("graph TD\nA --> B\nB --> C\nC --> A"))
        #expect(diagram.nodes.count == 3)
        #expect(diagram.edges.contains { $0.isReversed })
        #expect(noOverlaps(diagram))
    }

    @Test("places disconnected components without overlapping them")
    func disconnectedComponents() throws {
        let diagram = DiagramLayout.layout(try graph("""
            graph TD
            A --> B
            C --> D
            E --> F
            """))
        #expect(diagram.nodes.count == 6)
        #expect(noOverlaps(diagram))
    }

    @Test("keeps a wide fan-out clear of itself")
    func wideFanOut() throws {
        let diagram = DiagramLayout.layout(try graph("""
            graph TD
            Root[Cell Cycle] --> A[Interphase]
            Root --> B[Prophase]
            Root --> C[Metaphase]
            Root --> D[Anaphase]
            Root --> E[Telophase]
            """))
        #expect(noOverlaps(diagram))
    }

    @Test("is deterministic -- the same graph lays out identically twice")
    func deterministic() throws {
        let source = """
            graph TD
            A[Start] --> B{Check}
            B -->|yes| C[Go]
            B -->|no| D[Stop]
            C & D --> E[End]
            """
        let first = DiagramLayout.layout(try graph(source))
        let second = DiagramLayout.layout(try graph(source))
        #expect(first == second)
    }

    @Test("wraps a long label instead of letting the box run away")
    func longLabelWraps() throws {
        let diagram = DiagramLayout.layout(try graph(
            "graph TD\nA[The cell cycle is the series of events that take place in a cell]"
        ))
        let node = try #require(diagram.nodes.first)
        #expect(node.lines.count > 1)
        #expect(node.size.width <= DiagramMetrics().maxNodeWidth + 0.01)
    }

    @Test("gives a diamond more box than a rectangle for the same text")
    func diamondIsLarger() throws {
        let rectangle = DiagramLayout.layout(try graph("graph TD\nA[Checkpoint]"))
        let diamond = DiagramLayout.layout(try graph("graph TD\nA{Checkpoint}"))
        let first = try #require(rectangle.nodes.first)
        let second = try #require(diamond.nodes.first)
        #expect(second.size.width > first.size.width)
        #expect(second.size.height > first.size.height)
    }

    @Test("stops edges at the node border, not its centre")
    func edgesStopAtBorders() throws {
        let diagram = DiagramLayout.layout(try graph("graph TD\nA --> B"))
        let edge = try #require(diagram.edges.first)
        let from = try #require(diagram.nodes.first { $0.id == "A" })
        #expect(edge.waypoints.count == 3)
        // The start sits on A's lower edge rather than at its centre.
        #expect(edge.waypoints[0].y > from.center.y)
        #expect(abs(edge.waypoints[0].y - (from.center.y + from.size.height / 2)) < 0.01)
    }

    @Test("a single node's bounds are just that node")
    func singleNode() throws {
        let diagram = DiagramLayout.layout(try graph("graph TD\nA[Only]"))
        let node = try #require(diagram.nodes.first)
        #expect(abs(diagram.bounds.width - node.size.width) < 0.01)
        #expect(abs(diagram.bounds.height - node.size.height) < 0.01)
    }

    @Test("an empty graph lays out to nothing rather than crashing")
    func emptyGraph() {
        let empty = MermaidGraph(
            kind: .flowchart, direction: .topDown, nodes: [], edges: [], skippedLineCount: 0
        )
        let diagram = DiagramLayout.layout(empty)
        #expect(diagram.isEmpty)
        #expect(diagram.bounds.width == 0)
    }

    @Test("arranges a small mindmap in rings around its root")
    func mindmapRadial() throws {
        let diagram = DiagramLayout.layout(try graph("""
            mindmap
            Cell Cycle
              Interphase
              Mitosis
              Cytokinesis
            """))
        #expect(diagram.nodes.count == 4)
        #expect(noOverlaps(diagram))
        // The root sits inside the ring its children form.
        let root = try #require(diagram.nodes.first)
        let children = diagram.nodes.dropFirst()
        #expect(children.allSatisfy { $0.center.x != root.center.x || $0.center.y != root.center.y })
    }

    @Test("falls back to an indented tree once a mindmap gets large")
    func mindmapIndentedAboveThreshold() throws {
        var source = "mindmap\nRoot\n"
        for index in 0..<30 { source += "  Child \(index)\n" }
        let diagram = DiagramLayout.layout(try graph(source))
        #expect(diagram.nodes.count > DiagramLayout.radialNodeLimit)
        #expect(noOverlaps(diagram))
        // An indented tree runs straight down: every row has a distinct y.
        let ys = Set(diagram.nodes.map { Int($0.center.y) })
        #expect(ys.count == diagram.nodes.count)
    }

    @Test("honours an injected text measurer instead of the character estimate")
    func customMeasurerIsUsed() throws {
        var metrics = DiagramMetrics()
        metrics.measure = { line in
            DiagramSize(width: Double(line.count) * 20, height: 16)
        }
        // Long enough that neither result is clamped to `minNodeWidth`,
        // which would make the two measurers indistinguishable.
        let wide = DiagramLayout.layout(try graph("graph TD\nA[Prophase]"), metrics: metrics)
        let narrow = DiagramLayout.layout(try graph("graph TD\nA[Prophase]"))
        let first = try #require(wide.nodes.first)
        let second = try #require(narrow.nodes.first)
        #expect(first.size.width > second.size.width)
    }
}
