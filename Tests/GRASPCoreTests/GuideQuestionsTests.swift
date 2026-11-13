import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// A guide's worked examples saved as questions, not cards.
@Suite("Guide questions")
struct GuideQuestionsTests {
    static let text = """
    Exam 1 Study Guide
    Part 1 · Costs (3 questions)
    Example 1 - A shop sells mugs.
    Question: Which is the average cost? (a) $1 (b) $2 (c) $3 (d) $4 (e) $5
    Step 1: Add the costs and divide.
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

    @Test("a lettered question is saved as multiple choice with its options in order; the rest as written")
    func shapes() async throws {
        let (db, guideId, _) = try await library()
        let result = try await db.queue.write { try GuideQuestions.addQuestions(guideId: guideId, db: $0) }
        #expect(result.added == 2 && result.skipped == 1 && result.alreadyThere == 0)
        let saved = try await db.queue.read { try TestQuestion.fetchAll($0) }
        #expect(saved.allSatisfy { $0.sourceKind == .yours && $0.statusKind == .active && $0.materialId != nil })
        let mc = try #require(saved.compactMap(\.problem).first { $0.kind == .multipleChoice })
        #expect(mc.prompt == "Example 1 - A shop sells mugs. Which is the average cost?"
                || mc.prompt.hasSuffix("Which is the average cost?"))
        #expect(mc.choices == ["$1", "$2", "$3", "$4", "$5"] && mc.correct == 2)
        #expect(mc.explanation?.contains("Add the costs and divide.") == true, "explanation=\(String(describing: mc.explanation))")
        let written = try #require(saved.compactMap(\.problem).first { $0.kind == .written })
        #expect(written.answer == "(a) 40 loaves. (b) $120.")
    }

    @Test("it makes questions and no cards, in one deck named for the exam")
    func noCards() async throws {
        let (db, guideId, courseId) = try await library(examTitle: "ECO 2023 Midterm 1")
        try await db.queue.write { conn in
            var guide = try #require(try StudyGuide.fetchOne(conn, key: guideId))
            guide.examEventId = try CalendarEvent.fetchOne(conn)?.id
            try guide.save(conn)
        }
        let cardsBefore = try await db.queue.read { try Card.fetchCount($0) }
        let result = try await db.queue.write { try GuideQuestions.addQuestions(guideId: guideId, db: $0) }
        #expect(result.deckName == "ECO 2023 Midterm 1 practice")
        let (cards, decks, links) = try await db.queue.read { conn in
            (try Card.fetchCount(conn), try Deck.filter(Column("courseId") == courseId).fetchAll(conn), try DeckCard.fetchCount(conn))
        }
        #expect(cards == cardsBefore && links == 0)
        #expect(decks.count == 1 && decks[0].name == "ECO 2023 Midterm 1 practice")
        let listed = try await db.queue.read { try QuestionBank.listing(inDecks: decks.map(\.id), db: $0) }
        #expect(listed.count == 2)
    }

    @Test("asking again adds nothing, and a question the student deleted stays deleted")
    func repeatAndDelete() async throws {
        let (db, guideId, _) = try await library()
        try await db.queue.write { _ = try GuideQuestions.addQuestions(guideId: guideId, db: $0) }
        var again = try await db.queue.write { try GuideQuestions.addQuestions(guideId: guideId, db: $0) }
        #expect(again.added == 0 && again.alreadyThere == 2)
        try await db.queue.write { conn in
            var q = try #require(try TestQuestion.fetchAll(conn).first)
            q.deletedAt = Date()
            try q.save(conn)
        }
        again = try await db.queue.write { try GuideQuestions.addQuestions(guideId: guideId, db: $0) }
        #expect(again.added == 0 && again.alreadyThere == 2)
        let count = try await db.queue.read { try TestQuestion.fetchCount($0) }
        #expect(count == 2)
    }
}

/// The real Exam 2 guide, when its fixture is on this machine.
@Suite("Exam 2 guide as questions", .enabled(if: FileManager.default.fileExists(atPath: Exam2Fixture.file.path)))
struct Exam2GuideQuestionsTests {
    @Test("59 questions: 40 five-option multiple choice with the key's answers, 19 written; a test can ask them")
    func allFiftyNine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gq-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("College/Fall Semester 2026-2027/Microeconomic Principles")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Exam2Fixture.file, to: dir.appendingPathComponent("ECO 2023 - Exam 2 Study Guide.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try GRASPDatabase.inMemory()
        _ = try await VaultScanner(database: db).scan(vaultRoot: root)
        let guideId = try #require(try await db.queue.read { try StudyGuide.fetchOne($0)?.id })
        let cardsBefore = try await db.queue.read { try Card.fetchCount($0) }

        let result = try await db.queue.write { try GuideQuestions.addQuestions(guideId: guideId, db: $0) }
        #expect(result.added == 59 && result.skipped == 0)
        let cardsAfter = try await db.queue.read { try Card.fetchCount($0) }
        #expect(cardsAfter == cardsBefore)

        let saved = try await db.queue.read { try TestQuestion.fetchAll($0) }.compactMap(\.problem)
        let mc = saved.filter { $0.kind == .multipleChoice }
        #expect(mc.count == 40 && saved.filter { $0.kind == .written }.count == 19)
        #expect(mc.allSatisfy { $0.choices?.count == 5 && $0.correct != nil })
        let withWhy = saved.filter { ($0.explanation ?? "").count > 10 }.count
        // The app keeps an explanation of one to five sentences; a longer worked solution stays in the guide.
        #expect(withWhy >= 45, "only \(withWhy) of 59 kept their explanation")
        let key = Exam2GuideChoiceTests.key
        for (number, letterIndex) in key.enumerated().map({ ($0.offset + 1, "abcde".firstIndex(of: Character($0.element))!.utf16Offset(in: "abcde")) }) {
            let q = try #require(mc.first { $0.prompt.contains("Practice exam Q\(number).") }, "Q\(number)")
            #expect(q.correct == letterIndex, "Q\(number)")
        }

        // Listed under the course's decks, and a test round can pick them.
        let deckIds = try await db.queue.read { try Deck.fetchAll($0).map(\.id) }
        let listed = try await db.queue.read { try QuestionBank.listing(inDecks: deckIds, db: $0) }
        #expect(listed.count == 59)
        let round = try await db.queue.read { conn -> [LearnEngine.RoundQuestion] in
            var rng = SystemRandomNumberGenerator()
            return try CodeQuestionBank.pickRound(count: 20, inDecks: deckIds, allowWritten: false,
                                                  allowMultipleChoice: true, using: &rng, db: conn)
        }
        #expect(!round.isEmpty && round.allSatisfy { $0.type == .multipleChoice && $0.choices?.count == 5 })
        let again = try await db.queue.write { try GuideQuestions.addQuestions(guideId: guideId, db: $0) }
        #expect(again.added == 0)
    }
}
