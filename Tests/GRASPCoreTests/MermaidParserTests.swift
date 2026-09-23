import Testing
@testable import GRASPCore

/// The parser stands between a local model's free-text output and a Canvas
/// that has to draw something. Its contract is that it never throws, never
/// lets one malformed line cost the rest of the diagram, and returns nil
/// only when the source isn't a diagram type this app draws at all -- so
/// most of what's asserted here is tolerance rather than correctness on
/// well-formed input.
@Suite("Mermaid parser")
struct MermaidParserTests {

    // MARK: - Header

    @Test("recognises every flowchart header spelling and direction")
    func flowchartHeaders() {
        #expect(MermaidParser.parse("graph TD\nA-->B")?.direction == .topDown)
        #expect(MermaidParser.parse("graph TB\nA-->B")?.direction == .topDown)
        #expect(MermaidParser.parse("graph LR\nA-->B")?.direction == .leftRight)
        #expect(MermaidParser.parse("graph BT\nA-->B")?.direction == .bottomTop)
        #expect(MermaidParser.parse("graph RL\nA-->B")?.direction == .rightLeft)
        #expect(MermaidParser.parse("flowchart TD\nA-->B")?.kind == .flowchart)
        #expect(MermaidParser.parse("GRAPH td\nA-->B")?.direction == .topDown)
    }

    @Test("a header with no direction defaults to top-down")
    func headerWithoutDirection() {
        #expect(MermaidParser.parse("graph\nA-->B")?.direction == .topDown)
    }

    @Test("returns nil for diagram types this app doesn't draw")
    func unsupportedDiagramTypes() {
        #expect(MermaidParser.parse("sequenceDiagram\nA->>B: hi") == nil)
        #expect(MermaidParser.parse("classDiagram\nClass01 <|-- Class02") == nil)
        #expect(MermaidParser.parse("gantt\ntitle A") == nil)
        #expect(MermaidParser.parse("erDiagram") == nil)
        #expect(MermaidParser.parse("") == nil)
        #expect(MermaidParser.parse("   \n\n  ") == nil)
        #expect(MermaidParser.parse("Here is a diagram of the cell cycle.") == nil)
    }

    @Test("a leading comment doesn't hide the header")
    func commentBeforeHeader() {
        #expect(MermaidParser.parse("%% the cell cycle\ngraph TD\nA-->B")?.nodes.count == 2)
    }

    // MARK: - Nodes

