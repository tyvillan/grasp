import Testing
import Foundation
@testable import GRASPCore

/// The pictures a practice question refers to, worked out from its own numbers.
@Suite("Question figures")
struct QuestionFigureTests {
    static let q1 = "Practice exam Q1. Figure 1, a price floor on lentils: demand meets the $9 floor at 80 million bushels and supply meets it at 140 million. The market-clearing point is 100 million bushels at $7, and supply passes through $6 at 80 million bushels. A law sets the $9 floor. No agency buys lentils or limits planting, growers plant only the lentils that buyers take at $9, the growers with the lowest costs plant them, and no grower offers extras.\nCompared with no floor, what is the deadweight loss of the floor, in millions of dollars a year?"
    static let q29 = "Practice exam Q29. Figure 2, Preston's and Rudy's weekly frontiers, each a straight line. Preston can make up to 54 wind chimes or 36 doormats a week. Rudy can make up to 18 wind chimes or 30 doormats a week. Rudy makes only doormats, 30 a week, and trades 10 of them to Preston for 10 wind chimes, so Rudy ends the week with 20 doormats and 10 wind chimes.\nCompared with the most wind chimes Rudy could make for himself while still keeping 20 doormats, how many more wind chimes does he have?"

    @Test("Figure 1: the price floor, with lines through the points the question gives")
    func priceFloor() throws {
        guard case .priceFloor(let f)? = QuestionFigure.detect(in: Self.q1) else { Issue.record("no figure"); return }
        #expect(f.floor == 9 && f.demandedAtFloor == 80 && f.suppliedAtFloor == 140)
        #expect(f.marketQuantity == 100 && f.marketPrice == 7 && f.supplyPoint.quantity == 80 && f.supplyPoint.price == 6)
        // Supply starts at $2 and meets the floor at 140; demand starts at $17.
        #expect(abs(f.supplyPrice(at: 0) - 2) < 1e-9 && abs(f.supplyPrice(at: 140) - 9) < 1e-9)
        #expect(abs(f.demandPrice(at: 0) - 17) < 1e-9 && abs(f.demandPrice(at: 80) - 9) < 1e-9)
    }

    @Test("Figure 2: two frontiers, with Rudy's point after the trade")
    func frontiers() throws {
        guard case .frontiers(let list)? = QuestionFigure.detect(in: Self.q29) else { Issue.record("no figure"); return }
        #expect(list.map(\.name) == ["Preston", "Rudy"])
        #expect(list[0].maxX == 54 && list[0].maxY == 36 && list[0].marker == nil)
        #expect(list[1].maxX == 18 && list[1].maxY == 30)
        #expect(list[1].marker?.x == 10 && list[1].marker?.y == 20)
    }

    @Test("a question that only says 'figure', or lacks a number, draws nothing")
    func noGuessing() {
        #expect(QuestionFigure.detect(in: "Use the figure to find the loss.") == nil)
        #expect(QuestionFigure.detect(in: "Practice exam Q8. A county's youth soccer clubs fill 1,500 roster spots.") == nil)
        #expect(QuestionFigure.detect(in: Self.q1.replacingOccurrences(of: "supply passes through $6 at 80 million bushels", with: "supply is upward sloping")) == nil)
        #expect(QuestionFigure.detect(in: Self.q29.replacingOccurrences(of: "Rudy can make up to 18 wind chimes or 30 doormats", with: "Rudy is slower")) == nil)
    }
}

/// The real Exam 2 guide, when its fixture is on this machine.
@Suite("Exam 2 guide figures", .enabled(if: FileManager.default.fileExists(atPath: Exam2Fixture.file.path)))
struct Exam2GuideFigureTests {
    @Test("only Q1, Q2 and Q29 get a figure, and Q1 and Q2 get the same one")
    func which() async throws {
        let page = try await Exam2Fixture.page()
        var withFigure: [String: QuestionFigure] = [:]
        for example in page.parts.flatMap(\.examples).map(\.example) {
            guard let figure = QuestionFigure.detect(in: example.question) else { continue }
            let q = try #require(example.question.range(of: #"Practice exam Q\d+"#, options: .regularExpression)
                .map { String(example.question[$0]) })
            withFigure[q] = figure
        }
        #expect(Set(withFigure.keys) == ["Practice exam Q1", "Practice exam Q2", "Practice exam Q29"])
        #expect(withFigure["Practice exam Q1"] == withFigure["Practice exam Q2"])
    }
}
