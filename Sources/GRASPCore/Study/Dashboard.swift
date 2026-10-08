import Foundation
import GRDB

/// Home's deck figures: the Mac `AppStore.dashboardDecks` query and its
/// "Jump back in" and "Recent" picks, moved here so the Mac and Windows
/// dashboards agree.
public enum Dashboard {
    public struct DeckSummary: Identifiable, Sendable, Equatable {
        public var id: String { deckId }
        public let deckId: String
        public let deckName: String
        public let courseId: String
        public let courseName: String
        public let cardCount: Int
        public let dueCount: Int
        /// Cards reviewed at least once.
        public let reviewedCount: Int
        public let lastReviewedAt: Date?

        public init(deckId: String, deckName: String, courseId: String, courseName: String,
                    cardCount: Int, dueCount: Int, reviewedCount: Int, lastReviewedAt: Date?) {
            self.deckId = deckId
            self.deckName = deckName
            self.courseId = courseId
            self.courseName = courseName
            self.cardCount = cardCount
            self.dueCount = dueCount
            self.reviewedCount = reviewedCount
            self.lastReviewedAt = lastReviewedAt
        }
    }

    /// Every live deck in a course that isn't archived, with its counts and
    /// when it was last studied.
    public static func decks(now: Date = Date(), db: Database) throws -> [DeckSummary] {
        try Row.fetchAll(db, sql: """
            SELECT deck.id AS deckId, deck.name AS deckName, course.id AS courseId, course.name AS courseName,
                   COUNT(CASE WHEN card.deletedAt IS NULL AND card.status != 'suspended' THEN 1 END) AS cardCount,
                   COUNT(CASE WHEN card.deletedAt IS NULL AND card.status = 'active' AND card.due <= ? THEN 1 END) AS dueCount,
                   COUNT(CASE WHEN card.deletedAt IS NULL AND card.reps > 0 THEN 1 END) AS reviewedCount,
                   MAX(lastReview.reviewedAt) AS lastReviewedAt
            FROM deck
            JOIN course ON course.id = deck.courseId
            LEFT JOIN deckCard ON deckCard.deckId = deck.id
            LEFT JOIN card ON card.id = deckCard.cardId
            -- One row per card, so a long review history can't multiply the
            -- join (it used to, and the counts needed DISTINCT to undo it).
            LEFT JOIN (SELECT cardId, MAX(reviewedAt) AS reviewedAt FROM review GROUP BY cardId) AS lastReview
                   ON lastReview.cardId = card.id
            -- Archived courses are hidden everywhere else; counting them
            -- here made Home's totals disagree with the course list.
            WHERE deck.deletedAt IS NULL AND course.isArchived = 0
            GROUP BY deck.id
            """, arguments: [now])
            .map { row in
                DeckSummary(
                    deckId: row["deckId"], deckName: row["deckName"], courseId: row["courseId"],
                    courseName: row["courseName"], cardCount: row["cardCount"], dueCount: row["dueCount"],
                    reviewedCount: row["reviewedCount"], lastReviewedAt: row["lastReviewedAt"]
                )
            }
    }

    /// "Pick up where you left off": the deck studied most recently, else
    /// the one with the most due.
    public static func jumpBackIn(_ decks: [DeckSummary]) -> DeckSummary? {
        if let mostRecent = decks.filter({ $0.lastReviewedAt != nil })
            .max(by: { $0.lastReviewedAt! < $1.lastReviewedAt! }) {
            return mostRecent
        }
        return decks.filter { $0.dueCount > 0 }.max { $0.dueCount < $1.dueCount }
    }

    /// Decks studied at least once, most recent first, without the one
    /// already headlining "Jump back in".
    public static func recents(_ decks: [DeckSummary], limit: Int = 6) -> [DeckSummary] {
        let headline = jumpBackIn(decks)?.deckId
        return Array(decks
            .filter { $0.lastReviewedAt != nil && $0.deckId != headline }
            .sorted { $0.lastReviewedAt! > $1.lastReviewedAt! }
            .prefix(limit))
    }
}
