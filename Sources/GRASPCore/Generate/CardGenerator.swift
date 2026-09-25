import Foundation

public struct GeneratedCard: Sendable, Equatable {
    public let front: String
    public let back: String

    public init(front: String, back: String) {
        self.front = front
        self.back = back
    }
}

public struct GeneratedTestQuestion: Sendable, Equatable {
    public let prompt: String
    public let correctAnswer: String

    public init(prompt: String, correctAnswer: String) {
        self.prompt = prompt
        self.correctAnswer = correctAnswer
    }
}

/// One figure a generator proposed, and which section (0-based, in the
/// order the headings were given) it belongs beside.
public struct GeneratedFigure: Sendable, Equatable {
    public let sectionIndex: Int
    public let figure: OverviewFigure

    public init(sectionIndex: Int, figure: OverviewFigure) {
        self.sectionIndex = sectionIndex
        self.figure = figure
    }
}

/// A whole-note study overview, before it is merged, linked or persisted.
/// Mirrors `GeneratedCard`/`GeneratedTestQuestion`: a plain value the
/// generator produces and the caller decides what to do with.
public struct GeneratedOverview: Sendable, Equatable {
    public let document: OverviewDocument

    public init(document: OverviewDocument) { self.document = document }

    /// The fail-soft result for no model, no note, or a response that
    /// couldn't be read. Deliberately not an optional or a thrown error:
    /// `generateAdditional` already established that "nothing came back"
    /// and "there was nothing to say" are the same answer to a caller.
    public static let empty = GeneratedOverview(document: .empty)

    public var isEmpty: Bool { document.isEmpty }
}

/// The outcome of checking one card's definition against its term and
/// source note -- see `CardGenerator.validateContext`.
public struct ContextValidation: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// The term is a real course concept and the definition already
        /// states it accurately. No change.
        case valid
        /// The term is a real course concept, but its extracted
        /// definition doesn't state it -- a brand-new, general definition
        /// written from the model's own subject knowledge, not a
        /// summary/paraphrase of the flawed extracted text.
        case refine(newBack: String)
        /// The *term itself* isn't a real, general course concept at
        /// all -- a label specific to one document (an essay draft's own
        /// section heading, an assignment instruction, a personal
        /// reference, a stray fragment) that the deterministic parser's
        /// own filters didn't catch. Judged independently of how good or
        /// bad its extracted definition happens to be.
        case reject
    }
    public let verdict: Verdict
    public init(_ verdict: Verdict) { self.verdict = verdict }
}

/// A pluggable upgrade path over the deterministic parser: takes its raw
/// candidate pairs and produces cleaner cards, or generates distractors for
/// multiple-choice questions. Every implementation must fail soft --
/// `refine` returning the untouched candidates and `distractors` returning
/// fewer (or zero) options are both valid outcomes a caller can act on,
/// never a thrown error the UI has to handle specially. Nothing a
/// generator produces skips the review queue: it always lands as
/// `status: .draft`, same as parser output.
public protocol CardGenerator: Sendable {
    var isAvailable: Bool { get async }

