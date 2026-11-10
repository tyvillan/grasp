import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// The visuals reach a stored overview with no model call and no rewrite.
@Suite("Note visuals in a stored overview")
struct NoteVisualsReaderTests {
    static let note = """
    ## The Compilation Pipeline

    ```
    source (.cpp, plain text)
       → compiler checks syntax → object file
       → linker joins your objects + OS/library objects
       → executable / application
    ```

    ## Data Types Introduced

    | Type | Notes |
    | --- | --- |
    | `int` | whole numbers |
    | `double` | twice the size of an int |

    ## Anatomy of a C++ Program

    ```cpp
    #include <iostream>   // needed in every program in this class
    #include <string>     // needed whenever you use the string class
    using namespace std;

    int main()
    {
        int numPies, numSlices, totalSlices;
        totalSlices = numPies * numSlices;
        return 0;         // 0 means it ran correctly
    }
    ```
    """

    private func library(title: String, raw: String, sections: [OverviewSection]) async throws -> (GRASPDatabase, String) {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Systems Programming")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Module 1")
            try deck.insert(conn)
            let material = Material(courseId: course.id, relativePath: "/vault/\(title).md", kind: .markdown,
                                    contentHash: "hash", title: title)
            try material.insert(conn)
            try NoteText(materialId: material.id, raw: raw, reflowed: raw, wordCount: raw.split(whereSeparator: \.isWhitespace).count,
                         hasMath: false).insert(conn)
            let card = Card(materialId: material.id, front: "What is a pipeline?", back: "A", origin: .parser, status: .active)
            try card.insert(conn)
            try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            let document = OverviewDocument(title: "Programs are built in stages", sections: sections)
            try NoteOverview(materialId: material.id, bodyJSON: OverviewCoding.encode(document),
                             sourceContentHash: "hash", generator: .ollama).save(conn)
            return deck.id
        }
        return (db, deckId)
    }

    @Test("each picture lands under the section that discusses it, the plain listing is replaced, and nothing is left over")
    func placed() async throws {
        let (db, deckId) = try await library(title: "2026-08-27_Module-01_Introduction-to-C++", raw: Self.note, sections: [
            OverviewSection(heading: "Programs are built by compiling and linking",
                            paragraphs: ["The compiler turns source into an object file, and the linker joins objects into an executable."]),
            OverviewSection(heading: "Every variable has a type",
                            paragraphs: ["An int holds whole numbers and a double is twice the size of an int."]),
            OverviewSection(heading: "A program reads numPies and numSlices",
                            paragraphs: ["The program stores totalSlices from numPies and numSlices."]),
        ])
        let overview = try await db.queue.read { try DeckOverviewReader.read(deckIds: [deckId], db: $0) }
        let entry = try #require(overview.entries.first)
        func kinds(_ s: RenderedSection) -> [String] {
            s.visuals.map { v in
                switch v.kind {
                case .pipeline: return "pipeline"
                case .table: return "table"
                case .annotatedCode: return "code"
                case .memory: return "memory"
                }
            }
        }
        #expect(kinds(entry.sections[0]) == ["pipeline"])
        #expect(kinds(entry.sections[1]) == ["table"])
        #expect(Set(kinds(entry.sections[2])) == ["code", "memory"])
        #expect(entry.sections[2].code == nil)
        #expect(entry.noteVisuals.isEmpty)
    }

    @Test("a picture no section discusses is kept after the lesson, not dropped")
    func leftOver() async throws {
        let (db, deckId) = try await library(title: "2026-08-27_Module-01_Introduction-to-C++", raw: Self.note, sections: [
            OverviewSection(heading: "Braces make blocks", paragraphs: ["A block starts and ends with braces."]),
        ])
        let overview = try await db.queue.read { try DeckOverviewReader.read(deckIds: [deckId], db: $0) }
        let entry = try #require(overview.entries.first)
        #expect(entry.sections[0].visuals.isEmpty)
        #expect(entry.noteVisuals.count >= 3)
    }

    @Test("a syllabus overview has no pictures")
    func syllabus() async throws {
        let raw = "Instructor office hours are Tuesdays. Late work is not accepted. Attendance is not graded. Submit on Canvas.\n\n"
            + "| Part | Weight |\n| --- | --- |\n| Homework | 35% |\n| Labs | 15% |\n| Midterm | 25% |\n"
        let (db, deckId) = try await library(title: "2026-08-25_Module-01_First-Day-Syllabus-Overview", raw: raw, sections: [
            OverviewSection(heading: "The course has weights", paragraphs: ["Homework is a part of the grade."]),
        ])
        let overview = try await db.queue.read { try DeckOverviewReader.read(deckIds: [deckId], db: $0) }
        let entry = try #require(overview.entries.first)
        #expect(entry.sections[0].visuals.isEmpty && entry.noteVisuals.isEmpty)
    }
}
