import Testing
@testable import GRASPCore

@Suite("PairParser")
struct PairParserTests {
    @Test("extracts a bare-term definition pair")
    func extractsBareTermPair() {
        let text = "Permeability\nThe ability of a material to transmit fluids through pore spaces and fractures"
        let pairs = PairParser.parse(text)
        #expect(pairs.contains { $0.front == "Permeability" && $0.back.contains("pore spaces") })
    }

    @Test("extracts an inline 'Term: definition' pair after reflow")
    func extractsInlineColonPairAfterReflow() {
        // Real vault raw lines (Physical Geology 10.28.25.md), wrapped
        // mid-sentence -- reflow must rejoin before the colon shape matches.
        let raw = "Inner Planets: terrestrial planets (rocky\nplanets) = Mercury, Venus, Earth, Mars"
        let pairs = PairParser.parse(Reflow.reflow(raw))
        #expect(pairs.contains { $0.front == "Inner Planets" && $0.back.contains("Mercury") })
    }

    @Test("does not treat a heading as a term")
    func ignoresHeadings() {
        let pairs = PairParser.parse("# Physical Geology 10/28/25\n\nSome real term\nA definition that is long enough to count as real content here")
        #expect(!pairs.contains { $0.front.hasPrefix("#") })
    }

    @Test("does not pair a short line with a short following line")
    func rejectsShortDefinitions() {
        let pairs = PairParser.parse("Term\nToo short")
        #expect(pairs.isEmpty)
    }
}