    func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard]

    func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String]

    /// Proposes up to `maxCount` *additional* cards for concepts a note's
    /// own text implies but the parser's fixed shapes didn't happen to
    /// capture -- a term used in passing but never given its own
    /// definition line, a listed item without an example. `noteContext`
    /// is the only source of truth: every implementation must be grounded
    /// to it and must not introduce a fact the note doesn't support.
    /// `existing` (the cards already made from this same note) is there so
    /// the model doesn't propose a near-duplicate of one already covered.
    /// An empty result is a valid, expected outcome -- most notes don't
    /// have an obvious gap worth filling, and fabricating one to hit
    /// `maxCount` would be worse than proposing nothing. `topic`, when
    /// non-nil and non-empty, steers *which* gap to look for (e.g. "mitosis
    /// phases") without loosening the grounding requirement -- it narrows
    /// the search, it never licenses adding a fact the note doesn't support.
    func generateAdditional(
        existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?
    ) async -> [GeneratedCard]

    /// Proposes up to `maxCount` fresh, written/free-response practice
    /// questions grounded in `noteContext`, for a test-only question that
    /// is never saved as a `Card` and never enters the draft review queue
    /// -- unlike `generateAdditional`, nothing this returns is persisted;
    /// a test asks for a fresh batch every time it starts. `existing` (the
    /// cards already made from this note) steers the model away from
    /// asking something that just restates a card the deck already tests
    /// directly. Same grounding contract as `generateAdditional`: every
    /// fact must come from `noteContext`, an empty result is a normal,
    /// expected outcome, and every implementation must fail soft.
    func generateTestQuestions(
        existing: [CandidatePair], noteContext: String, maxCount: Int
    ) async -> [GeneratedTestQuestion]

    /// Judges a card two ways, kept deliberately separate (see
    /// `ContextValidation.Verdict`): first whether `front` names a real,
    /// general concept for `courseName` at all (independent of how good
    /// `back` is), then -- only for a term that passes that bar -- whether
    /// `back` already states it accurately. Unlike `generateAdditional`,
    /// a `.refine` result is NOT restricted to what `noteContext` happens
    /// to say: it's a brand-new definition from the model's own subject
    /// knowledge, because the whole point is correcting a term whose
    /// extracted text is wrong or off-topic -- restating that same flawed
    /// text more smoothly (what an earlier version of this prompt did)
    /// isn't a fix. `noteContext` is still passed as grounding/reference,
    /// just not as a hard boundary the way it is for `generateAdditional`.
    /// `.valid` is the fail-soft default: no generator available, an
    /// empty `noteContext`, or any error all look the same to a caller --
    /// keep the card exactly as parsed rather than risk rejecting
    /// something real on a shaky signal.
    func validateContext(
        front: String, back: String, noteContext: String, courseName: String
    ) async -> ContextValidation

    /// Teaches one note as a short lesson: a claim-style title, an opening
    /// question, objectives, claim-headed sections with inline key terms and
    /// self-checks, and takeaways. Unlike every card-facing method here this
    /// is *not* grounded to the note's wording -- a lesson that stays inside
    /// the note's own sentences reads as a copy of the student's notes. The
    /// boundary is topical instead: explain the concepts the note raises as
    /// well as possible, without wandering onto concepts it doesn't raise.
    /// An empty result is still a normal, expected outcome.
    ///
    /// `noteContext` is NOT truncated by the implementation, unlike every
    /// other method here. The caller has already cut the note into pieces
    /// that fit `overviewContextWordBudget`, because a whole-note summary
    /// silently cut off at 3,000 characters is a *wrong* answer rather than
    /// a slightly thinner one -- it describes the first third of a lecture
    /// while presenting itself as describing the lecture.
    ///
    /// `includeFormulas` comes from `NoteText.hasMath`: a note with no
    /// math shouldn't be shown a formulas section at all, because a model
    /// shown an empty section fills it. `partLabel`, when non-nil, tells
    /// the model it is seeing one piece of a longer note so it summarises
    /// only that piece.
    ///
    /// Deliberately does not produce the diagram -- see `generateDiagram`.
    func generateOverview(
        noteTitle: String, courseName: String, noteContext: String,
        includeFormulas: Bool, partLabel: String?
    ) async -> GeneratedOverview

    /// Draws one concept diagram over an already-summarised note, as raw
    /// Mermaid source in the restricted subset `MermaidParser` accepts.
    ///
    /// Split out of `generateOverview` for one concrete reason: a Mermaid
    /// block is inherently multi-line, every other call in this file comes
    /// back inside a JSON string, and an unescaped newline in a JSON string
    /// is the most common way a local 7B response fails to decode. Asking
    /// for the diagram in its own plain-text response removes that failure
    /// mode rather than trying to survive it, and it lets the overview pass
    /// demand single-line strings everywhere.
    ///
    /// Returns the source verbatim, never a parsed graph: parsing belongs
    /// to `MermaidParser`, which is pure, tolerant, independently testable,
    /// and able to improve without regenerating anything. `""` is the
    /// fail-soft empty result, and also the honest answer for a note with
    /// no relationships worth drawing.
    func generateDiagram(
        noteTitle: String, courseName: String, conceptOutline: String
    ) async -> String

    /// Chooses interactive figures for a lesson that has already been
    /// written, from the fixed set `OverviewFigure.Kind` names, and supplies
    /// only their *numbers* -- the equations the note contains, the row
    /// operations it performs, a matrix it discusses. `sectionHeadings` are
    /// the lesson's headings in order, so each figure can say which section
    /// it belongs beside.
    ///
    /// A separate pass from `generateOverview` so the lesson prompt can stay
    /// about writing well, and so a model that fumbles this narrower,
    /// numbers-only question costs the lesson its pictures and nothing else.
    /// Everything drawn is recomputed from these numbers by
    /// `OverviewFigures`; nothing here is trusted to be arithmetic. `[]` is
    /// the fail-soft empty result, and the honest one for any note with no
    /// equations or matrices in it.
    func generateFigures(
        noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]
    ) async -> [GeneratedFigure]

    /// Roughly how many words of note text this generator can be handed in
    /// one call and still answer well -- what `OverviewChunker` sizes its
    /// chunks against. Words rather than tokens because nothing in this
    /// codebase has a tokenizer, and `NoteText.wordCount` is already stored.
    var overviewContextWordBudget: Int { get }
}

