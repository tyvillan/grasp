import Foundation

/// Builds a custom test from a card pool: a fixed question count, a subset
/// of question types cycled round-robin so an all-types test isn't
/// accidentally all one type, shuffled or in deck order. Reuses
/// `LearnEngine.RoundQuestion` as the question shape (identical fields
/// serve both) and `LearnEngine.distractors` for multiple-choice/true-false
/// options, since both draw from the same deterministic, model-free pool.
public enum TestBuilder {
    public struct Config: Sendable {
        public var questionCount: Int
        public var allowMultipleChoice: Bool
        public var allowWritten: Bool
        public var allowTrueFalse: Bool
        public var shuffle: Bool
        public var timeLimitSeconds: Int?   // nil = untimed

        public init(
            questionCount: Int = 20, allowMultipleChoice: Bool = true, allowWritten: Bool = true,
            allowTrueFalse: Bool = true, shuffle: Bool = true, timeLimitSeconds: Int? = nil
        ) {
            self.questionCount = questionCount
            self.allowMultipleChoice = allowMultipleChoice
            self.allowWritten = allowWritten
            self.allowTrueFalse = allowTrueFalse
            self.shuffle = shuffle
            self.timeLimitSeconds = timeLimitSeconds
        }

        var enabledTypes: [LearnEngine.QuestionType] {
            var types: [LearnEngine.QuestionType] = []
            if allowMultipleChoice { types.append(.multipleChoice) }
            if allowWritten { types.append(.written) }
            if allowTrueFalse { types.append(.trueFalse) }
            return types
        }
    }

    public static func build<R: RandomNumberGenerator>(
        from cards: [(cardId: String, front: String, back: String)], config: Config, using rng: inout R
    ) -> [LearnEngine.RoundQuestion] {
        let types = config.enabledTypes
        guard !cards.isEmpty, !types.isEmpty else { return [] }

        let pool = cards.map { LearnEngine.Candidate(cardId: $0.cardId, front: $0.front, back: $0.back, level: .new) }
        var selected = pool
        if config.shuffle { selected.shuffle(using: &rng) }
        selected = Array(selected.prefix(config.questionCount))

        return selected.enumerated().map { index, candidate in
            switch types[index % types.count] {
            case .multipleChoice:
                var choices = LearnEngine.distractors(for: candidate, in: pool, count: 3, using: &rng)
                choices.append(candidate.back)
                choices.shuffle(using: &rng)
                return LearnEngine.RoundQuestion(cardId: candidate.cardId, prompt: candidate.front,
                                                  correctAnswer: candidate.back, type: .multipleChoice, choices: choices)
            case .trueFalse:
                let showTrue = Bool.random(using: &rng)
                let statement = showTrue
                    ? candidate.back
                    : (LearnEngine.distractors(for: candidate, in: pool, count: 1, using: &rng).first ?? candidate.back)
                return LearnEngine.RoundQuestion(cardId: candidate.cardId, prompt: candidate.front,
                                                  correctAnswer: showTrue ? "True" : "False", type: .trueFalse,
                                                  statement: statement, statementIsTrue: showTrue)
            case .written:
                return LearnEngine.RoundQuestion(cardId: candidate.cardId, prompt: candidate.front,
                                                  correctAnswer: candidate.back, type: .written)
            }
        }
    }
}
