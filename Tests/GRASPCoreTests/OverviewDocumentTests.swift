import Testing
@testable import GRASPCore

/// The document is what survives in the database, so what's protected here
/// is that it round-trips exactly, encodes stably, and that merging several
/// chunks' worth of lesson never quietly drops or duplicates what a note
/// said.
@Suite("Overview document")
struct OverviewDocumentTests {

    private func section(
        _ heading: String, terms: [OverviewDefinition] = [], figure: OverviewFigure? = nil
    ) -> OverviewSection {
        OverviewSection(heading: heading, paragraphs: ["Explained."], terms: terms, figure: figure)
    }

    private func sample() -> OverviewDocument {
        OverviewDocument(
            title: "Row operations never move the answer",
            hook: "Why can we scribble all over a system of equations and still trust the result?",
            objectives: ["Perform the three row operations."],
            sections: [
                OverviewSection(
                    heading: "Swapping two equations cannot change the answer",
                    paragraphs: ["Try it with x + y = 3.", "Nothing about the facts changed."],
                    terms: [OverviewDefinition(term: "Interchange", text: "Swap two rows.")],
                    figure: OverviewFigure(
                        kind: .systemOfLines, caption: "Watch the crossing.",
                        equations: [[1, 1, 3], [1, -1, 1]],
                        steps: [RowOperation(kind: .replace, target: 2, source: 1, multiplier: -1)]
                    ),
                    check: OverviewCheck(question: "Why?", answer: "Because.")
                ),
            ],
            takeaways: ["Row operations preserve solutions."],
            formulas: [OverviewFormula(name: "Rate", latex: "\\frac{n}{t}", plain: "n/t")]
        )
    }

    @Test("round-trips through JSON unchanged, figures and optionals included")
    func roundTrip() throws {
        let original = sample()
        let decoded = try #require(OverviewCoding.decode(OverviewCoding.encode(original)))
        #expect(decoded == original)
    }

    @Test("encodes the same document to identical text every time")
    func stableEncoding() {
        let document = sample()
        #expect(OverviewCoding.encode(document) == OverviewCoding.encode(document))
    }

    @Test("decodes garbage to nil rather than throwing")
    func decodeFailure() {
        #expect(OverviewCoding.decode("not json") == nil)
        #expect(OverviewCoding.decode("") == nil)
        #expect(OverviewCoding.decode("{\"sections\": 5}") == nil)
    }

    @Test("counts a lesson with no sections as empty, whatever else it has")
    func emptiness() {
        // A title, a hook and some takeaways alone aren't a lesson -- there
        // is nothing there that teaches.
        let thin = OverviewDocument(title: "T", hook: "H", takeaways: ["A"])
        #expect(thin.isEmpty)
        #expect(OverviewDocument.empty.isEmpty)
        #expect(!OverviewDocument(sections: [section("A claim")]).isEmpty)
    }

    @Test("gathers every section's terms in reading order")
    func allTerms() {
        let document = OverviewDocument(sections: [
            section("One", terms: [OverviewDefinition(term: "A", text: "a")]),
            section("Two", terms: [OverviewDefinition(term: "B", text: "b")]),
        ])
        #expect(document.allTerms.map(\.term) == ["A", "B"])
    }

    // MARK: - Merge

    private func part(
        _ document: OverviewDocument
    ) -> (chunk: OverviewChunker.Chunk, document: OverviewDocument) {
        (OverviewChunker.Chunk(text: "", heading: nil, wordCount: 0), document)
    }

    private let lines = OverviewFigure(kind: .systemOfLines, equations: [[1, 1, 3], [1, -1, 1]])

    @Test("takes the title and hook from the chunk that saw the note's opening")
    func titleComesFromTheFirstChunk() {
        let merged = OverviewComposer.merge([
            part(OverviewDocument(title: "First", hook: "Hook one", sections: [section("A")])),
            part(OverviewDocument(title: "Second", hook: "Hook two", sections: [section("B")])),
        ])
        #expect(merged.title == "First")
        #expect(merged.hook == "Hook one")
    }

    @Test("concatenates sections across chunks in order")
    func sectionsConcatenate() {
        let merged = OverviewComposer.merge([
            part(OverviewDocument(sections: [section("A")])),
            part(OverviewDocument(sections: [section("B")])),
        ])
        #expect(merged.sections.map(\.heading) == ["A", "B"])
    }

    @Test("dedupes a section heading the model repeated across chunks")
    func dedupesSections() {
        let merged = OverviewComposer.merge([
            part(OverviewDocument(sections: [section("Row operations are safe")])),
            part(OverviewDocument(sections: [section("row operations are safe")])),
        ])
        #expect(merged.sections.count == 1)
    }

    @Test("keeps the first definition of a term that reappears in a later section")
    func firstDefinitionWins() {
        let merged = OverviewComposer.merge([
            part(OverviewDocument(sections: [
                section("A", terms: [OverviewDefinition(term: "Chromatid", text: "Introduced here.")]),
            ])),
            part(OverviewDocument(sections: [
                section("B", terms: [OverviewDefinition(term: "chromatid", text: "Mentioned again.")]),
            ])),
        ])
        #expect(merged.allTerms.count == 1)
        #expect(merged.allTerms.first?.text == "Introduced here.")
        // The section itself survives -- only the repeated term goes.
        #expect(merged.sections.count == 2)
    }

    @Test("caps figures across the whole lesson, not per chunk")
    func figureCapIsLessonWide() {
        let parts = (0..<3).map { index in
            part(OverviewDocument(sections: [
                section("Chunk \(index) first", figure: lines),
                section("Chunk \(index) second", figure: lines),
            ]))
        }
        let merged = OverviewComposer.merge(parts)
        #expect(merged.sections.count == 6)
        #expect(merged.sections.filter { $0.figure != nil }.count == OverviewLimits.figures)
    }

    @Test("caps every list so one chatty note can't flood the reader")
    func caps() {
        let flood = OverviewDocument(
            objectives: (0..<20).map { "Objective \($0)" },
            sections: (0..<20).map { section("Claim \($0)") },
            takeaways: (0..<20).map { "Takeaway \($0)" },
            formulas: (0..<40).map { OverviewFormula(name: "F\($0)", plain: "x") }
        )
        let merged = OverviewComposer.merge([part(flood)])
        #expect(merged.objectives.count == OverviewLimits.objectives)
        #expect(merged.sections.count == OverviewLimits.sections)
        #expect(merged.takeaways.count == OverviewLimits.takeaways)
        #expect(merged.formulas.count == OverviewLimits.formulas)
    }

    @Test("builds the diagram spine from the lesson's claims")
    func diagramSpine() {
        let spine = OverviewComposer.diagramSpine(of: sample())
        #expect(spine.contains("Row operations never move the answer"))
        #expect(spine.contains("Swapping two equations cannot change the answer"))
        #expect(spine.contains("Interchange"))
    }
}
