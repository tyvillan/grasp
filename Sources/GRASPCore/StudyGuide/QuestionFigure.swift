import Foundation

/// A picture a practice question refers to ("Figure 1"), worked out from the
/// numbers the question itself states, so it is drawn rather than stored: it
/// needs no image file, no database column and no sync, and it follows the
/// question wherever its text goes (a guide test, a saved question, a
/// resumed test, the guide's own page).
public enum QuestionFigure: Equatable, Sendable {
    /// Supply and demand with a price floor.
    case priceFloor(PriceFloor)
    /// Straight production frontiers, side by side, with an optional point.
    case frontiers([Frontier])

    /// Two straight lines through points the question gives.
    public struct PriceFloor: Equatable, Sendable {
        public var floor: Double
        /// Quantity demanded and supplied at the floor price.
        public var demandedAtFloor: Double
        public var suppliedAtFloor: Double
        public var marketQuantity: Double
        public var marketPrice: Double
        /// A second point on the supply line.
        public var supplyPoint: (quantity: Double, price: Double)
        public var unit: String

        public static func == (a: PriceFloor, b: PriceFloor) -> Bool {
            a.floor == b.floor && a.demandedAtFloor == b.demandedAtFloor && a.suppliedAtFloor == b.suppliedAtFloor
                && a.marketQuantity == b.marketQuantity && a.marketPrice == b.marketPrice
                && a.supplyPoint.quantity == b.supplyPoint.quantity && a.supplyPoint.price == b.supplyPoint.price
                && a.unit == b.unit
        }

        /// Price on the demand line at `quantity`: through the market point
        /// and the point where demand meets the floor.
        public func demandPrice(at quantity: Double) -> Double {
            let slope = (floor - marketPrice) / (demandedAtFloor - marketQuantity)
            return marketPrice + slope * (quantity - marketQuantity)
        }

        /// Price on the supply line at `quantity`: through the market point
        /// and the second supply point.
        public func supplyPrice(at quantity: Double) -> Double {
            let slope = (marketPrice - supplyPoint.price) / (marketQuantity - supplyPoint.quantity)
            return marketPrice + slope * (quantity - marketQuantity)
        }
    }

    public struct Frontier: Equatable, Sendable {
        public var name: String
        /// The most of each good, with nothing of the other.
        public var maxX: Double
        public var maxY: Double
        public var xGood: String
        public var yGood: String
        /// A point to mark, such as where a trade leaves someone.
        public var marker: (x: Double, y: Double)?

        public static func == (a: Frontier, b: Frontier) -> Bool {
            a.name == b.name && a.maxX == b.maxX && a.maxY == b.maxY && a.xGood == b.xGood && a.yGood == b.yGood
                && a.marker?.x == b.marker?.x && a.marker?.y == b.marker?.y
        }
    }

    // MARK: - Reading a question

    private static let number = #"(\d+(?:\.\d+)?)"#

    private static func numbers(_ pattern: String, in text: String) -> [Double]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).flatMap { Double(text[$0]) } }
    }

    /// The figure a question's text describes, or nil when it describes none.
    /// Needs every number the picture draws, so a question that only
    /// mentions "a figure" shows nothing rather than something wrong.
    public static func detect(in text: String) -> QuestionFigure? {
        priceFloor(in: text) ?? frontiers(in: text)
    }

    static func priceFloor(in text: String) -> QuestionFigure? {
        let n = number
        guard text.localizedCaseInsensitiveContains("price floor"),
              let atFloor = numbers(#"demand meets the \$\#(n) floor at \#(n) million bushels and supply meets it at \#(n) million"#, in: text),
              atFloor.count == 3,
              let market = numbers(#"market-clearing point is \#(n) million bushels at \$\#(n)"#, in: text), market.count == 2,
              let supply = numbers(#"supply passes through \$\#(n) at \#(n) million bushels"#, in: text), supply.count == 2,
              market[0] != atFloor[1], market[0] != supply[1]
        else { return nil }
        return .priceFloor(PriceFloor(
            floor: atFloor[0], demandedAtFloor: atFloor[1], suppliedAtFloor: atFloor[2],
            marketQuantity: market[0], marketPrice: market[1],
            supplyPoint: (quantity: supply[1], price: supply[0]), unit: "million bushels a year"))
    }

    static func frontiers(in text: String) -> QuestionFigure? {
        let n = number
        let pattern = #"([A-Z][a-z]+) can make up to \#(n) wind chimes or \#(n) doormats"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 2 else { return nil }
        // "so Rudy ends the week with 20 doormats and 10 wind chimes".
        let ends = numbers(#"([A-Z][a-z]+) ends the week with \#(n) doormats and \#(n) wind chimes"#, in: text)
        let endsName = text.range(of: #"([A-Z][a-z]+) ends the week with"#, options: .regularExpression)
            .map { String(text[$0]).replacingOccurrences(of: " ends the week with", with: "") }
        var result: [Frontier] = []
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let chimes = Range(match.range(at: 2), in: text).flatMap({ Double(text[$0]) }),
                  let doormats = Range(match.range(at: 3), in: text).flatMap({ Double(text[$0]) }) else { return nil }
            let name = String(text[nameRange])
            var marker: (x: Double, y: Double)?
            if let ends, ends.count == 2, endsName == name { marker = (x: ends[1], y: ends[0]) }
            result.append(Frontier(name: name, maxX: chimes, maxY: doormats, xGood: "Wind chimes", yGood: "Doormats", marker: marker))
        }
        return .frontiers(result)
    }
}
