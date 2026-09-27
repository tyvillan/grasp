import Foundation
import GRDB

/// The source files behind a deck: the Mac `AppStore.deckFiles` query,
/// moved here so both apps list the same files with the same counts.
public enum DeckFiles {
    public struct File: Identifiable, Sendable {
        public var id: String { material.id }
        public let material: Material
        /// Live cards from this file that are in the deck.
        public let cardCount: Int
        /// How many of those are still drafts awaiting review.
        public let draftCount: Int
    }

    /// The files a deck's cards were made from, in reading order, and how
    /// many of its cards were typed by hand (and so came from no file).
    ///
    /// "In this deck" means a file at least one live card in the deck came
    /// from -- a deck has no list of files, only cards pointing back at the
    /// note they were read out of.
    public static func list(inDecks deckIds: [String], db: Database) throws -> (files: [File], handTypedCardCount: Int) {
        guard !deckIds.isEmpty else { return ([], 0) }
        let materials = try OverviewQueries.materials(forDecks: deckIds, db: db)
        let placeholders = Array(repeating: "?", count: deckIds.count).joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT card.materialId AS materialId,
                   COUNT(DISTINCT card.id) AS cards,
                   COUNT(DISTINCT CASE WHEN card.status = ? THEN card.id END) AS drafts
            FROM deckCard
            JOIN card ON card.id = deckCard.cardId AND card.deletedAt IS NULL
            WHERE deckCard.deckId IN (\(placeholders))
            GROUP BY card.materialId
            """, arguments: StatementArguments([CardStatus.draft.rawValue] + deckIds))
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
            return File(material: material, cardCount: count.cards, draftCount: count.drafts)
        }
        return (files, handTyped)
    }

    /// Where a file lives: vault notes are stored relative to the vault;
    /// files added by hand from elsewhere keep their full path.
    public static func url(for material: Material, vaultRoot: URL?) -> URL? {
        let path = material.relativePath
        if path.hasPrefix("/") || (path.count > 2 && path.dropFirst().hasPrefix(":")) {
            return URL(fileURLWithPath: path)
        }
        return vaultRoot?.appendingPathComponent(path)
    }
}
