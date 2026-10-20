import Foundation

/// Runs independent AI calls with a ceiling on how many are in flight, and
/// hands the results back in the order the items were given, whatever
/// order they finished in.
public enum AIConcurrency {
    /// `limit` of 1 (or less) runs strictly one after another. After
    /// cancellation no further item is started; their slots are nil.
    public static func map<Item: Sendable, Result: Sendable>(
        _ items: [Item], limit: Int, _ operation: @escaping @Sendable (Item) async -> Result
    ) async -> [Result?] {
        guard !items.isEmpty else { return [] }
        let width = max(1, min(limit, items.count))
        var results = [Result?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, Result?).self) { group in
            var next = 0
            func launch() {
                guard next < items.count, !Task.isCancelled else { return }
                let index = next
                next += 1
                let item = items[index]
                group.addTask { (index, await operation(item)) }
            }
            for _ in 0..<width { launch() }
            while let (index, value) = await group.next() {
                results[index] = value
                launch()
            }
        }
        return results
    }
}
