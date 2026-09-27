import Foundation
import GRDB

/// Organising the library by hand: editing, archiving, adding and deleting
/// courses, and adding, renaming and deleting decks. The Mac `AppStore`'s
/// course and deck actions, moved here so both apps change the same rows
/// the same way.
public enum LibraryActions {
    // MARK: - Courses

    public static func materialCount(inCourse courseId: String, db: Database) throws -> Int {
        try Material.filter(Column("courseId") == courseId).fetchCount(db)
    }

    public static func updateCourse(_ course: Course, now: Date = Date(), db: Database) throws {
        var updated = course
        updated.updatedAt = now
        try updated.save(db)
    }

    /// Hides a course without touching its data. Reversible, and the
    /// scanner reuses the same (still archived) row on re-import rather
    /// than resurrecting it as a new course.
    public static func setCourseArchived(_ courseId: String, archived: Bool, now: Date = Date(), db: Database) throws {
        guard var course = try Course.fetchOne(db, key: courseId) else { return }
        course.isArchived = archived
        course.updatedAt = now
        try course.save(db)
    }

    /// What a delete would actually remove, so the confirmation can say it
    /// in numbers. Cards are counted by deck membership, not `materialId`,
    /// which would miss every hand-typed card.
    public static func courseDeletionImpact(_ courseId: String, db: Database) throws -> (materials: Int, cards: Int, reviews: Int) {
        let materials = try Material.filter(Column("courseId") == courseId).fetchCount(db)
        // Live cards only: deleted ones still have deck rows, and counting
        // them made the warning claim more than the student has.
        let cards = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM card WHERE deletedAt IS NULL AND id IN (
                SELECT cardId FROM deckCard WHERE deckId IN (SELECT id FROM deck WHERE courseId = ?)
            )
            """, arguments: [courseId]) ?? 0
        let reviews = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM review WHERE cardId IN (
                SELECT id FROM card WHERE deletedAt IS NULL AND id IN (
                    SELECT cardId FROM deckCard WHERE deckId IN (SELECT id FROM deck WHERE courseId = ?)
                )
            )
            """, arguments: [courseId]) ?? 0
        return (materials, cards, reviews)
    }

    /// The only way a course is deleted: excludes its vault folder first
    /// (if it has one), so the next scan can't recreate it, then removes the
    /// course and everything derived from it. Notes in the vault are never
    /// touched.
    public static func removeCourseAndExclude(_ courseId: String, db: Database) throws {
        if let folderPath = try Course.fetchOne(db, key: courseId)?.folderPath {
            try ExcludedFolder(folderPath: folderPath).insert(db, onConflict: .ignore)
        }
        // `card.materialId` is ON DELETE SET NULL, so cascading from the
        // course alone would strand its cards: they go first, by deck
        // membership (hand-typed cards) and by note (cards whose deck was
        // already deleted).
        try db.execute(sql: """
            DELETE FROM card WHERE id IN (
                SELECT cardId FROM deckCard WHERE deckId IN (SELECT id FROM deck WHERE courseId = ?)
            ) OR materialId IN (SELECT id FROM material WHERE courseId = ?)
            """, arguments: [courseId, courseId])
        _ = try Course.deleteOne(db, key: courseId)
    }

    @discardableResult
    public static func addManualCourse(name: String, code: String?, semesterId: String? = nil, db: Database) throws -> String {
        let course = Course(semesterId: semesterId, name: name, code: code)
        try course.insert(db)
        return course.id
    }

    /// The manual counterpart to the scanner's semester lookup, for a
    /// timeline typed by hand ("Fall 2026", "Quarter 1"). Slugified the way
    /// the vault's are, so typing the name of a semester the vault already
    /// made reuses it; new ones sort after every existing one.
    @discardableResult
    public static func findOrCreateSemester(name: String, db: Database) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = slugify(trimmed)
        if let existing = try Semester.filter(Column("slug") == slug).fetchOne(db) {
            return existing.id
        }
        let nextSortKey = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortKey), 0) + 1 FROM semester")) ?? 1
        let semester = Semester(name: trimmed, slug: slug, sortKey: nextSortKey)
        try semester.insert(db)
        return semester.id
    }

    /// Falls back to the lowercased text itself rather than a random id, so
    /// a name with no a-z0-9 at all still dedupes against itself.
    static func slugify(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let trimmed = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? text.lowercased() : trimmed
    }

    // MARK: - Decks

    /// A hand-named deck at the end of the course's decks. Scanner decks
    /// all have `sortIndex` 0, so `MAX + 1` lands after every parsed one.
    @discardableResult
    public static func createDeck(courseId: String, name: String, db: Database) throws -> String {
        let next = try Int.fetchOne(db, sql:
            "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deck WHERE courseId = ? AND deletedAt IS NULL",
            arguments: [courseId]) ?? 0
        let deck = Deck(courseId: courseId, name: name, chapter: nil, origin: "manual", sortIndex: next)
        try deck.insert(db)
        return deck.id
    }

    public static func renameDeck(_ deckId: String, name: String, now: Date = Date(), db: Database) throws {
        guard var deck = try Deck.fetchOne(db, key: deckId) else { return }
        deck.name = name
        deck.updatedAt = now
        try deck.save(db)
    }

    /// Live cards in the deck, suspended ones included -- what a delete
    /// confirmation should count.
    public static func deckCardCount(_ deckId: String, db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM deckCard
            JOIN card ON card.id = deckCard.cardId
            WHERE deckCard.deckId = ? AND card.deletedAt IS NULL
            """, arguments: [deckId]) ?? 0
    }

    /// Removes a deck from view. With a target deck, every card moves there;
    /// with nil, the deck's own cards are soft-deleted (never a hard delete,
    /// which would take their study history with them).
    public static func deleteDeck(_ deckId: String, migrateCardsTo targetDeckId: String?, now: Date = Date(),
                                  db: Database) throws {
        guard var deck = try Deck.fetchOne(db, key: deckId) else { return }
        if let targetDeckId, targetDeckId != deckId,
           let target = try Deck.fetchOne(db, key: targetDeckId), target.deletedAt == nil {
            // Insert-or-ignore then drop the source rows: a plain UPDATE
            // aborts on a card already in both decks.
            let base = try Int.fetchOne(db, sql:
                "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?",
                arguments: [targetDeckId]) ?? 0
            try db.execute(sql: """
                INSERT OR IGNORE INTO deckCard (deckId, cardId, sortIndex)
                SELECT ?, cardId, ? + (ROW_NUMBER() OVER (ORDER BY sortIndex) - 1)
                FROM deckCard WHERE deckId = ?
                """, arguments: [targetDeckId, base, deckId])
        } else {
            // Only cards whose sole membership is this deck.
            try db.execute(sql: """
                UPDATE card SET deletedAt = ?, updatedAt = ?
                WHERE id IN (SELECT cardId FROM deckCard WHERE deckId = ?)
                  AND id NOT IN (SELECT cardId FROM deckCard WHERE deckId != ?)
                """, arguments: [now, now, deckId, deckId])
        }
        try db.execute(sql: "DELETE FROM deckCard WHERE deckId = ?", arguments: [deckId])
        // Decks are soft-deleted, so the calendar's ON DELETE SET NULL never
        // fires; an exam would keep pointing at a deck that's gone.
        try db.execute(sql: "UPDATE calendarEvent SET deckId = NULL WHERE deckId = ?", arguments: [deckId])
        deck.deletedAt = now
        deck.updatedAt = now
        try deck.save(db)
    }
}
