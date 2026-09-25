import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// `Study` is what every GRASP app calls to study -- the Mac and iPhone
/// through `AppStore`, Windows directly -- so these pin its database effects.
@Suite("Study")
struct StudyTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A course with one deck holding one active and one draft card.
    private func makeLibrary() throws -> (GRASPDatabase, course: String, deck: String, active: String, draft: String) {
        let db = try GRASPDatabase.inMemory()
        let course = Course(semesterId: nil, name: "Matrix Theory")
        let deck = Deck(courseId: course.id, name: "Lecture 2")
        let active = Card(materialId: nil, front: "Pivot", back: "A leading 1", origin: .manual, status: .active)
        let draft = Card(materialId: nil, front: "Free variable", back: "No pivot", origin: .manual, status: .draft)
        try db.queue.write { conn in
            try course.insert(conn)
            try deck.insert(conn)
            for card in [active, draft] {
                var card = card
                card.due = now.addingTimeInterval(-60)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            }
        }
        return (db, course.id, deck.id, active.id, draft.id)
    }

    @Test("only active cards are due; approving drafts makes them due too")
    func dueAndApprove() throws {
        let (db, _, deck, active, draft) = try makeLibrary()
        let before = try db.queue.read { try Study.dueCards(inDecks: [deck], now: now, db: $0) }
        #expect(before.map(\.id) == [active])

        try db.queue.write { try Study.approveDrafts(inDecks: [deck], now: now, db: $0) }
        let after = try db.queue.read { try Study.dueCards(inDecks: [deck], now: now, db: $0) }
        #expect(Set(after.map(\.id)) == [active, draft])
    }

    @Test("grading moves the card's due date forward and logs a review")
    func gradeWritesSchedulerStateAndReview() throws {
        let (db, _, deck, active, _) = try makeLibrary()
        try db.queue.write { try Study.grade(active, grade: .good, source: "flashcards", now: now, db: $0) }

        try db.queue.read { conn in
            let card = try #require(try Card.fetchOne(conn, key: active))
            #expect(card.due > now)
            #expect(card.reps == 1)
            #expect(card.lastReview == now)
            let reviews = try Review.filter(Column("cardId") == active).fetchAll(conn)
            #expect(reviews.count == 1)
            #expect(reviews.first?.grade == FSRS.Grade.good.rawValue)
            #expect(reviews.first?.source == "flashcards")
            let stillDue = try Study.dueCards(inDecks: [deck], now: now, db: conn)
            #expect(stillDue.isEmpty)
        }
    }

    @Test("an upcoming exam caps the next review to land before it")
    func examCapsInterval() throws {
        let (db, course, _, active, _) = try makeLibrary()
        let exam = now.addingTimeInterval(2 * 86400)
        try db.queue.write { conn in
            try CalendarEvent(courseId: course, kind: .exam, title: "Midterm", startsAt: exam).insert(conn)
            // Easy on a mature card would normally schedule weeks out.
            try conn.execute(sql: "UPDATE card SET stability = 40, reps = 5, schedulerState = 2, lastReview = ? WHERE id = ?",
                             arguments: [now.addingTimeInterval(-30 * 86400), active])
            try Study.grade(active, grade: .easy, source: "flashcards", now: now, db: conn)
        }
        let due = try db.queue.read { try #require(try Card.fetchOne($0, key: active)).due }
        #expect(due <= exam)
    }

    @Test("an exam stays upcoming for its whole day, then stops counting")
    func nearestExamWindow() throws {
        let (db, course, _, _, _) = try makeLibrary()
        let examDay = now.addingTimeInterval(-3600)   // all-day exam that "started" an hour ago
        try db.queue.write { try CalendarEvent(courseId: course, title: "Quiz", startsAt: examDay).insert($0) }
        let (today, tomorrow) = try db.queue.read { conn in
            (try Study.nearestUpcomingExam(forCourseId: course, now: now, db: conn),
             try Study.nearestUpcomingExam(forCourseId: course, now: now.addingTimeInterval(86400), db: conn))
        }
        #expect(today != nil)
        #expect(tomorrow == nil)
    }
}
