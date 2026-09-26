import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Overview writer")
struct OverviewWriterTests {
    /// Answers every overview call with one section, and draws a two-box
    /// diagram.
    private final class OneSectionGenerator: CardGenerator, @unchecked Sendable {
        var available = true
        var overviewCalls = 0

        var isAvailable: Bool { get async { available } }
        var overviewContextWordBudget: Int { 1_800 }
        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
        func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
        func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation {
            ContextValidation(.valid)
        }
        func generateOverview(noteTitle: String, courseName: String, noteContext: String,
                              includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview {
            overviewCalls += 1
            return GeneratedOverview(document: OverviewDocument(
                title: "Light becomes sugar",
                sections: [OverviewSection(heading: "Chlorophyll catches light", paragraphs: ["Chlorophyll absorbs light."])]
            ))
        }
        func generateDiagram(noteTitle: String, courseName: String, conceptOutline: String) async -> String {
            "graph TD\nA[Light]-->B[Sugar]"
        }
        func generateFigures(noteTitle: String, courseName: String, noteContext: String,
                             sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
    }

    private func makeNote(words: Int) async throws -> (GRASPDatabase, String) {
        let db = try GRASPDatabase.inMemory()
        let id = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Biology")
            try course.insert(conn)
            let material = Material(courseId: course.id, relativePath: "/v/photo.md", kind: .markdown,
                                    contentHash: "hash-1", title: "Photosynthesis")
            try material.insert(conn)
            let sentence = "Chlorophyll in the thylakoid membrane absorbs light and passes the energy on."
            let text = Array(repeating: sentence, count: max(1, words / 12)).joined(separator: " ")
            try NoteText(materialId: material.id, raw: text, reflowed: text,
                         wordCount: text.split(separator: " ").count, hasMath: false).insert(conn)
            return material.id
        }
        return (db, id)
    }

    @Test("a written overview is saved with the note's hash, then left alone until the note changes")
    func writesThenUnchanged() async throws {
        let (db, id) = try await makeNote(words: 240)
        let generator = OneSectionGenerator()
        let first = await OverviewWriter.write(materialId: id, using: generator, database: db)
        #expect(first == .written)
        let stored = try #require(try await db.queue.read { try NoteOverview.fetchOne($0, key: id) })
        #expect(stored.sourceContentHash == "hash-1")
        #expect(stored.document()?.sections.first?.heading == "Chlorophyll catches light")
        #expect(stored.mermaidSource?.contains("Light") == true)

        let calls = generator.overviewCalls
        #expect(await OverviewWriter.write(materialId: id, using: generator, database: db) == .unchanged)
        #expect(generator.overviewCalls == calls)
        #expect(await OverviewWriter.write(materialId: id, force: true, using: generator, database: db) == .written)
    }

    @Test("a note too short to summarise isn't sent to the model")
    func tooShort() async throws {
        let (db, id) = try await makeNote(words: 20)
        let generator = OneSectionGenerator()
        #expect(await OverviewWriter.write(materialId: id, using: generator, database: db) == .tooShort)
        #expect(generator.overviewCalls == 0)
    }

    @Test("no model, or no such note, writes nothing")
    func unavailable() async throws {
        let (db, id) = try await makeNote(words: 240)
        let generator = OneSectionGenerator()
        generator.available = false
        #expect(await OverviewWriter.write(materialId: id, using: generator, database: db) == .unavailable)
        generator.available = true
        #expect(await OverviewWriter.write(materialId: "missing", using: generator, database: db) == .unavailable)
        #expect(try await db.queue.read { try NoteOverview.fetchCount($0) } == 0)
    }
}
