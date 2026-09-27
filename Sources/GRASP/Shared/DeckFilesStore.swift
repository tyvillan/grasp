import Foundation
import GRDB
import GRASPCore

extension AppStore {
    /// One source file behind a deck, with how much of the deck came from it.
    struct DeckFile: Identifiable, Sendable {
        let material: Material
        /// Live cards from this file that are in the deck.
        let cardCount: Int
        /// How many of those are still drafts awaiting review.
        let draftCount: Int
        let url: URL
        var id: String { material.id }
        var existsOnDisk: Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    /// The files a deck's cards were made from, in reading order, and how
    /// many cards were typed by hand (see `DeckFiles.list`, shared with
    /// Windows).
    func deckFiles(inDecks deckIds: [String]) throws -> (files: [DeckFile], handTypedCardCount: Int) {
        let listed = try database.queue.read { db in try DeckFiles.list(inDecks: deckIds, db: db) }
        let files = listed.files.map { file in
            DeckFile(material: file.material, cardCount: file.cardCount, draftCount: file.draftCount,
                     url: fileURL(for: file.material))
        }
        return (files, listed.handTypedCardCount)
    }

    /// Where a material lives on disk. Vault notes are stored relative to
    /// the vault; files added by hand from elsewhere keep their full path.
    func fileURL(for material: Material) -> URL {
        DeckFiles.url(for: material, vaultRoot: URL(fileURLWithPath: vaultPath))
            ?? URL(fileURLWithPath: material.relativePath)
    }
}
