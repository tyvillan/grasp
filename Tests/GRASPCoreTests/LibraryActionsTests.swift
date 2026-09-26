import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Library actions")
struct LibraryActionsTests {
    /// A course from the vault with two decks: "Week 1" (two cards, one
    /// reviewed) and "Week 2" (one card).
    private func makeCourse() async throws -> (GRASPDatabase, course: String, week1: String, week2: String) {
        let db = try GRASPDatabase.inMemory()
        let ids = try await db.queue.write { conn -> (String, String, String) in
            var course = Course(semesterId: nil, name: "Biology")
            course.folderPath = "/vault/College/Fall 2026/Biology"
            try course.insert(conn)
            let week1 = Deck(courseId: course.id, name: "Week 1")
            try week1.insert(conn)
            let week2 = Deck(courseId: course.id, name: "Week 2")
            try week2.insert(conn)
            for (index, deck) in [week1, week1, week2].enumerated() {
                let card = Card(materialId: nil, front: "Q\(index)", back: "A", origin: .manual, status: .active)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: index).insert(conn)
                if index == 0 { try Study.grade(card.id, grade: .good, source: "flashcards", db: conn) }
            }
            return (course.id, week1.id, week2.id)
        }
        return (db, ids.0, ids.1, ids.2)
    }

    @Test("deleting a course says what it removes, then removes it and excludes its folder")
    func deleteCourse() async throws {
        let (db, course, _, _) = try await makeCourse()
        let impact = try await db.queue.read { try LibraryActions.courseDeletionImpact(course, db: $0) }
        #expect(impact.cards == 3)
        #expect(impact.reviews == 1)
        try await db.queue.write { try LibraryActions.removeCourseAndExclude(course, db: $0) }
        let (courses, cards, excluded) = try await db.queue.read { db in
            (try Course.fetchCount(db), try Card.fetchCount(db), try ExcludedFolder.fetchAll(db).map(\.folderPath))
        }
        #expect(courses == 0)
        #expect(cards == 0)
        #expect(excluded == ["/vault/College/Fall 2026/Biology"])
    }

    @Test("archiving hides a course and unarchiving brings it back")
    func archive() async throws {
        let (db, course, _, _) = try await makeCourse()
        try await db.queue.write { try LibraryActions.setCourseArchived(course, archived: true, db: $0) }
        #expect(try await db.queue.read { try Course.fetchOne($0, key: course)?.isArchived } == true)
        try await db.queue.write { try LibraryActions.setCourseArchived(course, archived: false, db: $0) }
        #expect(try await db.queue.read { try Course.fetchOne($0, key: course)?.isArchived } == false)
    }

    @Test("a typed timeline reuses a matching semester and otherwise sorts after the rest")
    func semesters() async throws {
        let db = try GRASPDatabase.inMemory()
        let (first, again, other, count) = try await db.queue.write { db in
            let first = try LibraryActions.findOrCreateSemester(name: " Fall 2026 ", db: db)
            let again = try LibraryActions.findOrCreateSemester(name: "fall 2026", db: db)
            let other = try LibraryActions.findOrCreateSemester(name: "Quarter 1", db: db)
            return (first, again, other, try Semester.fetchCount(db))
        }
        #expect(first == again)
        #expect(first != other)
        #expect(count == 2)
        #expect(LibraryActions.slugify("Fall 2026") == "fall-2026")
    }

    @Test("a new deck goes last, and renaming changes only its name")
    func createAndRename() async throws {
        let (db, course, _, _) = try await makeCourse()
        let id = try await db.queue.write { try LibraryActions.createDeck(courseId: course, name: "Midterm Review", db: $0) }
        try await db.queue.write { try LibraryActions.renameDeck(id, name: "Final Review", db: $0) }
        let deck = try #require(try await db.queue.read { try Deck.fetchOne($0, key: id) })
        #expect(deck.name == "Final Review")
        #expect(deck.sortIndex == 1)
        #expect(deck.origin == "manual")
    }

    @Test("deleting a deck can move its cards, or soft-delete them")
    func deleteDeck() async throws {
        let (db, _, week1, week2) = try await makeCourse()
        #expect(try await db.queue.read { try LibraryActions.deckCardCount(week1, db: $0) } == 2)
        try await db.queue.write { try LibraryActions.deleteDeck(week1, migrateCardsTo: week2, db: $0) }
        let moved = try await db.queue.read { try CardActions.cards(inDecks: [week2], db: $0).count }
        #expect(moved == 3)
        try await db.queue.write { try LibraryActions.deleteDeck(week2, migrateCardsTo: nil, db: $0) }
        let (live, decks) = try await db.queue.read { db in
            (try Card.filter(Column("deletedAt") == nil).fetchCount(db),
             try Deck.filter(Column("deletedAt") == nil).fetchCount(db))
        }
        #expect(live == 0)
        #expect(decks == 0)
    }
}
