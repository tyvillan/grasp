import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("LessonDates")
struct LessonDatesTests {
    private let us = Locale(identifier: "en_US")

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test("a single date, a range in one month, and a range across months")
    func formats() {
        #expect(LessonDates.format(start: day(2026, 8, 27), end: nil, locale: us) == "AUG 27")
        #expect(LessonDates.format(start: day(2026, 8, 27), end: day(2026, 8, 27), locale: us) == "AUG 27")
        #expect(LessonDates.format(start: day(2026, 8, 27), end: day(2026, 8, 29), locale: us) == "AUG 27–29")
        #expect(LessonDates.format(start: day(2026, 8, 30), end: day(2026, 9, 2), locale: us) == "AUG 30 – SEP 2")
    }

    @Test("extracted dates win; a manual date only fills in where there are none")
    func kickers() async throws {
        let db = try GRASPDatabase.inMemory()
        let ids = try await db.queue.write { conn -> (dated: String, manual: String, bare: String, both: String) in
            let course = Course(semesterId: nil, name: "Econ")
            try course.insert(conn)
            func deck(_ name: String, notes: [String], manual: Date? = nil, end: Date? = nil) throws -> String {
                let deck = Deck(courseId: course.id, name: name, manualLessonDate: manual, manualLessonDateEnd: end)
                try deck.insert(conn)
                for (index, title) in notes.enumerated() {
                    let note = Material(courseId: course.id, relativePath: "/n/\(name)-\(index).md", kind: .markdown,
                                        contentHash: "h\(name)\(index)", title: title)
                    try note.insert(conn)
                    let card = Card(materialId: note.id, front: "Q", back: "A", origin: .parser, status: .active)
                    try card.insert(conn)
                    try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: index).insert(conn)
                }
                return deck.id
            }
            return (
                try deck("Dated", notes: ["2026-08-27_Lecture-02_Markets", "2026-08-29_Lecture-03_Prices"]),
                try deck("Manual", notes: ["Undated"], manual: self.day(2026, 9, 3)),
                try deck("Bare", notes: []),
                try deck("Both", notes: ["2026-08-25_Lecture-01_Intro"], manual: self.day(2026, 9, 3))
            )
        }
        let kickers = try await db.queue.read { try LessonDates.kickers(db: $0, locale: self.us) }
        #expect(kickers[ids.dated] == "AUG 27–29")
        #expect(kickers[ids.manual] == "SEP 3")
        #expect(kickers[ids.bare] == nil)
        #expect(kickers[ids.both] == "AUG 25")
    }

    @Test("setting a range, then clearing it")
    func setAndClear() async throws {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Econ")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Markets")
            try deck.insert(conn)
            return deck.id
        }
        try await db.queue.write {
            try LessonDates.setManual(deckId: deckId, start: self.day(2026, 8, 30), end: self.day(2026, 9, 2), db: $0)
        }
        var kickers = try await db.queue.read { try LessonDates.kickers(db: $0, locale: self.us) }
        #expect(kickers[deckId] == "AUG 30 – SEP 2")
        try await db.queue.write { try LessonDates.setManual(deckId: deckId, start: nil, end: self.day(2026, 9, 2), db: $0) }
        kickers = try await db.queue.read { try LessonDates.kickers(db: $0, locale: self.us) }
        #expect(kickers[deckId] == nil)
    }
}
