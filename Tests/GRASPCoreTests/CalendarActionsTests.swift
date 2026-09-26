import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// `CalendarActions` and `StudyProgress` back the calendar and the Home
/// figures in every app, so these pin the behaviour they carried over from
/// the Mac's `AppStore`.
@Suite("CalendarActions")
struct CalendarActionsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A course with two decks: three active cards and one draft between them.
    private func makeLibrary() throws -> (GRASPDatabase, course: String, deckA: String, deckB: String, cards: [String]) {
        let db = try GRASPDatabase.inMemory()
        let course = Course(semesterId: nil, name: "Matrix Theory")
        let deckA = Deck(courseId: course.id, name: "Lecture 1")
        let deckB = Deck(courseId: course.id, name: "Lecture 2")
        let cards = [
            (Card(materialId: nil, front: "Pivot", back: "A leading 1", origin: .manual, status: .active), deckA),
            (Card(materialId: nil, front: "Rank", back: "Number of pivots", origin: .manual, status: .active), deckA),
            (Card(materialId: nil, front: "Span", back: "All combinations", origin: .manual, status: .active), deckB),
            (Card(materialId: nil, front: "Basis", back: "Independent spanning set", origin: .manual, status: .draft), deckB),
        ]
        try db.queue.write { conn in
            try course.insert(conn)
            try deckA.insert(conn)
            try deckB.insert(conn)
            for (card, deck) in cards {
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            }
        }
        return (db, course.id, deckA.id, deckB.id, cards.map(\.0.id))
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    @Test("events come back in date order, only those starting inside the range")
    func eventsInRange() throws {
        let (db, course, _, _, _) = try makeLibrary()
        try db.queue.write { conn in
            try CalendarEvent(courseId: course, title: "Later", startsAt: day(5)).insert(conn)
            try CalendarEvent(courseId: course, title: "Sooner", startsAt: day(2)).insert(conn)
            try CalendarEvent(courseId: course, title: "Outside", startsAt: day(9)).insert(conn)
        }
        let titles = try db.queue.read { try CalendarActions.events(from: day(0), to: day(7), db: $0) }.map(\.title)
        #expect(titles == ["Sooner", "Later"])
    }

    @Test("upcoming exams include today's, skip study blocks and deadlines, and respect the limit")
    func upcomingExams() throws {
        let (db, course, _, _, _) = try makeLibrary()
        try db.queue.write { conn in
            try CalendarEvent(courseId: course, kind: .exam, title: "This morning", startsAt: now.addingTimeInterval(-3600)).insert(conn)
            try CalendarEvent(courseId: course, kind: .study, title: "Block", startsAt: day(1)).insert(conn)
            try CalendarEvent(courseId: course, kind: .deadline, title: "Essay", startsAt: day(1)).insert(conn)
            try CalendarEvent(courseId: course, kind: .quiz, title: "Quiz", startsAt: day(3)).insert(conn)
            try CalendarEvent(courseId: course, kind: .exam, title: "Too far", startsAt: day(40)).insert(conn)
        }
        let titles = try db.queue.read {
            try CalendarActions.upcomingExams(within: 30, limit: 5, now: now, calendar: calendar, db: $0)
        }.map(\.title)
        #expect(titles == ["This morning", "Quiz"])
        let limited = try db.queue.read {
            try CalendarActions.upcomingExams(within: 30, limit: 1, now: now, calendar: calendar, db: $0)
        }
        #expect(limited.count == 1)
    }

    @Test("daily load counts active cards by due day, with overdue ones on the first day")
    func dailyLoad() throws {
        let (db, _, _, _, cards) = try makeLibrary()
        try db.queue.write { conn in
            try conn.execute(sql: "UPDATE card SET due = ? WHERE id = ?", arguments: [day(-3), cards[0]])
            try conn.execute(sql: "UPDATE card SET due = ? WHERE id = ?", arguments: [day(2).addingTimeInterval(600), cards[1]])
            try conn.execute(sql: "UPDATE card SET due = ? WHERE id = ?", arguments: [day(20), cards[2]])
            try conn.execute(sql: "UPDATE card SET due = ? WHERE id = ?", arguments: [day(1), cards[3]])  // a draft
        }
        let load = try db.queue.read {
            try CalendarActions.dailyCardLoad(from: day(0), to: day(7), calendar: calendar, db: $0)
        }
        #expect(load == [day(0): 1, day(2): 1])
    }

    @Test("deleting an exam takes its study plan with it")
    func deleteRemovesPlan() throws {
        let (db, course, _, _, _) = try makeLibrary()
        let exam = CalendarEvent(courseId: course, kind: .exam, title: "Midterm", startsAt: day(6))
        let hadPlan = try db.queue.write { conn -> Bool in
            try CalendarActions.add(exam, db: conn)
            try CalendarActions.generateStudyPlan(for: exam, courseName: "Matrix Theory", now: now, db: conn)
            return try CalendarActions.hasStudyPlan(for: exam.id, db: conn)
        }
        #expect(hadPlan)
        try db.queue.write { try CalendarActions.delete(exam.id, db: $0) }
        let remaining = try db.queue.read { try CalendarEvent.fetchCount($0) }
        #expect(remaining == 0)
    }

    @Test("a plan covers the deck's active cards, or the whole course's when no deck is set")
    func plannableCards() throws {
        let (db, course, deckA, _, _) = try makeLibrary()
        let forDeck = CalendarEvent(courseId: course, deckId: deckA, title: "Quiz", startsAt: day(3))
        let forCourse = CalendarEvent(courseId: course, title: "Final", startsAt: day(3))
        let personal = CalendarEvent(title: "Dentist", startsAt: day(3))
        let counts = try db.queue.read { conn in
            try [forDeck, forCourse, personal].map { try CalendarActions.plannableCardCount(for: $0, db: conn) }
        }
        #expect(counts == [2, 3, 0])
    }

    @Test("regenerating a plan replaces its own blocks and leaves hand-made events alone")
    func regeneratePlan() throws {
        let (db, course, _, _, _) = try makeLibrary()
        let exam = CalendarEvent(courseId: course, kind: .exam, title: "Final", startsAt: day(6))
        let first = try db.queue.write { conn -> CalendarActions.PlanSummary in
            try CalendarActions.add(exam, db: conn)
            try CalendarEvent(courseId: course, kind: .study, title: "My own block", startsAt: day(2)).insert(conn)
            return try CalendarActions.generateStudyPlan(for: exam, courseName: "Matrix Theory", now: now, db: conn)
        }
        #expect(first.blocksCreated > 0)
        #expect(first.cardsCovered == 3)
        #expect(!first.replacedExisting)

        let second = try db.queue.write {
            try CalendarActions.generateStudyPlan(for: exam, courseName: "Matrix Theory", now: now, db: $0)
        }
        #expect(second.replacedExisting)
        let (blocks, handMade) = try db.queue.read { conn in
            (try CalendarEvent.filter(Column("parentEventId") == exam.id).fetchCount(conn),
             try CalendarEvent.filter(Column("title") == "My own block").fetchCount(conn))
        }
        #expect(blocks == second.blocksCreated)
        #expect(handMade == 1)
    }

    @Test("updating an event stamps updatedAt")
    func updateStamps() throws {
        let (db, course, _, _, _) = try makeLibrary()
        var event = CalendarEvent(courseId: course, title: "Quiz", startsAt: day(3), updatedAt: day(-10))
        try db.queue.write { try CalendarActions.add(event, db: $0) }
        event.title = "Quiz 2"
        try db.queue.write { try CalendarActions.update(event, now: now, db: $0) }
        let saved = try db.queue.read { try #require(try CalendarEvent.fetchOne($0, key: event.id)) }
        #expect(saved.title == "Quiz 2")
        #expect(saved.updatedAt == now)
    }
}

@Suite("StudyProgress")
struct StudyProgressTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func review(_ cardId: String, daysAgo: Int, hour: Int = 12) -> Review {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        return Review(cardId: cardId, reviewedAt: day.addingTimeInterval(Double(hour) * 3600), grade: 3,
                      source: "flashcards", dueAfter: now, schedulerVersion: "fsrs5")
    }

    private func makeDatabase(reviewDaysAgo: [Int]) throws -> GRASPDatabase {
        let db = try GRASPDatabase.inMemory()
        let card = Card(materialId: nil, front: "Pivot", back: "A leading 1", origin: .manual, status: .active)
        try db.queue.write { conn in
            try card.insert(conn)
            for daysAgo in reviewDaysAgo { try review(card.id, daysAgo: daysAgo).insert(conn) }
        }
        return db
    }

    @Test("studying yesterday but not yet today keeps the streak")
    func streakSurvivesUntilTonight() throws {
        let db = try makeDatabase(reviewDaysAgo: [1, 2, 3, 5])
        let streak = try db.queue.read { try StudyProgress.streak(now: now, calendar: calendar, db: $0) }
        #expect(streak == StudyProgress.Streak(days: 3, studiedToday: false, reviewsToday: 0))
    }

    @Test("today's reviews count toward the streak and today's total")
    func streakIncludesToday() throws {
        let db = try makeDatabase(reviewDaysAgo: [0, 0, 1])
        let streak = try db.queue.read { try StudyProgress.streak(now: now, calendar: calendar, db: $0) }
        #expect(streak.days == 2)
        #expect(streak.studiedToday)
        #expect(streak.reviewsToday == 2)
    }

    @Test("a missed day breaks the streak")
    func missedDayBreaks() throws {
        let db = try makeDatabase(reviewDaysAgo: [2, 3])
        let streak = try db.queue.read { try StudyProgress.streak(now: now, calendar: calendar, db: $0) }
        #expect(streak.days == 0)
    }
}
