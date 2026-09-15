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

    @Test("rejects a definition that opens on a dangling pronoun")
    func rejectsDanglingPronounBack() {
        let pairs = PairParser.parse(
            "- **Polymorphism** - It also lets a subclass override its parent's behavior at runtime."
        )
        #expect(pairs.isEmpty)
    }

    @Test("rejects a definition that opens on a referential demonstrative")
    func rejectsReferentialDemonstrativeBack() {
        let pairs = PairParser.parse(
            "- **Encapsulation** - This is the process by which internal state is hidden from callers."
        )
        #expect(pairs.isEmpty)
    }

    @Test("keeps a definition where a demonstrative is followed by a noun, not a verb")
    func keepsDemonstrativeFollowedByNoun() {
        let pairs = PairParser.parse(
            "- **Observer pattern** - This pattern decouples the publisher from anything listening to it."
        )
        #expect(pairs.contains { $0.front == "Observer pattern" })
    }

    @Test("rejects a definition that is really submission/logistics instructions")
    func rejectsAssignmentMetaText() {
        let pairs = PairParser.parse(
            "- **Final Project** - Submit your answer as a PDF by Friday at midnight through Gradescope."
        )
        #expect(pairs.isEmpty)
    }

    @Test("rejects a definition referencing a rubric or a page/points count")
    func rejectsRubricAndPageReference() {
        let a = PairParser.parse("- **Essay Grading** - See rubric on page 3 for the full grading breakdown.")
        let b = PairParser.parse("- **Late Work** - Late submissions lose 10 points per day, up to 3 days.")
        #expect(a.isEmpty)
        #expect(b.isEmpty)
    }

    @Test("keeps a real definition that happens to mention a course tool in passing")
    func keepsRealDefinitionNotJustLogistics() {
        // A genuine conceptual definition shouldn't be caught just because
        // the word "grade" or "submit" appears in an unrelated sense --
        // this one has neither, it's here to confirm the keyword gate
        // isn't so broad it rejects ordinary CS vocabulary.
        let pairs = PairParser.parse(
            "- **Encapsulation** - Bundling data with the methods that operate on it, hiding internal state from outside callers."
        )
        #expect(pairs.contains { $0.front == "Encapsulation" })
    }

    @Test("a bare-term line whose term is a section locator produces no card")
    func rejectsBareTermLocator() {
        let pairs = PairParser.parse("Week 3\nRead the assigned chapter before class starts on Thursday morning")
        #expect(pairs.isEmpty)
    }

    @Test("strips markdown embedded in a bare-term line's front")
    func stripsMarkdownFromBareTermPair() {
        // The line itself must still satisfy isBareTermLine's raw checks
        // (starts with an uppercase letter, no trailing punctuation) --
        // this is inline emphasis on part of the term, not the whole line
        // wrapped in "**", which wouldn't match the bare-term shape at all.
        let pairs = PairParser.parse(
            "Client **Server** Model\nThe architecture where one program requests data and another provides it over a network"
        )
        let pair = pairs.first { $0.front.contains("Server") }
        #expect(pair?.front == "Client Server Model")
        #expect(pair?.back.contains("*") == false)
    }
}
