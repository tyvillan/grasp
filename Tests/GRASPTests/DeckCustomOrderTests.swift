import Foundation
import Testing
import GRASPCore
@testable import GRASP

@Suite("Deck custom order")
struct DeckCustomOrderTests {
    private func decks(_ names: [String]) -> [Deck] {
        names.map { Deck(id: $0, courseId: "c", name: $0) }
    }

    @Test("with nothing saved the default order is kept")
    func nothingSaved() {
        let list = decks(["A", "B", "C"])
        #expect(DeckCustomOrder.apply(list, saved: []).map(\.id) == ["A", "B", "C"])
    }

    @Test("placed decks come first in the saved order, new decks follow in default order")
    func placedFirst() {
        let list = decks(["A", "B", "C", "D"])
        #expect(DeckCustomOrder.apply(list, saved: ["C", "A"]).map(\.id) == ["C", "A", "B", "D"])
    }

    @Test("a saved deck that no longer exists, or is listed twice, is ignored")
    func staleIds() {
        let list = decks(["A", "B"])
        #expect(DeckCustomOrder.apply(list, saved: ["Z", "B", "B", "A"]).map(\.id) == ["B", "A"])
    }

    @Test("dragging up lands above the target, dragging down lands below it")
    func moving() {
        let ids = ["A", "B", "C", "D"]
        #expect(DeckCustomOrder.moving("D", onto: "B", in: ids) == ["A", "D", "B", "C"])
        #expect(DeckCustomOrder.moving("A", onto: "C", in: ids) == ["B", "C", "A", "D"])
        #expect(DeckCustomOrder.moving("B", onto: "B", in: ids) == ids)
        #expect(DeckCustomOrder.moving("X", onto: "B", in: ids) == ids)
    }

    @Test("the order is saved per course and clearing it removes it")
    func saveAndClear() throws {
        let defaults = try #require(UserDefaults(suiteName: "deck-custom-order-\(UUID().uuidString)"))
        DeckCustomOrder.save(["B", "A"], courseId: "c1", defaults: defaults)
        #expect(DeckCustomOrder.load(courseId: "c1", defaults: defaults) == ["B", "A"])
        #expect(DeckCustomOrder.load(courseId: "c2", defaults: defaults).isEmpty)
        DeckCustomOrder.save([], courseId: "c1", defaults: defaults)
        #expect(DeckCustomOrder.load(courseId: "c1", defaults: defaults).isEmpty)
    }
}
