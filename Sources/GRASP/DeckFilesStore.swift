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

    /// The files a deck's cards were made from, in reading order.
    ///
    /// "In this deck" means a file at least one live card in the deck came
    /// from -- the deck itself has no list of files, only cards that point
    /// back at the note they were read out of. Hand-typed cards point at
    /// nothing, so they're counted separately by the caller.
    func deckFiles(inDecks deckIds: [String]) throws -> (files: [DeckFile], handTypedCardCount: Int) {
        guard !deckIds.isEmpty else { return ([], 0) }
        let placeholders = databaseQuestionMarks(count: deckIds.count)
        let (materials, rows) = try database.queue.read { db in
            let materials = try OverviewQueries.materials(forDecks: deckIds, db: db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT card.materialId AS materialId,
                       COUNT(DISTINCT card.id) AS cards,
                       COUNT(DISTINCT CASE WHEN card.status = ? THEN card.id END) AS drafts
                FROM deckCard
                JOIN card ON card.id = deckCard.cardId AND card.deletedAt IS NULL
                WHERE deckCard.deckId IN (\(placeholders))
                GROUP BY card.materialId
                """, arguments: StatementArguments([CardStatus.draft.rawValue] + deckIds))
            return (materials, rows)
        }

        var counts: [String: (cards: Int, drafts: Int)] = [:]
        var handTyped = 0
        for row in rows {
            let cards: Int = row["cards"]
            if let materialId: String = row["materialId"] {
                counts[materialId] = (cards, row["drafts"])
            } else {
                handTyped = cards
            }
        }

        let files = materials.map { material in
            let count = counts[material.id] ?? (0, 0)
            return DeckFile(
                material: material, cardCount: count.cards, draftCount: count.drafts,
                url: fileURL(for: material)
            )
        }
        return (files, handTyped)
    }

    /// Where a material lives on disk. Vault notes are stored relative to
    /// the vault; files added by hand from elsewhere keep their full path.
    func fileURL(for material: Material) -> URL {
        if material.relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: material.relativePath)
        }
        return URL(fileURLWithPath: vaultPath).appendingPathComponent(material.relativePath)
    }
}
