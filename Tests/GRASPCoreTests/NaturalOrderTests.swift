import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("NaturalOrder")
struct NaturalOrderTests {
    private func names(_ decks: [Deck]) -> [String] { decks.map(\.name) }

    @Test("Lecture 10 and 11 come after Lecture 9, not after Lecture 1")
    func lecturesInNumericOrder() {
        let shuffled = ["Lecture 11", "Lecture 2", "Lecture 10", "Lecture 1", "Lecture 9", "Lecture 3", "Lecture 12"]
        let decks = shuffled.map { Deck(courseId: "c", name: $0, chapter: $0) }
        #expect(names(Deck.ordered(decks)) == [
            "Lecture 1", "Lecture 2", "Lecture 3", "Lecture 9", "Lecture 10", "Lecture 11", "Lecture 12",
        ])
    }

    @Test("weeks, lectures and modules come before labs; decks with no chapter stay last")
    func lecturesBeforeLabs() {
        let labels = ["Lab 2", "Week 2", "Lab 1", "Week 1", "Module 1", "Lecture 1", "Week 10", "Lab 10"]
        var decks = labels.map { Deck(courseId: "c", name: $0, chapter: $0) }
        decks.append(Deck(courseId: "c", name: "General"))
        #expect(names(Deck.ordered(decks)) == [
            "Lecture 1", "Module 1", "Week 1", "Week 2", "Week 10", "Lab 1", "Lab 2", "Lab 10", "General",
        ])
    }

    @Test("case and accents are ignored, like localeCompare with sensitivity base")
    func ignoresCaseAndAccents() {
        #expect(NaturalOrder.compare("lecture 2", "Lecture 2") == .orderedSame)
        #expect(NaturalOrder.compare("Café 2", "cafe 2") == .orderedSame)
        #expect(NaturalOrder.isOrdered("Lecture 2", before: "LECTURE 10"))
    }

    @Test("hand-made decks keep their position after the auto decks, in creation order")
    func manualDecksStayAfterAutoDecks() {
        let auto = [10, 2, 1].map { Deck(courseId: "c", name: "Lecture \($0)", chapter: "Lecture \($0)") }
        let manual = [
            Deck(courseId: "c", name: "Zebra review", origin: "manual", sortIndex: 1),
            Deck(courseId: "c", name: "Alpha review", origin: "manual", sortIndex: 2),
        ]
        #expect(names(Deck.ordered(manual + auto)) == [
            "Lecture 1", "Lecture 2", "Lecture 10", "Zebra review", "Alpha review",
        ])
    }

    @Test("a deck with no chapter sorts after decks that have one, then by name")
    func missingChapterLast() {
        let decks = [
            Deck(courseId: "c", name: "Loose notes", chapter: nil),
            Deck(courseId: "c", name: "Lecture 2", chapter: "Lecture 2"),
            Deck(courseId: "c", name: "Another loose", chapter: nil),
        ]
        #expect(names(Deck.ordered(decks)) == ["Lecture 2", "Another loose", "Loose notes"])
    }

    @Test("equal decks keep the order they came in")
    func stable() {
        let decks = (0..<5).map { Deck(id: "id\($0)", courseId: "c", name: "Same", chapter: "Same") }
        #expect(Deck.ordered(decks).map(\.id) == (0..<5).map { "id\($0)" })
    }

    @Test("notes on one deck read in date order, ties and undated notes in natural title order")
    func materialsInReadingOrder() async throws {
        let db = try GRASPDatabase.inMemory()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let ids = try await db.queue.write { conn -> [String] in
            let course = Course(semesterId: nil, name: "Matrix Theory")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "All")
            try deck.insert(conn)
            // Inserted out of order on purpose.
            let notes: [(String, Date?)] = [
                ("Lecture 10", nil), ("Lecture 2", nil), ("Lecture 11", nil),
                ("Dated later", day.addingTimeInterval(86_400)), ("Dated first", day),
            ]
            for (title, date) in notes {
                let material = Material(courseId: course.id, relativePath: "/v/\(title).md", kind: .markdown,
                                        contentHash: title, title: title, noteDate: date)
                try material.insert(conn)
                let card = Card(materialId: material.id, front: title, back: "A", origin: .parser, status: .active)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            }
            return [deck.id]
        }
        let titles = try await db.queue.read { conn in
            try OverviewQueries.materials(forDecks: ids, db: conn).map(\.title)
        }
        #expect(titles == ["Dated first", "Dated later", "Lecture 2", "Lecture 10", "Lecture 11"])
    }
}
