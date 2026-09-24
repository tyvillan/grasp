import Foundation
import Testing
@testable import GRASPCore

/// The widgets draw from a snapshot made minutes or hours earlier, so what
/// matters is that reading it later gives the numbers the app would show.
@Suite("Widget snapshot")
struct WidgetSnapshotTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// Wednesday 2026-09-23, 10:00 local.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10))!
    }

    private func hours(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }

    private func snapshot(
        streak: Int = 4, lastStudyDay: Date? = nil, reviews: Int = 12,
        decks: [WidgetSnapshot.Deck] = [], events: [WidgetSnapshot.Event] = []
    ) -> WidgetSnapshot {
        let today = calendar.startOfDay(for: now)
        return WidgetSnapshot(
            generatedAt: now, profileName: "Tyler", dailyGoal: 20,
            streakDays: streak, lastStudyDay: lastStudyDay ?? today,
            reviewsToday: reviews, reviewsDay: today,
            due: WidgetSnapshot.DueTimes(overdue: 5, upcoming: [hours(3), hours(1), hours(30)]),
            decks: decks, events: events
        )
    }

    @Test("due count grows as cards fall due")
    func dueCountOverTime() {
        let s = snapshot()
        #expect(s.state(at: now, calendar: calendar).dueNow == 5)
        #expect(s.state(at: hours(1), calendar: calendar).dueNow == 6)   // due exactly at 11:00 counts
        #expect(s.state(at: hours(2), calendar: calendar).dueNow == 6)
        #expect(s.state(at: hours(4), calendar: calendar).dueNow == 7)
        #expect(s.state(at: hours(31), calendar: calendar).dueNow == 8)
    }

    @Test("streak survives until a whole day is missed")
    func streakRollover() {
        let s = snapshot()
        let tomorrow = hours(24)
        let dayAfter = hours(48)
        #expect(s.state(at: now, calendar: calendar).streakDays == 4)
        #expect(s.state(at: now, calendar: calendar).studiedToday)
        #expect(s.state(at: tomorrow, calendar: calendar).streakDays == 4)
        #expect(!s.state(at: tomorrow, calendar: calendar).studiedToday)
        #expect(s.state(at: dayAfter, calendar: calendar).streakDays == 0)
    }

    @Test("reviewed-today resets at midnight")
    func reviewsReset() {
        let s = snapshot()
        #expect(s.state(at: hours(13), calendar: calendar).reviewsToday == 12)   // 23:00 same day
        #expect(s.state(at: hours(14.5), calendar: calendar).reviewsToday == 0)  // 00:30 next day
    }

    @Test("jump back in picks the most recently studied deck with cards due")
    func jumpBackIn() {
        let old = WidgetSnapshot.Deck(id: "a", name: "Lecture 1", courseName: "Matrix", lastReviewedAt: hours(-48),
                                      due: .init(overdue: 30, upcoming: []))
        let recent = WidgetSnapshot.Deck(id: "b", name: "Lecture 2", courseName: "Matrix", lastReviewedAt: hours(-2),
                                         due: .init(overdue: 0, upcoming: [hours(2)]))
        let never = WidgetSnapshot.Deck(id: "c", name: "Lecture 3", courseName: "Design", lastReviewedAt: nil,
                                        due: .init(overdue: 50, upcoming: []))
        let s = snapshot(decks: [old, recent, never])

        // Deck b has nothing due yet, so the recent-with-due rule falls to a.
        #expect(s.state(at: now, calendar: calendar).jumpBackIn?.deck.id == "a")
        // Once b's card falls due, it wins on recency.
        #expect(s.state(at: hours(3), calendar: calendar).jumpBackIn?.deck.id == "b")

        let state = s.state(at: now, calendar: calendar)
        #expect(state.dueDecks.map(\.deck.id) == ["c", "a"])
        #expect(state.dueByCourse.first?.name == "Design")
        #expect(state.dueByCourse.first?.dueCount == 50)
    }

    @Test("with nothing studied, the deck with the most due is next")
    func jumpBackInFallback() {
        let small = WidgetSnapshot.Deck(id: "a", name: "A", courseName: "C", lastReviewedAt: nil, due: .init(overdue: 2, upcoming: []))
        let big = WidgetSnapshot.Deck(id: "b", name: "B", courseName: "C", lastReviewedAt: nil, due: .init(overdue: 9, upcoming: []))
        #expect(snapshot(decks: [small, big]).state(at: now, calendar: calendar).jumpBackIn?.deck.id == "b")
        #expect(snapshot(decks: []).state(at: now, calendar: calendar).jumpBackIn == nil)
    }

    @Test("an exam stays upcoming all of its day, counted in calendar days")
    func exams() {
        let morning = WidgetSnapshot.Event(id: "e1", title: "Midterm", kind: "exam", courseName: "Matrix",
                                           startsAt: hours(-2), isAllDay: false)       // 8:00 today
        let tomorrow = WidgetSnapshot.Event(id: "e2", title: "Quiz", kind: "quiz", courseName: nil,
                                            startsAt: hours(22), isAllDay: false)     // 8:00 tomorrow
        let s = snapshot(events: [tomorrow, morning])
        let state = s.state(at: now, calendar: calendar)
        #expect(state.upcomingEvents.map(\.id) == ["e1", "e2"])
        #expect(WidgetSnapshot.daysAway(tomorrow, from: now, calendar: calendar) == 1)
        #expect(WidgetSnapshot.daysAway(morning, from: now, calendar: calendar) == 0)
        // The next day, this morning's exam is gone.
        #expect(s.state(at: hours(15), calendar: calendar).upcomingEvents.map(\.id) == ["e2"])
    }

    @Test("timeline changes land on due times and midnights")
    func changeTimes() {
        let times = snapshot().changeTimes(after: now, until: hours(24), calendar: calendar)
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        #expect(times == [hours(1), hours(3), midnight])
    }

    @Test("round-trips through the shared file, and ignores publish time when comparing")
    func fileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent(WidgetSnapshotFile.fileName)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = snapshot(decks: [.init(id: "a", name: "A", courseName: "C", lastReviewedAt: now, due: .init(overdue: 1, upcoming: [hours(2)]))])
        try WidgetSnapshotFile.write(s, to: url)
        let read = try #require(WidgetSnapshotFile.read(from: url))
        #expect(read == s)

        var later = s
        later.generatedAt = hours(1)
        #expect(later.sameContent(as: s))
        later.reviewsToday += 1
        #expect(!later.sameContent(as: s))
    }

    @Test("a missing or unreadable file reads as no snapshot")
    func unreadable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        #expect(WidgetSnapshotFile.read(from: url) == nil)
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WidgetSnapshotFile.read(from: url) == nil)
    }

    @Test("widget links round-trip, and sign-in callbacks aren't mistaken for them")
    func links() {
        for link in [WidgetLink.today, .calendar, .deck("3F2A-deck")] {
            #expect(WidgetLink(url: link.url) == link)
        }
        #expect(WidgetLink(url: URL(string: "grasp://auth-callback?code=abc")!) == nil)
        #expect(WidgetLink(url: URL(string: "grasp://widget/deck/")!) == nil)
        #expect(WidgetLink(url: URL(string: "https://widget/today")!) == nil)
    }
}
