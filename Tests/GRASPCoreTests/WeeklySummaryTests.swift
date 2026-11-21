import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Weekly summary")
struct WeeklySummaryTests {
    private func review(_ conn: Database, cardId: String, at date: Date) throws {
        try Review(cardId: cardId, reviewedAt: date, grade: 3, source: "flashcards", dueAfter: date,
                   schedulerVersion: "test").insert(conn)
    }

    @Test("reviews are counted per day for the last seven days and compared with the seven before")
    func counts() async throws {
        let db = try GRASPDatabase.inMemory()
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15))!
        @Sendable func at(daysAgo: Int) -> Date { calendar.date(byAdding: .day, value: -daysAgo, to: now)! }
        try await db.queue.write { conn in
            let card = Card(materialId: nil, front: "Q", back: "A", origin: .manual, status: .active)
            try card.insert(conn)
            for daysAgo in [0, 0, 0, 2, 6] { try review(conn, cardId: card.id, at: at(daysAgo: daysAgo)) }
            for daysAgo in [7, 9, 13] { try review(conn, cardId: card.id, at: at(daysAgo: daysAgo)) }
            try review(conn, cardId: card.id, at: at(daysAgo: 20))
        }
        let week = try await db.queue.read { try StudyProgress.week(now: now, calendar: calendar, db: $0) }
        #expect(week.days.count == 7)
        #expect(week.days.last?.reviews == 3)
        #expect(week.days.first?.reviews == 1)
        #expect(week.totalReviews == 5)
        #expect(week.daysStudied == 3)
        #expect(week.previousReviews == 3)
        #expect(week.change == 2)
    }
}
