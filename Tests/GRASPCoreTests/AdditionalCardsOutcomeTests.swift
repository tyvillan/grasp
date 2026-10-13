import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// "Add more cards" has to say why it came back empty: the notes being
/// covered already is a finding, anything else is a failure (issue #1).
@Suite("Additional cards outcome")
struct AdditionalCardsOutcomeTests {
    private final class Generator: CardGenerator, @unchecked Sendable {
        var available = true
        /// Called once per note; may break things, then returns the proposals.
        var onCall: (Int) async -> [GeneratedCard] = { _ in [] }
        private(set) var calls = 0
        var isAvailable: Bool { get async { available } }
        var overviewContextWordBudget: Int { 1_800 }
        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] {
            calls += 1
            return await onCall(calls)
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

    /// A deck with one card from a note that has text.
    private func makeDeck(fromNote: Bool = true) async throws -> (GRASPDatabase, deckId: String) {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Biology")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Photosynthesis")
            try deck.insert(conn)
            var materialId: String?
            if fromNote {
                let material = Material(courseId: course.id, relativePath: "/v/p.md", kind: .markdown, contentHash: "h", title: "P")
                try material.insert(conn)
                let text = "Chlorophyll absorbs light. The Calvin cycle fixes carbon in the stroma."
                try NoteText(materialId: material.id, raw: text, reflowed: text, wordCount: 12, hasMath: false).insert(conn)
                materialId = material.id
            }
            let card = Card(materialId: materialId, front: "Chlorophyll", back: "Absorbs light",
                            origin: fromNote ? .parser : .manual, status: .active)
            try card.insert(conn)
            try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: 0).insert(conn)
            return deck.id
        }
        return (db, deckId)
    }

    @Test("new cards come back as .added with the count")
    func added() async throws {
        let (db, deckId) = try await makeDeck()
        let generator = Generator()
        generator.onCall = { _ in [GeneratedCard(front: "Stroma", back: "The fluid around the thylakoids")] }
        let outcome = await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: generator, database: db)
        #expect(outcome == .added(1))
    }

    @Test("a model that looked and found nothing new is .nothingToAdd, not a failure")
    func nothingToAdd() async throws {
        let (db, deckId) = try await makeDeck()
        let generator = Generator()
        generator.onCall = { _ in [] }
        #expect(await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: generator, database: db) == .nothingToAdd)
        // Only a duplicate of what is already there: also nothing to add.
        generator.onCall = { _ in [GeneratedCard(front: "Chlorophyll", back: "Absorbs light")] }
        #expect(await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: generator, database: db) == .nothingToAdd)
    }

    @Test("no model at the start is a failure")
    func unavailableAtStart() async throws {
        let (db, deckId) = try await makeDeck()
        let generator = Generator()
        generator.available = false
        let outcome = await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: generator, database: db)
        #expect(outcome == .failed(.generatorUnavailable))
        #expect(generator.calls == 0)
    }

    @Test("a model that is gone by the end of an empty run is a failure, not 'no gaps'")
    func goneMidRun() async throws {
        let (db, deckId) = try await makeDeck()
        let generator = Generator()
        generator.onCall = { [unowned generator] _ in generator.available = false; return [] }
        let outcome = await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: generator, database: db)
        #expect(outcome == .failed(.generatorUnavailable))
    }

    @Test("a deck with no card tied to a note has nothing to read")
    func noSourceNotes() async throws {
        let (db, deckId) = try await makeDeck(fromNote: false)
        let outcome = await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: Generator(), database: db)
        #expect(outcome == .failed(.noSourceNotes))
    }

    @Test("a save that fails is reported as such, with what was saved before it")
    func writeFails() async throws {
        let (db, deckId) = try await makeDeck()
        let generator = Generator()
        generator.onCall = { _ in
            try? await db.queue.write { try $0.execute(sql: "DROP TABLE deckCard") }
            return [GeneratedCard(front: "Stroma", back: "The fluid around the thylakoids")]
        }
        let outcome = await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: generator, database: db)
        guard case .failed(.writeFailed(let created, let reason)) = outcome else {
            Issue.record("expected a write failure, got \(outcome)"); return
        }
        #expect(created == 0)
        #expect(!reason.isEmpty)
    }

    @Test("the Int-returning function still works for existing callers")
    func legacyWrapper() async throws {
        let (db, deckId) = try await makeDeck()
        let generator = Generator()
        generator.onCall = { _ in [GeneratedCard(front: "Stroma", back: "The fluid around the thylakoids")] }
        #expect(await CardAI.generateAdditionalCards(inDecks: [deckId], using: generator, database: db) == 1)
        generator.available = false
        #expect(await CardAI.generateAdditionalCards(inDecks: [deckId], using: generator, database: db) == 0)
    }
}

