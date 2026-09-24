import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model as the zero-install fallback generator: no
/// download, no server to run, but noticeably weaker than a local 7B at
/// this task, and it requires Apple Intelligence to be enabled (checked
/// for real via `SystemLanguageModel.default.availability`, never assumed
/// from the OS version alone). Gated to macOS 26+ since the universal
/// build still runs on older systems via `OllamaGenerator`/`NoGenerator`.
@available(macOS 26.0, iOS 26.0, *)
public struct FoundationModelsGenerator: CardGenerator {
    public init() {}

    public var isAvailable: Bool {
        get async {
            #if canImport(FoundationModels)
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
            return false
            #else
            return false
            #endif
        }
    }

    #if canImport(FoundationModels)
    @Generable
    fileprivate struct RefinedCard {
        @Guide(description: "A short, clear flashcard term or question -- replaced entirely if the " +
               "original was garbled or mislabeled, otherwise only lightly cleaned up")
        var front: String
        @Guide(description: "A concise, accurate answer")
        var back: String
    }
    #endif

    public func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        let fallback = candidates.map { GeneratedCard(front: $0.front, back: $0.back) }
        #if canImport(FoundationModels)
        guard await isAvailable, !candidates.isEmpty else { return fallback }
        var results: [GeneratedCard] = []
        for candidate in candidates {
            // A fresh session per card. One shared session kept every prompt
            // and answer in its transcript, and once that filled the
            // on-device context window every remaining card failed.
            let session = LanguageModelSession(
                instructions: """
                    You clean up flashcards auto-extracted from lecture notes. If a front is garbled, \
                    truncated, or mislabeled -- it doesn't actually name the concept the back describes -- \
                    replace it entirely with the correct short term or question, grounded only in the note \
                    context given. Otherwise leave its meaning alone and only fix minor wording or OCR \
                    artifacts. Keep the back concise and accurate. Never invent facts not in the note.
                    """
            )
            let prompt = """
            Note context: \(noteContext.prefix(500))
            Front: \(candidate.front)
            Back: \(candidate.back)
            """
            guard let response = try? await session.respond(to: prompt, generating: RefinedCard.self) else {
                results.append(GeneratedCard(front: candidate.front, back: candidate.back))
                continue
            }
            results.append(GeneratedCard(front: response.content.front, back: response.content.back))
        }
        return results
        #else
        return fallback
        #endif
    }

    /// Apple's on-device model has a far smaller context window than a
    /// local 7B, so the same note gets cut into more, smaller pieces.
    /// Lowering the budget rather than truncating the text is the whole
    /// point of `OverviewChunker` existing.
    public var overviewContextWordBudget: Int { 500 }

    #if canImport(FoundationModels)
    @Generable
    fileprivate struct DefinitionDraft {
        @Guide(description: "The term, worded the way the note words it")
        var term: String
        @Guide(description: "A one-sentence definition")
        var definition: String
    }

    @Generable
    fileprivate struct CheckDraft {
        @Guide(description: "A question that makes the reader apply the idea. Empty string if none.")
        var question: String
        @Guide(description: "A short answer explaining the reasoning. Empty string if none.")
        var answer: String
    }

    @Generable
    fileprivate struct SectionDraft {
        @Guide(description: "A full sentence stating the insight, like 'Swapping two equations cannot change the answer' -- never a bare topic")
        var heading: String
        @Guide(description: "Two or three short paragraphs that build intuition from a concrete case before naming the idea. Do not repeat the note's sentences.")
        var paragraphs: [String]
        @Guide(description: "Key terms first introduced in this section. Empty if none.")
        var terms: [DefinitionDraft]
        var check: CheckDraft
    }

    @Generable
    fileprivate struct FormulaDraft {
        @Guide(description: "What the formula is called, or the quantity it computes")
        var name: String
        @Guide(description: "The formula in LaTeX. Empty string if the note doesn't write it in LaTeX.")
        var latex: String
        @Guide(description: "The formula written in plain text")
        var plain: String
        @Guide(description: "What its symbols stand for. Empty string if the note doesn't say.")
        var meaning: String
    }

    @Generable
    fileprivate struct LessonDraft {
        @Guide(description: "A short claim capturing the lecture's central insight")
        var title: String
        @Guide(description: "Two or three sentences opening with the question or puzzle this lecture answers")
        var hook: String
        @Guide(description: "2 to 4 things the reader will be able to do afterwards, each starting with a verb")
        var objectives: [String]
        @Guide(description: "3 to 5 sections, in the order a learner should meet them")
        var sections: [SectionDraft]
        @Guide(description: "3 to 5 sentences, each one idea worth remembering")
        var takeaways: [String]
        @Guide(description: "Every formula, equation or named rule the note states. Empty if it states none.")
        var formulas: [FormulaDraft]
    }
    #endif

    public func generateOverview(
        noteTitle: String, courseName: String, noteContext: String,
        includeFormulas: Bool, partLabel: String?
    ) async -> GeneratedOverview {
        #if canImport(FoundationModels)
        guard await isAvailable, !noteContext.isEmpty else { return .empty }
        let partLine = partLabel.map {
            "You are being shown one piece of a longer note: \($0). Cover only what this piece " +
            "raises; the rest is being handled separately.\n"
        } ?? ""
        let session = LanguageModelSession(
            instructions: """
                You are writing a short lesson for the course "\(courseName)", in the style of \
                3Blue1Brown: curious, visual, and built so the reader discovers each idea instead \
                of being told it. Start from a concrete question. Show a concrete case with real \
                numbers before the general rule, then give it its name. Explain why each idea \
                has to be true. Talk to the reader using you and we.

                You may draw on what you know about the subject to explain the concepts in the \
                note, but do not introduce concepts it never raises. Never repeat the note's own \
                sentences back. An empty part is a normal and expected result, not a failure.
                """
        )
        // Not truncated here, unlike every other method in this type:
        // `OverviewChunker` has already cut this to `overviewContextWordBudget`.
        let prompt = """
        \(partLine)Note title: \(noteTitle)

        Note:
        \(noteContext)
        """
        guard let response = try? await session.respond(
            to: prompt, generating: LessonDraft.self
        ) else { return .empty }

        let draft = response.content
        // The file's established convention: an empty string is the
        // "absent" sentinel, since `@Generable` handles optionals poorly.
        func optional(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let sections = draft.sections.compactMap { entry -> OverviewSection? in
            let paragraphs = entry.paragraphs.compactMap(optional)
                .prefix(OverviewLimits.paragraphsPerSection)
            guard let heading = optional(entry.heading), !paragraphs.isEmpty else { return nil }
            let terms = entry.terms.compactMap { term -> OverviewDefinition? in
                guard let name = optional(term.term), let text = optional(term.definition)
                else { return nil }
                return OverviewDefinition(term: name, text: text)
            }.prefix(OverviewLimits.termsPerSection)
            let check = optional(entry.check.question).flatMap { question in
                optional(entry.check.answer).map { OverviewCheck(question: question, answer: $0) }
            }
            return OverviewSection(
                heading: heading, paragraphs: Array(paragraphs), terms: Array(terms), check: check
            )
        }.prefix(OverviewLimits.sections)

        let document = OverviewDocument(
            title: optional(draft.title),
            hook: optional(draft.hook),
            objectives: Array(draft.objectives.compactMap(optional).prefix(OverviewLimits.objectives)),
            sections: Array(sections),
            takeaways: Array(draft.takeaways.compactMap(optional).prefix(OverviewLimits.takeaways)),
            formulas: includeFormulas
                ? Array(draft.formulas.compactMap { entry -> OverviewFormula? in
                    guard let name = optional(entry.name) else { return nil }
                    let latex = optional(entry.latex)
                    guard let plain = optional(entry.plain) ?? latex.map(LatexPlainText.render)
                    else { return nil }
                    return OverviewFormula(
                        name: name, latex: latex, plain: plain, meaning: optional(entry.meaning)
                    )
                }.prefix(OverviewLimits.formulas))
                : []
        )
        return GeneratedOverview(document: document)
        #else
        return .empty
        #endif
    }

    /// Always empty. Figures need a model that can copy exact coefficients
    /// and row operations out of a note, and the on-device model can't be
    /// relied on to -- a figure built from misread numbers is a confidently
    /// wrong picture. The lesson still works without them, and the write
    /// sheet already tells the student that a local 7B gives better results.
    public func generateFigures(
        noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]
    ) async -> [GeneratedFigure] {
        []
    }

    /// Unguided, unlike everything else here. Guided generation can't
    /// express "valid Mermaid in this subset", and forcing a `@Generable`
    /// node/edge schema is exactly the bespoke-schema approach the Mermaid
    /// decision rejected -- the same instruction text goes to both
    /// generators so one parser handles both.
    public func generateDiagram(
        noteTitle: String, courseName: String, conceptOutline: String
    ) async -> String {
        #if canImport(FoundationModels)
        guard await isAvailable, !conceptOutline.isEmpty else { return "" }
        let session = LanguageModelSession(
            instructions: OllamaGenerator.diagramInstructions(courseName: courseName)
        )
        let prompt = """
        Note title: \(noteTitle)

        Outline:
        \(conceptOutline.prefix(1500))
        """
        guard let response = try? await session.respond(to: prompt) else { return "" }
        return OllamaGenerator.salvageMermaid(response.content)
        #else
        return ""
        #endif
    }

    #if canImport(FoundationModels)
    @Generable
    fileprivate struct AdditionalCards {
        @Guide(description: "Additional flashcards for concepts this note implies but doesn't already have a card for. Empty if there are none.")
        var cards: [RefinedCard]
    }
    #endif

    public func generateAdditional(
        existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?
    ) async -> [GeneratedCard] {
        #if canImport(FoundationModels)
        guard await isAvailable, maxCount > 0, !noteContext.isEmpty else { return [] }
        let instructions = """
            You are a student's study assistant. Given one of their lecture notes and the flashcards \
            already made from it, find at most a few additional concepts the note itself mentions or \
            implies but that aren't covered yet. Every fact must be directly supported by the note \
            text -- never add outside knowledge or invent an example, number, or date the note doesn't \
            contain. An empty result is normal and expected when the note has no such gap.
            """
        let session = LanguageModelSession(instructions: instructions)
        let covered = existing.map { "- \($0.front): \($0.back)" }.joined(separator: "\n")
        let trimmedTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusLine = (trimmedTopic?.isEmpty == false) ? "Focus especially on: \(trimmedTopic!).\n" : ""
        let prompt = """
        \(focusLine)Note: \(noteContext.prefix(1500))
        Cards already made from this note:
        \(covered.isEmpty ? "(none yet)" : covered)
        Propose at most \(maxCount) additional card(s).
        """
        guard let response = try? await session.respond(to: prompt, generating: AdditionalCards.self) else {
            return []
        }
        return response.content.cards.prefix(maxCount).map { GeneratedCard(front: $0.front, back: $0.back) }
        #else
        return []
        #endif
    }

    #if canImport(FoundationModels)
    @Generable
    fileprivate struct TestQuestion {
        @Guide(description: "A short free-response practice question testing understanding of the note")
        var prompt: String
        @Guide(description: "The correct answer to the question")
        var correctAnswer: String
    }

    @Generable
    fileprivate struct TestQuestions {
        @Guide(description: "Free-response practice questions grounded in the note. Empty if none are worth asking.")
        var questions: [TestQuestion]
    }
    #endif

    public func generateTestQuestions(
        existing: [CandidatePair], noteContext: String, maxCount: Int
    ) async -> [GeneratedTestQuestion] {
        #if canImport(FoundationModels)
        guard await isAvailable, maxCount > 0, !noteContext.isEmpty else { return [] }
        let instructions = """
            You are a student's study assistant, writing practice questions for a test. Given one of \
            their lecture notes and the flashcards already made from it, write a few short \
            free-response questions that test understanding of the note -- prefer connecting or \
            applying an idea over restating an existing card word-for-word. Every fact in the \
            question and its answer must be directly supported by the note text -- never add outside \
            knowledge or invent an example, number, or date the note doesn't contain. An empty result \
            is normal and expected when the note has nothing more worth asking.
            """
        let session = LanguageModelSession(instructions: instructions)
        let covered = existing.map { "- \($0.front): \($0.back)" }.joined(separator: "\n")
        let prompt = """
        Note: \(noteContext.prefix(1500))
        Cards already made from this note:
        \(covered.isEmpty ? "(none yet)" : covered)
        Write at most \(maxCount) practice question(s).
        """
        guard let response = try? await session.respond(to: prompt, generating: TestQuestions.self) else {
            return []
        }
        return response.content.questions.prefix(maxCount)
            .map { GeneratedTestQuestion(prompt: $0.prompt, correctAnswer: $0.correctAnswer) }
        #else
        return []
        #endif
    }

    #if canImport(FoundationModels)
    @Generable
    fileprivate struct ContextCheck {
        @Guide(description: "Exactly one of: valid, refine, reject")
        var verdict: String
        @Guide(description: "Only meaningful when verdict is refine: a concise definition drawn only from the note text. Empty string otherwise.")
        var refinedBack: String
    }
    #endif

    public func validateContext(
        front: String, back: String, noteContext: String, courseName: String
    ) async -> ContextValidation {
        #if canImport(FoundationModels)
        guard await isAvailable, !noteContext.isEmpty else { return ContextValidation(.valid) }
        let instructions = """
            You are checking flashcards auto-extracted from a student's notes for the course \
            "\(courseName)". A flashcard's front is a term and its back should be a general, \
            academically accurate definition of that term -- the kind that belongs in a course \
            glossary, true regardless of which specific assignment or example it came from.

            First decide whether the term itself is a real, general concept a student in this course \
            would need to know, or just a label specific to this one document (a draft's section \
            heading, an assignment instruction, a personal narrative, a fragment) -- judge the term \
            itself, not the quality of its extracted definition. If it's not a real general concept, \
            verdict is "reject". If it is: verdict is "valid" when the extracted definition already \
            states the general concept accurately; otherwise verdict is "refine" with a brand-new, \
            general, academically accurate definition written from your own knowledge of the subject. \
            Do not summarize, paraphrase, or shorten the extracted text or the note's specific \
            example -- state what the term actually means in general, even if that differs from what \
            the specific extracted text or note said.
            """
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Term: \(front)
        Extracted definition: \(back)
        Note: \(noteContext.prefix(1500))
        """
        guard let response = try? await session.respond(to: prompt, generating: ContextCheck.self) else {
            return ContextValidation(.valid)
        }
        switch response.content.verdict.lowercased() {
        case "refine":
            let refined = response.content.refinedBack.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !refined.isEmpty else { return ContextValidation(.valid) }
            return ContextValidation(.refine(newBack: refined))
        case "reject":
            return ContextValidation(.reject)
        default:
            return ContextValidation(.valid)
        }
        #else
        return ContextValidation(.valid)
        #endif
    }

    public func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] {
        // Distractor generation is left to the deterministic fallback even
        // when Foundation Models is available -- the quality gain over
        // `LearnEngine.distractors` doesn't clearly justify a per-question
        // model round trip for this generator; Ollama's version does the
        // model-backed variant.
        Array(deckContext.filter { $0 != correctAnswer }.shuffled().prefix(count))
    }
}
