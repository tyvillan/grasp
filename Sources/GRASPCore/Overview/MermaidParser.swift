import Foundation

/// A concept diagram, parsed from the Mermaid subset the generator is asked
/// to write in. Deliberately holds no geometry -- `DiagramLayout` turns
/// this into positions, and the renderer draws those.
public struct MermaidGraph: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case flowchart, mindmap
    }

    public enum Direction: String, Sendable, Equatable {
        case topDown, leftRight, bottomTop, rightLeft
    }

    public enum NodeShape: String, Sendable, Equatable {
        case rectangle, rounded, stadium, diamond, circle
    }

    public enum EdgeStyle: String, Sendable, Equatable {
        case solid, dotted, thick, open
    }

    public struct Node: Sendable, Equatable, Identifiable {
        public let id: String
        public var label: String
        public var shape: NodeShape
        /// Mindmap nesting depth, 0 for a root. nil in a flowchart, where
        /// depth is a layout output rather than a fact about the source.
        public var depth: Int?

        public init(id: String, label: String, shape: NodeShape, depth: Int? = nil) {
            self.id = id
            self.label = label
            self.shape = shape
            self.depth = depth
        }
    }

    public struct Edge: Sendable, Equatable, Identifiable {
        public var id: String { "\(from)>\(to)#\(ordinal)" }
        public let from: String
        public let to: String
        public var label: String?
        public var style: EdgeStyle
        /// Declaration order. Keeps `id` unique for a repeated `A --> B`
        /// and keeps layout deterministic.
        public let ordinal: Int

        public init(from: String, to: String, label: String? = nil,
                    style: EdgeStyle = .solid, ordinal: Int) {
            self.from = from
            self.to = to
            self.label = label
            self.style = style
            self.ordinal = ordinal
        }
    }

    public let kind: Kind
    public let direction: Direction
    public var nodes: [Node]
    public var edges: [Edge]
    /// Lines the parser couldn't classify. Not surfaced in the UI -- it
    /// exists so a test can assert the parser skipped exactly what it
    /// should have, rather than inferring it from what survived.
    public var skippedLineCount: Int

    public var isEmpty: Bool { nodes.isEmpty }

    /// True when there is nothing here worth drawing.
    ///
    /// A single box on its own is the shape a *failed* response takes, not a
    /// concept map: it's what's left when a model gave every box the same
    /// name and they all collapsed into one. A real diagram relates at least
    /// two things to each other, so anything less is better shown as the
    /// raw source than as a lone rectangle floating in an empty canvas --
    /// which is precisely what shipped the first time.
    public var isWorthDrawing: Bool { nodes.count >= 2 && !edges.isEmpty }

    /// Nodes with no incoming edge, in declaration order. A wholly cyclic
    /// graph has none, so the first declared node stands in -- layout
    /// always needs somewhere to start.
    public var roots: [Node] {
        let targets = Set(edges.map(\.to))
        let found = nodes.filter { !targets.contains($0.id) }
        if found.isEmpty, let first = nodes.first { return [first] }
        return found
    }
}

/// Parses the restricted Mermaid subset `diagramPrompt` asks for.
///
/// Totally tolerant, in `PairParser`'s style: it never throws and never
/// lets one bad line cost the rest. It returns nil for exactly one reason
/// -- the source doesn't open with a diagram type this app renders -- and
/// the view falls back to showing the raw source, which is still something
/// the student can read. Everything else degrades: an unknown node shape
/// becomes a rectangle, an unknown arrow becomes a solid edge, a `subgraph`
/// wrapper is dropped while the nodes inside it survive, and a line that
/// makes no sense at all is counted and skipped.
public enum MermaidParser {
    /// Guards against a runaway response making the canvas unrenderable.
    /// Each cap returns what was parsed so far rather than failing.
    static let maximumLines = 400
    static let maximumNodes = 64
    static let maximumEdges = 128
    static let maximumLabelLength = 120


