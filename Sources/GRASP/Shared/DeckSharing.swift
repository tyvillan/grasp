import Foundation
import GRASPCore

extension AppStore {
    func sharedDeck(_ deckId: String, includeQuestions: Bool) -> SharedDeck? {
        try? database.queue.read { db in try DeckShare.export(deckId: deckId, includeQuestions: includeQuestions, db: db) }
    }

    /// Reads a deck file and adds it to a course as a new deck, with an Undo.
    func importSharedDeck(from url: URL, intoCourse courseId: String) throws -> DeckShare.ImportResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let shared = try DeckShare.decode(try Data(contentsOf: url))
        let result = try database.queue.write { db in
            try DeckShare.importDeck(shared, intoCourse: courseId, db: db)
        }
        reload()
        var message = "Added \u{201C}\(shared.name)\u{201D}: \(result.cardsAdded) card\(result.cardsAdded == 1 ? "" : "s")"
        if result.duplicatesSkipped > 0 { message += ", \(result.duplicatesSkipped) already in this course" }
        postUndo(message, seconds: 12) { [weak self] in
            try? self?.deleteDeck(result.deckId, migrateCardsTo: nil)
        }
        return result
    }

    /// Plain wording for a deck file that couldn't be opened.
    static func shareMessage(for error: Error) -> String {
        switch error as? DeckShare.ShareError {
        case .notADeckFile: return "That isn't a GRASP deck file."
        case .newerVersion: return "That deck file is from a newer GRASP. Update GRASP to open it."
        case .courseMissing: return "That course no longer exists."
        case .deckMissing: return "That deck no longer exists."
        case nil: return "Couldn't open that file."
        }
    }
}
