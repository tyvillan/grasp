import Foundation

/// Runs one note all the way from its stored text to a finished overview:
/// cut it to size, summarise each piece, merge the pieces deterministically,
/// then draw one diagram over the merged result.
///
/// The merge is plain Swift, not a second model call. Asking a 7B to merge
/// four summaries costs another 20-60 seconds and introduces a fresh chance
/// to invent something the note never said, to do work that dedupe and
/// concatenation already do exactly right.
public enum OverviewComposer {
    public struct Result: Sendable, Equatable {
        public let document: OverviewDocument
        /// nil when the model declined to draw one, which is the ordinary
        /// outcome for a note that's a flat list of unrelated definitions.
        public let mermaidSource: String?
        public let chunkCount: Int
    }

    public enum Outcome: Sendable, Equatable {
        case generated(Result)
        /// Structurally not applicable -- too short or too long to be worth
        /// an overview. Distinct from `.empty`, which means the model ran.
        case tooShort(wordCount: Int)
        case tooLong(wordCount: Int)
        /// The model ran and had nothing usable to say.
        case empty
    }

    public static func compose(
        using generator: any CardGenerator,
        noteTitle: String,
        courseName: String,
        note: NoteText
    ) async -> Outcome {
        let plan = OverviewChunker.plan(
            reflowed: note.reflowed,
            wordCount: note.wordCount,
            hasMath: note.hasMath,
            wordBudget: generator.overviewContextWordBudget
        )

        let chunks: [OverviewChunker.Chunk]
        switch plan {
        case .tooShort(let wordCount): return .tooShort(wordCount: wordCount)
        case .tooLong(let wordCount): return .tooLong(wordCount: wordCount)
        case .chunks(let value): chunks = value
        }
        guard !chunks.isEmpty else { return .empty }

        // Per piece: the lesson (a plan call plus one call per section, the
        // section count assumed until the plan says otherwise) and the
        // figures call. Then one diagram for the whole note.
        let progress = AIProgress.current
        let lessonSteps = 1 + assumedSectionsPerPart
        progress?.expect(chunks.count * (lessonSteps + 1) + 1)

        var parts: [(chunk: OverviewChunker.Chunk, document: OverviewDocument)] = []
        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { return .empty }
            // Only labelled when there's actually more than one piece --
            // telling a model it's reading "part 1 of 1" invites it to
            // hedge about content it can already see all of.
            let partLabel = chunks.count > 1 ? "part \(index + 1) of \(chunks.count)" : nil
            progress?.setPart(chunks.count > 1 ? "Part \(index + 1) of \(chunks.count)" : nil)
            progress?.begin("Planning the lesson")
            let stepsBefore = progress?.snapshot.completed ?? 0
            let generated = await generator.generateOverview(
                noteTitle: noteTitle,
                courseName: courseName,
                noteContext: chunk.text,
                // Asked for only when the note is about math. `hasMath` means
                // the note contains LaTeX, which a business lecture writing
                // \(88\%\) does too -- and a model asked for formulas in a
                // lecture with none sometimes answered with a formula object
                // in place of the whole lesson plan.
                includeFormulas: NoteMath.isMathematical(chunk.text),
                partLabel: partLabel
            )
            // A generator that reports its own calls has already corrected
            // the estimate. One that doesn't made a single call as far as
            // the bar is concerned.
            if let progress, progress.snapshot.completed == stepsBefore {
                progress.expect(1 - lessonSteps)
                progress.advance()
            }
            var document = generated.document
            document.sections = document.sections.map(tidied)

            // Figures are asked for per chunk, against that chunk's own text
            // and headings: the coefficients a figure needs are in the note
            // itself, and only the chunk that contains them can copy them
            // out. Skipped when the lesson came back empty -- there'd be no
            // section to put a figure beside.
            if !document.sections.isEmpty, !Task.isCancelled {
                let extracted = attachExtractedFigures(to: &document, noteText: chunk.text)
                // Only the model can propose a transformation; the note's own
                // system is read out directly above. So the call is only
                // worth making when the note talks about matrices -- which
                // for most lectures in most courses it doesn't, and that's a
                // whole model call saved per piece.
                let supported = NoteMath.supportedFigureKinds(in: chunk.text)
                var figures: [GeneratedFigure] = []
                if supported.contains(.linearTransform) {
                    progress?.begin("Finding figures in the note")
                    figures = await generator.generateFigures(
                        noteTitle: noteTitle,
                        courseName: courseName,
                        noteContext: chunk.text,
                        sectionHeadings: document.sections.map(\.heading)
                    )
                }
                for proposed in figures where document.sections.indices.contains(proposed.sectionIndex) {
                    guard document.sections[proposed.sectionIndex].figure == nil,
                          supported.contains(proposed.figure.kind),
                          // The note's own system beats any system a model
                          // proposes -- the model tends to grab the first
                          // example it sees rather than the one the lecture
                          // was built around.
                          !(proposed.figure.kind == .systemOfLines && extracted),
                          // Every number has to actually be in the note. A
                          // model-invented example drawn beside the
                          // student's own notes is worse than no figure.
                          NoteMath.isGrounded(proposed.figure, in: chunk.text)
                    else { continue }
                    var figure = proposed.figure
                    if figure.kind == .systemOfLines, (figure.steps ?? []).isEmpty,
                       let system = LinearSystem2(rows: figure.equations ?? []) {
                        figure.steps = system.gaussJordanSteps()
                    }
                    document.sections[proposed.sectionIndex].figure = figure
                }
            }
            // Counted whether or not the call ran, so a skipped one doesn't
            // leave the bar short of the end.
            progress?.advance()
            parts.append((chunk: chunk, document: document))
        }

