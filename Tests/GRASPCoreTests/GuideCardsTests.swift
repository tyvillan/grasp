import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// A guide's worked examples as flashcards.
@Suite("Guide cards")
struct GuideCardsTests {
    static let text = """
    Exam 1 Study Guide
    Part 1 · Costs (3 questions)
    Example 1 - A shop sells mugs.
    Question: Which is the average cost? (a) $1 (b) $2 (c) $3 (d) $4 (e) $5
    Answer: (c) $3.
    Example 2 - A bakery has two ovens.
    Question: (a) How many loaves? (b) How much profit?
    Answer: (a) 40 loaves. (b) $120.
    Example 3 - Use the table on page 4 to find the price.
    Question: What is the price?
    Answer: $9
    """

    private func library(examTitle: String? = nil) async throws -> (db: GRASPDatabase, guideId: String, courseId: String) {
        let db = try GRASPDatabase.inMemory()
        let course = Course(semesterId: nil, name: "Microeconomic Principles", code: "ECO 2023")
        let material = Material(courseId: course.id, relativePath: "/vault/guide.md", kind: .markdown,
                                title: "ECO 2023 - Exam 1 Study Guide")
        let guideId = try await db.queue.write { conn -> String in
            try course.insert(conn)
            try material.insert(conn)
            if let examTitle {
                try CalendarEvent(courseId: course.id, kind: .exam, title: examTitle, startsAt: Date()).insert(conn)
            }
            return try StudyGuideActions.importGuide(material: material, pages: [Self.text], db: conn).id
        }
        return (db, guideId, course.id)
    }

    @Test("a lettered question keeps its choices on the front and the option's words on the back; the rest stay as written")
    func shapes() async throws {
        let (db, guideId, courseId) = try await library()
        let result = try await db.queue.write { try GuideCards.addCards(guideId: guideId, db: $0) }
        #expect(result.added == 2 && result.alreadyThere == 0)
        let cards = try await db.queue.read { try Card.fetchAll($0) }.sorted { $0.front < $1.front }
        let lettered = try #require(cards.first { $0.front.contains("(e) $5") })
        #expect(lettered.back == "$3")
        #expect(lettered.front.contains("Which is the average cost?"))
        let multi = try #require(cards.first { $0.front.contains("How many loaves") })
        #expect(multi.back == "(a) 40 loaves. (b) $120.")
        #expect(cards.allSatisfy { $0.status == .active && $0.origin == .manual && $0.materialId != nil })
        _ = courseId
    }

    @Test("an example that needs a table or has no answer is left out, and the count says so")
    func skipped() async throws {
        let (db, guideId, _) = try await library()
        let result = try await db.queue.write { try GuideCards.addCards(guideId: guideId, db: $0) }
        #expect(result.skipped == 1)
    }

    @Test("the cards go in one deck named for the exam, and pressing again adds nothing")
    func deckAndRepeat() async throws {
        let (db, guideId, courseId) = try await library(examTitle: "ECO 2023 Midterm 1")
        // The guide links to its exam when imported, so import again after the event exists.
        try await db.queue.write { conn in
            var guide = try #require(try StudyGuide.fetchOne(conn, key: guideId))
            guide.examEventId = try CalendarEvent.fetchOne(conn)?.id
            try guide.save(conn)
        }
        let first = try await db.queue.write { try GuideCards.addCards(guideId: guideId, db: $0) }
        #expect(first.deckName == "ECO 2023 Midterm 1 practice" && first.added == 2)
        let again = try await db.queue.write { try GuideCards.addCards(guideId: guideId, db: $0) }
        #expect(again.added == 0 && again.alreadyThere == 2)
        let (decks, links, cards) = try await db.queue.read { conn in
            (try Deck.filter(Column("courseId") == courseId).fetchAll(conn), try DeckCard.fetchCount(conn), try Card.fetchCount(conn))
        }
        #expect(decks.count == 1 && decks[0].name == "ECO 2023 Midterm 1 practice")
        #expect(links == 2 && cards == 2)
    }

    @Test("a card the student deleted does not come back")
    func deletedStaysDeleted() async throws {
        let (db, guideId, _) = try await library()
        try await db.queue.write { _ = try GuideCards.addCards(guideId: guideId, db: $0) }
        try await db.queue.write { conn in
            var card = try #require(try Card.fetchAll(conn).first)
            card.deletedAt = Date()
            try card.save(conn)
        }
        let again = try await db.queue.write { try GuideCards.addCards(guideId: guideId, db: $0) }
        #expect(again.added == 0 && again.alreadyThere == 2)
    }

    @Test("a guide with nothing to add makes no deck")
    func noEmptyDeck() async throws {
        let db = try GRASPDatabase.inMemory()
        let course = Course(semesterId: nil, name: "Course", code: nil)
        let material = Material(courseId: course.id, relativePath: "/vault/g.md", kind: .markdown, title: "Exam 1 Study Guide")
        let guideId = try await db.queue.write { conn -> String in
            try course.insert(conn); try material.insert(conn)
            return try StudyGuideActions.importGuide(material: material, pages: ["Exam 1 Study Guide\nPart 1 · Nothing (1 question)"], db: conn).id
        }
        let result = try await db.queue.write { try GuideCards.addCards(guideId: guideId, db: $0) }
        #expect(result.added == 0 && result.deckId == nil)
        let decks = try await db.queue.read { try Deck.fetchCount($0) }
        #expect(decks == 0)
    }
}

/// The real Exam 2 guide, when its fixture is on this machine.
@Suite("Exam 2 guide as cards", .enabled(if: FileManager.default.fileExists(atPath: Exam2Fixture.file.path)))
struct Exam2GuideCardsTests {
    @Test("all 59 examples become cards: 40 with five lettered choices, none with a letter on the back")
    func allFiftyNine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("College/Fall Semester 2026-2027/Microeconomic Principles")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Exam2Fixture.file, to: dir.appendingPathComponent("ECO 2023 - Exam 2 Study Guide.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try GRASPDatabase.inMemory()
        _ = try await VaultScanner(database: db).scan(vaultRoot: root)
        let guideId = try #require(try await db.queue.read { try StudyGuide.fetchOne($0)?.id })
        let before = try await db.queue.read { try Card.fetchCount($0) }

        let result = try await db.queue.write { try GuideCards.addCards(guideId: guideId, db: $0) }
        #expect(result.added == 59 && result.skipped == 0 && result.alreadyThere == 0)
        let cards = try await db.queue.read { try Card.filter(Column("origin") == "manual").fetchAll($0) }
        let after = try await db.queue.read { try Card.fetchCount($0) }
        #expect(cards.count == 59 && after == before + 59)
        let lettered = cards.filter { $0.front.contains("\n(a) ") && $0.front.contains("\n(e) ") }
        #expect(lettered.count == 40)
        #expect(lettered.allSatisfy { !$0.back.hasPrefix("(") && !$0.back.isEmpty })
        // The numeric ones now grade on the words typed.
        let numeric = try #require(lettered.first { $0.front.contains("Practice exam Q14.") })
        #expect(numeric.back == "$190")
        #expect(AnswerGrading.grade(given: "$190", correct: numeric.back) == .correct)
        let again = try await db.queue.write { try GuideCards.addCards(guideId: guideId, db: $0) }
        #expect(again.added == 0)
    }
}
