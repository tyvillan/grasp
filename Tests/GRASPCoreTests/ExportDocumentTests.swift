import Testing
import Foundation
@testable import GRASPCore

/// Overviews and study guides as files: the shared layout every app's
/// download writes out.
@Suite("ExportDocument")
struct ExportDocumentTests {
    let sample = ExportDocument(title: "ECO 2023 Midterm 1", subtitle: "40 questions", blocks: [
        .heading("Part 1 · Thinking", level: 1),
        .bullets(["Find the **full cost**"]),
        .table(rows: [["1", "2", "3"], ["4", "5", "6"]], bar: 2),
        .problem(number: 1, label: nil, question: "Gas is $45.\nWhat is the full cost?", hint: "Uses a table."),
        .heading("Concept map", level: 2),
        .code("graph TD\na --> b", language: "mermaid"),
        .pageBreak,
        .answer(number: 1, label: nil, steps: ["$45 + $100"], answer: "$145"),
    ])

    @Test("Markdown keeps headings, emphasis, line breaks, an augmented bar and a Mermaid map")
    func markdown() {
        let md = sample.markdown()
        #expect(md.hasPrefix("# ECO 2023 Midterm 1\n*40 questions*"))
        #expect(md.contains("## Part 1 · Thinking"))
        #expect(md.contains("- Find the **full cost**"))
        #expect(md.contains("| 1 | 2 | │ 3 |"))
        #expect(md.contains("**1.** Gas is $45.  \nWhat is the full cost?"))
        #expect(md.contains("```mermaid\ngraph TD"))
    }

    @Test("HTML escapes text, turns inline Markdown into tags and leaves the map off paper")
    func html() {
        let html = ExportDocument(title: "A < B", blocks: [.paragraph("**bold** and `x & y`")]).html()
        #expect(html.contains("<h1>A &lt; B</h1>"))
        #expect(html.contains("<b>bold</b> and <code>x &amp; y</code>"))
        let full = sample.html()
        #expect(full.contains("What is the full cost?"))
        #expect(full.contains("Gas is $45.<br>What"))
        #expect(full.contains("<td class=\"bar\">3</td>"))
        #expect(!full.contains("graph TD"))
        #expect(!full.contains("Concept map"))
    }

    @Test("a file name drops characters a file system refuses")
    func fileName() {
        #expect(ExportDocument(title: "Week 1: I/O").fileName == "Week 1- I-O")
    }

    @Test("an exam page exports its problems numbered once, answers only in the key")
    func studyGuide() throws {
        let db = try GRASPDatabase.inMemory()
        let course = Course(semesterId: nil, name: "Micro", code: "ECO 2023")
        let deck = Deck(courseId: course.id, name: "Lecture 1", chapter: "Lecture 1")
        let exam = CalendarEvent(courseId: course.id, kind: .exam, title: "Midterm 1", startsAt: Date(timeIntervalSince1970: 1_790_000_000))
        let pages = ["""
            Part 1 • The Economic Way of Thinking (6 questions)
            You should be able to
            • Find the full cost of a choice from a list of items, leaving out sunk costs.
            • Example 1 - Gas is $45 and work pays $100. What is the full cost of going?
            $145, since both happen only because she goes.
            """]
        let page = try db.queue.write { conn -> StudyGuideActions.ExamPage? in
            try course.insert(conn); try deck.insert(conn); try exam.insert(conn)
            let material = Material(courseId: course.id, relativePath: "/g.pdf", kind: .pdf, contentHash: "h", title: "Exam 1 Review")
            try material.insert(conn)
            let guide = try StudyGuideActions.importGuide(material: material, pages: pages, db: conn)
            try StudyGuideActions.setExam(guideId: guide.id, examEventId: exam.id, db: conn)
            try StudyGuideActions.setDecks(guideId: guide.id, partIndex: 0, deckIds: [deck.id], db: conn)
            return try StudyGuideActions.examPage(examEventId: exam.id, db: conn)
        }
        let examPage = try #require(page)
        let withKey = StudyGuideExport.document(page: examPage, deckNames: [deck.id: deck.name], answerKey: true)
        let md = withKey.markdown()
        #expect(md.contains("*6 of 6 questions · Covers Lecture 1*"))
        #expect(md.contains("**1.** Gas is $45 and work pays $100. What is the full cost of going?"))
        #expect(md.contains("## Answer key"))
        #expect(md.contains("$145, since both happen only because she goes."))
        let sheet = StudyGuideExport.document(page: examPage, deckNames: [:], answerKey: false).markdown()
        #expect(sheet.contains("What is the full cost of going?"))
        #expect(!sheet.contains("$145"))
        #expect(!sheet.contains("Answer key"))
    }
}
