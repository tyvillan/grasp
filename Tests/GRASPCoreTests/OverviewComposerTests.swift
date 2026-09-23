import Testing
import Foundation
@testable import GRASPCore

/// Drives the whole per-note pipeline against a stub generator, so the call
/// *shape* is pinned without a model: how many times the note is summarised,
/// that the diagram is drawn exactly once over the merged result, and that
/// each piece is told which piece it is.
@Suite("Overview composer")
struct OverviewComposerTests {

    /// Records what it was asked, and answers with one takeaway per call so
    /// merging has something distinguishable to work with.
    private final class StubGenerator: CardGenerator, @unchecked Sendable {
        var overviewCalls: [(context: String, partLabel: String?, includeFormulas: Bool)] = []
        var diagramCalls: [String] = []
        var figureCalls: [(context: String, headings: [String])] = []
        var budget: Int
        var diagramAnswer: String
        var returnsEmpty: Bool
        var figureAnswer: [GeneratedFigure]

        init(budget: Int = 1_200, diagramAnswer: String = "graph TD\nA-->B",
             returnsEmpty: Bool = false, figureAnswer: [GeneratedFigure] = []) {
            self.budget = budget
            self.diagramAnswer = diagramAnswer
            self.returnsEmpty = returnsEmpty
            self.figureAnswer = figureAnswer
        }

        var isAvailable: Bool { get async { true } }
        var overviewContextWordBudget: Int { budget }

        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(
            existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?
        ) async -> [GeneratedCard] { [] }
        func generateTestQuestions(
            existing: [CandidatePair], noteContext: String, maxCount: Int
        ) async -> [GeneratedTestQuestion] { [] }
        func validateContext(
            front: String, back: String, noteContext: String, courseName: String
        ) async -> ContextValidation { ContextValidation(.valid) }

        func generateOverview(
            noteTitle: String, courseName: String, noteContext: String,
            includeFormulas: Bool, partLabel: String?
        ) async -> GeneratedOverview {
            overviewCalls.append((noteContext, partLabel, includeFormulas))
            guard !returnsEmpty else { return .empty }
            let index = overviewCalls.count
            return GeneratedOverview(document: OverviewDocument(
                title: "Title from call \(index)",
                sections: [
                    OverviewSection(
                        heading: "Claim \(index)a", paragraphs: ["Explained in call \(index)."],
                        terms: [OverviewDefinition(term: "Term \(index)", text: "Definition.")]
                    ),
                    OverviewSection(heading: "Claim \(index)b", paragraphs: ["More."]),
                ]
            ))
        }

        func generateDiagram(
            noteTitle: String, courseName: String, conceptOutline: String
        ) async -> String {
            diagramCalls.append(conceptOutline)
            return diagramAnswer
        }