public extension CardGenerator {
    /// ~1,200 words is roughly 1,600 tokens of English prose, leaving a
    /// 7-8B model's 8k window comfortable room for the prompt and a full
    /// answer. `FoundationModelsGenerator` overrides this downward.
    var overviewContextWordBudget: Int { 1_200 }

    /// The second pass over a written section: corrections for statements
    /// the note contradicts or that are simply wrong. Empty by default --
    /// a generator that can't check reliably shouldn't pretend to.
    func reviewSection(noteContext: String, section: OverviewSection) async -> [OverviewFix] { [] }

    /// The second pass over a whole lesson: sections and takeaways that
    /// repeat an earlier one.
    func findRepetition(in document: OverviewDocument) async -> OverviewRepetition { .none }
}

/// One correction from the review pass: `original` is text the section
/// contains; `corrected` replaces it, or nil removes it.
public struct OverviewFix: Sendable, Equatable {
    public let original: String
    public let corrected: String?
    public init(original: String, corrected: String?) {
        self.original = original
        self.corrected = corrected
    }
}

/// What the lesson-level review found repeated, as 0-based indices.
public struct OverviewRepetition: Sendable, Equatable {
    /// Each repeated section, and the earlier one that already teaches it.
    public let sections: [(repeated: Int, original: Int)]
    public let takeaways: [Int]
    public init(sections: [(repeated: Int, original: Int)], takeaways: [Int]) {
        self.sections = sections
        self.takeaways = takeaways
    }
    public static let none = OverviewRepetition(sections: [], takeaways: [])
    public static func == (a: Self, b: Self) -> Bool {
        a.takeaways == b.takeaways && a.sections.map(\.repeated) == b.sections.map(\.repeated)
            && a.sections.map(\.original) == b.sections.map(\.original)
    }
}

/// The v1 default: no model, no network, no framework check. Candidates
/// pass through untouched (the deterministic parser already did the real
/// work), and distractors are a plain random sample of the deck's other
/// answers -- the same fallback `LearnEngine`/`TestBuilder` already use on
/// their own, kept here only so every `CardGenerator` responds to the same
/// two calls.
public struct NoGenerator: CardGenerator {
    public init() {}

    public var isAvailable: Bool { get async { false } }

