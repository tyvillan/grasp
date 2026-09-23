import Foundation
import GRDB

/// How complete a deck's overviews are, for the tab badge.
public struct DeckOverviewStatus: Sendable, Equatable {
    public let materialCount: Int
    public let overviewCount: Int
    public let staleCount: Int

    public init(materialCount: Int, overviewCount: Int, staleCount: Int) {
        self.materialCount = materialCount
        self.overviewCount = overviewCount
        self.staleCount = staleCount
    }

    public var isComplete: Bool { overviewCount == materialCount && staleCount == 0 }
    public var hasAnything: Bool { overviewCount > 0 }
}

/// The SQL behind the overview feature.
///
/// This lives in `GRASPCore` rather than `AppStore`, which breaks the
/// convention that store queries stay in `AppStore` and tests mirror them.
/// That convention is fine for statements whose correctness is obvious at a
/// glance; the join below is the opposite. Its correctness is entirely in
/// its null handling, and a mirrored copy in the test target is exactly the
/// thing that would drift on it and then pass anyway.
public enum OverviewQueries {
    /// The materials behind a set of decks.
    ///
    /// There is no deck-to-material link in this schema, and there
    /// shouldn't be: a deck's relationship to a note is entirely transitive
    /// through the cards made from it. The inner joins do real work --
    /// a hand-typed card has `materialId == nil`, and so does a card whose
    /// material was deleted (`ON DELETE SET NULL`), and neither has a note
    /// to overview. Soft-deleted cards and materials drop out for the same
    /// reason.
    ///
    /// Ordered the way a stitched overview should read: by note date, with
    /// undated notes last. SQLite sorts NULL first on an ascending key,
    /// hence the explicit `IS NULL` sort column ahead of it.
    public static func materials(forDecks deckIds: [String], db: Database) throws -> [Material] {
        guard !deckIds.isEmpty else { return [] }
        let placeholders = databaseQuestionMarks(count: deckIds.count)
        return try Material.fetchAll(db, sql: """
            SELECT DISTINCT material.*
            FROM deckCard
            JOIN card ON card.id = deckCard.cardId AND card.deletedAt IS NULL
            JOIN material ON material.id = card.materialId AND material.deletedAt IS NULL
            WHERE deckCard.deckId IN (\(placeholders))
            ORDER BY material.noteDate IS NULL, material.noteDate, material.title
            """, arguments: StatementArguments(deckIds))
    }

    /// Every deck's overview coverage in one pass, for `AppStore.reload()`.
    ///
    /// `IS NOT` is SQLite's null-safe inequality: a material with no
    /// `contentHash` compares equal to an overview that recorded none, so
    /// it isn't counted stale. That's the same "no signal, don't nag" rule
    /// `NoteOverview.isStale(for:)` applies, and the two must agree or the
    /// badge and the banner will disagree on screen.
    public static func statusByDeck(db: Database) throws -> [String: DeckOverviewStatus] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT deckCard.deckId AS deckId,
                   COUNT(DISTINCT material.id) AS materialCount,
                   COUNT(DISTINCT noteOverview.materialId) AS overviewCount,
                   COUNT(DISTINCT CASE
                       WHEN noteOverview.sourceContentHash IS NOT material.contentHash
                       THEN noteOverview.materialId END) AS staleCount
            FROM deckCard
            JOIN card ON card.id = deckCard.cardId AND card.deletedAt IS NULL
            JOIN material ON material.id = card.materialId AND material.deletedAt IS NULL
            LEFT JOIN noteOverview ON noteOverview.materialId = material.id
            GROUP BY deckCard.deckId
            """)
        return rows.reduce(into: [:]) { result, row in
            guard let deckId: String = row["deckId"] else { return }
            result[deckId] = DeckOverviewStatus(
                materialCount: row["materialCount"] ?? 0,
                overviewCount: row["overviewCount"] ?? 0,
                staleCount: row["staleCount"] ?? 0
            )
        }
    }

    /// The live cards made from one note, for resolving a definition term
    /// to the card that tests it. Soft-deleted cards are included and
    /// ranked last by `OverviewCardLinker` rather than excluded here --
    /// a term whose only card was deleted is still worth linking, and the
    /// linker is where that judgement belongs.
    public static func cards(forMaterial materialId: String, db: Database) throws -> [Card] {
        try Card.filter(Column("materialId") == materialId).fetchAll(db)
    }
}
