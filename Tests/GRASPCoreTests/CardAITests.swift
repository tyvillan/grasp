import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Card AI")
struct CardAITests {
    /// Rewords by appending "!", rejects fronts containing "homework",
    /// rewrites backs containing "vague", and proposes one extra card.
    private final class ScriptedGenerator: CardGenerator, @unchecked Sendable {
        var proposal = GeneratedCard(front: "Stroma", back: "The fluid around the thylakoids")
        var isAvailable: Bool { get async { true } }
        var overviewContextWordBudget: Int { 1_800 }
        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
            candidates.map { GeneratedCard(front: $0.front, back: $0.back + "!") }
        }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] {
            [proposal, GeneratedCard(front: existing[0].front, back: existing[0].back)]
        }
        func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] {
            Array([GeneratedTestQuestion(prompt: "Where is carbon fixed?", correctAnswer: "The stroma"),
                   GeneratedTestQuestion(prompt: "What absorbs light?", correctAnswer: "Chlorophyll")].prefix(maxCount))
        }
        func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation {
            if front.contains("homework") { return ContextValidation(.reject) }
            if back.contains("vague") { return ContextValidation(.refine(newBack: "Absorbs light for photosynthesis")) }
            return ContextValidation(.valid)
        }
        func generateOverview(noteTitle: String, courseName: String, noteContext: String,
                              includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview { .empty }
        func generateFigures(noteTitle: String, courseName: String, noteContext: String,
                             sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
    }

    private func makeDeck() async throws -> (GRASPDatabase, deckId: String, cards: [String]) {
        let db = try GRASPDatabase.inMemory()
        let ids = try await db.queue.write { conn -> (String, [String]) in
            let course = Course(semesterId: nil, name: "Biology")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Photosynthesis")
            try deck.insert(conn)
            let material = Material(courseId: course.id, relativePath: "/v/p.md", kind: .markdown, contentHash: "h", title: "P")
            try material.insert(conn)
            let text = "Chlorophyll absorbs light. The Calvin cycle fixes carbon in the stroma."
            try NoteText(materialId: material.id, raw: text, reflowed: text, wordCount: 12, hasMath: false).insert(conn)
            var cardIds: [String] = []
            for (index, (front, back)) in [("Chlorophyll", "something vague"), ("Calvin cycle", "Fixes carbon"),
                                           ("Do the homework", "Page 12")].enumerated() {
                let card = Card(materialId: material.id, front: front, back: back, origin: .parser, status: .draft)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: index).insert(conn)
                cardIds.append(card.id)
            }
            return (deck.id, cardIds)
        }
        return (db, ids.0, ids.1)
    }

    @Test("refining a deck rewrites vague cards, removes assignment text, then rewords the rest")
    func refineDeck() async throws {
        let (db, deckId, cards) = try await makeDeck()
        let summary = await CardAI.refineDeck(inDecks: [deckId], using: ScriptedGenerator(), database: db)
        #expect(summary.context.refined.map(\.cardId) == [cards[0]])
        #expect(summary.context.removed.map(\.cardId) == [cards[2]])
        #expect(summary.wordingRefinedCount == 2)
        let first = try #require(try await db.queue.read { try Card.fetchOne($0, key: cards[0]) })
        #expect(first.back == "Absorbs light for photosynthesis!")
        #expect(first.originalBack == "something vague")
        #expect(first.isContextRefined)
        #expect(first.origin == .ollama)
        #expect(first.status == .draft)
        #expect(try await db.queue.read { try Card.fetchOne($0, key: cards[2])?.deletedAt } != nil)
    }

    @Test("filling gaps adds new drafts marked AI-generated and skips duplicates")
    func fillGaps() async throws {
        let (db, deckId, _) = try await makeDeck()
        let added = await CardAI.generateAdditionalCards(inDecks: [deckId], using: ScriptedGenerator(), database: db)
        #expect(added == 1)
        let stroma = try #require(try await db.queue.read { try Card.filter(Column("front") == "Stroma").fetchOne($0) })
        #expect(stroma.origin == .aiGenerated)
        #expect(stroma.status == .draft)
    }

    @Test("refining one card reports what happened")
    func refineCard() async throws {
        let (db, _, cards) = try await makeDeck()
        #expect(await CardAI.refineCard(cards[2], using: ScriptedGenerator(), database: db) == .removed)
        #expect(await CardAI.refineCard(cards[1], using: ScriptedGenerator(), database: db) == .refined)
        #expect(await CardAI.refineCard("missing", using: ScriptedGenerator(), database: db) == .unavailable)
    }

    @Test("AI test questions are written questions without a card, capped at the budget")
    func testQuestions() async throws {
        let (db, deckId, _) = try await makeDeck()
        let (questions, warning) = await CardAI.generateTestQuestions(
            inDecks: [deckId], maxCount: 1, using: ScriptedGenerator(), database: db)
        #expect(questions.count == 1)
        #expect(questions.first?.cardId == nil)
        #expect(questions.first?.type == .written)
        #expect(warning == nil)
        let none = await CardAI.generateTestQuestions(inDecks: [deckId], maxCount: 0, using: ScriptedGenerator(), database: db)
        #expect(none.questions.isEmpty)
    }

    @Test("the library-wide scan groups duplicates within a course, not across courses")
    func duplicatesAcrossCourses() async throws {
        let db = try GRASPDatabase.inMemory()
        try await db.queue.write { conn in
            for courseName in ["Biology", "Chemistry"] {
                let course = Course(semesterId: nil, name: courseName)
                try course.insert(conn)
                for index in 0..<2 {
                    let deck = Deck(courseId: course.id, name: "Deck \(index)")
                    try deck.insert(conn)
                    let card = Card(materialId: nil, front: "Mitochondria", back: "Makes ATP", origin: .parser, status: .draft)
                    try card.insert(conn)
                    try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: 0).insert(conn)
                }
            }
        }
        let groups = try await db.queue.read { try CardAI.duplicateGroupsAcrossAllCourses(db: $0) }
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.cards.count == 2 })
    }

    @Test("duplicate groups keep the card with history")
    func duplicates() {
        var studied = Card(materialId: nil, front: "Mitochondria", back: "Makes ATP", origin: .parser, status: .active)
        studied.reps = 3
        let twin = Card(materialId: nil, front: "Mitochondria", back: "Makes ATP", origin: .parser, status: .draft)
        let other = Card(materialId: nil, front: "Ribosome", back: "Builds proteins", origin: .parser, status: .draft)
        let groups = CardAI.duplicateGroups([twin, studied, other])
        #expect(groups.count == 1)
        #expect(groups.first?.suggestedKeepId == studied.id)
        #expect(groups.first?.hasCompetingHistory == false)
    }
}
