import Foundation
import GRDB

/// Browsing and editing cards, and searching notes: the Mac's `AppStore`
/// card actions, moved here so the Windows app does exactly the same thing
/// to the same rows. Each takes the database connection its caller opened,
/// like `Study`.
public enum CardActions {
    /// SQLite's `IN (...)` caps at a few hundred bound parameters on some
    /// builds -- unreachable at today's deck sizes, but a "select all in a
    /// huge deck" is a real enough path to guard cheaply rather than trust.
    static let chunkSize = 500

    // MARK: - Reading

    /// Every live card in these decks, deck by deck, each deck in its own
    /// order -- a course's All Cards reads as its decks laid end to end,
    /// not interleaved by raw sort index.
    public static func cards(inDecks deckIds: [String], db: Database) throws -> [Card] {
        let cardIds = try DeckCard
            .filter(deckIds.contains(Column("deckId")))
            .order(Column("deckId"), Column("sortIndex"))
            .fetchAll(db)
            .map(\.cardId)
        guard !cardIds.isEmpty else { return [] }
        var cards: [Card] = []
        for chunk in cardIds.chunked(into: chunkSize) {
            cards += try Card
                .filter(chunk.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .fetchAll(db)
        }
        // A card in two of the requested decks (a convention, not a
        // constraint) keeps its first position rather than crashing here.
        let order = Dictionary(cardIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        cards.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        return cards
    }

    /// The deck a card sits in (a card belongs to one deck by convention).
    public static func deckId(ofCard cardId: String, db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT deckId FROM deckCard WHERE cardId = ? LIMIT 1", arguments: [cardId])
    }

    // MARK: - Editing

    /// Saves an edit to a card's text -- and only its text.
    ///
    /// Edit sheets hold a copy of the card from when they opened. Saving
    /// that whole copy wrote back every column as it was then: a review
    /// graded meanwhile lost its new due date, and a card an AI pass had
    /// removed or rewritten while the sheet was open came back as it was.
    /// So the row is re-read and only front and back change, and only when
    /// they actually did. Returns whether anything changed.
    @discardableResult
    public static func updateText(cardId: String, front: String, back: String,
                                  now: Date = Date(), db: Database) throws -> Bool {
        let front = front.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = back.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty, !back.isEmpty,
              var current = try Card.fetchOne(db, key: cardId), current.deletedAt == nil,
              current.front != front || current.back != back
        else { return false }
        current.front = front
        current.back = back
        // Hand-edited parser cards stop being the scanner's to replace on
        // re-import. AI-generated ones keep their origin, so their "worth
        // double-checking" badge survives a typo fix.
        if current.origin == .parser { current.origin = .manual }
        current.updatedAt = now
        try current.save(db)
        return true
    }

    /// Soft delete: sets `deletedAt` rather than removing the row, so a
    /// card's review history stays intact for stats.
    public static func delete(_ cardIds: [String], now: Date = Date(), db: Database) throws {
        for chunk in cardIds.chunked(into: chunkSize) {
            try Card
                .filter(chunk.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .updateAll(db, Column("deletedAt").set(to: now), Column("updatedAt").set(to: now))
        }
    }

    public static func setStatus(_ cardIds: [String], to status: CardStatus, now: Date = Date(), db: Database) throws {
        for chunk in cardIds.chunked(into: chunkSize) {
            try Card
                .filter(chunk.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .updateAll(db, Column("status").set(to: status.rawValue), Column("updatedAt").set(to: now))
        }
    }

    /// Undoes one AI context-refinement: restores `back` from
    /// `originalBack`. A no-op for a card that was never refined.
    public static func revertContextRefinement(_ cardId: String, now: Date = Date(), db: Database) throws {
        guard var card = try Card.fetchOne(db, key: cardId), let original = card.originalBack else { return }
        card.back = original
        card.originalBack = nil
        card.isContextRefined = false
        card.updatedAt = now
        try card.save(db)
    }

    /// Moves cards to the end of another deck, in the order given. Cards
    /// already in the target stay where they are: moving them "into" their
    /// own deck used to push them to the end of it.
    public static func move(_ cardIds: [String], toDeck targetDeckId: String, db: Database) throws {
        guard let target = try Deck.fetchOne(db, key: targetDeckId), target.deletedAt == nil else { return }
        let alreadyThere = Set(try String.fetchAll(db, sql:
            "SELECT cardId FROM deckCard WHERE deckId = ?", arguments: [targetDeckId]))
        let moving = cardIds.filter { !alreadyThere.contains($0) }
        guard !moving.isEmpty else { return }
        for chunk in moving.chunked(into: chunkSize) {
            try DeckCard.filter(chunk.contains(Column("cardId"))).deleteAll(db)
        }
        var next = try nextSortIndex(inDeck: targetDeckId, db: db)
        for cardId in moving {
            try DeckCard(deckId: targetDeckId, cardId: cardId, sortIndex: next).insert(db)
            next += 1
        }
    }

    /// A card typed by hand. Active, not a draft: the draft gate exists to
    /// catch parser noise, and a card someone just wrote has already had
    /// the human glance that gate is there to force.
    @discardableResult
    public static func createManual(front: String, back: String, deckId: String, db: Database) throws -> String {
        let front = front.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = back.trimmingCharacters(in: .whitespacesAndNewlines)
        let card = Card(
            materialId: nil, front: front, back: back,
            hasMath: back.contains("\\(") || back.contains("\\["),
            origin: .manual, status: .active
        )
        try card.insert(db)
        try DeckCard(deckId: deckId, cardId: card.id, sortIndex: try nextSortIndex(inDeck: deckId, db: db)).insert(db)
        return card.id
    }

    private static func nextSortIndex(inDeck deckId: String, db: Database) throws -> Int {
        try Int.fetchOne(db, sql:
            "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?", arguments: [deckId]) ?? 0
    }

    // MARK: - Search

    public struct NoteMatch: Identifiable, Sendable, Equatable {
        public var id: String { materialId }
        public let materialId: String
        public let courseId: String
        public let title: String
        /// A short excerpt with each match between `\u{2}` and `\u{3}`.
        public let snippet: String
    }

    /// Full-text search over every imported note (FTS5's `noteFTS`, kept
    /// in step with `noteText`). The FTS rowid mirrors `noteText`'s implicit
    /// rowid, not its `materialId` key, so the join goes through that.
    public static func searchNotes(_ query: String, limit: Int = 40, db: Database) throws -> [NoteMatch] {
        let sanitized = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            // Quoted: bare, an uppercase AND, OR or NOT is FTS5 syntax, and
            // "TCP OR UDP" or "AND gate" was a syntax error that showed up
            // as "No matches". A quoted prefix still matches the same words.
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
        guard !sanitized.isEmpty else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT material.id AS materialId, material.courseId AS courseId, material.title AS title,
                   snippet(noteFTS, 0, char(2), char(3), '…', 12) AS snippet
            FROM noteFTS
            JOIN noteText ON noteText.rowid = noteFTS.rowid
            JOIN material ON material.id = noteText.materialId
            WHERE noteFTS MATCH ? AND material.deletedAt IS NULL
            ORDER BY rank
            LIMIT ?
            """, arguments: [sanitized, limit])
            .map { row in
                NoteMatch(materialId: row["materialId"], courseId: row["courseId"],
                          title: row["title"], snippet: row["snippet"])
            }
    }

    public struct CardMatch: Identifiable, Sendable {
        public var id: String { card.id }
        public let card: Card
        public let deckId: String
        public let courseId: String
    }

    /// Cards whose front or back contains every word of the query, in any
    /// case -- the Mac finds cards by filtering a deck's list; on Windows
    /// the one search box looks through cards too.
    public static func searchCards(_ query: String, limit: Int = 40, db: Database) throws -> [CardMatch] {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var sql = """
            SELECT card.*, deckCard.deckId AS matchDeckId, deck.courseId AS matchCourseId
            FROM card
            JOIN deckCard ON deckCard.cardId = card.id
            JOIN deck ON deck.id = deckCard.deckId
            WHERE card.deletedAt IS NULL AND deck.deletedAt IS NULL
            """
        var arguments: [DatabaseValueConvertible] = []
        for word in words {
            sql += " AND (lower(card.front) LIKE ? OR lower(card.back) LIKE ?)"
            arguments += ["%\(word)%", "%\(word)%"]
        }
        sql += " ORDER BY card.status = 'active' DESC, length(card.front) LIMIT ?"
        arguments.append(limit)
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
            CardMatch(card: try Card(row: row), deckId: row["matchDeckId"], courseId: row["matchCourseId"])
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
