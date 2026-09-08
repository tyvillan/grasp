import Testing
import Foundation
@testable import GRASPCore

/// Reference vectors ported from the vendored (but unusable-as-a-dependency,
/// see FSRS.swift's header comment) swift-fsrs package's own test suite --
/// `FSRSV5Tests.swift` and `FSRSDefaultTests.swift` -- so this hand-rolled
/// port is checked against known-good published output, not just its own
/// internal consistency.
@Suite("FSRS")
struct FSRSTests {
    /// The custom weight set FSRSV5Tests.testFirstRepeat uses (not the
    /// production defaults) -- kept exactly as in the reference so its
    /// asserted numbers carry over unchanged.
    static let referenceWeights: [Double] = [
        0.4197, 1.1869, 3.0412, 15.2441, 7.1434, 0.6477, 1.0007, 0.0674, 1.6597,
        0.1712, 1.1178, 2.0225, 0.0904, 0.3025, 2.1214, 0.2498, 2.9466, 0.4891, 0.6468,
    ]

    private static func newCardSnapshot() -> FSRS.Snapshot {
        FSRS.Snapshot(stability: 0, difficulty: 0, reps: 0, lapses: 0, state: .new, lastReview: nil)
    }

    @Test("matches the published default weight set")
    func matchesDefaultWeights() {
        let expected: [Double] = [
            0.4072, 1.1829, 3.1262, 15.4722, 7.2102, 0.5316, 1.0651, 0.0234, 1.616,
            0.1544, 1.0824, 1.9813, 0.0953, 0.2975, 2.2042, 0.2407, 2.9466, 0.5034, 0.6567,
        ]
        #expect(FSRS.defaultWeights == expected)
    }

    @Test("first review of a new card matches FSRSV5Tests.testFirstRepeat")
    func firstRepeatMatchesReference() {
        let now = Date()
        var stabilities: Set<Double> = []
        var difficulties: Set<Double> = []
        var reps: Set<Int> = []
        var lapses: Set<Int> = []
        var scheduledDays: Set<Int> = []
        var states: Set<FSRS.CardState> = []

        for grade in FSRS.Grade.allCases {
            let result = FSRS.schedule(Self.newCardSnapshot(), grade: grade, now: now, weights: Self.referenceWeights)
            stabilities.insert((result.stability * 10000).rounded() / 10000)
            difficulties.insert((result.difficulty * 1e8).rounded() / 1e8)
            reps.insert(result.reps)
            lapses.insert(result.lapses)
            scheduledDays.insert(Int(result.scheduledDays))
            states.insert(result.state)
        }

        #expect(stabilities == [0.4197, 1.1869, 3.0412, 15.2441])
        #expect(difficulties == [7.1434, 6.23225985, 4.49094334, 1.16304343])
        #expect(reps == [1])
        #expect(lapses == [0])
        #expect(scheduledDays == [0, 15])
        #expect(states == [.learning, .review])
    }

    @Test("retrievability at a card's own due date matches RetrievabilityTests (default weights)")
    func retrievabilityMatchesReference() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        let reviewedAt = df.date(from: "2023-12-01 04:05:00")!

        // Easy on a brand-new card: elapsedDays at the resulting due date
        // equals the (whole-day, floored) scheduled interval, and
        // retrievability there should land at ~90.26% per the reference.
        let result = FSRS.schedule(Self.newCardSnapshot(), grade: .easy, now: reviewedAt)
        #expect(result.state == .review)
        let elapsedAtDue = (result.due.timeIntervalSince(reviewedAt) / 86400).rounded(.down)
        let r = FSRS.retrievability(elapsedDays: elapsedAtDue, stability: result.stability)
        #expect(abs(r - 0.9026208) < 0.0001)
    }

    @Test("a new card returns zero retrievability")
    func newCardHasZeroRetrievability() {
        #expect(FSRS.retrievability(elapsedDays: 0, stability: 0) == 0)
    }

    @Test("repeated lapses shorten the next interval relative to a clean run")
    func lapsesShortenSubsequentIntervals() {
        let now = Date()
        let clean = FSRS.schedule(Self.newCardSnapshot(), grade: .good, now: now)
        let review1 = FSRS.schedule(
            FSRS.Snapshot(stability: clean.stability, difficulty: clean.difficulty, reps: clean.reps,
                          lapses: clean.lapses, state: clean.state, lastReview: now),
            grade: .good, now: now.addingTimeInterval(1 * 86400)
        )
        // Diverge: one path keeps passing, the other lapses once then
        // recovers with a "good" -- the lapsed path's next interval should
        // be shorter than the clean path's at the same rep count.
        let passing = FSRS.schedule(
            FSRS.Snapshot(stability: review1.stability, difficulty: review1.difficulty, reps: review1.reps,
                          lapses: review1.lapses, state: review1.state, lastReview: now.addingTimeInterval(1 * 86400)),
            grade: .good, now: now.addingTimeInterval(1 * 86400 + review1.scheduledDays * 86400)
        )
        let lapsed = FSRS.schedule(
            FSRS.Snapshot(stability: review1.stability, difficulty: review1.difficulty, reps: review1.reps,
                          lapses: review1.lapses, state: review1.state, lastReview: now.addingTimeInterval(1 * 86400)),
            grade: .again, now: now.addingTimeInterval(1 * 86400 + review1.scheduledDays * 86400)
        )
        #expect(lapsed.state == .relearning)
        #expect(lapsed.lapses == review1.lapses + 1)
        #expect(lapsed.scheduledDays < passing.scheduledDays)
    }
}
