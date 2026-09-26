import Foundation
import GRDB

/// The calendar's reads and writes, shared by every app so they behave the
/// same everywhere. Moved out of the Mac's `AppStore` (`calendarEvents`,
/// `dailyCardLoad`, `add/update/deleteCalendarEvent`, `upcomingExams`,
/// `plannableCardCount`, `hasStudyPlan`, `generateStudyPlan`) with
/// identical behaviour; each takes the database connection, like `Study`.
public enum CalendarActions {
    /// What laying out a study plan did.
    public struct PlanSummary: Sendable, Equatable {
        public let blocksCreated: Int
        public let cardsCovered: Int
        public let replacedExisting: Bool
        public let firstDay: Date?
    }

    /// Every event starting in `start..<end`, soonest first -- what the
    /// month grid, the week columns and the agenda all read.
    public static func events(from start: Date, to end: Date, db: Database) throws -> [CalendarEvent] {
        try CalendarEvent
            .filter(Column("startsAt") >= start && Column("startsAt") < end)
            .order(Column("startsAt"))
            .fetchAll(db)
    }

    /// Exams and quizzes from the start of today through `days` ahead,
    /// soonest first. Events earlier today still count: an exam at 2pm
    /// shouldn't drop off the list at 2:01pm on the day it matters most.
    public static func upcomingExams(
        within days: Int = 30, limit: Int = 5, now: Date = Date(),
        calendar: Calendar = .current, db: Database
    ) throws -> [CalendarEvent] {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? start
        return try CalendarEvent
            .filter(CalendarEventKind.examLike.map(\.rawValue).contains(Column("kind")))
            .filter(Column("startsAt") >= start && Column("startsAt") < end)
            .order(Column("startsAt"))
            .limit(limit)
            .fetchAll(db)
    }

    /// Active cards falling due on each day before `end`, keyed by start of
    /// day, for the calendar's workload colouring. Anything already overdue
    /// lands on the first day, which is where it will actually be waiting.
    public static func dailyCardLoad(
        from start: Date, to end: Date, calendar: Calendar = .current, db: Database
    ) throws -> [Date: Int] {
        let firstDay = calendar.startOfDay(for: start)
        let dues = try Date.fetchAll(
            db,
            sql: "SELECT due FROM card WHERE deletedAt IS NULL AND status = 'active' AND due < ?",
            arguments: [end]
        )
        return dues.reduce(into: [:]) { counts, due in
            counts[max(calendar.startOfDay(for: due), firstDay), default: 0] += 1
        }
    }

    public static func add(_ event: CalendarEvent, db: Database) throws {
        try event.insert(db)
    }

    public static func update(_ event: CalendarEvent, now: Date = Date(), db: Database) throws {
        var updated = event
        updated.updatedAt = now
        try updated.update(db)
    }

    /// Deletes the event and any study plan generated for it: blocks for an
    /// exam that no longer exists are clutter nobody would think to clear.
    public static func delete(_ eventId: String, db: Database) throws {
        try CalendarEvent.filter(Column("parentEventId") == eventId).deleteAll(db)
        _ = try CalendarEvent.deleteOne(db, key: eventId)
    }

    /// How many cards a plan for this event would cover: the linked deck's
    /// active cards, or the whole course's (its live decks) when no deck is
    /// set. Zero for an event with neither.
    public static func plannableCardCount(for event: CalendarEvent, db: Database) throws -> Int {
        let deckIds: [String]
        if let deckId = event.deckId {
            deckIds = [deckId]
        } else if let courseId = event.courseId {
            deckIds = try Deck
                .filter(Column("courseId") == courseId)
                .filter(Column("deletedAt") == nil)
                .fetchAll(db)
                .map(\.id)
        } else {
            deckIds = []
        }
        guard !deckIds.isEmpty else { return 0 }
        let cardIds = try DeckCard
            .filter(deckIds.contains(Column("deckId")))
            .fetchAll(db)
            .map(\.cardId)
        guard !cardIds.isEmpty else { return 0 }
        return try Card
            .filter(cardIds.contains(Column("id")))
            .filter(Column("deletedAt") == nil)
            .filter(Column("status") == CardStatus.active.rawValue)
            .fetchCount(db)
    }

    public static func hasStudyPlan(for eventId: String, db: Database) throws -> Bool {
        try CalendarEvent.filter(Column("parentEventId") == eventId).fetchCount(db) > 0
    }

    /// Lays a `StudyPlanner` plan onto the calendar as all-day study blocks,
    /// each linked back to the exam, replacing exactly the blocks a previous
    /// plan for it made and nothing else.
    @discardableResult
    public static func generateStudyPlan(
        for event: CalendarEvent, courseName: String?, now: Date = Date(), db: Database
    ) throws -> PlanSummary {
        let cardCount = try plannableCardCount(for: event, db: db)
        let blocks = StudyPlanner.plan(cardCount: cardCount, from: now, examDate: event.startsAt)
        let replaced = try CalendarEvent.filter(Column("parentEventId") == event.id).deleteAll(db) > 0
        for block in blocks {
            try CalendarEvent(
                courseId: event.courseId, deckId: event.deckId, kind: .study,
                title: StudyPlanner.blockTitle(courseName: courseName, block: block),
                startsAt: block.day, isAllDay: true, parentEventId: event.id
            ).insert(db)
        }
        return PlanSummary(
            blocksCreated: blocks.count, cardsCovered: cardCount,
            replacedExisting: replaced, firstDay: blocks.first?.day
        )
    }
}
