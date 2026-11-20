import Foundation
import GRDB
import Testing
@testable import GRASPCore

@Suite("HTML study guides")
struct HTMLStudyGuideTests {
    private let page = """
    <!DOCTYPE html><html><head><title></title>
    <style>
     body { color: red; }
     .x { margin: 0 }
    </style>
    <script>var junk = "Part 9 · Not a part";</script></head>
    <body>
    <header id="ally-beeline-theme-selector" data-beeline-skip=""><label>Bright</label></header>
    <main><section>
    <header><h2>What the Final Tests</h2><p>Thursday, December 3, 2026 &middot; 30 multiple-choice questions</p></header>
    <h3>Part 1 · Lectures 1 to 5 (10 questions)</h3>
    <p>The Exam 1 material, one lecture at a time. Each question tests an idea the course used again and again.</p>
    <h4>Lecture 1 · Thinking</h4>
    <p>You should be able to</p>
    <ul><li>Find the full cost of a choice: the money plus what you give up.</li>
        <li>Tell sunk costs from <strong>real</strong> costs &amp; ignore them.</li></ul>
    <div><p>Traps the wrong answers are built on</p>
    <ul><li>Calling something free because no money changes hands.</li></ul></div>
    <h4>Part 1 · Worked examples</h4>
    <details><summary>Example 1. A lunch special falls from $20 to $16 and sales rise from 5 to 6. Is demand elastic?</summary>
    <div><p>Quantity: 1 &divide; 5.5 = 18%. Price: 4 / 18 = 22%. So it is <strong>inelastic</strong>.</p></div></details>
    </section></main>
    <footer><a href="https://example.com"><span class="beeline-logo"></span><span>Powered by BeeLine Reader</span></a></footer>
    </body></html>
    """

    @Test("style, script, the reading tool's toolbar and credit line are dropped; entities and bullets are kept")
    func readsText() throws {
        let text = try #require(HTMLTextReader.text(from: page))
        #expect(!text.contains("color: red"))
        #expect(!text.contains("Not a part"))
        #expect(!text.contains("Bright"))
        #expect(!text.contains("Powered by"))
        #expect(text.contains("Thursday, December 3, 2026 · 30 multiple-choice questions"))
        #expect(text.contains("• Tell sunk costs from real costs & ignore them."))
        #expect(HTMLTextReader.text(from: "<html><body><script>x()</script></body></html>") == nil)
    }

    @Test("the parser reads the page as one part with its skills, traps and example, not two parts")
    func parses() throws {
        let document = StudyGuideParser.parse(try #require(HTMLTextReader.text(from: page)))
        #expect(document.parts.count == 1)
        let part = try #require(document.parts.first)
        #expect(part.number == 1)
        #expect(part.skills.count == 2)
        #expect(part.traps.count == 1)
        #expect(part.examples.count == 1)
        #expect(part.examples.first?.answer?.contains("inelastic") == true)
    }

    @Test("an .html file is imported into a course as a study guide")
    func importsAsGuide() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-html-guide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Final Exam Study Guide.html")
        try page.write(to: url, atomically: false, encoding: .utf8)

        let db = try GRASPDatabase.inMemory()
        let courseId: String = try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Micro")
            try course.insert(conn)
            return course.id
        }
        let summary = try await VaultScanner(database: db).importPaths([url], intoCourse: courseId)
        #expect(summary.studyGuidesImported == 1)
        let guides = try await db.queue.read { try StudyGuideActions.guides(forCourse: courseId, db: $0) }
        #expect(guides.count == 1)
        #expect(guides.first?.document()?.parts.first?.skills.count == 2)
    }
}
