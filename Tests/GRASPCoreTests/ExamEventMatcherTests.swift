import Testing
import Foundation
@testable import GRASPCore

@Suite("ExamEventMatcher")
struct ExamEventMatcherTests {
    private let courses: [(id: String, name: String, code: String?)] = [
        (id: "econ", name: "Principles of Economics", code: "ECON 201"),
        (id: "swe", name: "Intro to Software Design", code: "COP 3014"),
        (id: "writing", name: "College Writing", code: nil),
    ]

    @Test("exam-shaped titles are recognized, with quizzes kept distinct")
    func recognizesExams() {
        #expect(ExamEventMatcher.examKind(forTitle: "ECON 201 Midterm") == .exam)
        #expect(ExamEventMatcher.examKind(forTitle: "Final Exam - Software Design") == .exam)
        #expect(ExamEventMatcher.examKind(forTitle: "COP 3014 Quiz 4") == .quiz)
    }

    @Test("ordinary calendar entries are not exams")
    func ignoresNonExams() {
        #expect(ExamEventMatcher.examKind(forTitle: "Dentist") == nil)
        #expect(ExamEventMatcher.examKind(forTitle: "ECON 201 lecture") == nil)
        #expect(ExamEventMatcher.examKind(forTitle: "Coffee with Sam") == nil)
    }

    /// A bare substring check would misfire here: "exam" inside "example",
    /// "test" inside "contest"/"latest", "final" inside "finally". None of
    /// these titles are exams, but they'd have matched before this was a
    /// whole-word check.
    @Test("exam-shaped substrings inside ordinary words are not exams")
    func ignoresSubstringFalsePositives() {
        #expect(ExamEventMatcher.examKind(forTitle: "Example Set 3 Due") == nil)
        #expect(ExamEventMatcher.examKind(forTitle: "Latest Reading Assignment") == nil)
        #expect(ExamEventMatcher.examKind(forTitle: "Contest Signup") == nil)
        #expect(ExamEventMatcher.examKind(forTitle: "Finally Submitting Project") == nil)
    }

    /// The room name "Study Hall" must not veto a title that is otherwise
    /// unambiguously "Final Exam" -- the preparation-phrase list exists to
    /// catch review *sessions*, not to blank out any exam whose location
    /// happens to contain "study".
    @Test("a real exam is still recognized when its location mentions study")
    func realExamSurvivesStudyLocation() {
        #expect(ExamEventMatcher.examKind(forTitle: "Final Exam — Study Hall B12") == .exam)
    }

    /// The failure this prevents: a calendar full of "exam review session"
    /// entries would otherwise each create a second exam date, and FSRS
    /// would start capping intervals toward a study session rather than
    /// the real test.
    @Test("preparing for an exam is not itself an exam")
    func ignoresPreparation() {
        #expect(ExamEventMatcher.examKind(forTitle: "ECON 201 exam review session") == nil)
        #expect(ExamEventMatcher.examKind(forTitle: "Study group for the midterm") == nil)
        #expect(ExamEventMatcher.examKind(forTitle: "Office hours before the test") == nil)
        #expect(ExamEventMatcher.examKind(forTitle: "Practice test") == nil)
    }

    /// "study" and "prep" alone are deliberately not on the preparation
    /// list (see its doc comment) -- they're common enough in a real
    /// exam's own title or location that vetoing on them costs more real
    /// exams than the review-session titles it was meant to catch.
    @Test("bare 'study' or 'prep' alongside an exam word does not veto it")
    func bareStudyOrPrepDoesNotVeto() {
        #expect(ExamEventMatcher.examKind(forTitle: "Study for final") == .exam)
        #expect(ExamEventMatcher.examKind(forTitle: "Midterm prep") == .exam)
    }

    @Test("a course code in the title picks the course, however it's spaced")
    func matchesByCode() {
        #expect(ExamEventMatcher.matchCourse(title: "ECON 201 Midterm", courses: courses) == "econ")
        #expect(ExamEventMatcher.matchCourse(title: "econ201 final", courses: courses) == "econ")
        #expect(ExamEventMatcher.matchCourse(title: "Exam: COP-3014", courses: courses) == "swe")
    }

    /// The expensive mistake: attaching an exam to the wrong course also
    /// attaches its interval capping to the wrong cards. An unrecognized
    /// code must stay unmatched rather than fall through to a fuzzy
    /// name match that happens to score well.
    @Test("a code for some other class does not fall through to a name match")
    func unknownCodeStaysUnmatched() {
        #expect(ExamEventMatcher.matchCourse(title: "ECON 202 Midterm", courses: courses) == nil)
        #expect(ExamEventMatcher.matchCourse(title: "PSY 101 final", courses: courses) == nil)
    }

