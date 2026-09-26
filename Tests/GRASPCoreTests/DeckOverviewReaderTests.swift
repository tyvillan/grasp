import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Deck overview reader")
struct DeckOverviewReaderTests {
    /// A course with one deck and three notes: one with an overview, one
    /// too short to summarise, one never written. Plus a hand-typed card.
    private func makeLibrary() async throws -> (GRASPDatabase, deckId: String, written: String, short: String, unwritten: String) {
        let db = try GRASPDatabase.inMemory()
        let ids = try await db.queue.write { conn -> (String, String, String, String) in
            let course = Course(semesterId: nil, name: "Linear Algebra")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Systems")
            try deck.insert(conn)

            func material(_ title: String, words: Int?) throws -> String {
                let material = Material(courseId: course.id, relativePath: "/vault/\(title).md", kind: .markdown,
                                        contentHash: "hash-\(title)", title: title)
                try material.insert(conn)
                if let words {
                    let text = Array(repeating: "word", count: words).joined(separator: " ")
                    try NoteText(materialId: material.id, raw: text, reflowed: text, wordCount: words, hasMath: false)
                        .insert(conn)
                }
                return material.id
            }
            func card(_ front: String, materialId: String?) throws {
                let card = Card(materialId: materialId, front: front, back: "A",
                                origin: materialId == nil ? .manual : .parser, status: .active)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            }

            let written = try material("2026-08-25_Lecture-01_Systems-of-Equations", words: 400)
            let short = try material("Short note", words: 20)
            let unwritten = try material("Lecture 3", words: 500)
            try card("What is a pivot?", materialId: written)
            try card("Short card", materialId: short)
            try card("Unwritten card", materialId: unwritten)
            try card("Typed by hand", materialId: nil)

            let document = OverviewDocument(
                title: "Row operations never move the answer",
                hook: "Why can you shuffle equations freely?",
                objectives: ["Solve a system by elimination"],
                sections: [
                    OverviewSection(
                        heading: "Pivots anchor each row",
                        paragraphs: ["A pivot is the first nonzero entry."],
                        terms: [OverviewDefinition(term: "Pivot", text: "The leading nonzero entry of a row.")],
                        figure: OverviewFigure(kind: .rowReduction,
                                               steps: [RowOperation(kind: .replace, target: 2, source: 1, multiplier: -2)],
                                               matrix: [[1, 2, 3], [2, 5, 8]], augmentedColumns: 1),
                        check: OverviewCheck(question: "Where is the pivot?", answer: "Top left.")
                    ),
                ],
                takeaways: ["Row operations keep the solution set."],
                formulas: [OverviewFormula(name: "Replacement", plain: "R2 → R2 − 2R1")]
            )
            try NoteOverview(materialId: written, bodyJSON: OverviewCoding.encode(document),
                             sourceContentHash: "hash-\(("2026-08-25_Lecture-01_Systems-of-Equations"))",
                             generator: .ollama).save(conn)
            return (deck.id, written, short, unwritten)
        }
        return (db, ids.0, ids.1, ids.2, ids.3)
    }

    @Test("an overview renders with ids, a fallback-free title, linked terms and its figure computed")
    func rendersEntry() async throws {
        let (db, deckId, written, _, _) = try await makeLibrary()
        let overview = try await db.queue.read { try DeckOverviewReader.read(deckIds: [deckId], db: $0) }

        let entry = try #require(overview.entries.first)
        #expect(overview.entries.count == 1)
        #expect(entry.materialId == written)
        #expect(entry.title == "Row operations never move the answer")
        #expect(entry.kicker?.hasPrefix("LECTURE 1") == true)
        #expect(entry.isStale == false)
        let section = try #require(entry.sections.first)
        #expect(section.id == "\(written)#s0")
        #expect(section.terms.first?.id == "\(written)#s0t0")
        #expect(section.check?.answer == "Top left.")
        guard case .rowReduction(let walk) = section.figure else {
            Issue.record("expected a row-reduction figure"); return
        }
        #expect(walk.states.count == walk.steps.count + 1)
        // The formula isn't in the note text, so the read-time clean-up drops it.
        #expect(entry.formulas.isEmpty)
        #expect(entry.takeaways == ["Row operations keep the solution set."])
    }

    @Test("notes without an overview say why, and hand-typed cards are counted")
    func missingAndHandTyped() async throws {
        let (db, deckId, _, short, unwritten) = try await makeLibrary()
        let overview = try await db.queue.read { try DeckOverviewReader.read(deckIds: [deckId], db: $0) }

        #expect(overview.handTypedCardCount == 1)
        let reasons = Dictionary(uniqueKeysWithValues: overview.missing.map { ($0.materialId, $0.reason) })
        #expect(reasons[short] == .tooShort(wordCount: 20))
        #expect(reasons[unwritten] == .neverWritten)
        #expect(overview.writable.map(\.materialId) == [unwritten])
    }

    @Test("a note edited since its overview was written reads as stale")
    func staleness() async throws {
        let (db, deckId, written, _, _) = try await makeLibrary()
        try await db.queue.write { conn in
            try conn.execute(sql: "UPDATE material SET contentHash = 'edited' WHERE id = ?", arguments: [written])
        }
        let overview = try await db.queue.read { try DeckOverviewReader.read(deckIds: [deckId], db: $0) }
        #expect(overview.staleEntries.map(\.materialId) == [written])
    }

    @Test("the lesson heading comes from the filename when the document has no title")
    func lessonHeading() {
        let material = Material(courseId: "c", relativePath: "/v/x.md", kind: .markdown, contentHash: nil,
                                title: "2026-08-25_Lecture-01_First-Day-Systems")
        let heading = DeckOverviewReader.lessonHeading(for: material)
        #expect(heading.title == "First Day Systems")
        #expect(heading.kicker?.contains("LECTURE 1") == true)
    }
}
