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
        /// Why the answer is right, for an AI-written question that came
        /// with one (the code and problem kinds carry theirs inside).
        public var explanation: String?
        /// An understood card brought back to check it is still known.
        public var isComeback = false
        /// For a comeback: the card was understood (a check), as opposed
        /// to one still being learned that you answered before.
        public var comebackWasUnderstood = false
        /// The explanation to show under "Why", whichever kind this is.
        public var whyText: String? { explanation ?? code?.explanation ?? problem?.explanation }

        /// Whether "I actually got this right" may be offered. Text matching
        /// is a poor judge of a loaded free-response answer, but blanks,
        /// predicted output and a bug's line number are compared exactly
        /// against a checked answer, so an override there only turns a real
        /// miss into a hit. `completeFunction` stays overridable: on a device
        /// that cannot run code the student marks it themselves.
        public var allowsMarkCorrect: Bool {
            guard type == .written else { return false }
            guard let code else { return true }
            return code.kind == .completeFunction
        }

        public init(id: String? = nil, cardId: String?, prompt: String, correctAnswer: String, type: QuestionType,
                    choices: [String]? = nil, statement: String? = nil, statementIsTrue: Bool? = nil,
                    code: CodeQuestion? = nil, problem: ProblemQuestion? = nil, explanation: String? = nil) {
            self.explanation = explanation
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
        /// When the card was last answered, and its signed run (rights in a
        /// row, or a remembered miss). Together they say when an understood
        /// card is due to be checked again.
        public var lastSeenAt: Date?
        public var consecutiveCorrect: Int

        public init(cardId: String, front: String, back: String, level: Level,
                    lastSeenAt: Date? = nil, consecutiveCorrect: Int = 0) {
            self.cardId = cardId; self.front = front; self.back = back; self.level = level
            self.lastSeenAt = lastSeenAt; self.consecutiveCorrect = consecutiveCorrect
        }
    }

    // MARK: - Comebacks

    /// How many of a round's questions are reserved for cards that are due
    /// to come back: understood cards due for a check, and cards still being
    /// learned that you answered before and have rested long enough.
    public static let comebackSlots = 3

    /// How long an understood card may rest before it is checked: a day,
    /// then 3, 7 and 14 as it keeps passing. A remembered miss counts as
    /// the shortest rest.
    public static func checkInterval(run: Int) -> TimeInterval {
        let days: Double
        switch max(run, 0) {
        case 0, 1: days = 1
        case 2: days = 3
        case 3: days = 7
        default: days = 14
        }
        return days * 86_400
    }

    /// The shorter rest for a card still being learned: 20 minutes after a
    /// first right answer (so it comes back later in the same sitting), a day
    /// after two in a row, 3 days after three. A remembered miss is back in
    /// 10 minutes.
    public static func learningRest(run: Int) -> TimeInterval {
        switch run {
        case ..<0: return 10 * 60
        case 0, 1: return 20 * 60
        case 2: return 86_400
        default: return 3 * 86_400
        }
    }

    /// When a card is due to come back, nil if it has no answer on record
    /// (nothing to measure from).
    public static func dueDate(of candidate: Candidate) -> Date? {
        guard let seen = candidate.lastSeenAt else { return nil }
        let rest = candidate.level == .mastered
            ? checkInterval(run: candidate.consecutiveCorrect)
            : learningRest(run: candidate.consecutiveCorrect)
        return seen.addingTimeInterval(rest)
    }

    /// A card is due once its rest is over. A card with no recorded answer
    /// is never due.
    public static func isDueForCheck(_ candidate: Candidate, now: Date) -> Bool {
        guard let due = dueDate(of: candidate) else { return false }
        return now >= due
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
    ///
    /// Comebacks: up to `comebackSlots` of the round's questions are
    /// cards you answered before that are due again (see `isDueForCheck`),
    /// most overdue first, mixed in at random places. A right answer on one
    /// pushes its next check further out; a miss follows the two-misses
    /// rule. This is how an individual card keeps advancing and is
    /// re-verified without waiting for the whole deck.
    public static func buildRound<R: RandomNumberGenerator>(
        from candidates: [Candidate], using rng: inout R,
        now: Date = Date(), comebackSlots: Int = LearnEngine.comebackSlots
    ) -> [RoundQuestion] {
        let due = comebackSlots <= 0 ? [] : candidates
            .filter { isDueForCheck($0, now: now) }
            .sorted { (dueDate(of: $0) ?? .distantFuture) < (dueDate(of: $1) ?? .distantFuture) }
        let comebacks = Array(due.prefix(comebackSlots))
        let comebackIds = Set(comebacks.map(\.cardId))

        let unmastered = candidates.filter { $0.level != .mastered }
        var pool: [Candidate]
        if !candidates.isEmpty && Double(unmastered.count) / Double(candidates.count) <= randomReinforcementThreshold {
            pool = candidates.shuffled(using: &rng)
        } else {
            pool = unmastered
        }
        pool.removeAll { comebackIds.contains($0.cardId) }
        let selected = Array(pool.prefix(max(roundSize - comebacks.count, 0)))
        var questions = selected.enumerated().map { index, candidate in
            question(for: candidate, allCandidates: candidates, ordinal: index, using: &rng)
        }
        for candidate in comebacks {
            var q = question(for: candidate, allCandidates: candidates, ordinal: 0, using: &rng)
            q.isComeback = true
            q.comebackWasUnderstood = candidate.level == .mastered
            questions.insert(q, at: Int.random(in: 0...questions.count, using: &rng))
        }
        return questions
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
    /// correct (capped at mastered). A miss does not drop the card by
    /// itself: the first miss only remembers it (the streak goes to -1), and
    /// a second miss in a row drops it one level (never below new) and
    /// starts the streak over. A right answer in between clears the miss.
    ///
    /// `consecutiveCorrect` is a signed run: positive is right answers in a
    /// row, negative is misses in a row. An older client reads a negative
    /// run as a streak and still works.
    public static func advance(level: Level, consecutiveCorrect: Int, wasCorrect: Bool) -> (level: Level, consecutiveCorrect: Int) {
        if wasCorrect {
            let run = max(consecutiveCorrect, 0) + 1
            // Familiar sits outside the 0...3 ladder (its raw value is 4),
            // so a right answer proves it outright.
            if level == .familiar { return (.mastered, run) }
            let next = Level(rawValue: min(level.rawValue + 1, Level.mastered.rawValue)) ?? .mastered
            return (next, run)
        }
        // A miss. The first one is remembered; the second in a row drops.
        guard consecutiveCorrect < 0 else { return (level, -1) }
        if level == .familiar { return (.recognition, 0) }
        let previous = Level(rawValue: max(level.rawValue - 1, Level.new.rawValue)) ?? .new
        return (previous, 0)
    }
}
