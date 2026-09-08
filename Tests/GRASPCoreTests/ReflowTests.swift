import Testing
@testable import GRASPCore

@Suite("Reflow")
struct ReflowTests {
    @Test("rejoins a sentence hard-wrapped across two lines")
    func rejoinsWrappedSentence() {
        // Real vault raw lines (Physical Geology 10.28.25.md): the visual
        // wrap breaks mid-sentence, with no blank line between the two
        // physical lines.
        let input = "Inner Planets: terrestrial planets (rocky\nplanets) = Mercury, Venus, Earth, Mars"
        let out = Reflow.reflow(input)
        #expect(out == "Inner Planets: terrestrial planets (rocky planets) = Mercury, Venus, Earth, Mars")
    }

    @Test("does not merge two independent bare-term lines")
    func doesNotMergeStructurallyDistinctLines() {
        // Regression fixture for the "bang" / "proto-Sun" garbage pairs
        // found before reflow was added: real sentence breaks (terminal
        // punctuation) must not be bridged.
        let input = "Gravity pulls gas and dust inward.\nDust and ice coalesce into disks."
        let out = Reflow.reflow(input)
        #expect(out.contains("inward.\nDust"))
    }

    @Test("strips literal 'undefined' artifact lines")
    func stripsUndefinedLines() {
        let input = "Sum = A XOR B\nCarry = A AND B\nundefined\n"
        let out = Reflow.reflow(input)
        #expect(!out.contains("undefined"))
    }

    @Test("preserves blank lines as paragraph breaks")
    func preservesBlankLines() {
        let input = "Term One\n\nTerm Two"
        let out = Reflow.reflow(input)
        #expect(out == "Term One\n\nTerm Two")
    }
}
