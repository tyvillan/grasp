import Foundation
import GRASPCore

/// The Questions tab's reads and writes. Saved questions belong to a deck,
/// like cards, and sync once active (a draft stays on its device).
extension AppStore {
    func savedQuestions(inDecks deckIds: [String]) -> [TestQuestion] {
        (try? database.queue.read { try QuestionBank.listing(inDecks: deckIds, db: $0) }) ?? []
    }

    func questionHistory(of ids: [String]) -> [String: QuestionHistory] {
        (try? database.queue.read { try QuestionBank.history(of: ids, db: $0) }) ?? [:]
    }

    /// How many questions a test could draw from these decks (active only).
    func activeQuestionCount(inDecks deckIds: [String]) -> Int {
        (try? database.queue.read { try QuestionBank.activeCount(inDecks: deckIds, db: $0) }) ?? 0
    }

    /// How many questions a test with these settings can really ask, for Test setup.
    func matchingTestQuestionCount(deckIds: [String], config: TestBuilder.Config, includeQuestions: Bool) -> Int {
        (try? database.queue.read {
            try Study.matchingTestQuestionCount(deckIds: deckIds, config: config, includeQuestions: includeQuestions, db: $0)
        }) ?? 0
    }

    func saveQuestion(_ input: UserQuestionInput, deckId: String) throws {
        try database.queue.write { _ = try QuestionBank.create(input, deckId: deckId, db: $0) }
        reload()
    }

    func updateQuestion(_ id: String, with input: UserQuestionInput) throws {
        try database.queue.write { try QuestionBank.update(id, with: input, db: $0) }
        reload()
    }

    func setQuestionStatus(_ id: String, to status: QuestionStatus) {
        try? database.queue.write { try QuestionBank.setStatus(id, to: status, db: $0) }
        reload()
    }

    /// Moves questions to another deck. Nil when the deck is gone.
    @discardableResult
    func moveQuestions(_ ids: [String], toDeck deckId: String) -> QuestionBank.MoveResult? {
        let result = try? database.queue.write { try QuestionBank.move(ids, toDeck: deckId, db: $0) }
        reload()
        return result
    }

    /// Copies questions into another deck. Nil when the deck is gone.
    @discardableResult
    func copyQuestions(_ ids: [String], toDeck deckId: String) -> QuestionBank.MoveResult? {
        let result = try? database.queue.write { try QuestionBank.copy(ids, toDeck: deckId, db: $0) }
        reload()
        return result
    }

    func setQuestionStatus(_ ids: [String], to status: QuestionStatus) {
        try? database.queue.write { try QuestionBank.setStatus(ids, to: status, db: $0) }
        reload()
    }

    func deleteCodeQuestions(_ ids: [String]) {
        try? database.queue.write { db in for id in ids { try CodeQuestionBank.delete(id, db: db) } }
        reload()
    }

    /// How many approved cards these decks have (what a test's flashcards come from).
    func activeCardCount(inDecks deckIds: [String]) -> Int {
        ((try? cards(inDecks: deckIds)) ?? []).filter { $0.status == .active }.count
    }

    /// Active cards of these decks, for linking a question to one.
    func linkableCards(inDecks deckIds: [String]) -> [Card] {
        ((try? cards(inDecks: deckIds)) ?? []).filter { $0.status == .active }
    }
}