    @Test("a course name written out in the title matches it")
    func matchesByName() {
        #expect(ExamEventMatcher.matchCourse(title: "College Writing final", courses: courses) == "writing")
        #expect(
            ExamEventMatcher.matchCourse(title: "Intro to Software Design midterm", courses: courses) == "swe"
        )
    }

    @Test("an unrelated title matches nothing")
    func noMatch() {
        #expect(ExamEventMatcher.matchCourse(title: "Driving test", courses: courses) == nil)
    }

    @Test("course codes are read out of surrounding text")
    func extractsCodes() {
        #expect(ExamEventMatcher.courseCode(in: "ECON 201 Midterm") == "econ201")
        #expect(ExamEventMatcher.courseCode(in: "midterm for MAC-2311!") == "mac2311")
        #expect(ExamEventMatcher.courseCode(in: "no code here") == nil)
    }
}

@Suite("StudyPlanner")
struct StudyPlannerTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private static func exam(inDays days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: start)!
    }

    @Test("a deck is spread across the days before the exam, ending in a full review")
    func spreadsDeckAcrossDays() {
        let blocks = StudyPlanner.plan(
            cardCount: 120, from: Self.start, examDate: Self.exam(inDays: 7), calendar: Self.calendar
        )
        #expect(blocks.count == 7)  // 6 days of new material + the final review
        #expect(blocks.last?.isFinalReview == true)
        #expect(blocks.last?.cardCount == 120)

        let newMaterial = blocks.filter { !$0.isFinalReview }
        #expect(newMaterial.reduce(0) { $0 + $1.cardCount } == 120)
        #expect(newMaterial.allSatisfy { $0.cardCount == 20 })
    }

    @Test("a normally-sized deck stays under the daily cap")
    func capsDailyLoadWhenThereIsRoom() {
        let blocks = StudyPlanner.plan(
            cardCount: 120, from: Self.start, examDate: Self.exam(inDays: 7), calendar: Self.calendar
        )
        #expect(blocks.filter { !$0.isFinalReview }.allSatisfy { $0.cardCount <= StudyPlanner.maxCardsPerDay })
    }

    /// The bug this guards: capping every day at `maxCardsPerDay` when the
    /// deck doesn't fit in `studyDays * maxCardsPerDay` used to just drop
    /// the remainder -- a 900-card deck three days out silently planned
    /// for only 120 of them. Every card must land in some block, even if
    /// that means the last day runs over the ordinary daily cap.
    @Test("a deck too big for the days available still gets every card placed somewhere")
    func neverDropsCardsWhenSqueezed() {
        let blocks = StudyPlanner.plan(
            cardCount: 900, from: Self.start, examDate: Self.exam(inDays: 3), calendar: Self.calendar
        )
        let newMaterial = blocks.filter { !$0.isFinalReview }
        #expect(newMaterial.reduce(0) { $0 + $1.cardCount } == 900)
    }

    @Test("an exam tomorrow gets the one day it has")
    func examTomorrow() {
        let blocks = StudyPlanner.plan(
            cardCount: 40, from: Self.start, examDate: Self.exam(inDays: 1), calendar: Self.calendar
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].isFinalReview == false)
    }

    @Test("nothing to plan yields no plan rather than a bad one")
    func emptyPlans() {
        #expect(StudyPlanner.plan(
            cardCount: 0, from: Self.start, examDate: Self.exam(inDays: 7), calendar: Self.calendar
        ).isEmpty)
        #expect(StudyPlanner.plan(
            cardCount: 50, from: Self.start, examDate: Self.exam(inDays: 0), calendar: Self.calendar
        ).isEmpty)
        #expect(StudyPlanner.plan(
            cardCount: 50, from: Self.start, examDate: Self.exam(inDays: -3), calendar: Self.calendar
        ).isEmpty)
    }

    @Test("blocks land on consecutive days starting today")
    func blocksAreConsecutive() {
        let blocks = StudyPlanner.plan(
            cardCount: 60, from: Self.start, examDate: Self.exam(inDays: 4), calendar: Self.calendar
        )
        let expectedFirst = Self.calendar.startOfDay(for: Self.start)
        #expect(blocks.first?.day == expectedFirst)
        for (offset, block) in blocks.enumerated() {
            let expected = Self.calendar.date(byAdding: .day, value: offset, to: expectedFirst)
            #expect(block.day == expected)
        }
    }
}
