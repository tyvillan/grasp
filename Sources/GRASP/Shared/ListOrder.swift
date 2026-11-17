import Foundation

/// A student's own order for a list of ids (courses in a term), kept on this
/// device like the deck order. Items not placed yet follow the placed ones in
/// their original order.
enum ListOrder {
    static func load(_ key: String, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func save(_ ids: [String], key: String, defaults: UserDefaults = .standard) {
        if ids.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(ids, forKey: key) }
    }

    static func apply<T: Identifiable>(_ items: [T], saved: [String]) -> [T] where T.ID == String {
        guard !saved.isEmpty else { return items }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var placed: [T] = []
        for id in saved { if let item = byId[id], seen.insert(id).inserted { placed.append(item) } }
        return placed + items.filter { !seen.contains($0.id) }
    }
}