        func generateFigures(
            noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]
        ) async -> [GeneratedFigure] {
            figureCalls.append((noteContext, sectionHeadings))
            return figureAnswer
        }
    }

    /// Real sentences, capitalised. The chunker only treats a full stop as
    /// a boundary when what follows could open a sentence, so lowercase
    /// filler would come back as one unsplittable block.
    private func note(words count: Int, hasMath: Bool = false) -> NoteText {
        let text = stride(from: 0, to: count, by: 10)
            .map { start -> String in
                let end = min(start + 10, count)
                let body = (start..<end).map { "word\($0)" }.joined(separator: " ")
                return body.prefix(1).uppercased() + body.dropFirst() + "."
            }
            .joined(separator: " ")
        return NoteText(
            materialId: "m1", raw: text, reflowed: text, wordCount: count, hasMath: hasMath
        )
    }

    /// The same filler, opening with a line about matrices -- the only kind
    /// of note the model is asked for figures on.
    private func matrixNote(words count: Int) -> NoteText {
        var base = note(words: count)
        let text = "Every matrix defines a linear transformation of the plane. " + base.reflowed
        base.raw = text
        base.reflowed = text
        return base
    }

    @Test("a short note costs one overview call and one diagram call")
    func shortNote() async {
        let generator = StubGenerator()
        let outcome = await OverviewComposer.compose(
            using: generator, noteTitle: "Lecture 1", courseName: "Biology", note: note(words: 800)
        )
        #expect(generator.overviewCalls.count == 1)
        #expect(generator.diagramCalls.count == 1)
        guard case .generated(let result) = outcome else {
            Issue.record("expected a generated overview")
            return
        }
        #expect(result.chunkCount == 1)
        #expect(result.mermaidSource == "graph TD\nA-->B")
    }

    @Test("accounts for every step of a long note, so the bar ends at the end")
    func progressCoversEveryStep() async {
        let generator = StubGenerator()
        let progress = AIProgress()
        _ = await AIProgress.$current.withValue(progress) {
            await OverviewComposer.compose(
                using: generator, noteTitle: "L", courseName: "Biology", note: note(words: 4_000)
            )
        }
        let snapshot = progress.snapshot
        // This stub reports nothing itself: each lesson counts as one step,
        // plus a figures step per piece and the diagram.
        #expect(snapshot.completed == generator.overviewCalls.count * 2 + 1)
        #expect(snapshot.completed == snapshot.expected)
        #expect(snapshot.step == "Drawing the concept map")
        #expect(snapshot.part == nil)
    }

    @Test("takes a generator's own section count over the assumed one")
    func progressUsesReportedSections() async {
        /// Reports the way OllamaGenerator does: a plan step, then three
        /// sections where five were assumed.
        final class ReportingGenerator: CardGenerator, @unchecked Sendable {
            let inner = StubGenerator()
            var isAvailable: Bool { get async { true } }
            func refine(_ c: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
            func distractors(for a: String, deckContext: [String], count: Int) async -> [String] { [] }
            func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
            func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
            func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation { ContextValidation(.valid) }
            func generateOverview(noteTitle: String, courseName: String, noteContext: String, includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview {
                AIProgress.current?.advance()
                AIProgress.current?.expect(3 - OverviewComposer.assumedSectionsPerPart)
                AIProgress.current?.advance(3)
                return await inner.generateOverview(noteTitle: noteTitle, courseName: courseName, noteContext: noteContext, includeFormulas: includeFormulas, partLabel: partLabel)
            }
            func generateDiagram(noteTitle: String, courseName: String, conceptOutline: String) async -> String { "graph TD\nA-->B" }
            func generateFigures(noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
        }
        let progress = AIProgress()
        _ = await AIProgress.$current.withValue(progress) {
            await OverviewComposer.compose(
                using: ReportingGenerator(), noteTitle: "L", courseName: "Biology", note: note(words: 800)
            )
        }
        // Plan + 3 sections + figures + diagram.
        #expect(progress.snapshot.completed == 6)
        #expect(progress.snapshot.expected == 6)
    }

    @Test("a single-chunk note is not told it is part of anything")
    func noPartLabelForOneChunk() async {
        let generator = StubGenerator()
        _ = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Biology", note: note(words: 800)
        )
        #expect(generator.overviewCalls.first?.partLabel == nil)
    }

    @Test("a long note is summarised in pieces but still drawn exactly once")
    func longNoteDrawsOneDiagram() async {
        let generator = StubGenerator()
        let outcome = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Biology", note: note(words: 4_000)
        )
        #expect(generator.overviewCalls.count > 1)
        // The reason `generateDiagram` is a separate protocol method: a
        // diagram per chunk would be N unrelated fragments.
        #expect(generator.diagramCalls.count == 1)
        guard case .generated(let result) = outcome else {
            Issue.record("expected a generated overview")
            return
        }
        #expect(result.chunkCount == generator.overviewCalls.count)
    }

    @Test("tells each piece of a long note which piece it is")
    func partLabels() async {
        let generator = StubGenerator()
        _ = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Biology", note: note(words: 4_000)
        )
        let labels = generator.overviewCalls.compactMap(\.partLabel)
        #expect(labels.count == generator.overviewCalls.count)
        #expect(labels.first == "part 1 of \(generator.overviewCalls.count)")
    }

    @Test("a smaller generator budget means more calls for the same note")
    func budgetDrivesCallCount() async {
        let large = StubGenerator(budget: 1_200)
        _ = await OverviewComposer.compose(
            using: large, noteTitle: "L", courseName: "Biology", note: note(words: 3_000)
        )
        let small = StubGenerator(budget: 500)
        _ = await OverviewComposer.compose(
            using: small, noteTitle: "L", courseName: "Biology", note: note(words: 3_000)
        )
        #expect(small.overviewCalls.count > large.overviewCalls.count)
    }

    @Test("only asks for formulas when the note is about math")
    func formulasFollowTheSubject() async {
        // LaTeX alone isn't math: a business lecture writing percentages
        // in it gets no formulas section.
        let latexOnly = StubGenerator()
        _ = await OverviewComposer.compose(
            using: latexOnly, noteTitle: "L", courseName: "Side Lectures",
            note: note(words: 800, hasMath: true)
        )
        #expect(latexOnly.overviewCalls.first?.includeFormulas == false)

        let math = StubGenerator()
        _ = await OverviewComposer.compose(
            using: math, noteTitle: "L", courseName: "Matrix Theory", note: matrixNote(words: 800)
        )
        #expect(math.overviewCalls.first?.includeFormulas == true)
    }

    @Test("draws the diagram from the merged summary, not the raw note")
    func diagramSeesTheSummary() async {
        let generator = StubGenerator()
        _ = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Biology", note: note(words: 800)
        )
        let spine = try! #require(generator.diagramCalls.first)
        #expect(spine.contains("Claim 1a"))
        // Headings only: given paragraphs too, a real 7B pasted them into
        // the concept map's boxes whole.
        #expect(!spine.contains("Explained in call 1."))
        #expect(!spine.contains("word0 word1"))
    }

    @Test("reports a model that had nothing to say as empty, not as a document")
    func emptyModelOutput() async {
        let generator = StubGenerator(returnsEmpty: true)
        let outcome = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Biology", note: note(words: 800)
        )
        #expect(outcome == .empty)
        // Nothing to draw, so the diagram call never happens.
        #expect(generator.diagramCalls.isEmpty)
    }

    @Test("stores no diagram when the model declines to draw one")
    func declinedDiagram() async {
        let generator = StubGenerator(diagramAnswer: "")
        let outcome = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Biology", note: note(words: 800)
        )
        guard case .generated(let result) = outcome else {
            Issue.record("expected a generated overview")
            return
        }
        // nil, not "" -- the view's "no diagram" state keys off absence.
        #expect(result.mermaidSource == nil)
    }

    @Test("passes the chunker's verdict straight through for a note it won't touch")
    func gatesAreReported() async {
        let generator = StubGenerator()
        let short = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Biology", note: note(words: 40)
        )
        #expect(short == .tooShort(wordCount: 40))
        #expect(generator.overviewCalls.isEmpty)

        let long = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Biology", note: note(words: 20_000)
        )
        if case .tooLong = long {} else { Issue.record("expected tooLong") }
    }

    @Test("a generator with no model produces nothing to persist")
    func noGeneratorProducesNothing() async {
        let outcome = await OverviewComposer.compose(
            using: NoGenerator(), noteTitle: "L", courseName: "Biology", note: note(words: 800)
        )
        #expect(outcome == .empty)
    }

    // MARK: - Figures

    @Test("asks for figures against each chunk's own text and headings")
    func figuresAreAskedPerChunk() async {
        let generator = StubGenerator()
        _ = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Math", note: matrixNote(words: 800)
        )
        #expect(generator.figureCalls.count == 1)
        #expect(generator.figureCalls.first?.headings == ["Claim 1a", "Claim 1b"])
    }

    @Test("puts a proposed figure beside the section it names")
    func figureLandsInItsSection() async {
        // Entries of 0 and 1 only, which count as grounded in any note --
        // they're routinely implicit, so the grounding check exempts them.
        let figure = OverviewFigure(kind: .linearTransform, matrix: [[1, 1], [0, 1]])
        let generator = StubGenerator(figureAnswer: [GeneratedFigure(sectionIndex: 1, figure: figure)])
        let outcome = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Math", note: matrixNote(words: 800)
        )
        guard case .generated(let result) = outcome else {
            Issue.record("expected a generated overview")
            return
        }
        #expect(result.document.sections[0].figure == nil)
        #expect(result.document.sections[1].figure == figure)
    }

    @Test("doesn't ask for figures at all on a note with no math to draw")
    func noFiguresCallWithoutMath() async {
        let generator = StubGenerator()
        _ = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Side Lectures", note: note(words: 800)
        )
        #expect(generator.figureCalls.isEmpty)
    }

    @Test("rejects a figure of a kind the note can't support, even with grounded numbers")
    func rejectsUnsupportedFigureKind() async {
        // Verbatim from a real run on a lecture about AI agents: "4.5
        // minutes vs. 300 minutes" read as x = 4.5, 300y = 300. Every number
        // is in the note; the note has no system of equations.
        let bogus = OverviewFigure(kind: .systemOfLines, equations: [[1, 0, 4.5], [0, 300, 300]])
        let generator = StubGenerator(figureAnswer: [GeneratedFigure(sectionIndex: 0, figure: bogus)])
        var workshop = matrixNote(words: 800)
        workshop.reflowed += " AI completes in 4.5 minutes vs. 300 minutes for a person."
        let outcome = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Side Lectures", note: workshop
        )
        guard case .generated(let result) = outcome else {
            Issue.record("expected a generated overview")
            return
        }
        #expect(result.document.sections.allSatisfy { $0.figure == nil })
    }

    @Test("ignores a figure pointing at a section that doesn't exist")
    func outOfRangeFigureIsIgnored() async {
        let figure = OverviewFigure(kind: .systemOfLines, equations: [[1, 1, 3], [1, -1, 1]])
        let generator = StubGenerator(figureAnswer: [GeneratedFigure(sectionIndex: 9, figure: figure)])
        let outcome = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Math", note: note(words: 800)
        )
        guard case .generated(let result) = outcome else {
            Issue.record("expected a generated overview")
            return
        }
        #expect(result.document.sections.allSatisfy { $0.figure == nil })
    }

    @Test("doesn't ask for figures when the lesson came back empty")
    func noFiguresForAnEmptyLesson() async {
        let generator = StubGenerator(returnsEmpty: true)
        _ = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Math", note: note(words: 800)
        )
        #expect(generator.figureCalls.isEmpty)
    }

    @Test("rejects a proposed figure whose numbers aren't in the note")
    func ungroundedFigureIsRejected() async {
        let invented = OverviewFigure(kind: .linearTransform, matrix: [[7, 3], [2, 9]])
        let generator = StubGenerator(figureAnswer: [GeneratedFigure(sectionIndex: 0, figure: invented)])
        let outcome = await OverviewComposer.compose(
            using: generator, noteTitle: "L", courseName: "Math", note: note(words: 800)
        )
        guard case .generated(let result) = outcome else {
            Issue.record("expected a generated overview")
            return
        }
        #expect(result.document.sections.allSatisfy { $0.figure == nil })
    }

    @Test("builds the main figure from the note's own system, row-reduced")
    func extractedSystemBecomesTheFigure() {
        var document = OverviewDocument(sections: [
            OverviewSection(heading: "Two lines cross at the solution", paragraphs: ["Lines."]),
            OverviewSection(heading: "Row operations never move the answer", paragraphs: ["Ops."]),
        ])
        let note = "Written as a matrix:\n[ 1  5 | 7 ]\n[ 2  1 | 5 ]\nThen row-reduce."
        let placed = OverviewComposer.attachExtractedFigures(to: &document, noteText: note)
        #expect(placed)
        #expect(document.sections[0].figure == nil)
        let figure = try! #require(document.sections[1].figure)
        #expect(figure.equations == [[1, 5, 7], [2, 1, 5]])
        #expect(figure.steps?.count == 3)
    }

    @Test("puts a no-solution system only beside a section headed about it")
    func parallelFigurePlacement() {
        var document = OverviewDocument(sections: [
            OverviewSection(heading: "Row operations never move the answer", paragraphs: ["No solution here too."]),
            OverviewSection(heading: "Some systems have no solution at all", paragraphs: ["Parallel."]),
        ])
        let note = "[ 1  5 | 7 ]\n[ 2  1 | 5 ]\nAlso x + y = 1 and x + y = 5 can never both hold."
        OverviewComposer.attachExtractedFigures(to: &document, noteText: note)
        #expect(document.sections[1].figure?.equations == [[1, 1, 1], [1, 1, 5]])
    }

    @Test("splits a paragraph that ran long into short ones, keeping every sentence")
    func splitsLongParagraphs() {
        let long = (1...7).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let pieces = OverviewComposer.splitLongParagraph(long)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { OverviewChunker.sentences(of: $0).count <= OverviewComposer.maximumSentencesPerParagraph })
        #expect(pieces.joined(separator: " ") == long)
    }

    @Test("corrects a wrong stated solution in a section's prose and its check")
    func tidiedCorrectsArithmetic() {
        let section = OverviewSection(
            heading: "A claim",
            paragraphs: ["The lines x + 2y = 7 and x + y = 6 intersect at x = 3, y = 3."],
            check: OverviewCheck(
                question: "Where do x + 5y = 7 and 2x + y = 5 cross?",
                answer: "At (x, y) = (1, 1)."
            )
        )
        let tidied = OverviewComposer.tidied(section)
        #expect(tidied.paragraphs.first?.contains("x = 5, y = 1") == true)
        #expect(tidied.check?.answer.contains("(x, y) = (2, 1)") == true)
        #expect(tidied.check?.question == "Where do x + 5y = 7 and 2x + y = 5 cross?")
    }

    /// A generator whose every call takes a long time, the way a 9B model's
    /// section calls do -- but honours cancellation, as URLSession does.
    private final class SlowGenerator: CardGenerator, @unchecked Sendable {
        var calls = 0
        var isAvailable: Bool { get async { true } }
        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
        func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
        func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation { ContextValidation(.valid) }
        func generateOverview(noteTitle: String, courseName: String, noteContext: String, includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview {
            calls += 1
            try? await Task.sleep(for: .seconds(30))
            return GeneratedOverview(document: OverviewDocument(
                sections: [OverviewSection(heading: "A claim here", paragraphs: ["Text."])]
            ))
        }
        func generateDiagram(noteTitle: String, courseName: String, conceptOutline: String) async -> String {
            calls += 1
            try? await Task.sleep(for: .seconds(30))
            return ""
        }
        func generateFigures(noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]) async -> [GeneratedFigure] {
            calls += 1
            try? await Task.sleep(for: .seconds(30))
            return []
        }
    }

    @Test("stops promptly when cancelled, without making the remaining calls")
    func cancellationStopsPromptly() async {
        let generator = SlowGenerator()
        let note = note(words: 4_000)   // several chunks: many calls queued up
        let task = Task { await OverviewComposer.compose(using: generator, noteTitle: "L", courseName: "C", note: note) }
        try? await Task.sleep(for: .milliseconds(200))
        let cancelledAt = Date()
        task.cancel()
        let outcome = await task.value
        #expect(Date().timeIntervalSince(cancelledAt) < 2)
        #expect(outcome == .empty)
        // The call in flight when Stop was pressed, and nothing after it.
        // At most one rather than exactly one: on a loaded machine the
        // first call may not have started by the time Stop is pressed.
        #expect(generator.calls <= 1)
    }
}