    public func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        candidates.map { GeneratedCard(front: $0.front, back: $0.back) }
    }

    public func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] {
        Array(deckContext.filter { $0 != correctAnswer }.shuffled().prefix(count))
    }

    /// No model means no proposal -- an empty array, never a fabricated
    /// one, matching `refine`'s "candidates pass through untouched" spirit.
    public func generateAdditional(
        existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?
    ) async -> [GeneratedCard] {
        []
    }

    /// No model means no proposal -- same "nothing fabricated" spirit as
    /// `generateAdditional`.
    public func generateTestQuestions(
        existing: [CandidatePair], noteContext: String, maxCount: Int
    ) async -> [GeneratedTestQuestion] {
        []
    }

    /// No model means no opinion -- always `.valid`, i.e. leave the card
    /// exactly as the deterministic parser produced it.
    public func validateContext(
        front: String, back: String, noteContext: String, courseName: String
    ) async -> ContextValidation {
        ContextValidation(.valid)
    }

    /// No model means no overview -- the empty document, never a fabricated
    /// one, matching `generateAdditional`'s "nothing invented" spirit. An
    /// empty document is never persisted, so this writes no row.
    public func generateOverview(
        noteTitle: String, courseName: String, noteContext: String,
        includeFormulas: Bool, partLabel: String?
    ) async -> GeneratedOverview {
        .empty
    }

    /// No model means no diagram. `""` rather than a stub graph: the view's
    /// "no diagram" state is the right thing to show, where a placeholder
    /// would look like a real answer that happened to be wrong.
    public func generateDiagram(
        noteTitle: String, courseName: String, conceptOutline: String
    ) async -> String {
        ""
    }

    public func generateFigures(
        noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]
    ) async -> [GeneratedFigure] {
        []
    }
}

/// Picks the best generator available on this machine, in the order the
/// design calls for: a local Ollama server first (highest quality), then
/// Apple's on-device Foundation Models (zero setup but weaker), then no
/// generator at all. Every candidate is checked for real -- a network
/// probe for Ollama, a framework availability check for Foundation
/// Models -- rather than assumed from what's installed.
public enum CardGenerators {
    public static func select() async -> any CardGenerator {
        // Ollama runs on a computer -- Mac, Windows or Linux -- and GRASP
        // reaches it at this device's own address. On iPhone there's nothing
        // there -- and in the simulator, which shares the Mac's network, it
        // found the Mac's Ollama and claimed to be using it, which no real
        // phone could.
        #if !os(iOS)
        let probe = OllamaGenerator()
        if await probe.isAvailable {
            // A running server with the wrong model name answers every
            // request with a 404 that `try?` turns into silence -- so the
            // model is chosen from what's actually installed, never assumed.
            let installed = await probe.installedModels()
            let preferred = UserDefaults.standard.string(forKey: OllamaModelChoice.defaultsKey)
            if let model = OllamaModelChoice.resolve(preferred: preferred, installed: installed) {
                return OllamaGenerator(model: model)
            }
        }
        #endif

        if #available(macOS 26.0, iOS 26.0, *) {
            let foundationModels = FoundationModelsGenerator()
            if await foundationModels.isAvailable { return foundationModels }
        }

        return NoGenerator()
    }
}

/// Which installed Ollama model GRASP talks to.
public enum OllamaModelChoice {
    /// Machine-wide rather than per profile: models are installed on this
    /// Mac, not in anyone's account.
    public static let defaultsKey = "GRASP.ollamaModel"

    /// Best first, for when the student hasn't chosen. Ordered by how each
    /// did on the same real lecture note -- following the lesson's style
    /// rules and keeping its math straight -- not by size or reputation.
    /// qwen3.5:9b wrote claim headings, covered every part of the lecture
    /// and stated no false math; qwen2.5:7b titled the same lesson "Every
    /// system of linear equations has a solution", which is the opposite of
    /// what the lecture teaches. gemma4:12b is deliberately absent: on a
    /// 16 GB laptop it made the whole machine lag.
    public static let recommended = ["qwen3.5:9b", "qwen2.5:7b-instruct"]

    /// The student's choice if it's installed; otherwise the best installed
    /// recommended model; otherwise whatever is installed. nil only when
    /// nothing is -- a server with no models can't answer anything.
    public static func resolve(preferred: String?, installed: [String]) -> String? {
        if let preferred, !preferred.isEmpty, installed.contains(preferred) { return preferred }
        if let best = recommended.first(where: installed.contains) { return best }
        return installed.first
    }
}