/// A generator that overrides the per-note result, as the real ones do.
@Suite("Additional cards, per-note results")
struct AdditionalNoteResultTests {
    private final class Reporting: CardGenerator, @unchecked Sendable {
        var results: [AdditionalNoteResult] = []
        private var next = 0
        var isAvailable: Bool { get async { true } }
        var overviewContextWordBudget: Int { 1_800 }
        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
        func generateAdditionalResult(existing: [CandidatePair], noteContext: String, maxCount: Int,
                                      topic: String?) async -> AdditionalNoteResult {
            defer { next += 1 }
            return results[min(next, results.count - 1)]
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

    /// A deck with `notes` notes of one card each.
    private func makeDeck(notes: Int) async throws -> (GRASPDatabase, String) {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Biology")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Deck")
            try deck.insert(conn)
            for n in 0..<notes {
                let material = Material(courseId: course.id, relativePath: "/v/\(n).md", kind: .markdown,
                                        contentHash: "h\(n)", title: "Note \(n)")
                try material.insert(conn)
                let text = "Chlorophyll absorbs light. Note number \(n) talks about the Calvin cycle."
                try NoteText(materialId: material.id, raw: text, reflowed: text, wordCount: 12, hasMath: false).insert(conn)
                let card = Card(materialId: material.id, front: "Term \(n)", back: "Def \(n)", origin: .parser, status: .active)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: n).insert(conn)
            }
            return deck.id
        }
        return (db, deckId)
    }

    @Test("every note answered with an empty list is nothing to add")
    func allEmptyIsNothingToAdd() async throws {
        let (db, deckId) = try await makeDeck(notes: 3)
        let generator = Reporting()
        generator.results = [.cards([])]
        #expect(await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: generator, database: db) == .nothingToAdd)
    }

    @Test("every note failing is a failure with the reason, not 'no gaps'")
    func allFailedIsFailure() async throws {
        let (db, deckId) = try await makeDeck(notes: 3)
        let generator = Reporting()
        generator.results = [.failed("The model's reply couldn't be read.")]
        let outcome = await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: generator, database: db)
        #expect(outcome == .failed(.modelGaveNoAnswer(reason: "The model's reply couldn't be read.")))
    }

    @Test("some notes failing and the rest empty is still not a failure of the run")
    func mixedFailureAndEmpty() async throws {
        let (db, deckId) = try await makeDeck(notes: 2)
        let generator = Reporting()
        generator.results = [.failed("The model didn't answer."), .cards([])]
        #expect(await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: generator, database: db) == .nothingToAdd)
    }

    @Test("cards from the notes that worked are kept when another note failed")
    func partialSuccessKeepsCards() async throws {
        let (db, deckId) = try await makeDeck(notes: 2)
        let generator = Reporting()
        generator.results = [.failed("The model didn't answer."),
                             .cards([GeneratedCard(front: "Stroma", back: "The fluid around the thylakoids")])]
        let outcome = await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: generator, database: db)
        #expect(outcome == .added(1))
    }

    @Test("a generator that only implements generateAdditional is read as .cards through the default")
    func defaultWrapsOldFunction() async {
        struct Old: CardGenerator {
            var isAvailable: Bool { get async { true } }
            var overviewContextWordBudget: Int { 1_800 }
            func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
            func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
            func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] {
                [GeneratedCard(front: "A", back: "B")]
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
        let generator: any CardGenerator = Old()
        let result = await generator.generateAdditionalResult(existing: [], noteContext: "x", maxCount: 3, topic: nil)
        guard case .cards(let cards) = result else { Issue.record("expected cards"); return }
        #expect(cards.count == 1)
    }
}

/// The real Ollama/Cloud pipeline, over a stub transport.
@Suite("Additional cards, pipeline")
struct AdditionalPipelineTests {
    private struct Stub: ChatTransport {
        var answer: String?
        func complete(prompt: String, json: Bool, maxTokens: Int?) async throws -> String {
            guard let answer else { throw AIBackendError.unauthorized }
            return answer
        }
    }

    private func result(_ answer: String?) async -> AdditionalNoteResult {
        let generator = OllamaGenerator(transport: Stub(answer: answer), model: "stub", wordBudget: 3_000)
        return await generator.generateAdditionalResult(
            existing: [CandidatePair(front: "A", back: "B", sourceLine: 0)], noteContext: "Some note text.",
            maxCount: 3, topic: nil)
    }

    @Test("an empty list is the model finding nothing; garbage and errors are failures")
    func classifies() async {
        if case .cards(let cards) = await result(#"{"items": []}"#) { #expect(cards.isEmpty) } else { Issue.record("empty list should be .cards") }
        if case .cards(let cards) = await result(#"{"items": [{"front": "Stroma", "back": "Fluid"}]}"#) {
            #expect(cards.count == 1)
        } else { Issue.record("a card list should be .cards") }
        if case .failed = await result("I'm sorry, I can't help with that.") {} else { Issue.record("prose should be .failed") }
        if case .failed = await result(nil) {} else { Issue.record("a transport error should be .failed") }
    }

    @Test("the Int-returning function treats a failed note as no cards")
    func legacyFunctionStillWorks() async {
        let generator = OllamaGenerator(transport: Stub(answer: "nonsense"), model: "stub", wordBudget: 3_000)
        let cards = await generator.generateAdditional(
            existing: [], noteContext: "Some note text.", maxCount: 3, topic: nil)
        #expect(cards.isEmpty)
    }
}
