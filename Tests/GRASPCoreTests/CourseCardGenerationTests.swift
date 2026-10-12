import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Course card generation")
struct CourseCardGenerationTests {
    /// Proposes whatever `script` returns for the n-th call (1-based), and
    /// can run a side effect first, so a test can break the database
    /// between two notes.
    private final class ScriptedGenerator: CardGenerator, @unchecked Sendable {
        var available = true
        var script: (Int, String) async -> [GeneratedCard] = { _, _ in [] }
        private(set) var calls = 0
        var isAvailable: Bool { get async { available } }
        var overviewContextWordBudget: Int { 1_800 }
        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] {
            calls += 1
            return await script(calls, noteContext)
        }
        func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
        func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation {
            ContextValidation(.valid)
        }
        func generateOverview(noteTitle: String, courseName: String, noteContext: String,
                              includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview { .empty }
        func generateFigures(noteTitle: String, courseName: String, noteContext: String,
                             sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
    }

    /// An empty deck in a course with `notes` notes, each with its text.
    private func makeCourse(notes: [String]) async throws -> (GRASPDatabase, course: String, deck: String, materials: [String]) {
        let db = try GRASPDatabase.inMemory()
        let ids = try await db.queue.write { conn -> (String, String, [String]) in
            let course = Course(semesterId: nil, name: "Biology")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Empty")
            try deck.insert(conn)
            var materialIds: [String] = []
            for (index, text) in notes.enumerated() {
                let material = Material(courseId: course.id, relativePath: "/v/\(index).md", kind: .markdown,
                                        contentHash: "h\(index)", title: "Note \(index + 1)")
                try material.insert(conn)
                try NoteText(materialId: material.id, raw: text, reflowed: text, wordCount: 3, hasMath: false).insert(conn)
                materialIds.append(material.id)
            }
            return (course.id, deck.id, materialIds)
        }
        return (db, ids.0, ids.1, ids.2)
    }

    private func cards(in db: GRASPDatabase, deck: String) async throws -> [Card] {
        try await db.queue.read { conn in
            let ids = try DeckCard.filter(Column("deckId") == deck).order(Column("sortIndex")).fetchAll(conn).map(\.cardId)
            return try ids.compactMap { try Card.fetchOne(conn, key: $0) }
        }
    }

    @Test("a course with no notes says so, rather than returning zero")
    func noMaterials() async throws {
        let (db, course, deck, _) = try await makeCourse(notes: [])
        let generator = ScriptedGenerator()
        let outcome = try await CardAI.generateCards(fromCourse: course, intoDeck: deck, using: generator, database: db)
        #expect(outcome == .noMaterials)
        #expect(generator.calls == 0)
    }

    @Test("notes with no readable text are an error, not an empty success")
    func noReadableNotes() async throws {
        let (db, course, deck, _) = try await makeCourse(notes: ["   ", ""])
        await #expect(throws: CardAI.CourseGenerationError.noReadableNotes) {
            try await CardAI.generateCards(fromCourse: course, intoDeck: deck, using: ScriptedGenerator(), database: db)
        }
    }

    @Test("an unreachable model is an error")
    func unavailable() async throws {
        let (db, course, deck, _) = try await makeCourse(notes: ["Chlorophyll absorbs light."])
        let generator = ScriptedGenerator()
        generator.available = false
        await #expect(throws: CardAI.CourseGenerationError.generatorUnavailable) {
            try await CardAI.generateCards(fromCourse: course, intoDeck: deck, using: generator, database: db)
        }
    }

    @Test("one note: its cards land in the deck as AI drafts pointing at the note")
    func oneNote() async throws {
        let (db, course, deck, materials) = try await makeCourse(notes: ["Chlorophyll absorbs light."])
        let generator = ScriptedGenerator()
        generator.script = { _, _ in
            [GeneratedCard(front: "Chlorophyll", back: "Absorbs light"),
             GeneratedCard(front: "Stroma", back: "The fluid around the thylakoids")]
        }
        let outcome = try await CardAI.generateCards(fromCourse: course, intoDeck: deck, using: generator, database: db)
        #expect(outcome == .generated(created: 2, notesRead: 1, notesWithoutText: 0))
        let written = try await cards(in: db, deck: deck)
        #expect(written.map(\.front) == ["Chlorophyll", "Stroma"])
        #expect(written.allSatisfy { $0.origin == .aiGenerated && $0.status == .draft && $0.materialId == materials[0] })
    }

    @Test("a model with nothing to add is a success with zero, distinct from the errors")
    func nothingToAdd() async throws {
        let (db, course, deck, _) = try await makeCourse(notes: ["Chlorophyll absorbs light."])
        let outcome = try await CardAI.generateCards(
            fromCourse: course, intoDeck: deck, using: ScriptedGenerator(), database: db)
        #expect(outcome == .generated(created: 0, notesRead: 1, notesWithoutText: 0))
    }

    @Test("several notes: each note's cards are written in turn, duplicates skipped, sort order continues")
    func severalNotes() async throws {
        let (db, course, deck, materials) = try await makeCourse(notes: ["one", "two", "three"])
        let generator = ScriptedGenerator()
        generator.script = { call, _ in
            switch call {
            case 1: return [GeneratedCard(front: "Alpha", back: "First term")]
            case 2: return [GeneratedCard(front: "Alpha", back: "First term"), GeneratedCard(front: "Beta", back: "Second term")]
            default: return [GeneratedCard(front: "Gamma", back: "Third term")]
            }
        }
        let outcome = try await CardAI.generateCards(fromCourse: course, intoDeck: deck, using: generator, database: db)
        #expect(outcome == .generated(created: 3, notesRead: 3, notesWithoutText: 0))
        let written = try await cards(in: db, deck: deck)
        #expect(written.map(\.front) == ["Alpha", "Beta", "Gamma"])
        #expect(Set(written.compactMap(\.materialId)) == Set(materials))
        let indexes = try await db.queue.read { try DeckCard.filter(Column("deckId") == deck).order(Column("sortIndex")).fetchAll($0).map(\.sortIndex) }
        #expect(indexes == [0, 1, 2])
    }

    @Test("a failure partway throws with the count, and earlier notes' cards are kept")
    func failureMidway() async throws {
        let (db, course, deck, _) = try await makeCourse(notes: ["one", "two", "three"])
        let generator = ScriptedGenerator()
        generator.script = { call, _ in
            if call == 2 {
                // Break the next write: the deck's card table vanishes.
                try? await db.queue.write { try $0.execute(sql: "DROP TABLE deckCard") }
            }
            return [GeneratedCard(front: "Term \(call)", back: "Meaning \(call)")]
        }
        do {
            _ = try await CardAI.generateCards(fromCourse: course, intoDeck: deck, using: generator, database: db)
            Issue.record("expected a thrown error")
        } catch let error as CardAI.CourseGenerationError {
            guard case .writeFailed(let created, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(created == 1)
        }
        let kept = try await db.queue.read { try Card.filter(Column("origin") == CardOrigin.aiGenerated.rawValue).fetchAll($0) }
        #expect(kept.map(\.front) == ["Term 1"])
        #expect(generator.calls == 2)
    }
}
