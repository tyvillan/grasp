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
}
