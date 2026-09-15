import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("CalendarEvent")
struct CalendarEventTests {
    /// Fixed calendar and instant: countdown math is all calendar-day
    /// arithmetic, which is exactly the kind of thing that passes locally
    /// and fails on a machine in another timezone (or the morning the
    /// clocks change) if the test leans on `.current` and `Date()`.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13 UTC

    private static func event(daysFromNow days: Int, hour: Int = 9) -> CalendarEvent {
        let day = calendar.date(byAdding: .day, value: days, to: now)!
        let at = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        return CalendarEvent(title: "Midterm", startsAt: at)
    }

    @Test("countdown reads today, tomorrow, and a plain day count")
    func countdownPhrasing() {
        #expect(Self.event(daysFromNow: 0).countdownText(from: Self.now, calendar: Self.calendar) == "Today")
        #expect(Self.event(daysFromNow: 1).countdownText(from: Self.now, calendar: Self.calendar) == "Tomorrow")
        #expect(Self.event(daysFromNow: 4).countdownText(from: Self.now, calendar: Self.calendar) == "in 4 days")
    }

    /// The bug this guards: an exam at 9am tomorrow is under 24 hours away
    /// from an evening "now", so a plain `timeIntervalSince` would floor it
    /// to zero and announce it as happening today.
    @Test("an event less than 24 hours out but on the next day counts as tomorrow")
    func subDayIntervalStillCountsAsNextCalendarDay() {
        let tomorrowMorning = Self.event(daysFromNow: 1, hour: 9)
        #expect(tomorrowMorning.startsAt.timeIntervalSince(Self.now) < 86400)
        #expect(tomorrowMorning.daysAway(from: Self.now, calendar: Self.calendar) == 1)
    }

    @Test("a past event counts backwards")
    func pastEvents() {
        #expect(Self.event(daysFromNow: -1).countdownText(from: Self.now, calendar: Self.calendar) == "Yesterday")
        #expect(Self.event(daysFromNow: -3).countdownText(from: Self.now, calendar: Self.calendar) == "3 days ago")
    }

    /// Deadlines and study blocks share the calendar with exams but must
    /// never reach FSRS's interval capping -- a study block you scheduled
    /// is not a date every card in the course has to be ready for.
    @Test("only exams and quizzes are exam-like for scheduling")
    func examLikeKinds() {
        #expect(CalendarEventKind.examLike == [.exam, .quiz])
        #expect(!CalendarEventKind.examLike.contains(.deadline))
        #expect(!CalendarEventKind.examLike.contains(.study))
    }

    @Test("an event round-trips through the database, including a course-less study block")
    func roundTrip() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-calendar-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try GRASPDatabase(path: path)

        let block = CalendarEvent(
            kind: .study, title: "Review session", startsAt: Self.now,
            endsAt: Self.now.addingTimeInterval(3600), isAllDay: false
        )
        try database.queue.write { db in try block.insert(db) }

        let loaded = try database.queue.read { db in try CalendarEvent.fetchOne(db, key: block.id) }
        #expect(loaded?.kind == .study)
        #expect(loaded?.courseId == nil)
        #expect(loaded?.deckId == nil)
        #expect(loaded?.isAllDay == false)
        #expect(loaded?.endsAt != nil)
    }

    /// The v5 migration rewrites the old exams-only table. Real exam dates
    /// already set in someone's database drive FSRS biasing, so losing
    /// them silently would change how their cards are scheduled -- this
    /// walks a database up to the previous schema, plants an exam row the
    /// old way, and checks it survives the upgrade.
    @Test("the v5 migration carries existing exam rows into calendarEvent")
    func migrationPreservesExams() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-migrate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }

        let queue = try DatabaseQueue(path: path.path)
        let migrator = Schema.migrator()
        try migrator.migrate(queue, upTo: "v4_card_context_refinement")

        let examDate = Date(timeIntervalSince1970: 1_800_000_000)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO course (id, name, sortIndex, isArchived, createdAt, updatedAt) "
                    + "VALUES ('c1', 'Econ 201', 0, 0, ?, ?)",
                arguments: [Self.now, Self.now]
            )
            try db.execute(
                sql: "INSERT INTO exam (id, courseId, name, examDate) VALUES ('e1', 'c1', 'Midterm', ?)",
                arguments: [examDate]
            )
        }

        try migrator.migrate(queue)

        let carried = try queue.read { db in try CalendarEvent.fetchOne(db, key: "e1") }
        #expect(carried?.title == "Midterm")
        #expect(carried?.courseId == "c1")
        #expect(carried?.kind == .exam)
        #expect(carried?.isAllDay == true)
        #expect(carried?.startsAt == examDate)

        let oldTableGone = try queue.read { db in try db.tableExists("exam") == false }
        #expect(oldTableGone)
    }
}
