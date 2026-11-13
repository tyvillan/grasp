import Testing
import Foundation
import GRASPCore
@testable import GRASP

@Suite("Card row status word")
struct CardRowStatusTests {
    private func card(status: CardStatus = .active, reps: Int = 0, lastReview: Date? = nil, due: Date = Date()) -> Card {
        var c = Card(materialId: nil, front: "f", back: "b", origin: .manual, status: status, due: due)
        c.reps = reps
        c.lastReview = lastReview
        return c
    }

    @Test("a never-reviewed card says New, unless it has Learn progress")
    func newWord() {
        #expect(CardRowStatus.text(for: card()) == "New")
        #expect(CardRowStatus.text(for: card(), hasProgress: false) == "New")
        #expect(CardRowStatus.text(for: card(), hasProgress: true) == "")
    }

    @Test("due words and Draft are unchanged by progress")
    func otherWords() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let inThree = Calendar.current.date(byAdding: .day, value: 3, to: now)!
        #expect(CardRowStatus.text(for: card(reps: 2, lastReview: yesterday, due: yesterday), hasProgress: true, now: now) == "Overdue")
        #expect(CardRowStatus.text(for: card(reps: 2, lastReview: yesterday, due: now), hasProgress: true, now: now) == "Due today")
        #expect(CardRowStatus.text(for: card(reps: 2, lastReview: yesterday, due: inThree), hasProgress: true, now: now) == "in 3d")
        #expect(CardRowStatus.text(for: card(status: .draft), hasProgress: true) == "Draft")
        #expect(CardRowStatus.text(for: card(status: .suspended), hasProgress: true) == "Suspended")
    }
}
