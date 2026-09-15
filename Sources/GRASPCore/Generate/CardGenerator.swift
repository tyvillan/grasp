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
}

/// Picks the best generator available on this machine, in the order the
/// design calls for: a local Ollama server first (highest quality), then
/// Apple's on-device Foundation Models (zero setup but weaker), then no
/// generator at all. Every candidate is checked for real -- a network
/// probe for Ollama, a framework availability check for Foundation
/// Models -- rather than assumed from what's installed.
public enum CardGenerators {
    public static func select() async -> any CardGenerator {
        let ollama = OllamaGenerator()
        if await ollama.isAvailable { return ollama }

        if #available(macOS 26.0, *) {
            let foundationModels = FoundationModelsGenerator()
            if await foundationModels.isAvailable { return foundationModels }
        }

        return NoGenerator()
    }
}