    @Test("parses every node shape, and degrades the ones it doesn't draw")
    func nodeShapes() throws {
        let graph = try #require(MermaidParser.parse("""
            graph TD
            a[Box]
            b(Round)
            c([Stadium])
            d{Diamond}
            e((Circle))
            f[[Subroutine]]
            g[(Database)]
            """))
        #expect(graph.nodes.count == 7)
        #expect(graph.nodes[0].shape == .rectangle)
        #expect(graph.nodes[1].shape == .rounded)
        #expect(graph.nodes[2].shape == .stadium)
        #expect(graph.nodes[3].shape == .diamond)
        #expect(graph.nodes[4].shape == .circle)
        #expect(graph.nodes[5].shape == .rectangle)   // degraded
        #expect(graph.nodes[6].shape == .rounded)     // degraded
    }

    @Test("cleans quoted labels, line-break tags and HTML entities")
    func labelCleaning() throws {
        let graph = try #require(MermaidParser.parse("""
            graph TD
            a["Quoted"]
            b[First<br/>Second]
            c[Tom &amp; Jerry]
            d[5 &lt; 6]
            """))
        #expect(graph.nodes[0].label == "Quoted")
        #expect(graph.nodes[1].label == "First\nSecond")
        #expect(graph.nodes[2].label == "Tom & Jerry")
        #expect(graph.nodes[3].label == "5 < 6")
    }

    @Test("truncates a runaway label instead of letting it break the canvas")
    func labelTruncation() throws {
        let long = String(repeating: "word ", count: 80)
        let graph = try #require(MermaidParser.parse("graph TD\na[\(long)]"))
        #expect(graph.nodes[0].label.count <= MermaidParser.maximumLabelLength + 1)
    }

    @Test("a bare id in an edge doesn't overwrite a label declared earlier")
    func bareIdKeepsEarlierLabel() throws {
        let graph = try #require(MermaidParser.parse("""
            graph TD
            interphase[Interphase]
            interphase --> prophase[Prophase]
            """))
        #expect(graph.nodes.first { $0.id == "interphase" }?.label == "Interphase")
    }

    @Test("an edge to an undeclared id still creates that node")
    func undeclaredIdsBecomeNodes() throws {
        let graph = try #require(MermaidParser.parse("graph TD\nA --> B"))
        #expect(graph.nodes.count == 2)
        #expect(graph.nodes.map(\.label) == ["A", "B"])
    }

    // MARK: - Edges

    @Test("parses every arrow form and maps it to a style")
    func edgeStyles() throws {
        let graph = try #require(MermaidParser.parse("""
            graph TD
            a --> b
            c --- d
            e -.-> f
            g ==> h
            i --x j
            """))
        #expect(graph.edges.count == 5)
        #expect(graph.edges[0].style == .solid)
        #expect(graph.edges[1].style == .open)
        #expect(graph.edges[2].style == .dotted)
        #expect(graph.edges[3].style == .thick)
        #expect(graph.edges[4].style == .solid)
    }

    @Test("a bidirectional arrow becomes two edges")
    func bidirectionalEdge() throws {
        let graph = try #require(MermaidParser.parse("graph TD\na <--> b"))
        #expect(graph.edges.count == 2)
        #expect(graph.edges[0].from == "a")
        #expect(graph.edges[1].from == "b")
    }

    @Test("reads both labelled-edge spellings")
    func edgeLabels() throws {
        let piped = try #require(MermaidParser.parse("graph TD\na -->|triggers| b"))
        #expect(piped.edges.first?.label == "triggers")

        let inline = try #require(MermaidParser.parse("graph TD\na -- triggers --> b"))
        #expect(inline.edges.count == 1)
        #expect(inline.edges.first?.label == "triggers")
        #expect(inline.edges.first?.from == "a")
        #expect(inline.edges.first?.to == "b")
    }

    @Test("an arrow inside a node label does not split the line")
    func arrowInsideLabelIsNotAnOperator() throws {
        let graph = try #require(MermaidParser.parse("graph TD\nA[step --> next] --> C"))
        #expect(graph.nodes.count == 2)
        #expect(graph.nodes.first { $0.id == "A" }?.label == "step --> next")
        #expect(graph.edges.count == 1)
        #expect(graph.edges.first?.from == "A")
        #expect(graph.edges.first?.to == "C")
    }

    @Test("builds every link in a chain")
    func chains() throws {
        let graph = try #require(MermaidParser.parse("graph TD\nA --> B --> C --> D"))
        #expect(graph.nodes.count == 4)
        #expect(graph.edges.count == 3)
        #expect(graph.edges.map { "\($0.from)\($0.to)" } == ["AB", "BC", "CD"])
    }

    @Test("expands fan-outs on either side of an arrow")
    func fanOuts() throws {
        let fanIn = try #require(MermaidParser.parse("graph TD\nA & B --> C"))
        #expect(fanIn.edges.count == 2)

        let fanOut = try #require(MermaidParser.parse("graph TD\nA --> B & C"))
        #expect(fanOut.edges.count == 2)
    }

    // MARK: - Tolerance

    @Test("ignores decoration lines but keeps the nodes inside a subgraph")
    func ignoredLines() throws {
        let graph = try #require(MermaidParser.parse("""
            graph TD
            %% a comment
            subgraph Phase One
            A[Interphase] --> B[Prophase]
            end
            style A fill:#f9f
            classDef big font-size:20px
            click A callback
            linkStyle 0 stroke:#333
            """))
        #expect(graph.nodes.count == 2)
        #expect(graph.edges.count == 1)
    }

    @Test("skips a line it can't classify and keeps the rest of the diagram")
    func garbageLinesAreSkipped() throws {
        let graph = try #require(MermaidParser.parse("""
            graph TD
            A[Start] --> B[Middle]
            !!! ???
            B --> C[End]
            """))
        #expect(graph.nodes.count == 3)
        #expect(graph.edges.count == 2)
        #expect(graph.skippedLineCount == 1)
    }

    @Test("drops a self-loop rather than drawing an arrow from a box to itself")
    func selfLoopsAreDropped() throws {
        let graph = try #require(MermaidParser.parse("graph TD\nA[Start] --> A\nA --> B[Next]"))
        #expect(graph.edges.count == 1)
        #expect(graph.edges.first?.to == "B")
    }

    @Test("a graph whose boxes all share one name is not worth drawing")
    func collapsedGraphIsNotWorthDrawing() throws {
        // Verbatim output from a real 7B, which read the old prompt's
        // "a node is written id[Label]" and used `id` as the literal name of
        // every box. They collapse to one node and every edge is a
        // self-loop. Rendering that gave a single rectangle floating in an
        // empty canvas; the reader now shows the source instead.
        let graph = try #require(MermaidParser.parse("""
            graph TD
            id[Elementary Row Operations] --> id[Replacement]
            id[Elementary Row Operations] --> id[Interchange]
            id[Key Terms] --> id[Key Terms]
            """))
        #expect(graph.nodes.count == 1)
        #expect(graph.edges.isEmpty)
        #expect(!graph.isWorthDrawing)
    }

    @Test("a real diagram is worth drawing")
    func realGraphIsWorthDrawing() throws {
        let graph = try #require(MermaidParser.parse("""
            graph TD
            scarcity[Wants exceed resources] --> choice[Every choice costs something]
            choice --> oppcost[Opportunity cost]
            """))
        #expect(graph.isWorthDrawing)
    }

    @Test("a lone box with no relationships is not worth drawing")
    func singleNodeIsNotWorthDrawing() throws {
        let graph = try #require(MermaidParser.parse("graph TD\nA[Only one thing]"))
        #expect(!graph.isWorthDrawing)
    }

    @Test("caps a runaway diagram instead of returning something unrenderable")
    func caps() throws {
        var source = "graph TD\n"
        for index in 0..<200 { source += "n\(index)[Node \(index)]\n" }
        let graph = try #require(MermaidParser.parse(source))
        #expect(graph.nodes.count <= MermaidParser.maximumNodes)
    }

    @Test("a cycle parses without hanging")
    func cycles() throws {
        let graph = try #require(MermaidParser.parse("graph TD\nA --> B\nB --> C\nC --> A"))
        #expect(graph.edges.count == 3)
        // Every node has an incoming edge, so `roots` falls back to the
        // first declared one rather than returning nothing for layout.
        #expect(graph.roots.count == 1)
        #expect(graph.roots.first?.id == "A")
    }

    @Test("every prefix of a real diagram parses without throwing")
    func prefixFuzz() {
        let source = """
            graph TD
            A[Interphase] --> B{Checkpoint}
            B -->|pass| C([Prophase])
            B -- fail --> D((Arrest))
            C & D --> E[Metaphase]
            """
        for length in 0...source.count {
            _ = MermaidParser.parse(String(source.prefix(length)))
        }
    }

    // MARK: - Mindmap

    @Test("nests a mindmap by indentation")
    func mindmapNesting() throws {
        let graph = try #require(MermaidParser.parse("""
            mindmap
            Cell Cycle
              Interphase
                G1 phase
                S phase
              Mitosis
                Prophase
            """))
        #expect(graph.kind == .mindmap)
        #expect(graph.nodes.count == 6)
        #expect(graph.nodes[0].depth == 0)
        #expect(graph.nodes[1].depth == 1)
        #expect(graph.nodes[2].depth == 2)
        #expect(graph.nodes[4].depth == 1)   // Mitosis, back up a level
        #expect(graph.edges.count == 5)
    }

    @Test("handles mixed indent widths and tabs")
    func mindmapMixedIndents() throws {
        let graph = try #require(MermaidParser.parse("""
            mindmap
            Root
                Four spaces
            \tTab
              Two spaces
            """))
        #expect(graph.nodes.count == 4)
        #expect(graph.nodes.allSatisfy { $0.depth == 0 || $0.depth == 1 })
    }

    @Test("reads a shaped mindmap root and bare text alike")
    func mindmapShapes() throws {
        let graph = try #require(MermaidParser.parse("""
            mindmap
            root((Cell Cycle))
              Interphase
            """))
        #expect(graph.nodes[0].label == "Cell Cycle")
        #expect(graph.nodes[0].shape == .circle)
        #expect(graph.nodes[1].label == "Interphase")
    }

    @Test("keeps several top-level mindmap nodes as a forest")
    func mindmapForest() throws {
        let graph = try #require(MermaidParser.parse("""
            mindmap
            First
              Child
            Second
            """))
        #expect(graph.nodes.filter { $0.depth == 0 }.count == 2)
        #expect(graph.roots.count == 2)
    }

    @Test("dedents by more than one level at once")
    func mindmapMultiLevelDedent() throws {
        let graph = try #require(MermaidParser.parse("""
            mindmap
            Root
              A
                B
                  C
              D
            """))
        #expect(graph.nodes.last?.label == "D")
        #expect(graph.nodes.last?.depth == 1)
        // D's parent is Root, not C.
        let dNode = try #require(graph.nodes.last)
        let incoming = graph.edges.first { $0.to == dNode.id }
        #expect(incoming?.from == graph.nodes[0].id)
    }
}
