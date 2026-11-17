import Foundation
import GRASPCore

/// The order a student arranged a course's decks in, by dragging them in the
/// sidebar. It lives on this device (like the sort choice itself), not in the
/// library, so it needs no schema change and never touches sync. Decks the
/// student hasn't placed yet, such as one made later, follow the placed ones
/// in the default order.
enum DeckCustomOrder {
    static func key(_ courseId: String) -> String { "deckCustomOrder.\(courseId)" }

    static func load(courseId: String, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key(courseId)) ?? []
    }

    static func save(_ ids: [String], courseId: String, defaults: UserDefaults = .standard) {
        if ids.isEmpty {
            defaults.removeObject(forKey: key(courseId))
        } else {
            defaults.set(ids, forKey: key(courseId))
        }
    }

    /// `decks` (already in default order) with the placed ones first, in the
    /// saved order, then the rest in the order they came. Saved ids with no
    /// deck any more are ignored.
    static func apply(_ decks: [Deck], saved: [String]) -> [Deck] {
        guard !saved.isEmpty else { return decks }
        let byId = Dictionary(decks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var placed: [Deck] = []
        for id in saved {
            if let deck = byId[id], seen.insert(id).inserted { placed.append(deck) }
        }
        return placed + decks.filter { !seen.contains($0.id) }
    }

    /// `ids` after dragging `id` onto `target`: it takes the target's spot, so
    /// moving up lands above the target and moving down lands below it.
    static func moving(_ id: String, onto target: String, in ids: [String]) -> [String] {
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else {
            return ids
        }
        var result = ids
        result.remove(at: from)
        result.insert(id, at: to)
        return result
    }
}
