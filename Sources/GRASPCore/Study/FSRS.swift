import Foundation

/// FSRS-5 (the "short-term" scheduling variant, i.e. same-day learning
/// steps enabled), hand-rolled rather than taken as a dependency.
///
/// A `swift-fsrs` package was pinned during early scaffolding, but every
/// method and initializer in its public types turned out to be `internal`
/// -- confirmed by a failing build probe (`'FSRSDefaults' initializer is
/// inaccessible due to 'internal' protection level`), not assumed. Its
/// entire functional API is unusable from outside its own module, so it
/// carries no runtime dependency here. Its vendored source (and its own
/// test suite's reference vectors) was used only as a reading reference
/// for the published formulas -- see `FSRSTests.swift` for the fixtures
/// ported into this module's tests.
///
/// Reference: https://github.com/open-spaced-repetition/fsrs4anki/wiki/The-Algorithm
public enum FSRS {
    /// The published FSRS-5 default parameters (19 weights).
    public static let defaultWeights: [Double] = [
        0.4072, 1.1829, 3.1262, 15.4722, 7.2102, 0.5316, 1.0651, 0.0234, 1.616,
        0.1544, 1.0824, 1.9813, 0.0953, 0.2975, 2.2042, 0.2407, 2.9466, 0.5034, 0.6567,
    ]
    public static let requestRetention = 0.9
    public static let maximumInterval = 36500.0

    private static let decay = -0.5
    private static let factor = 19.0 / 81.0

    /// $$I(r,s) = (r^{1/DECAY} - 1) / FACTOR$$ evaluated once at
    /// `requestRetention` -- multiplying a stability by this converts it to
    /// a day interval at the target retention.
    private static func intervalModifier() -> Double {
        (pow(requestRetention, 1 / decay) - 1) / factor
    }

    public enum Grade: Int, Sendable, CaseIterable {
        case again = 1, hard = 2, good = 3, easy = 4
    }

    public enum CardState: Int, Sendable {
        case new = 0, learning = 1, review = 2, relearning = 3
    }

    /// The scheduler fields this algorithm reads and produces, independent
    /// of how the caller persists them (mirrors `Card`'s own columns so the
    /// call site in `AppStore` is a direct field-for-field mapping).
    public struct Snapshot: Sendable {
        public var stability: Double
        public var difficulty: Double
        public var reps: Int
        public var lapses: Int
        public var state: CardState
        public var lastReview: Date?

        public init(stability: Double, difficulty: Double, reps: Int, lapses: Int,
                    state: CardState, lastReview: Date?) {
            self.stability = stability; self.difficulty = difficulty
            self.reps = reps; self.lapses = lapses
            self.state = state; self.lastReview = lastReview
        }
    }

    public struct Result: Sendable, Equatable {
        public var due: Date
        public var stability: Double
        public var difficulty: Double
        public var elapsedDays: Double
        public var scheduledDays: Double
        public var reps: Int
        public var lapses: Int
        public var state: CardState
    }

    // MARK: - Core formulas (ported 1:1 from FSRSAlgorithm.swift)

    private static func initStability(_ g: Grade, _ w: [Double]) -> Double {
        max(w[g.rawValue - 1], 0.1)
    }

    private static func constrainDifficulty(_ d: Double) -> Double {
        min(max(d, 1), 10)
    }

    private static func meanReversion(_ initValue: Double, _ current: Double, _ w: [Double]) -> Double {
        w[7] * initValue + (1 - w[7]) * current
    }

    private static func nextDifficulty(_ d: Double, _ g: Grade, _ w: [Double]) -> Double {
        // FSRS-5's linear damping: the closer difficulty is to its ceiling
        // of 10, the less a grade moves it. Without it difficulty ran up to
        // 10 and pinned there after a few lapses.
        let delta = -w[6] * (Double(g.rawValue) - 3)
        let next = d + delta * (10 - d) / 9
        let easyD0 = constrainDifficulty(w[4] - exp((Double(Grade.easy.rawValue) - 1) * w[5]) + 1)
        return constrainDifficulty(meanReversion(easyD0, next, w))
    }

