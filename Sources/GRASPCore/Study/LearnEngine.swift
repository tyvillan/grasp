import Foundation

/// Quizlet-style Learn mode: each card climbs a ladder
/// (new -> recognition -> recall -> mastered) via escalating question
/// types, independent of FSRS -- Learn drills initial acquisition, FSRS
/// handles ongoing long-term retention on `Card`'s own schedule. A card
/// mastered here still resurfaces in flashcards on its normal interval.
public enum LearnEngine {
    public enum Level: Int, Sendable {
        case new = 0, recognition = 1, recall = 2, mastered = 3
        /// Said "I know this" in Study but not yet shown in Learn. Not
        /// mastered: Learn asks it once as a typed answer, and a right answer
        /// makes it mastered. A client that doesn't know this value reads it
        /// as `.new` (`Level(rawValue:) ?? .new`), so it just gets tested.
        case familiar = 4
    }

    public enum QuestionType: String, Sendable {
        case multipleChoice, written, trueFalse
    }

    public struct RoundQuestion: Sendable, Identifiable {
        public let id: String
        /// nil for an ephemeral, AI-generated, test-only question with no
        /// backing `Card` -- never true for anything Learn mode produces.
        public var cardId: String?
        public var prompt: String
        public var correctAnswer: String
        public var type: QuestionType
        public var choices: [String]?       // multipleChoice only, includes correctAnswer, shuffled
        public var statement: String?       // trueFalse only: the (possibly false) statement shown
        public var statementIsTrue: Bool?   // trueFalse only
        /// A code question from the saved bank (see `CodeQuestionBank`):
        /// shown and graded as code, with `type` left as `.written`.
        public var code: CodeQuestion?
        /// A worked problem (matrices, economics, concepts) from the bank.
        public var problem: ProblemQuestion?

        public init(id: String? = nil, cardId: String?, prompt: String, correctAnswer: String, type: QuestionType,
                    choices: [String]? = nil, statement: String? = nil, statementIsTrue: Bool? = nil,
                    code: CodeQuestion? = nil, problem: ProblemQuestion? = nil) {
            self.code = code
            self.problem = problem
            self.id = id ?? cardId ?? UUID().uuidString
            self.cardId = cardId; self.prompt = prompt; self.correctAnswer = correctAnswer; self.type = type
            self.choices = choices; self.statement = statement; self.statementIsTrue = statementIsTrue
        }
    }

    /// One row of study material as the engine sees it -- deck-agnostic
    /// front/back pulled from `Card` plus its current Learn level.
    public struct Candidate: Sendable {
        public var cardId: String
        public var front: String
        public var back: String
        public var level: Level

        public init(cardId: String, front: String, back: String, level: Level) {
            self.cardId = cardId; self.front = front; self.back = back; self.level = level
        }
    }

    public static let roundSize = 7

    /// Below this fraction of a deck still unmastered, a round stops
    /// targeting the stragglers and starts reinforcing at random across
    /// the whole deck instead -- otherwise a nearly-mastered deck ends in
    /// endless rounds over the same last handful of cards.
    public static let randomReinforcementThreshold = 0.2

    /// Builds up to `roundSize` questions. While meaningfully more than
    /// `randomReinforcementThreshold` of the deck is still unmastered, the
    /// round draws only from those cards (not-yet-mastered candidates,
    /// callers pass them pre-ordered least-recently-seen first) -- Learn
    /// mode should only ask what the user hasn't proven they know. Once
    /// most of the deck is mastered, the round instead draws at random
    /// from every candidate, mastered or not, as spaced reinforcement.
    /// Question type still escalates with each card's own level. A missed
    /// question is the caller's job to requeue within the live session --
    /// this only builds the initial set.
    public static func buildRound<R: RandomNumberGenerator>(
        from candidates: [Candidate], using rng: inout R
    ) -> [RoundQuestion] {
        let unmastered = candidates.filter { $0.level != .mastered }
        let pool: [Candidate]
        if !candidates.isEmpty && Double(unmastered.count) / Double(candidates.count) <= randomReinforcementThreshold {
            pool = candidates.shuffled(using: &rng)
        } else {
            pool = unmastered
        }
        let selected = Array(pool.prefix(roundSize))
        return selected.enumerated().map { index, candidate in
            question(for: candidate, allCandidates: candidates, ordinal: index, using: &rng)
        }
    }

    private static func question<R: RandomNumberGenerator>(
        for candidate: Candidate, allCandidates: [Candidate], ordinal: Int, using rng: inout R
    ) -> RoundQuestion {
        switch candidate.level {
        case .new, .recognition:
            // Recognition-level cards alternate in true/false "as filler";
            // brand-new cards always start multiple choice, the gentlest
            // introduction to an unfamiliar term.
            // A prompt that is itself a question ("Which tool…?") can't be
            // called true or false, so it stays multiple choice.
            if candidate.level == .recognition && ordinal % 3 == 2 && !isQuestionPrompt(candidate.front) {
                return trueFalseQuestion(for: candidate, allCandidates: allCandidates, using: &rng)
            }
            return multipleChoiceQuestion(for: candidate, allCandidates: allCandidates, using: &rng)
        case .recall, .mastered, .familiar:
            return RoundQuestion(cardId: candidate.cardId, prompt: candidate.front,
                                  correctAnswer: candidate.back, type: .written)
        }
    }

