import Foundation

/// "Lecture 2" before "Lecture 10". SQLite's default text order puts
/// "Lecture 10" and "Lecture 11" right after "Lecture 1", and auto-created
/// decks all share `sortIndex` 0, so the text order of their names decided
/// everything. This is the equivalent of JavaScript's
/// `a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' })`:
/// digit runs compare as numbers, and case and accents are ignored.
///
/// A fixed (non-locale) comparison on purpose: the order has to be the same
/// on the Mac, the iPhone and Windows, and `localizedStandardCompare` isn't
/// guaranteed to behave the same way off Apple platforms.
public enum NaturalOrder {
    public static let options: String.CompareOptions = [.numeric, .caseInsensitive, .diacriticInsensitive]

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: options)
    }

    public static func isOrdered(_ a: String, before b: String) -> Bool {
        compare(a, b) == .orderedAscending
    }

    /// Like `compare`, but a missing value sorts after every present one.
    static func compare(_ a: String?, _ b: String?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let a?, let b?): return compare(a, b)
        }
    }
}

public extension Deck {
    /// The order decks are listed in: `sortIndex` first (hand-made decks
    /// are appended with a rising one), then the chapter and name in
    /// natural order. Stable, so equal decks keep their fetched order.
    static func ordered(_ decks: [Deck]) -> [Deck] {
        decks.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
            let chapter = NaturalOrder.compare(a.chapter, b.chapter)
            if chapter != .orderedSame { return chapter == .orderedAscending }
            let name = NaturalOrder.compare(a.name, b.name)
            if name != .orderedSame { return name == .orderedAscending }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
