import Testing
import GRASPCore
@testable import GRASP

@Suite("Today's plan wording")
struct TodayPlanTests {
    @Test("an exam that covers only some decks says how many of the due cards it covers")
    func scoped() {
        #expect(TodayPlan.reviewTitle(due: 139, courseDue: 155, examNoun: "midterm") == "Review 139 of 155 due for the midterm")
    }

    @Test("when everything due is in scope it is the plain wording")
    func everything() {
        #expect(TodayPlan.reviewTitle(due: 20, courseDue: 20, examNoun: "final") == "Review 20 due cards")
        #expect(TodayPlan.reviewTitle(due: 1, courseDue: 1, examNoun: "exam") == "Review 1 due card")
        // More in scope than the course total (decks counted twice) never reads as "of fewer".
        #expect(TodayPlan.reviewTitle(due: 30, courseDue: 12, examNoun: "exam") == "Review 30 due cards")
    }

    @Test("the exam noun comes from the title, then the kind")
    func noun() {
        #expect(TodayPlan.examNoun(title: "COP 3275C Midterm Exam", kind: .exam) == "midterm")
        #expect(TodayPlan.examNoun(title: "ECO 2023 Final", kind: .exam) == "final")
        #expect(TodayPlan.examNoun(title: "Module 3 Quiz (Ch. 5)", kind: .quiz) == "quiz")
        #expect(TodayPlan.examNoun(title: "Unit test", kind: .exam) == "exam")
    }
}