    private static func nextRecallStability(d: Double, s: Double, r: Double, g: Grade, _ w: [Double]) -> Double {
        let hardPenalty = g == .hard ? w[15] : 1
        let easyBonus = g == .easy ? w[16] : 1
        let value = s * (1 + exp(w[8]) * (11 - d) * pow(s, -w[9])
            * (exp((1 - r) * w[10]) - 1) * hardPenalty * easyBonus)
        return min(max(value, 0.01), 36500)
    }

    private static func nextForgetStability(d: Double, s: Double, r: Double, _ w: [Double]) -> Double {
        let value = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
        return min(max(value, 0.01), 36500)
    }

    private static func nextShortTermStability(_ s: Double, _ g: Grade, _ w: [Double]) -> Double {
        let value = s * exp(w[17] * (Double(g.rawValue) - 3 + w[18]))
        return min(max(value, 0.01), 36500)
    }

    /// $$R(t,S) = (1 + FACTOR \cdot t/S)^{DECAY}$$
    public static func retrievability(elapsedDays: Double, stability: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1 + (factor * elapsedDays) / stability, decay)
    }

    private static func nextIntervalDays(stability: Double) -> Double {
        min(max(1, (stability * intervalModifier()).rounded()), maximumInterval)
    }

    // MARK: - Scheduling entry point

    /// Schedules one grade against a card's current snapshot. `now` is both
    /// the review timestamp and the basis for `elapsedDays` (whole days
    /// since `lastReview`, floored -- matching the reference implementation
    /// rather than a fractional day count).
    public static func schedule(
        _ snapshot: Snapshot, grade: Grade, now: Date, weights: [Double] = defaultWeights
    ) -> Result {
        let elapsedDays: Double = {
            guard snapshot.state != .new, let lastReview = snapshot.lastReview else { return 0 }
            return max(0, (now.timeIntervalSince(lastReview) / 86400).rounded(.down))
        }()
        let reps = snapshot.reps + 1

        switch snapshot.state {
        case .new:
            return scheduleNew(grade: grade, now: now, reps: reps, lapses: snapshot.lapses, weights)
        case .learning, .relearning:
            return scheduleLearning(
                grade: grade, now: now, lastDifficulty: snapshot.difficulty, lastStability: snapshot.stability,
                elapsedDays: elapsedDays, reps: reps, lapses: snapshot.lapses,
                state: snapshot.state, weights
            )
        case .review:
            return scheduleReview(
                grade: grade, now: now, difficulty: snapshot.difficulty, stability: snapshot.stability,
                elapsedDays: elapsedDays, reps: reps, lapses: snapshot.lapses, weights
            )
        }
    }

    private static func minutes(_ n: Double, from now: Date) -> Date { now.addingTimeInterval(n * 60) }
    private static func days(_ n: Double, from now: Date) -> Date { now.addingTimeInterval(n * 86400) }

    private static func scheduleNew(
        grade: Grade, now: Date, reps: Int, lapses: Int, _ w: [Double]
    ) -> Result {
        let difficulty = constrainDifficulty(w[4] - exp((Double(grade.rawValue) - 1) * w[5]) + 1)
        let stability = initStability(grade, w)
        switch grade {
        case .again:
            return Result(due: minutes(1, from: now), stability: stability, difficulty: difficulty,
                          elapsedDays: 0, scheduledDays: 0, reps: reps, lapses: lapses, state: .learning)
        case .hard:
            return Result(due: minutes(5, from: now), stability: stability, difficulty: difficulty,
                          elapsedDays: 0, scheduledDays: 0, reps: reps, lapses: lapses, state: .learning)
        case .good:
            return Result(due: minutes(10, from: now), stability: stability, difficulty: difficulty,
                          elapsedDays: 0, scheduledDays: 0, reps: reps, lapses: lapses, state: .learning)
        case .easy:
            let interval = nextIntervalDays(stability: stability)
            return Result(due: days(interval, from: now), stability: stability, difficulty: difficulty,
                          elapsedDays: 0, scheduledDays: interval, reps: reps, lapses: lapses, state: .review)
        }
    }

    private static func scheduleLearning(
        grade: Grade, now: Date, lastDifficulty: Double, lastStability: Double,
        elapsedDays: Double, reps: Int, lapses: Int, state: CardState, _ w: [Double]
    ) -> Result {
        let difficulty = nextDifficulty(lastDifficulty, grade, w)
        let stability = nextShortTermStability(lastStability, grade, w)
        // Again or Hard keeps a relearning card relearning -- it had been
        // turned back into a first-time learner.
        switch grade {
        case .again:
            return Result(due: minutes(5, from: now), stability: stability, difficulty: difficulty,
                          elapsedDays: elapsedDays, scheduledDays: 0, reps: reps, lapses: lapses, state: state)
        case .hard:
            return Result(due: minutes(10, from: now), stability: stability, difficulty: difficulty,
                          elapsedDays: elapsedDays, scheduledDays: 0, reps: reps, lapses: lapses, state: state)
        case .good:
            let interval = nextIntervalDays(stability: stability)
            return Result(due: days(interval, from: now), stability: stability, difficulty: difficulty,
                          elapsedDays: elapsedDays, scheduledDays: interval, reps: reps, lapses: lapses, state: .review)
        case .easy:
            let goodStability = nextShortTermStability(lastStability, .good, w)
            let goodInterval = nextIntervalDays(stability: goodStability)
            let easyInterval = max(nextIntervalDays(stability: stability), goodInterval + 1)
            return Result(due: days(easyInterval, from: now), stability: stability, difficulty: difficulty,
                          elapsedDays: elapsedDays, scheduledDays: easyInterval, reps: reps, lapses: lapses, state: .review)
        }
    }

    private static func scheduleReview(
        grade: Grade, now: Date, difficulty: Double, stability: Double,
        elapsedDays: Double, reps: Int, lapses: Int, _ w: [Double]
    ) -> Result {
        let r = retrievability(elapsedDays: elapsedDays, stability: stability)

        let againDifficulty = nextDifficulty(difficulty, .again, w)
        let hardDifficulty = nextDifficulty(difficulty, .hard, w)
        let goodDifficulty = nextDifficulty(difficulty, .good, w)
        let easyDifficulty = nextDifficulty(difficulty, .easy, w)

        let againStability = nextForgetStability(d: difficulty, s: stability, r: r, w)
        let hardStability = nextRecallStability(d: difficulty, s: stability, r: r, g: .hard, w)
        let goodStability = nextRecallStability(d: difficulty, s: stability, r: r, g: .good, w)
        let easyStability = nextRecallStability(d: difficulty, s: stability, r: r, g: .easy, w)

        // Interval ordering guarantee: hard <= good <= easy, achieved by
        // clamping each interval against the others (matches
        // BasicScheduler.nextInterval in the reference) -- the stabilities
        // themselves are stored as computed above, unclamped.
        var hardInterval = nextIntervalDays(stability: hardStability)
        var goodInterval = nextIntervalDays(stability: goodStability)
        hardInterval = min(hardInterval, goodInterval)
        goodInterval = max(goodInterval, hardInterval + 1)
        let easyInterval = max(nextIntervalDays(stability: easyStability), goodInterval + 1)

        switch grade {
        case .again:
            return Result(due: minutes(5, from: now), stability: againStability, difficulty: againDifficulty,
                          elapsedDays: elapsedDays, scheduledDays: 0, reps: reps, lapses: lapses + 1, state: .relearning)
        case .hard:
            return Result(due: days(hardInterval, from: now), stability: hardStability, difficulty: hardDifficulty,
                          elapsedDays: elapsedDays, scheduledDays: hardInterval, reps: reps, lapses: lapses, state: .review)
        case .good:
            return Result(due: days(goodInterval, from: now), stability: goodStability, difficulty: goodDifficulty,
                          elapsedDays: elapsedDays, scheduledDays: goodInterval, reps: reps, lapses: lapses, state: .review)
        case .easy:
            return Result(due: days(easyInterval, from: now), stability: easyStability, difficulty: easyDifficulty,
                          elapsedDays: elapsedDays, scheduledDays: easyInterval, reps: reps, lapses: lapses, state: .review)
        }
    }
}
