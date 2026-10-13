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
        /// When true, the card pool this test draws from excludes anything
        /// already marked understood (`learnState.level == .mastered`) --
        /// a test can be "quiz me only on what I haven't proven I know"
        /// instead of re-testing cards already approved in Study. Applied
        /// by the caller (`AppStore.startTest`) before the pool reaches
        /// `build`, since mastery isn't part of the deterministic,
        /// model-free data this type otherwise works with.
        public var excludeMastered: Bool
        /// Draw only from cards the student keeps missing (see
        /// `Study.weakCardIds`).
        public var weakSpotsOnly: Bool

        public init(
            questionCount: Int = 20, allowMultipleChoice: Bool = true, allowWritten: Bool = true,
            allowTrueFalse: Bool = true, shuffle: Bool = true, timeLimitSeconds: Int? = nil,
            excludeMastered: Bool = false, weakSpotsOnly: Bool = false
        ) {
            self.weakSpotsOnly = weakSpotsOnly
            self.questionCount = questionCount
            self.allowMultipleChoice = allowMultipleChoice
            self.allowWritten = allowWritten
            self.allowTrueFalse = allowTrueFalse
            self.shuffle = shuffle
            self.timeLimitSeconds = timeLimitSeconds
            self.excludeMastered = excludeMastered
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

        // A true/false question needs a statement to judge, so a card whose
        // prompt is itself a question ("Which tool…?") is never asked that
        // way. When True/False is the only type allowed there is nothing
        // else to ask it as, so such cards are left out of the test.
        let nonTrueFalse = types.filter { $0 != .trueFalse }
        if nonTrueFalse.isEmpty {
            selected = selected.filter { !LearnEngine.isQuestionPrompt($0.front) }
        }
        selected = Array(selected.prefix(config.questionCount))

        // Types cycle round-robin; a True/False slot that lands on a question
        // prompt goes to whichever other enabled type has been asked least,
        // so the mix stays even.
        var asked: [LearnEngine.QuestionType: Int] = [:]
        return selected.enumerated().map { index, candidate in
            var type = types[index % types.count]
            if type == .trueFalse, LearnEngine.isQuestionPrompt(candidate.front), !nonTrueFalse.isEmpty {
                type = nonTrueFalse.min { (asked[$0] ?? 0) < (asked[$1] ?? 0) } ?? nonTrueFalse[0]
            }
            asked[type, default: 0] += 1
            switch type {
            case .multipleChoice:
                var choices = LearnEngine.distractors(for: candidate, in: pool, count: 3, using: &rng)
                choices.append(candidate.back)
                choices.shuffle(using: &rng)
                return LearnEngine.RoundQuestion(cardId: candidate.cardId, prompt: candidate.front,
                                                  correctAnswer: candidate.back, type: .multipleChoice, choices: choices)
            case .trueFalse:
                let (statement, showTrue) = LearnEngine.trueFalseStatement(for: candidate, in: pool, using: &rng)
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
