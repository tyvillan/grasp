import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Dashboard")
struct DashboardTests {
    private func summary(_ id: String, due: Int = 0, last: TimeInterval? = nil) -> Dashboard.DeckSummary {
        Dashboard.DeckSummary(deckId: id, deckName: id, courseId: "c", courseName: "C", cardCount: 10,
                              dueCount: due, reviewedCount: 0,
                              lastReviewedAt: last.map { Date(timeIntervalSince1970: $0) })
    }

    @Test("jump back in is the last deck studied, else the one with most due")
    func jumpBackIn() {
        let studied = [summary("a", due: 9, last: 100), summary("b", due: 1, last: 300), summary("c", due: 20)]
        #expect(Dashboard.jumpBackIn(studied)?.deckId == "b")
        let fresh = [summary("a", due: 3), summary("c", due: 20)]
        #expect(Dashboard.jumpBackIn(fresh)?.deckId == "c")
        #expect(Dashboard.jumpBackIn([summary("a")]) == nil)
    }

    @Test("recents are studied decks, newest first, without the headline")
    func recents() {
        let decks = [summary("a", last: 100), summary("b", last: 300), summary("c", last: 200), summary("d")]
        #expect(Dashboard.recents(decks).map(\.deckId) == ["c", "a"])
    }

    @Test("the query counts cards, due and reviewed per deck, and skips archived courses")
    func query() async throws {
        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Biology")
            try course.insert(conn)
            var archived = Course(semesterId: nil, name: "Old")
            archived.isArchived = true
            try archived.insert(conn)
            let deck = Deck(courseId: course.id, name: "Cells")
            try deck.insert(conn)
            try Deck(courseId: archived.id, name: "Hidden").insert(conn)
            for (index, status) in [CardStatus.active, .active, .draft, .suspended].enumerated() {
                let card = Card(materialId: nil, front: "Q\(index)", back: "A", origin: .manual, status: status)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: index).insert(conn)
                if index == 0 { try Study.grade(card.id, grade: .good, source: "flashcards", db: conn) }
            }
        }
        let decks = try await db.queue.read { try Dashboard.decks(db: $0) }
        #expect(decks.map(\.deckName) == ["Cells"])
        let cells = try #require(decks.first)
        #expect(cells.cardCount == 3)
        #expect(cells.dueCount == 1)
        #expect(cells.reviewedCount == 1)
        #expect(cells.lastReviewedAt != nil)
    }
}
