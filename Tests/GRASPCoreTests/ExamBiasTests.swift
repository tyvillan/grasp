import Testing
import Foundation
@testable import GRASPCore

@Suite("ExamBias")
struct ExamBiasTests {
    @Test("a due date before the exam is left untouched")
    func dueBeforeExamUnchanged() {
        let exam = Date().addingTimeInterval(30 * 86400)
        let due = Date().addingTimeInterval(10 * 86400)
        #expect(ExamBias.capDue(due, examDate: exam) == due)
    }

    @Test("a due date after the exam is capped to the day before")
    func dueAfterExamIsCapped() {
        let exam = Date().addingTimeInterval(10 * 86400)
        let due = Date().addingTimeInterval(30 * 86400)
        let capped = ExamBias.capDue(due, examDate: exam)
        #expect(capped == exam.addingTimeInterval(-86400))
    }

    @Test("inside the last day, a review still lands in the future and before the exam")
    func lastDayCapStaysAhead() {
        let now = Date()
        let exam = now.addingTimeInterval(20 * 3600)
        let capped = ExamBias.capDue(now.addingTimeInterval(3 * 86400), examDate: exam, now: now)
        #expect(capped > now)
        #expect(capped <= exam)
        #expect(capped == exam.addingTimeInterval(-6 * 3600))
    }

    @Test("an exam less than an hour away caps to the exam itself, never after it")
    func imminentExamCap() {
        let now = Date()
        let exam = now.addingTimeInterval(30 * 60)
        #expect(ExamBias.capDue(now.addingTimeInterval(86400), examDate: exam, now: now) == exam)
    }

    @Test("final week is true from 7 days out through the exam date")
    func finalWeekWindow() {
        let now = Date()
        #expect(ExamBias.isInFinalWeek(now: now, examDate: now.addingTimeInterval(7 * 86400)))
        #expect(ExamBias.isInFinalWeek(now: now, examDate: now.addingTimeInterval(1 * 86400)))
        #expect(ExamBias.isInFinalWeek(now: now, examDate: now))
    }

    @Test("more than 7 days out is not the final week")
    func notYetFinalWeek() {
        let now = Date()
        #expect(!ExamBias.isInFinalWeek(now: now, examDate: now.addingTimeInterval(8 * 86400)))
    }

    @Test("a past exam is not the final week")
    func pastExamIsNotFinalWeek() {
        let now = Date()
        #expect(!ExamBias.isInFinalWeek(now: now, examDate: now.addingTimeInterval(-1 * 86400)))
    }
}
