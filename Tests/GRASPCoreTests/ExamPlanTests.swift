import Testing
import Foundation
@testable import GRASPCore

@Suite("Exam plan")
struct ExamPlanTests {
    private func standing(due: Int = 0, active: Int = 50, weak: Int = 0, problems: Int = 0, since: Int? = nil) -> ExamPlan.Standing {
        .init(dueCards: due, activeCards: active, weakCards: weak, savedProblems: problems, daysSinceTest: since)
    }

    @Test("two weeks out with cards due: just review")
    func farOut() {
        #expect(ExamPlan.steps(daysAway: 12, standing: standing(due: 8)).map(\.kind) == [.review])
        #expect(ExamPlan.steps(daysAway: 12, standing: standing(due: 0)).map(\.kind) == [.learn])
        #expect(ExamPlan.steps(daysAway: 20, standing: standing(due: 8)).isEmpty)
    }

    @Test("inside a week adds tests, weak spots, and inside three days problems")
    func closing() {
        #expect(ExamPlan.steps(daysAway: 6, standing: standing(due: 3, since: nil)).map(\.kind) == [.review, .test])
        #expect(ExamPlan.steps(daysAway: 6, standing: standing(due: 3, weak: 4, since: 0)).map(\.kind) == [.review, .weakSpots])
        #expect(ExamPlan.steps(daysAway: 3, standing: standing(due: 3, problems: 5, since: 1)).map(\.kind) == [.review, .problems])
        #expect(ExamPlan.steps(daysAway: 1, standing: standing(due: 0, problems: 5, since: 0)).map(\.kind) == [.problems, .rest])
    }

    @Test("no cards, no plan; exam day says to stop")
    func edges() {
        #expect(ExamPlan.steps(daysAway: 3, standing: standing(active: 0)).isEmpty)
        #expect(ExamPlan.steps(daysAway: 0, standing: standing(due: 9)).map(\.kind) == [.rest])
    }
}
