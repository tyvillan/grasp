import Foundation
import Testing
@testable import GRASP

@Suite("List order")
struct ListOrderTests {
    private struct Item: Identifiable { let id: String }
    private func items(_ ids: [String]) -> [Item] { ids.map(Item.init) }

    @Test("with nothing saved the original order is kept")
    func nothingSaved() {
        #expect(ListOrder.apply(items(["A", "B"]), saved: []).map(\.id) == ["A", "B"])
    }

    @Test("placed items come first, new ones follow, stale and repeated ids are ignored")
    func placedFirst() {
        let result = ListOrder.apply(items(["A", "B", "C", "D"]), saved: ["Z", "C", "C", "A"])
        #expect(result.map(\.id) == ["C", "A", "B", "D"])
    }

    @Test("saved order round-trips and an empty save clears it")
    func roundTrip() {
        let defaults = UserDefaults(suiteName: "ListOrderTests-\(UUID().uuidString)")!
        ListOrder.save(["B", "A"], key: "k", defaults: defaults)
        #expect(ListOrder.load("k", defaults: defaults) == ["B", "A"])
        ListOrder.save([], key: "k", defaults: defaults)
        #expect(ListOrder.load("k", defaults: defaults).isEmpty)
    }
}