        let merged = merge(parts)
        guard !merged.isEmpty, !Task.isCancelled else { return .empty }

        // Exactly one diagram call, over the merged result. A diagram per
        // chunk would be N unrelated fragments with no way to join them.
        let outline = diagramSpine(of: merged)
        progress?.setPart(nil)
        progress?.begin("Drawing the concept map")
        let source = await generator.generateDiagram(
            noteTitle: noteTitle, courseName: courseName, conceptOutline: outline
        )
        progress?.advance()
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        return .generated(Result(
            document: merged,
            mermaidSource: trimmed.isEmpty ? nil : trimmed,
            chunkCount: chunks.count
        ))
    }

    /// How many sections the progress estimate assumes a lesson plan will
    /// have, until the plan comes back and says. Plans are asked for four or
    /// five, and five keeps the bar from overshooting.
    public static let assumedSectionsPerPart = 5

    // MARK: - Tidying a model's section

    /// Past this many sentences a paragraph is split. Asked for two or three
    /// short paragraphs, a real 7B wrote one paragraph of seven sentences
    /// -- the wall-of-text look this lesson layout exists to avoid.
    static let maximumSentencesPerParagraph = 4

    /// Corrects stated solutions the model got wrong, and breaks up
    /// paragraphs that ran long. Neither changes what the section says;
    /// both change whether it can be trusted and read.
    static func tidied(_ section: OverviewSection) -> OverviewSection {
        var section = section
        section.paragraphs = section.paragraphs
            .map(NoteMath.correctingSolutions)
            .flatMap(splitLongParagraph)
        if let check = section.check {
            // The system is usually stated in the question and solved in
            // the answer, so they're checked together and split back apart.
            let separator = "\n\u{1E}\n"
            let combined = NoteMath.correctingSolutions(in: check.question + separator + check.answer)
            if let range = combined.range(of: separator) {
                section.check = OverviewCheck(
                    question: String(combined[..<range.lowerBound]),
                    answer: String(combined[range.upperBound...])
                )
            }
        }
        return section
    }

    static func splitLongParagraph(_ paragraph: String) -> [String] {
        let sentences = OverviewChunker.sentences(of: paragraph)
        guard sentences.count > maximumSentencesPerParagraph else { return [paragraph] }
        // Even groups of about three, so the split doesn't leave a lonely
        // one-sentence paragraph dangling at the end.
        let groups = Int((Double(sentences.count) / 3).rounded(.up))
        let size = Int((Double(sentences.count) / Double(groups)).rounded(.up))
        return stride(from: 0, to: sentences.count, by: size).map {
            sentences[$0..<min($0 + size, sentences.count)].joined(separator: " ")
        }
    }

    // MARK: - Figures from the note itself

    /// Builds figures straight from the math in the note, with no model:
    /// the lecture's main system, row-reduced by ordinary Gauss-Jordan
    /// elimination, beside the section that teaches row operations; and,
    /// if the note also has a system with no single solution, that one as a
    /// still picture beside the section about consistency -- parallel lines
    /// that never meet are the clearest possible picture of "no solution".
    /// Returns whether the main figure was placed.
    @discardableResult
    static func attachExtractedFigures(to document: inout OverviewDocument, noteText: String) -> Bool {
        guard !document.sections.isEmpty, let primary = NoteMath.primarySystem(in: noteText) else {
            return false
        }
        let main = bestSection(
            in: document.sections,
            preferring: ["row operation", "row reduc", "elimination", "augmented", "replacement",
                         "echelon", "gaussian", "reduce"],
            thenMatching: ["solution", "solve", "intersect", "cross", "line", "system"]
        )
        document.sections[main].figure = OverviewFigure(
            kind: .systemOfLines,
            caption: primary.solution == nil
                ? "The system from your notes. Row reduction shows why it has no single solution."
                : "The system from your notes. Each row operation changes the equations, never the solution.",
            equations: primary.rows,
            steps: primary.gaussJordanSteps()
        )

        if let parallel = NoteMath.systems(in: noteText)
            .first(where: { $0.system.solution == nil && $0.system != primary })?.system {
            // Placed only beside a section whose *heading* is about there
            // being no solution. Matching the prose too put it beside a
            // row-operations section that merely mentioned the case in
            // passing, where a picture of two parallel lines just confused.
            let words = ["inconsistent", "no solution", "parallel", "never meet", "consistent",
                         "never cross", "no answer"]
            let target = document.sections.firstIndex { section in
                let heading = section.heading.lowercased()
                return words.contains { heading.contains($0) }
            }
            if let target, target != main, document.sections[target].figure == nil {
                document.sections[target].figure = OverviewFigure(
                    kind: .systemOfLines,
                    caption: "Two parallel lines from your notes: they never cross, so there's no solution.",
                    equations: parallel.rows,
                    steps: []
                )
            }
        }
        return true
    }

    /// The section that most mentions the first set of words, else the
    /// second, else the first section. Deterministic and cheap, and good
    /// enough: a figure only needs to sit beside the idea it illustrates,
    /// and a lesson's section about row operations reliably says so.
    static func bestSection(
        in sections: [OverviewSection], preferring primary: [String], thenMatching secondary: [String]
    ) -> Int {
        func score(_ section: OverviewSection, _ words: [String]) -> Int {
            let text = sectionText(section)
            return words.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
        }
        for words in [primary, secondary] where !words.isEmpty {
            let scores = sections.map { score($0, words) }
            if let best = scores.max(), best > 0, let index = scores.firstIndex(of: best) {
                return index
            }
        }
        return 0
    }

    private static func sectionText(_ section: OverviewSection) -> String {
        ([section.heading] + section.paragraphs + section.terms.map(\.term))
            .joined(separator: " ")
            .lowercased()
    }

    // MARK: - Merge

    /// Concatenate in chunk order, dedupe, cap. A single chunk takes the
    /// same path as several so there's no second code path to keep in step.
    static func merge(
        _ parts: [(chunk: OverviewChunker.Chunk, document: OverviewDocument)]
    ) -> OverviewDocument {
        var title: String?
        var hook: String?
        var objectives: [String] = []
        var seenObjectives: Set<String> = []
        var sections: [OverviewSection] = []
        var seenHeadings: Set<String> = []
        var seenTerms: Set<String> = []
        var takeaways: [String] = []
        var seenTakeaways: Set<String> = []
        var formulas: [OverviewFormula] = []
        var seenFormulas: Set<String> = []
        var figureCount = 0

        for part in parts {
            // The first chunk saw the note's opening, which is where a
            // lecture sets up the question it answers.
            if title == nil { title = part.document.title }
            if hook == nil { hook = part.document.hook }

            for objective in part.document.objectives {
                let key = AnswerGrading.normalize(objective)
                guard !key.isEmpty, seenObjectives.insert(key).inserted else { continue }
                objectives.append(objective)
            }
            for var section in part.document.sections {
                let key = AnswerGrading.normalize(section.heading)
                guard !key.isEmpty, seenHeadings.insert(key).inserted else { continue }
                // First definition of a repeated term wins: a term is best
                // defined where it's introduced, and a later chunk
                // mentioning it again is normally using it, not defining it.
                section.terms = section.terms.filter {
                    let termKey = AnswerGrading.normalize($0.term)
                    return !termKey.isEmpty && seenTerms.insert(termKey).inserted
                }
                // The figure cap is across the whole lesson, not per chunk,
                // or a long note would come back as a slideshow.
                if section.figure != nil {
                    if figureCount >= OverviewLimits.figures {
                        section.figure = nil
                    } else {
                        figureCount += 1
                    }
                }
                sections.append(section)
            }
            for takeaway in part.document.takeaways {
                let key = AnswerGrading.normalize(takeaway)
                guard !key.isEmpty, seenTakeaways.insert(key).inserted else { continue }
                takeaways.append(takeaway)
            }
            for formula in part.document.formulas {
                let key = AnswerGrading.normalize(formula.name)
                guard !key.isEmpty, seenFormulas.insert(key).inserted else { continue }
                formulas.append(formula)
            }
        }

        return OverviewDocument(
            title: title,
            hook: hook,
            objectives: Array(objectives.prefix(OverviewLimits.objectives)),
            sections: Array(sections.prefix(OverviewLimits.sections)),
            takeaways: Array(takeaways.prefix(OverviewLimits.takeaways)),
            formulas: Array(formulas.prefix(OverviewLimits.formulas))
        )
    }

    /// What the diagram pass draws from: the lesson's claims, in order, and
    /// the terms they introduce. The headings are already the insights
    /// stated as sentences, which is exactly what belongs in a concept
    /// map's boxes -- far easier to draw from than raw lecture text.
    public static func diagramSpine(of document: OverviewDocument) -> String {
        var lines: [String] = []
        if let title = document.title {
            lines.append("Lesson: \(title)")
            lines.append("")
        }
        // Headings only, no prose. Given each section's first paragraph as
        // well, a real 7B pasted those paragraphs into the boxes whole.
        if !document.sections.isEmpty {
            lines.append("Ideas, in order:")
            for section in document.sections {
                lines.append("- \(section.heading)")
            }
        }
        let terms = document.allTerms
        if !terms.isEmpty {
            lines.append("")
            lines.append("Terms:")
            lines += terms.prefix(12).map { "- \($0.term)" }
        }
        return lines.joined(separator: "\n")
    }
}
