import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// Recognizing a guide, linking it to its exam and lecture decks, and the
/// exam page that reads a course's guides together.
@Suite("StudyGuideActions")
struct StudyGuideActionsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: String) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 14))!
    }

    struct Library {
        let db: GRASPDatabase
        let course: String
        let lecture1: String
        let lecture3: String
        let midterm1: String
        let midterm2: String
    }

    /// A course like the real one: lecture decks whose cards come from
    /// notes named the way the vault names them, and two midterms.
    private func makeLibrary() throws -> Library {
        let db = try GRASPDatabase.inMemory()
        let course = Course(semesterId: nil, name: "Microeconomic Principles", code: "ECO 2023")
        let lecture1 = Deck(courseId: course.id, name: "Lecture 1", chapter: "Lecture 1")
        let lecture3 = Deck(courseId: course.id, name: "Lecture 3", chapter: "Lecture 3")
        let midterm1 = CalendarEvent(courseId: course.id, kind: .exam, title: "ECO 2023 Midterm 1",
                                     startsAt: date("2026-09-29"))
        let midterm2 = CalendarEvent(courseId: course.id, kind: .exam, title: "ECO 2023 Midterm 2",
                                     startsAt: date("2026-10-29"))
        try db.queue.write { conn in
            try course.insert(conn)
            try lecture1.insert(conn)
            try lecture3.insert(conn)
            try midterm1.insert(conn)
            try midterm2.insert(conn)
            for (title, deck) in [("2026-08-27_Lecture-01_The-Economic-Way-of-Thinking", lecture1),
                                  ("Lecture-03_Elasticity-and-the-Applications-of-Demand_Summary_Part-1", lecture3)] {
                let material = Material(courseId: course.id, relativePath: "/vault/\(title).md",
                                        kind: .markdown, title: title)
                try material.insert(conn)
                let card = Card(materialId: material.id, front: "Term", back: "Meaning", origin: .parser, status: .active)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            }
        }
        return Library(db: db, course: course.id, lecture1: lecture1.id, lecture3: lecture3.id,
                       midterm1: midterm1.id, midterm2: midterm2.id)
    }

    static let guidePages = [
        """
        Exam 1 • Study Guide
        Tuesday, September 29, 2026 • 40 multiple-choice questions • open note
        """,
        """
        Part 1 • The Economic Way of Thinking (6 questions)
        You should be able to
        • Find the full cost of a choice from a list of items, leaving out sunk costs.
        • Read a production possibilities frontier and name the efficient points on it.
        Part 2 • Elasticity and the Applications of Demand (11 questions)
        You should be able to
        • Compute a midpoint elasticity from a demand schedule with two prices.
        • Example 1 - A price falls from $15 to $10 and sales rise from 20 to 30. Elastic or inelastic?
        Unit elastic: both change by 40%, so revenue stays at $300.
        Part 3 • Markets and Coordination (8 questions)
        You should be able to
        • Add individual demands at each price to get the market demand for plots.
        """,
    ]

    static let studentGuide = """
        ECO 2023 - EXAM 1 STUDY GUIDE
        PART 1 - THE ECONOMIC WAY OF THINKING
        Full Cost: Money paid plus the best alternative you give up.
        PART 2 - ELASTICITY AND APPLICATIONS OF DEMAND
        Midpoint = (Old + New) ÷ 2
        """

    private func importGuide(_ library: Library, title: String, pages: [String],
                             now: Date? = nil) throws -> StudyGuide {
        try library.db.queue.write { conn in
            let material = try Material.filter(Column("title") == title).fetchOne(conn)
                ?? Material(courseId: library.course, relativePath: "/Desktop/\(title).pdf",
                            kind: .pdf, contentHash: "h-\(pages.count)", title: title)
            try material.save(conn)
            return try StudyGuideActions.importGuide(
                material: material, pages: pages, now: now ?? date("2026-09-26"), db: conn
            )
        }
    }

    @Test("guide files are recognized by name; lecture notes and schedules aren't")
    func recognizesGuides() {
        for title in ["ECO 2023 - Exam 1 Study Guide", "Microeconomics Exam 1 Review Professor",
                      "Exam 1 Review Packet", "2026-10-20_Midterm-2-Review", "Final Exam Prep"] {
            #expect(StudyGuideMatcher.isStudyGuide(title: title), "\(title)")
        }
        for title in ["2026-08-27_Lecture-01_The-Economic-Way-of-Thinking", "Exam Schedule",
                      "Lecture-04_Gains-from-Exchange_Summary_Part-1", "Review of Linear Maps"] {
            #expect(!StudyGuideMatcher.isStudyGuide(title: title), "\(title)")
        }
    }

    @Test("a guide links to the exam on the date it states, then by 'Exam N', then the next exam")
    func linksExam() throws {
        let library = try makeLibrary()
        let calendar = self.calendar
        let now = date("2026-10-01")
        func exam(_ document: StudyGuideDocument, _ title: String) throws -> String? {
            try library.db.queue.read { conn in
                try StudyGuideMatcher.exam(for: document, guideTitle: title, courseId: library.course,
                                           now: now, calendar: calendar, db: conn)?.id
            }
        }
        #expect(try exam(StudyGuideDocument(examDate: "2026-09-29"), "Guide") == library.midterm1)
        // "Exam 1" and "Midterm 1" are the same exam.
        #expect(try exam(StudyGuideDocument(), "ECO 2023 - Exam 1 Study Guide") == library.midterm1)
        #expect(try exam(StudyGuideDocument(), "Midterm 2 Review") == library.midterm2)
        // Nothing to go on: the next exam still to come.
        #expect(try exam(StudyGuideDocument(), "Study Guide") == library.midterm2)
    }

    @Test("parts map to the lecture decks whose notes share their title's words")
    func matchesDecks() throws {
        let library = try makeLibrary()
        let document = StudyGuideParser.parse(pages: Self.guidePages)
        let matched = try library.db.queue.read {
            try StudyGuideMatcher.decks(for: document, courseId: library.course, db: $0)
        }
        #expect(matched[0] == [library.lecture1])
        #expect(matched[1] == [library.lecture3])
        // No lecture has reached Markets yet.
        #expect(matched[2] == nil)
    }

    @Test("importing saves the guide with its exam and decks; a hand-set part survives re-import")
    func importKeepsManualDecks() throws {
        let library = try makeLibrary()
        let guide = try importGuide(library, title: "Microeconomics Exam 1 Review Professor", pages: Self.guidePages)
        #expect(guide.examEventId == library.midterm1)
        #expect(guide.document()?.parts.count == 3)
        #expect(try library.db.queue.read {
            try StudyGuideActions.examDeckIds(examEventId: library.midterm1, db: $0)
        } == [library.lecture1, library.lecture3])

        // The student says Part 3 is covered by Lecture 3 after all, and
        // moves the guide to Midterm 2; then the file changes and imports again.
        try library.db.queue.write { conn in
            try StudyGuideActions.setDecks(guideId: guide.id, partIndex: 2, deckIds: [library.lecture3], db: conn)
            try StudyGuideActions.setExam(guideId: guide.id, examEventId: library.midterm2, db: conn)
        }
        let again = try importGuide(library, title: "Microeconomics Exam 1 Review Professor", pages: Self.guidePages)
        #expect(again.id == guide.id)
        #expect(again.examEventId == library.midterm2)
        let rows = try library.db.queue.read {
            try StudyGuidePartDeck.filter(Column("guideId") == guide.id).order(Column("partIndex")).fetchAll($0)
        }
        #expect(rows.map(\.partIndex) == [0, 1, 2])
        #expect(rows[2].deckId == library.lecture3 && rows[2].isManual)
    }

    @Test("an exam page reads two guides together, merging the parts they share")
    func examPageMerges() throws {
        let library = try makeLibrary()
        let professor = try importGuide(library, title: "Microeconomics Exam 1 Review Professor", pages: Self.guidePages)
        _ = try importGuide(library, title: "ECO 2023 - Exam 1 Study Guide", pages: [Self.studentGuide])
        try library.db.queue.write { conn in
            try StudyGuideActions.rate(guideId: professor.id, skillId: StudyGuideDocument.skillId(part: 0, skill: 1),
                                       rating: .shaky, db: conn)
        }
        let page = try #require(try library.db.queue.read {
            try StudyGuideActions.examPage(examEventId: library.midterm1, db: $0)
        })
        #expect(page.guides.count == 2)
        #expect(page.questionCount == 25)
        #expect(page.format == ["40 multiple-choice questions", "open note"])
        // The professor's titles win; the student's parts fold into them.
        #expect(page.parts.map(\.title) == ["The Economic Way of Thinking",
                                            "Elasticity and the Applications of Demand",
                                            "Markets and Coordination"])
        #expect(page.parts[0].terms.map(\.term) == ["Full Cost"])
        #expect(page.parts[0].skills.map(\.rating) == [nil, .shaky])
        #expect(page.parts[1].formulas == ["Midpoint = (Old + New) ÷ 2"])
        #expect(page.parts[1].examples.count == 1)
        #expect(page.parts[1].sources.count == 2)
        #expect(page.parts[1].weight(of: page.questionCount) == 11.0 / 25.0)
        #expect(page.deckIds == [library.lecture1, library.lecture3])
        #expect(try library.db.queue.read {
            try StudyGuideActions.guidedExams(courseId: library.course, since: date("2026-09-01"), db: $0)
        }.map(\.id) == [library.midterm1])
    }

    @Test("a guide file imported into a course becomes a guide, not a deck of cards")
    func importerMakesGuides() async throws {
        let library = try makeLibrary()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-guide-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ECO 2023 - Exam 1 Study Guide.md")
        let body = Self.studentGuide + "\n" + String(repeating: "More review text for the exam. ", count: 10)
        try body.write(to: file, atomically: false, encoding: .utf8)

        let summary = try await VaultScanner(database: library.db).importPaths([file], intoCourse: library.course)
        #expect(summary.studyGuidesImported == 1)
        #expect(summary.cardsCreated == 0)
        try await library.db.queue.read { conn in
            #expect(try Deck.filter(Column("name") == "General").fetchCount(conn) == 0)
            let guide = try #require(try StudyGuide.fetchOne(conn))
            #expect(guide.examEventId == library.midterm1)
            #expect(guide.document()?.parts.count == 2)
            // Still searchable, like any imported note.
            #expect(try NoteText.fetchOne(conn, key: guide.materialId) != nil)
        }
    }

    @Test("the new tables sync")
    func syncs() {
        for name in ["studyGuide", "studyGuidePartDeck", "skillRating"] {
            #expect(SyncSchema.table(named: name) != nil)
        }
    }
}
