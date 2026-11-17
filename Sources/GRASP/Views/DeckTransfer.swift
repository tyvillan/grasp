import SwiftUI
import UniformTypeIdentifiers

/// A deck row being dragged to a new place in the sidebar list (custom order).
/// A custom type, like `CardTransfer`, so a deck row accepts only decks and
/// cards, never text dragged in from other apps.
nonisolated struct DeckTransfer: Codable, Transferable {
    let deckId: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .graspDeck)
    }
}

nonisolated extension UTType {
    /// Declared in Info.plist as an exported type, like `graspCard`.
    static let graspDeck = UTType(exportedAs: "com.tyvillan.grasp.deck")
}