    /// A Mermaid statement this renderer skips. Matched on the whole first
    /// word, not a prefix: as a prefix, "end" also swallowed a node called
    /// "End behavior of polynomials", and "direction" one called
    /// "Direction of force" -- and in a mindmap that node's children were
    /// then hung on the wrong parent.
    static func isDirective(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("%%") { return true }
        let first = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            .map { String($0).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":")) } ?? ""
        let keywords: Set<String> = [
            "subgraph", "end", "style", "classdef", "class", "click", "linkstyle",
            "direction", "acctitle", "accdescr",
        ]
        guard keywords.contains(first) else { return false }
        // `end` alone closes a subgraph; `end` followed by more is a node.
        if first == "end" { return trimmed.count == 3 }
        return true
    }

    public static func parse(_ source: String) -> MermaidGraph? {
        let rawLines = source.components(separatedBy: "\n").prefix(maximumLines)
        var lines = Array(rawLines)

        guard let headerIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("%%")
        }) else { return nil }

        let header = lines[headerIndex].trimmingCharacters(in: .whitespaces)
        lines = Array(lines[(headerIndex + 1)...])

        if let direction = flowchartDirection(header) {
            return parseFlowchart(lines, direction: direction)
        }
        if header.lowercased() == "mindmap" {
            return parseMindmap(lines)
        }
        return nil
    }

    // MARK: - Header

    private static func flowchartDirection(_ header: String) -> MermaidGraph.Direction? {
        let parts = header.split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first?.lowercased(),
              first == "graph" || first == "flowchart"
        else { return nil }
        guard parts.count > 1 else { return .topDown }
        switch parts[1].uppercased() {
        case "TD", "TB": return .topDown
        case "LR": return .leftRight
        case "BT": return .bottomTop
        case "RL": return .rightLeft
        default: return .topDown
        }
    }

    // MARK: - Flowchart

    private static func parseFlowchart(
        _ lines: [String], direction: MermaidGraph.Direction
    ) -> MermaidGraph {
        var nodes: [String: MermaidGraph.Node] = [:]
        var order: [String] = []
        var edges: [MermaidGraph.Edge] = []
        var skipped = 0

        /// Last declaration wins, matching Mermaid's own semantics -- but a
        /// bare `A` appearing in a later edge must not wipe the label an
        /// earlier `A[Real Label]` gave it.
        func remember(_ node: MermaidGraph.Node, explicit: Bool) {
            guard nodes.count < maximumNodes || nodes[node.id] != nil else { return }
            if let existing = nodes[node.id] {
                guard explicit else { return }
                nodes[node.id] = MermaidGraph.Node(
                    id: existing.id, label: node.label, shape: node.shape
                )
            } else {
                nodes[node.id] = node
                order.append(node.id)
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if isDirective(line) {
                continue
            }

            let tokens = tokenize(line)
            let operators = tokens.filter { if case .op = $0 { return true } else { return false } }

            if operators.isEmpty {
                // A standalone declaration: `A[Label]`, possibly several
                // separated by `&`.
                let declared = parseNodeGroup(line)
                if declared.isEmpty { skipped += 1; continue }
                for (node, explicit) in declared { remember(node, explicit: explicit) }
                continue
            }

            guard let links = buildChain(tokens) else { skipped += 1; continue }
            for link in links {
                for (node, explicit) in link.sources { remember(node, explicit: explicit) }
                for (node, explicit) in link.targets { remember(node, explicit: explicit) }
                for source in link.sources {
                    for target in link.targets {
                        guard edges.count < maximumEdges else { break }
                        guard nodes[source.0.id] != nil, nodes[target.0.id] != nil else { continue }
                        // A self-loop is never something a concept map
                        // meant to say. It shows up when a model reuses one
                        // id for every box -- which a real 7B did, taking
                        // the prompt's placeholder name literally -- and
                        // drawing it produces an arrow from a box to
                        // itself on top of an already-wrong diagram.
                        guard source.0.id != target.0.id else { continue }
                        edges.append(MermaidGraph.Edge(
                            from: source.0.id, to: target.0.id, label: link.label,
                            style: link.style, ordinal: edges.count
                        ))
                        if link.isBidirectional, edges.count < maximumEdges {
                            edges.append(MermaidGraph.Edge(
                                from: target.0.id, to: source.0.id, label: link.label,
                                style: link.style, ordinal: edges.count
                            ))
                        }
                    }
                }
            }
        }

        return MermaidGraph(
            kind: .flowchart, direction: direction,
            nodes: order.compactMap { nodes[$0] }, edges: edges, skippedLineCount: skipped
        )
    }

    // MARK: - Tokenizing

    private enum Token: Equatable {
        case text(String)
        case op(EdgeOperator)
    }

    private struct EdgeOperator: Equatable {
        var style: MermaidGraph.EdgeStyle
        var isDirected: Bool
        var isBidirectional: Bool
        /// True for a bare `--`, which is only an edge when an arrow
        /// follows it later on the line (`A -- label --> B`).
        var isBareDash: Bool
        var inlineLabel: String?
    }

    /// Operators, longest first so `-->` never matches as `--`.
    private static let operatorTable: [(token: String, style: MermaidGraph.EdgeStyle,
                                        directed: Bool, bidirectional: Bool)] = [
        ("<-->", .solid, true, true),
        ("<-.->", .dotted, true, true),
        ("-.->", .dotted, true, false),
        ("==>", .thick, true, false),
        ("-->", .solid, true, false),
        ("--x", .solid, true, false),
        ("--o", .solid, true, false),
        ("-.-", .dotted, false, false),
        ("===", .thick, false, false),
        ("---", .open, false, false),
        ("--", .open, false, false),
    ]

    /// Splits a line into text segments and edge operators, matching an
    /// operator only at bracket depth zero. That rule is the one piece of
    /// this parser that has to be exactly right: without it,
    /// `A[step --> next] --> C` splits inside the label and produces two
    /// nodes that don't exist.
    private static func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var depth = 0
        var inQuotes = false
        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                index += 1
                continue
            }
            if !inQuotes {
                if character == "[" || character == "(" || character == "{" { depth += 1 }
                if character == "]" || character == ")" || character == "}" { depth = max(0, depth - 1) }
            }

            if depth == 0, !inQuotes, character == "-" || character == "=" || character == "<" {
                if let match = operatorTable.first(where: { matches($0.token, in: characters, at: index) }) {
                    var index2 = index + match.token.count
                    var label: String?
                    if index2 < characters.count, characters[index2] == "|" {
                        var scan = index2 + 1
                        var text = ""
                        while scan < characters.count, characters[scan] != "|" {
                            text.append(characters[scan])
                            scan += 1
                        }
                        if scan < characters.count {
                            label = cleanLabel(text)
                            index2 = scan + 1
                        }
                    }
                    tokens.append(.text(current))
                    current = ""
                    tokens.append(.op(EdgeOperator(
                        style: match.style, isDirected: match.directed,
                        isBidirectional: match.bidirectional,
                        isBareDash: match.token == "--", inlineLabel: label
                    )))
                    index = index2
                    continue
                }
            }

            current.append(character)
            index += 1
        }
        tokens.append(.text(current))
        return tokens
    }

    private static func matches(_ token: String, in characters: [Character], at index: Int) -> Bool {
        let token = Array(token)
        guard index + token.count <= characters.count else { return false }
        for offset in 0..<token.count where characters[index + offset] != token[offset] {
            return false
        }
        return true
    }

    // MARK: - Chain building

    private struct Link {
        var sources: [(MermaidGraph.Node, Bool)]
        var targets: [(MermaidGraph.Node, Bool)]
        var label: String?
        var style: MermaidGraph.EdgeStyle
        var isBidirectional: Bool
    }

    /// Turns `A --> B --> C` into two links, and folds the
    /// `A -- label --> B` form (a bare `--`, then text, then an arrow) back
    /// into one labelled link. Fan-outs on either side (`A & B --> C`) are
    /// handled by `parseNodeGroup` returning more than one node.
    private static func buildChain(_ tokens: [Token]) -> [Link]? {
        var links: [Link] = []
        var index = 0
        var pending: [(MermaidGraph.Node, Bool)]?

        while index < tokens.count {
            guard case .text(let segment) = tokens[index] else { index += 1; continue }
            var group = parseNodeGroup(segment)
            if group.isEmpty, pending == nil { return nil }

            if let sources = pending {
                guard case .op(var edgeOperator) = tokens[index - 1] else { return nil }

                // `A -- label --> B`: the bare `--` carried no meaning on
                // its own, this segment is the label, and the real operator
                // is the arrow after it.
                if edgeOperator.isBareDash, index + 1 < tokens.count,
                   case .op(let following) = tokens[index + 1] {
                    let label = segment.trimmingCharacters(in: .whitespaces)
                    guard case .text(let targetSegment) = tokens[index + 2] else { return nil }
                    group = parseNodeGroup(targetSegment)
                    guard !group.isEmpty else { return nil }
                    edgeOperator = following
                    edgeOperator.inlineLabel = label.isEmpty ? nil : cleanLabel(label)
                    index += 2
                }

                guard !group.isEmpty else { return nil }
                links.append(Link(
                    sources: sources, targets: group, label: edgeOperator.inlineLabel,
                    style: edgeOperator.style, isBidirectional: edgeOperator.isBidirectional
                ))
            }
            pending = group
            index += 1
        }
        return links.isEmpty ? nil : links
    }

    // MARK: - Nodes

    /// A segment between operators, which may name several nodes joined by
    /// `&`. The `Bool` says whether the node carried an explicit label, so
    /// a bare `A` later in the file doesn't overwrite `A[Real Label]`.
    private static func parseNodeGroup(_ segment: String) -> [(MermaidGraph.Node, Bool)] {
        splitTopLevel(segment, on: "&").compactMap(parseNode)
    }

    private static func splitTopLevel(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inQuotes = false
        for character in text {
            if character == "\"" { inQuotes.toggle() }
            if !inQuotes {
                if character == "[" || character == "(" || character == "{" { depth += 1 }
                if character == "]" || character == ")" || character == "}" { depth = max(0, depth - 1) }
                if character == separator, depth == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }

    /// Shape delimiters, most specific first -- `((` must be tried before
    /// `(`, or every circle parses as a rounded box containing a stray
    /// parenthesis.
    private static let shapeTable: [(open: String, close: String, shape: MermaidGraph.NodeShape)] = [
        ("((", "))", .circle),
        ("([", "])", .stadium),
        ("[(", ")]", .rounded),
        ("[[", "]]", .rectangle),
        ("[/", "/]", .rectangle),
        ("[\\", "\\]", .rectangle),
        ("{{", "}}", .diamond),
        ("[", "]", .rectangle),
        ("(", ")", .rounded),
        ("{", "}", .diamond),
        (">", "]", .rectangle),
    ]

    static func parseNode(_ segment: String) -> (MermaidGraph.Node, Bool)? {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var identifier = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            guard character.isLetter || character.isNumber || character == "_" || character == "-"
            else { break }
            identifier.append(character)
            index = trimmed.index(after: index)
        }
        guard !identifier.isEmpty, identifier.first?.isNumber == false || identifier.count > 0
        else { return nil }

        let remainder = String(trimmed[index...])
        guard !remainder.isEmpty else {
            return (MermaidGraph.Node(id: identifier, label: identifier, shape: .rectangle), false)
        }

        for entry in shapeTable where remainder.hasPrefix(entry.open) {
            // The label ends at the first matching close, not at the end of
            // the line. A real 7B wrote `homoSys[Homogeneous Systems]
            // HomoNonzero[and Nonzero Solutions]` on one line; reading to the
            // line's last `]` put half the next node inside this one's box.
            // Whatever trails the close is dropped.
            let start = remainder.index(remainder.startIndex, offsetBy: entry.open.count)
            guard let close = remainder.range(of: entry.close, range: start..<remainder.endIndex)
            else { continue }
            let label = cleanLabel(String(remainder[start..<close.lowerBound]))
            return (
                MermaidGraph.Node(
                    id: identifier, label: label.isEmpty ? identifier : label, shape: entry.shape
                ),
                true
            )
        }

        // An id with trailing punctuation we don't understand. Keep the
        // node; a diagram missing one box is far better than none.
        return (MermaidGraph.Node(id: identifier, label: identifier, shape: .rectangle), false)
    }

    static func cleanLabel(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        text = text
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#35;", with: "#")
            .replacingOccurrences(of: "&amp;", with: "&")
        text = text.trimmingCharacters(in: .whitespaces)
        if text.count > maximumLabelLength {
            text = String(text.prefix(maximumLabelLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }

    // MARK: - Mindmap

    /// Indentation is tracked with a stack rather than a column-to-depth
    /// map, so a model that indents two spaces in one place and four in
    /// another still produces the tree it meant. Multiple depth-0 nodes
    /// stay a forest: the parser has no business inventing a root the note
    /// didn't have.
    private static func parseMindmap(_ lines: [String]) -> MermaidGraph {
        var nodes: [MermaidGraph.Node] = []
        var edges: [MermaidGraph.Edge] = []
        var stack: [(indent: Int, id: String)] = []
        var skipped = 0
        var counter = 0

        for rawLine in lines {
            let expanded = rawLine.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = expanded.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if isDirective(trimmed) {
                continue
            }
            guard nodes.count < maximumNodes else { break }

            let indent = expanded.prefix { $0 == " " }.count
            guard let (label, shape) = parseMindmapNode(trimmed) else { skipped += 1; continue }

            counter += 1
            let id = "n\(counter)"

            while let top = stack.last, top.indent >= indent { stack.removeLast() }
            let depth = stack.count
            if let parent = stack.last, edges.count < maximumEdges {
                edges.append(MermaidGraph.Edge(
                    from: parent.id, to: id, label: nil, style: .open, ordinal: edges.count
                ))
            }
            nodes.append(MermaidGraph.Node(id: id, label: label, shape: shape, depth: depth))
            stack.append((indent: indent, id: id))
        }

        return MermaidGraph(
            kind: .mindmap, direction: .topDown,
            nodes: nodes, edges: edges, skippedLineCount: skipped
        )
    }

    /// A mindmap line is `root((Text))`, `id[Text]`, `id(Text)`, or just
    /// bare text -- which is the form a model reaches for most often.
    private static func parseMindmapNode(_ line: String) -> (String, MermaidGraph.NodeShape)? {
        for entry in shapeTable where line.contains(entry.open) && line.hasSuffix(entry.close) {
            guard let openRange = line.range(of: entry.open) else { continue }
            // Only `id(text)` -- a single word before the bracket -- is a
            // shaped node. "Gaussian elimination (row reduction)" is text
            // that happens to end in a parenthesis, and was cut down to
            // "row reduction".
            let before = line[..<openRange.lowerBound]
            guard !before.contains(where: \.isWhitespace) else { continue }
            let end = line.index(line.endIndex, offsetBy: -entry.close.count)
            guard openRange.upperBound <= end else { continue }
            let label = cleanLabel(String(line[openRange.upperBound..<end]))
            if !label.isEmpty { return (label, entry.shape) }
        }
        let label = cleanLabel(line)
        return label.isEmpty ? nil : (label, .rounded)
    }
}
