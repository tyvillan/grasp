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
        note original: NoteText
    ) async -> Outcome {
        let note = freshlyReflowed(original)
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
            document.sections = document.sections.map { groundedExample(in: tidied($0), noteText: chunk.text) }

            // The second pass: each section checked against the note, and
            // anything the note contradicts corrected or removed. A 9B model
            // writing about a lecture got real statements wrong -- which
            // swap makes a reflection, what "one-to-one" means -- and a
            // study tool must not teach those with confidence.
            if !document.sections.isEmpty {
                progress?.expect(document.sections.count)
                for index in document.sections.indices {
                    if Task.isCancelled { return .empty }
                    progress?.begin("Checking section \(index + 1) of \(document.sections.count)")
                    let fixes = await generator.reviewSection(noteContext: chunk.text, section: document.sections[index])
                    document.sections[index] = OverviewReview.apply(fixes, to: document.sections[index])
                    progress?.advance()
                }
                document.sections = document.sections.filter { !$0.paragraphs.isEmpty }
            }

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
                // A row-reduction figure *is* the worked example, with exact
                // arithmetic. Any example the model wrote that pushes matrix
                // rows around -- beside the figure or elsewhere in the lesson
                // -- repeats it less reliably: on a real lecture one such
                // example "swapped R3 with a zero row" that didn't exist.
                if document.sections.contains(where: { $0.figure?.kind == .rowReduction }) {
                    for index in document.sections.indices {
                        if document.sections[index].figure?.kind == .rowReduction
                            || document.sections[index].example.map(manipulatesMatrixRows) == true {
                            document.sections[index].example = nil
                        }
                    }
                }
            }
            // Counted whether or not the call ran, so a skipped one doesn't
            // leave the bar short of the end.
            progress?.advance()
            parts.append((chunk: chunk, document: document))
        }

        var merged = merge(parts)
        guard !merged.isEmpty, !Task.isCancelled else { return .empty }

        // Once over the whole lesson: sections and takeaways that repeat an
        // earlier one. Only a model can tell -- measured on real lessons, two
        // sections teaching the same idea shared no more words than two that
        // merely shared a topic.
        if merged.sections.count > 2 {
            progress?.expect(1)
            progress?.begin("Removing repetition")
            merged = OverviewReview.apply(await generator.findRepetition(in: merged), to: merged)
            progress?.advance()
        }
        merged = OverviewReview.cleaned(merged, noteText: note.reflowed)

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

    /// The note's text reflowed now, from its raw body, rather than as it
    /// was stored at import. Reflow has improved since some notes were
    /// imported -- code blocks used to be joined into one line, which is
    /// what the model then read -- and a rewrite should see the note as
    /// this build reads it.
    static func freshlyReflowed(_ note: NoteText) -> NoteText {
        guard !note.raw.isEmpty else { return note }
        let body = TextCleaning.extractDateLine(TextCleaning.clean(note.raw)).1
        var fresh = note
        fresh.reflowed = Reflow.reflow(body)
        return fresh
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
        guard !document.sections.isEmpty else { return false }
        attachRowReductions(to: &document, noteText: noteText)
        guard let primary = NoteMath.primarySystem(in: noteText) else { return false }
        let main = bestSection(
            in: document.sections,
            preferring: ["row operation", "row reduc", "elimination", "augmented", "replacement",
                         "echelon", "gaussian", "reduce"],
            thenMatching: ["solution", "solve", "intersect", "cross", "line", "system"]
        )
        // A row-reduction walkthrough already there is the note's bigger
        // example; the lines go beside it only if nothing else fits.
        guard document.sections[main].figure == nil else { return false }
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

    /// The matrices the note works through, row-reduced one step at a time
    /// beside the sections that teach the method. The note's own example
    /// -- its operations, checked against the result it wrote -- goes
    /// first; a second walkthrough only lands beside a different section
    /// that's about row reduction too, never as filler.
    static func attachRowReductions(to document: inout OverviewDocument, noteText: String) {
        let walkthroughs = NoteMatrices.walkthroughs(in: noteText)
        guard !walkthroughs.isEmpty else { return }
        let words = ["row reduc", "echelon", "pivot", "elimination", "row operation", "worked",
                     "free variable", "basic variable", "reduce", "augmented", "replacement", "gauss"]
        var used: Set<Int> = []
        for (rank, walkthrough) in walkthroughs.prefix(2).enumerated() {
            let scores = document.sections.map { section -> Int in
                let text = sectionText(section)
                // A section that names this example's own operations is the
                // one teaching it -- far stronger evidence than vocabulary,
                // which every section of a row-reduction lecture shares.
                let full = fullText(section)
                let named = NoteMatrices.operations(in: full).filter { walkthrough.steps.contains($0.operation) }.count
                return words.reduce(0) { $0 + (text.contains($1) ? 1 : 0) } + named * 5
            }
            let candidates = document.sections.indices.filter {
                !used.contains($0) && document.sections[$0].figure == nil
            }
            guard let best = candidates.max(by: { scores[$0] != scores[$1] ? scores[$0] < scores[$1] : $0 > $1 }),
                  rank == 0 || scores[best] > 0
            else { continue }
            used.insert(best)
            let caption: String
            if walkthrough.matchesNoteResult {
                caption = "The worked example from your notes, one row operation at a time. The last matrix is the one your notes end with."
            } else if walkthrough.stepsFromNote {
                caption = "A matrix from your notes, reduced with the row operations your notes state."
            } else {
                caption = "A matrix from your notes, row-reduced step by step. GRASP chose these steps; your lecture may order them differently."
            }
            document.sections[best].figure = OverviewFigure(
                kind: .rowReduction,
                caption: caption,
                steps: walkthrough.steps,
                matrix: walkthrough.start.doubles,
                augmentedColumns: walkthrough.start.augmentedColumns,
                stepsFromNote: walkthrough.stepsFromNote
            )
        }
    }

    // MARK: - Worked examples

    /// Whether an example is row operations on a matrix: it names one
    /// (`R3 -> R3 + R1`), or writes out a row of numbers with a bar.
    static func manipulatesMatrixRows(_ example: OverviewWorkedExample) -> Bool {
        let text = ([example.title, example.setup, example.outcome].compactMap { $0 }
            + example.steps.flatMap { [$0.action, $0.result].compactMap { $0 } })
            .joined(separator: " ")
        if !NoteMatrices.operations(in: text).isEmpty { return true }
        let barredRow = #"(?:[+\-−–]?\d+\s+){2,}\|\s*[+\-−–]?\d+"#
        return text.range(of: barredRow, options: .regularExpression) != nil
            || text.range(of: #"\[\s*[+\-−–]?\d+(?:\s+[+\-−–]?\d+){2,}"#, options: .regularExpression) != nil
    }

    /// Keeps a model's worked example only when it's real: at least two
    /// steps, and every number in it written somewhere in the note. An
    /// example a model invented -- or one whose arithmetic it fumbled into
    /// numbers the note never had -- is dropped rather than taught.
    static func groundedExample(in section: OverviewSection, noteText: String) -> OverviewSection {
        guard var example = section.example else { return section }
        var section = section
        example.steps = Array(example.steps.prefix(OverviewLimits.exampleSteps))
        // Each picture is checked on its own; a bad one costs only itself.
        let isMath = NoteMath.isMathematical(noteText)
        for index in example.steps.indices {
            example.steps[index].visual = example.steps[index].visual.flatMap {
                StepVisuals.validate($0, noteText: noteText, isMath: isMath)
            }
            if let label = example.steps[index].label, label.split(separator: " ").count > 6 {
                example.steps[index].label = nil
            }
        }
        let text = ([example.title, example.setup, example.outcome].compactMap { $0 }
            + example.steps.flatMap { [$0.action, $0.result, $0.why].compactMap { $0 } })
            .joined(separator: " ")
        let available = NoteMath.numbers(in: noteText)
        let used = NoteMath.numbers(in: text)
        let grounded = used.allSatisfy { value in
            // Small counting numbers are how steps are described ("row 3",
            // "two equations"), not data copied from the note.
            value <= 10 && value == value.rounded() || available.contains { abs($0 - value) < 1e-9 }
        }
        section.example = example.steps.count >= 2 && grounded ? example : nil
        return section
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

    /// Everything a section says, including its example, as written.
    private static func fullText(_ section: OverviewSection) -> String {
        var parts = [section.heading] + section.paragraphs
        if let example = section.example {
            parts += [example.title, example.setup, example.outcome].compactMap { $0 }
            parts += example.steps.flatMap { [$0.action, $0.result].compactMap { $0 } }
        }
        return parts.joined(separator: " ")
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