    /// True when a card's front reads as a question or an instruction rather
    /// than a term or a statement: it ends in "?", opens with a question
    /// word (Which, What, How, Why, Who, Whom, Whose, When, Where) or with
    /// "According to…", opens with an instruction (Name, Identify, Describe,
    /// Explain, Define, List), or has a question clause after a comma
    /// ("According to the notes, which tool…"). A true/false question needs
    /// a statement to judge, so these are never asked that way.
    public static func isQuestionPrompt(_ prompt: String) -> Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        if text.hasSuffix("?") { return true }
        let openers = ["which ", "what ", "what's ", "how ", "why ", "who ", "whom ", "whose ", "when ", "where ",
                       "according to", "name ", "identify ", "describe ", "explain ", "define ", "list "]
        if openers.contains(where: { text.hasPrefix($0) }) { return true }
        let clauses = [", which ", ", what ", ", how ", ", why ", ", who ", ", when ", ", where "]
        return clauses.contains { text.contains($0) }
    }

    private static func multipleChoiceQuestion<R: RandomNumberGenerator>(
        for candidate: Candidate, allCandidates: [Candidate], using rng: inout R
    ) -> RoundQuestion {
        var choices = distractors(for: candidate, in: allCandidates, count: 3, using: &rng)
        choices.append(candidate.back)
        choices.shuffle(using: &rng)
        return RoundQuestion(cardId: candidate.cardId, prompt: candidate.front,
                              correctAnswer: candidate.back, type: .multipleChoice, choices: choices)
    }

    private static func trueFalseQuestion<R: RandomNumberGenerator>(
        for candidate: Candidate, allCandidates: [Candidate], using rng: inout R
    ) -> RoundQuestion {
        let (statement, showTrue) = trueFalseStatement(for: candidate, in: allCandidates, using: &rng)
        return RoundQuestion(cardId: candidate.cardId, prompt: candidate.front,
                              correctAnswer: showTrue ? "True" : "False", type: .trueFalse,
                              statement: statement, statementIsTrue: showTrue)
    }

    /// Deterministic, model-free distractor selection: other candidates'
    /// answers, preferring ones of similar length to the correct answer (a
    /// weak but free proximity signal), excluding the card itself and any
    /// answer identical to the correct one. A `CardGenerator` can replace
    /// this with semantically-chosen distractors later without changing
    /// the round builder's shape.
    /// The statement a true/false question shows, and whether it's true.
    /// A false one needs some other card's answer to show; with none to
    /// borrow the statement is always the true one. Showing the correct
    /// answer and keying it "False" -- what the old fallback did -- marked a
    /// student wrong for answering correctly.
    public static func trueFalseStatement<R: RandomNumberGenerator>(
        for candidate: Candidate, in pool: [Candidate], using rng: inout R
    ) -> (statement: String, isTrue: Bool) {
        if Bool.random(using: &rng),
           let wrong = distractors(for: candidate, in: pool, count: 1, using: &rng).first {
            return (wrong, false)
        }
        return (candidate.back, true)
    }

    public static func distractors<R: RandomNumberGenerator>(
        for candidate: Candidate, in pool: [Candidate], count: Int, using rng: inout R
    ) -> [String] {
        // One per distinct answer: two cards with the same back would
        // otherwise show the same option twice.
        var seen: Set<String> = [AnswerGrading.normalize(candidate.back)]
        let others = pool.filter {
            $0.cardId != candidate.cardId && seen.insert(AnswerGrading.normalize($0.back)).inserted
        }
        guard !others.isEmpty else { return [] }
        let targetLength = candidate.back.count
        let ranked = others.sorted { abs($0.back.count - targetLength) < abs($1.back.count - targetLength) }
        let nearPool = Array(ranked.prefix(max(count * 3, count)))
        return Array(nearPool.shuffled(using: &rng).prefix(count)).map(\.back)
    }

    // MARK: - Progress

    /// Applies one answer's outcome to a level/streak pair: promotion on
    /// correct (capped at mastered), demotion by one level on a miss
    /// (never below new).
    public static func advance(level: Level, consecutiveCorrect: Int, wasCorrect: Bool) -> (level: Level, consecutiveCorrect: Int) {
        // Familiar sits outside the 0...3 ladder (its raw value is 4), so
        // the arithmetic below would misread it: a right answer proves it,
        // a miss sends it to the gentlest rung.
        if level == .familiar {
            return wasCorrect ? (.mastered, consecutiveCorrect + 1) : (.recognition, 0)
        }
        if wasCorrect {
            let next = Level(rawValue: min(level.rawValue + 1, Level.mastered.rawValue)) ?? .mastered
            return (next, consecutiveCorrect + 1)
        } else {
            let previous = Level(rawValue: max(level.rawValue - 1, Level.new.rawValue)) ?? .new
            return (previous, 0)
        }
    }
}
