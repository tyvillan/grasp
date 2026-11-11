import Testing
import Foundation
import GRDB
#if canImport(PDFKit)
import PDFKit
import CoreText
import CoreGraphics
#endif
@testable import GRASPCore

/// A lecture's deck saved beside its note: left out of the scan, read as an
/// outline by the overview writer, shown beside the sections it matches.
@Suite("Slide decks")
struct SlideDeckTests {
    @Test("a deck file is named STEM.slides.pdf, a second STEM.slides-2.pdf, and nothing else is")
    func names() {
        #expect(SlideDeck.isDeckFile("2026-10-20_Module-07_Arrays-and-Pointers.slides.pdf"))
        #expect(SlideDeck.isDeckFile("2026-10-20_Module-07_Arrays.slides-2.pdf"))
        #expect(SlideDeck.isDeckFile("Lecture.slides.pptx"))
        #expect(!SlideDeck.isDeckFile("2026-10-20_Module-07_Arrays-and-Pointers.md"))
        #expect(!SlideDeck.isDeckFile("Midterm_Reference_Sheet.pdf"))
        #expect(!SlideDeck.isDeckFile("slides.pdf"))
        #expect(!SlideDeck.isDeckFile("My slides notes.pdf"))
        #expect(SlideDeck.candidatePaths(forNote: "/v/01_Lectures/2026-10-20_Module-07.md")
                == ["/v/01_Lectures/2026-10-20_Module-07.slides.pdf", "/v/01_Lectures/2026-10-20_Module-07.slides-2.pdf",
                    "/v/01_Lectures/2026-10-20_Module-07.slides-3.pdf"])
    }

    static let pages = [
        "COP 3275C\nModule 7",
        "REFERENCES",
        "TYPES OF ARRAYS\nBehaves like a list of variables with a uniform naming mechanism.\nStatic array size is determined when declared\ndynamic array size is determined while the program is running",
        "ARRAY INDEXED VARIABLES\nIndexed variable as an argument to a function is the same as any variable of that datatype\nvoid MyFunction(int);",
        "POINTER VARIABLE\npointer (pointer variable)\na memory cell that stores the address of a data item\nsyntax: type *variable\nint m = 25;\nint *itemp;",
        "ARRAY INDEXED VARIABLES\nanother slide with the same title and enough words to count here",
        "unable to meet the make-up deadline, other accommodations may\nbe arranged with the instructor in advance of the exam date",
        "Va r i a b l e s a n d data t y p e s\nan int holds whole numbers and a double holds decimals",
    ]

    @Test("slides keep their page numbers, read ALL CAPS titles plainly, and skip title and divider pages")
    func slides() {
        let slides = SlideDeck.slides(from: Self.pages)
        // The fragment on page 7 and the letter-spaced title on page 8 have no title to match.
        #expect(slides.map(\.page) == [3, 4, 5, 6])
        #expect(slides.map(\.title) == ["Types of arrays", "Array indexed variables", "Pointer variable", "Array indexed variables"])
        #expect(slides[0].text.contains("uniform naming mechanism"))
    }

    @Test("the outline lists titles in order, once in a row, and is nil when there is nothing to say")
    func outline() {
        let text = SlideDeck.outline(of: SlideDeck.slides(from: Self.pages))
        #expect(text?.hasPrefix(SlideDeck.outlineMarker) == true)
        #expect(text?.contains("1. Types of arrays\n2. Array indexed variables\n3. Pointer variable\n4. Array indexed variables") == true)
        #expect(SlideDeck.outline(of: Array(SlideDeck.slides(from: Self.pages).prefix(2))) == nil)
    }

    @Test("a slide goes beside the section that uses its title's words, once, and a passing mention gets nothing")
    func placing() {
        let sections = [
            OverviewSection(heading: "A pointer holds the address of a variable",
                            paragraphs: ["A pointer variable stores the address of a data item in a memory cell."]),
            OverviewSection(heading: "An array is a list of variables",
                            paragraphs: ["Static arrays have a size set when declared, and dynamic arrays set it while running."]),
            OverviewSection(heading: "Braces make blocks", paragraphs: ["A block starts and ends with braces."]),
        ]
        let placed = SlideDeck.placements(of: SlideDeck.slides(from: Self.pages), in: sections)
        #expect(placed[0]?.map(\.page) == [5])
        #expect(placed[1]?.map(\.page).contains(3) == true)
        #expect(placed[2] == nil)
        let all = placed.values.flatMap { $0 }.map(\.page)
        #expect(Set(all).count == all.count)
    }

    #if canImport(PDFKit)
    /// A deck on disk: one PDF page per entry, the text drawn so it can be read back.
    static func writeDeck(_ pages: [String], to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 960, height: 540)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for text in pages {
            context.beginPDFPage(nil)
            var y = 480.0
            for line in text.components(separatedBy: "\n") {
                let attributed = NSAttributedString(string: line, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 28, nil)])
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 40, y: y)
                CTLineDraw(ctLine, context)
                y -= 40
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func vault() throws -> (root: URL, lectures: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decks-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("College/Fall Semester 2026-2027/Systems Programming with C++/01_Lectures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (root, dir)
    }

    static let note = """
    # 2026-10-20 · Module 7 — Arrays and Pointers

    ## Key Terms

    - **Array** — a collection of homogeneous data, meaning many values of the same type.
    - **Pointer** — a variable that stores the memory address of another variable.
    - **Zero-based indexing** — the first element of an array is at index 0, so an array of five has indexes 0 to 4.
    """

    @Test("a scan imports the note and leaves its deck out, with no cards from slide text")
    func scanLeavesDeckOut() async throws {
        let (root, dir) = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.note.write(to: dir.appendingPathComponent("2026-10-20_Module-07_Arrays-and-Pointers.md"), atomically: true, encoding: .utf8)
        Self.writeDeck(Self.pages, to: dir.appendingPathComponent("2026-10-20_Module-07_Arrays-and-Pointers.slides.pdf"))
        let db = try GRASPDatabase.inMemory()
        _ = try await VaultScanner(database: db).scan(vaultRoot: root)
        let paths = try await db.queue.read { try Material.fetchAll($0).map(\.relativePath) }
        #expect(paths.count == 1 && paths[0].hasSuffix("Arrays-and-Pointers.md"))
    }

    @Test("a deck imported before this existed is retired by the next scan, with its untouched drafts, and an approved card stays")
    func sweepsOldDeck() async throws {
        let (root, dir) = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.note.write(to: dir.appendingPathComponent("2026-10-20_Module-07_Arrays-and-Pointers.md"), atomically: true, encoding: .utf8)
        let deckURL = dir.appendingPathComponent("2026-10-20_Module-07_Arrays-and-Pointers.slides.pdf")
        Self.writeDeck(Self.pages, to: deckURL)
        let db = try GRASPDatabase.inMemory()
        _ = try await VaultScanner(database: db).scan(vaultRoot: root)
        let kept = try await db.queue.write { conn -> (String, String) in
            let course = try #require(try Course.fetchOne(conn))
            let deck = Deck(courseId: course.id, name: "Old")
            try deck.insert(conn)
            // What the older scan did: the deck as a material with cards from its slides.
            let material = Material(courseId: course.id, relativePath: deckURL.path, kind: .pdf, contentHash: "h",
                                    title: "2026-10-20_Module-07_Arrays-and-Pointers.slides")
            try material.insert(conn)
            let draft = Card(materialId: material.id, front: "TYPES OF ARRAYS", back: "Behaves like a list", origin: .parser, status: .draft)
            let approved = Card(materialId: material.id, front: "Pointer", back: "An address", origin: .parser, status: .active)
            for card in [draft, approved] { try card.insert(conn); try DeckCard(deckId: deck.id, cardId: card.id).insert(conn) }
            return (draft.id, approved.id)
        }
        _ = try await VaultScanner(database: db).scan(vaultRoot: root)
        let (deckGone, draftExists, approvedExists) = try await db.queue.read { conn in
            (try Material.filter(Column("relativePath") == deckURL.path).fetchOne(conn)?.deletedAt != nil,
             try Card.fetchOne(conn, key: kept.0) != nil, try Card.fetchOne(conn, key: kept.1) != nil)
        }
        #expect(deckGone)
        #expect(!draftExists)
        #expect(approvedExists)
    }

    @Test("the writer reads the deck beside a note as an outline, and a note with no deck has none")
    func writerOutline() throws {
        let (root, dir) = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = dir.appendingPathComponent("2026-10-20_Module-07_Arrays-and-Pointers.md")
        #expect(OverviewWriter.slideOutline(forNoteAt: note.path) == nil)
        Self.writeDeck(Self.pages, to: dir.appendingPathComponent("2026-10-20_Module-07_Arrays-and-Pointers.slides.pdf"))
        let outline = OverviewWriter.slideOutline(forNoteAt: note.path)
        #expect(outline?.contains("Types of arrays") == true)
        #expect(outline?.contains("Pointer variable") == true)
    }
    #endif

    @Test("the plan is told the titles are an outline only when they are there")
    func planPrompt() {
        let outline = SlideDeck.outline(of: SlideDeck.slides(from: Self.pages))!
        let with = OllamaGenerator.lessonPlanPrompt(noteTitle: "Arrays", courseName: "C++", noteContext: "Arrays hold values.\n\n" + outline,
                                                    includeFormulas: false)
        let without = OllamaGenerator.lessonPlanPrompt(noteTitle: "Arrays", courseName: "C++", noteContext: "Arrays hold values.",
                                                       includeFormulas: false)
        #expect(with.contains("The notes end with the lecture's slide titles"))
        #expect(with.contains("teach only what the notes above them cover"))
        #expect(!without.contains("slide titles"))
    }
}
