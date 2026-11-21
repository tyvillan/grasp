import Foundation
import GRDB

/// Study streak and today's review count, shared by every app. Moved out
/// of the Mac's `AppStore.studyStreak()` with identical behaviour.
public enum StudyProgress {
    public struct Streak: Sendable, Equatable {
        /// Consecutive days with at least one review, counting back from today.
        public let days: Int
        public let studiedToday: Bool
        public let reviewsToday: Int

        public init(days: Int, studiedToday: Bool, reviewsToday: Int) {
            self.days = days
            self.studiedToday = studiedToday
            self.reviewsToday = reviewsToday
        }
    }

    /// Studying yesterday but not yet today keeps the streak alive: it only
    /// breaks once a whole day passes with nothing, which is what makes the
    /// number safe to show in the morning. Looks back at most a year.
    public static func streak(now: Date = Date(), calendar: Calendar = .current, db: Database) throws -> Streak {
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: -365, to: today) ?? today
        let days = Set(try Date.fetchAll(
            db, sql: "SELECT DISTINCT reviewedAt FROM review WHERE reviewedAt >= ?", arguments: [horizon]
        ).map { calendar.startOfDay(for: $0) })
        let studiedToday = days.contains(today)

        var streak = 0
        var cursor = studiedToday ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        let reviewsToday = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM review WHERE reviewedAt >= ?", arguments: [today]
        ) ?? 0
        return Streak(days: streak, studiedToday: studiedToday, reviewsToday: reviewsToday)
    }

    // MARK: - The last seven days

    /// The last seven days (today and the six before), for the Home "This
    /// week" card.
    public struct Week: Sendable, Equatable {
        /// Oldest first; `days.last` is today.
        public let days: [Day]
        /// Cards reviewed in the seven days before those.
        public let previousReviews: Int
        public let testsFinished: Int

        public struct Day: Sendable, Equatable {
            public let date: Date
            public let reviews: Int
            public init(date: Date, reviews: Int) { self.date = date; self.reviews = reviews }
        }

        public init(days: [Day], previousReviews: Int, testsFinished: Int) {
            self.days = days; self.previousReviews = previousReviews; self.testsFinished = testsFinished
        }

        public var totalReviews: Int { days.reduce(0) { $0 + $1.reviews } }
        public var daysStudied: Int { days.filter { $0.reviews > 0 }.count }
        /// Reviews this week minus the week before.
        public var change: Int { totalReviews - previousReviews }
    }

    public static func week(now: Date = Date(), calendar: Calendar = .current, db: Database) throws -> Week {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let before = calendar.date(byAdding: .day, value: -7, to: start) ?? start
        let reviewTimes = try Date.fetchAll(db, sql: "SELECT reviewedAt FROM review WHERE reviewedAt >= ?", arguments: [before])
        var perDay: [Date: Int] = [:]
        var previous = 0
        for time in reviewTimes {
            if time < start { previous += 1 } else { perDay[calendar.startOfDay(for: time), default: 0] += 1 }
        }
        let days = (0..<7).map { offset -> Week.Day in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            return Week.Day(date: date, reviews: perDay[date] ?? 0)
        }
        let tests = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM testAttempt WHERE finishedAt >= ?", arguments: [start]) ?? 0
        return Week(days: days, previousReviews: previous, testsFinished: tests)
    }
}
