import Testing
import Foundation
@testable import GRASPCore

@Suite("Learn comebacks")
struct LearnComebackTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func day(_ n: Double) -> TimeInterval { n * 86_400 }

    private func card(_ id: String, _ level: LearnEngine.Level, seenDaysAgo: Double? = nil, run: Int = 1)
        -> LearnEngine.Candidate {
        LearnEngine.Candidate(cardId: id, front: "front \(id)", back: "back \(id)", level: level,
                              lastSeenAt: seenDaysAgo.map { now.addingTimeInterval(-day($0)) },
                              consecutiveCorrect: run)
    }

    @Test("the rest grows with each success: a day, then 3, 7 and 14")
    func intervals() {
        #expect(LearnEngine.checkInterval(run: 0) == day(1))
        #expect(LearnEngine.checkInterval(run: 1) == day(1))
        #expect(LearnEngine.checkInterval(run: 2) == day(3))
        #expect(LearnEngine.checkInterval(run: 3) == day(7))
        #expect(LearnEngine.checkInterval(run: 4) == day(14))
        #expect(LearnEngine.checkInterval(run: 40) == day(14))
        // A remembered miss is the shortest rest.
        #expect(LearnEngine.checkInterval(run: -1) == day(1))
    }

    @Test("only an understood card whose rest is over is due; one with no answer on record never is")
    func due() {
        #expect(LearnEngine.isDueForCheck(card("a", .mastered, seenDaysAgo: 1.5, run: 1), now: now))
        #expect(!LearnEngine.isDueForCheck(card("b", .mastered, seenDaysAgo: 0.5, run: 1), now: now))
        #expect(!LearnEngine.isDueForCheck(card("c", .mastered, seenDaysAgo: 5, run: 3), now: now))
        #expect(LearnEngine.isDueForCheck(card("d", .mastered, seenDaysAgo: 8, run: 3), now: now))
        #expect(!LearnEngine.isDueForCheck(card("e", .recall, seenDaysAgo: 30, run: 5), now: now))
        #expect(!LearnEngine.isDueForCheck(card("f", .mastered, seenDaysAgo: nil), now: now))
    }

    @Test("a round carries up to two comebacks, most overdue first chosen, among the cards still being learned")
    func roundHasComebacks() {
        var candidates = (0..<10).map { card("n\($0)", .recognition) }
        candidates += [card("m1", .mastered, seenDaysAgo: 2, run: 1),   // 1 day overdue
                       card("m2", .mastered, seenDaysAgo: 20, run: 4),  // 6 days overdue
                       card("m3", .mastered, seenDaysAgo: 9, run: 2),   // 6 days overdue, shorter rest
                       card("m4", .mastered, seenDaysAgo: 0.2, run: 1)] // not due
        var rng = SystemRandomNumberGenerator()
        let round = LearnEngine.buildRound(from: candidates, using: &rng, now: now)
        #expect(round.count == LearnEngine.roundSize)
        let comebacks = round.filter(\.isComeback)
        #expect(comebacks.count == 2)
        let ids = Set(comebacks.compactMap(\.cardId))
        #expect(ids == ["m3", "m2"] || ids == ["m2", "m3"])
        #expect(!ids.contains("m4"))
        // A checked card is asked as a typed answer, and not asked twice.
        #expect(comebacks.allSatisfy { $0.type == .written })
        #expect(Set(round.compactMap(\.cardId)).count == round.count)
    }

    @Test("with nothing due the round is what it was")
    func nothingDue() {
        var candidates = (0..<10).map { card("n\($0)", .new) }
        candidates += [card("m", .mastered, seenDaysAgo: 0.1)]
        var rng = SystemRandomNumberGenerator()
        let round = LearnEngine.buildRound(from: candidates, using: &rng, now: now)
        #expect(round.filter(\.isComeback).isEmpty)
        #expect(round.count == LearnEngine.roundSize)
        #expect(!round.contains { $0.cardId == "m" })
    }

    @Test("a focus round asks no comebacks")
    func focusRound() {
        let candidates = [card("a", .recognition), card("m", .mastered, seenDaysAgo: 30)]
        var rng = SystemRandomNumberGenerator()
        let round = LearnEngine.buildRound(from: candidates, using: &rng, now: now, comebackSlots: 0)
        #expect(round.filter(\.isComeback).isEmpty)
    }

    @Test("a deck that is all understood still gives a round, with the due ones as comebacks")
    func allUnderstood() {
        let candidates = (0..<9).map { card("m\($0)", .mastered, seenDaysAgo: $0 < 4 ? 3 : 0.1, run: 1) }
        var rng = SystemRandomNumberGenerator()
        let round = LearnEngine.buildRound(from: candidates, using: &rng, now: now)
        #expect(!round.isEmpty)
        #expect(round.filter(\.isComeback).count == 2)
    }

    @Test("a comeback that is answered right is pushed further out, and a miss is only remembered")
    func comebackOutcomes() {
        let right = LearnEngine.advance(level: .mastered, consecutiveCorrect: 2, wasCorrect: true)
        #expect(right.level == .mastered)
        #expect(LearnEngine.checkInterval(run: right.consecutiveCorrect) == day(7))
        let miss = LearnEngine.advance(level: .mastered, consecutiveCorrect: 2, wasCorrect: false)
        #expect(miss.level == .mastered)
        #expect(LearnEngine.checkInterval(run: miss.consecutiveCorrect) == day(1))
        let twice = LearnEngine.advance(level: .mastered, consecutiveCorrect: miss.consecutiveCorrect, wasCorrect: false)
        #expect(twice.level == .recall)
    }
}
