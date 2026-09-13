import Foundation

public struct GeneratedCard: Sendable, Equatable {
    public let front: String
    public let back: String

    public init(front: String, back: String) {
        self.front = front
        self.back = back
    }
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
