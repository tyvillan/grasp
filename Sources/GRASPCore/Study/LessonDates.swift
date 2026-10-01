import Foundation
import GRDB

/// The lecture date a deck list shows above a deck's name: "AUG 27", or a
/// range for a deck spanning several class days. The same rules as the
/// Mac's `AppStore.deckKickers`, for the apps that don't have it.
public enum LessonDates {
    /// "AUG 27" for a single date, "AUG 27–29" for a range within one
    /// month, "AUG 30 – SEP 2" for one crossing a month boundary.
    public static func format(start: Date, end: Date?, locale: Locale = .current) -> String {
        let calendar = Calendar.current
        guard let end, !calendar.isDate(start, inSameDayAs: end) else {
            return start.formatted(.dateTime.month(.abbreviated).day().locale(locale)).uppercased()
        }
        let sameMonth = calendar.isDate(start, equalTo: end, toGranularity: .month)
            && calendar.isDate(start, equalTo: end, toGranularity: .year)
        if sameMonth {
            let month = start.formatted(.dateTime.month(.abbreviated).locale(locale))
            let startDay = start.formatted(.dateTime.day().locale(locale))
            let endDay = end.formatted(.dateTime.day().locale(locale))
            return "\(month) \(startDay)–\(endDay)".uppercased()
        }
        let startText = start.formatted(.dateTime.month(.abbreviated).day().locale(locale))
        let endText = end.formatted(.dateTime.month(.abbreviated).day().locale(locale))
        return "\(startText) – \(endText)".uppercased()
    }

    /// Each live deck's date text, by deck id. The earliest-to-latest date
    /// across the notes its cards come from when any note has one; else the
    /// date the student set by hand; else nothing. A manual date never
    /// overrides an extracted one.
    public static func kickers(db: Database, locale: Locale = .current) throws -> [String: String] {
        var extracted: [String: (start: Date, end: Date)] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT deckCard.deckId AS deckId, material.title AS title, material.noteDate AS noteDate
            FROM deckCard
            JOIN card ON card.id = deckCard.cardId AND card.deletedAt IS NULL
            JOIN material ON material.id = card.materialId AND material.deletedAt IS NULL
            """)
        var dates: [String: [Date]] = [:]
        for row in rows {
            let deckId: String = row["deckId"]
            let title: String = row["title"]
            let noteDate: Date? = row["noteDate"]
            let parsed = FilenameParsing.parse(fileNameWithoutExtension: title)
            if let date = noteDate ?? parsed.dateFromFilename { dates[deckId, default: []].append(date) }
        }
        for (deckId, list) in dates {
            if let start = list.min(), let end = list.max() { extracted[deckId] = (start, end) }
        }

        var result: [String: String] = [:]
        for deck in try Deck.filter(Column("deletedAt") == nil).fetchAll(db) {
            if let range = extracted[deck.id] {
                result[deck.id] = format(start: range.start, end: range.end, locale: locale)
            } else if let start = deck.manualLessonDate {
                result[deck.id] = format(start: start, end: deck.manualLessonDateEnd, locale: locale)
            }
        }
        return result
    }

    /// Sets, or with nil clears, the date (or range) the student gave a deck
    /// by hand. `end` nil means a single date.
    public static func setManual(deckId: String, start: Date?, end: Date?, db: Database) throws {
        guard var deck = try Deck.fetchOne(db, key: deckId) else { return }
        deck.manualLessonDate = start
        deck.manualLessonDateEnd = start == nil ? nil : end
        deck.updatedAt = Date()
        try deck.save(db)
    }
}
