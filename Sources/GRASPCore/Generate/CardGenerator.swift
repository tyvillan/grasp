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
