import SwiftUI
import GRASPCore

/// The picture a practice question refers to, drawn from the numbers its text
/// gives (see `QuestionFigure`). Shown above the question. Colours come from
/// `FigurePalette`, the figures' own palette.
struct QuestionFigureView: View {
    let figure: QuestionFigure

    /// The figure the text describes, if any.
    static func figure(for prompt: String) -> QuestionFigure? { QuestionFigure.detect(in: prompt) }

    var body: some View {
        Group {
            switch figure {
            case .priceFloor(let figure):
                PriceFloorPlot(figure: figure)
                    .aspectRatio(1.55, contentMode: .fit)
                    .frame(maxWidth: 520)
            case .frontiers(let frontiers):
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { panels(frontiers) }.frame(maxWidth: 560)
                    VStack(spacing: 12) { panels(frontiers) }.frame(maxWidth: 300)
                }
            }
        }
        .padding(10)
        .background(FigurePalette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(GRASPColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.description(of: figure))
    }

    @ViewBuilder private func panels(_ frontiers: [QuestionFigure.Frontier]) -> some View {
        ForEach(Array(frontiers.enumerated()), id: \.offset) { _, frontier in
            FrontierPlot(frontier: frontier).aspectRatio(1.1, contentMode: .fit)
        }
    }

    static func description(of figure: QuestionFigure) -> String {
        switch figure {
        case .priceFloor(let f):
            return "Supply and demand graph with a price floor of $\(format(f.floor)). Demand meets the floor at "
                + "\(format(f.demandedAtFloor)) and supply at \(format(f.suppliedAtFloor)) \(f.unit). The market clears at "
                + "\(format(f.marketQuantity)) at $\(format(f.marketPrice))."
        case .frontiers(let list):
            var parts: [String] = []
            for item in list {
                let xGood = item.xGood.lowercased()
                let yGood = item.yGood.lowercased()
                var text = "\(item.name) can make up to \(format(item.maxX)) \(xGood) or \(format(item.maxY)) \(yGood)"
                if let marker = item.marker {
                    text += ", ending at \(format(marker.x)) \(xGood) and \(format(marker.y)) \(yGood)"
                }
                parts.append(text)
            }
            return "Production frontiers: " + parts.joined(separator: "; ") + "."
        }
    }

    fileprivate static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }
}

// MARK: - A plot area

/// Maps data to the plot's rectangle and draws the pieces the figures share.
private struct PlotArea {
    let rect: CGRect
    let xMax: Double
    let yMax: Double

    init(size: CGSize, xMax: Double, yMax: Double) {
        rect = CGRect(x: 40, y: 10, width: max(size.width - 40 - 14, 10), height: max(size.height - 10 - 34, 10))
        self.xMax = xMax; self.yMax = yMax
    }

    func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * CGFloat(x / xMax), y: rect.maxY - rect.height * CGFloat(y / yMax))
    }

    func axes(in context: inout GraphicsContext, xTitle: String, yTitle: String) {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        context.stroke(path, with: .color(FigurePalette.axis), lineWidth: 1.5)
        context.draw(Text(xTitle).font(.graspUI(size: 10, weight: .medium)).foregroundColor(GRASPColor.textTertiary),
                     at: CGPoint(x: rect.midX, y: rect.maxY + 28), anchor: .center)
        var rotated = context
        rotated.translateBy(x: 9, y: rect.midY)
        rotated.rotate(by: .degrees(-90))
        rotated.draw(Text(yTitle).font(.graspUI(size: 10, weight: .medium)).foregroundColor(GRASPColor.textTertiary),
                     at: .zero, anchor: .center)
    }

    func tickX(_ value: Double, in context: inout GraphicsContext, label: String? = nil) {
        let p = point(value, 0)
        context.draw(Text(label ?? PlotArea.format(value)).font(.graspUI(size: 10, weight: .medium))
            .foregroundColor(GRASPColor.textSecondary), at: CGPoint(x: p.x, y: rect.maxY + 11), anchor: .center)
    }

    func tickY(_ value: Double, in context: inout GraphicsContext, label: String? = nil) {
        let p = point(0, value)
        context.draw(Text(label ?? PlotArea.format(value)).font(.graspUI(size: 10, weight: .medium))
            .foregroundColor(GRASPColor.textSecondary), at: CGPoint(x: rect.minX - 6, y: p.y), anchor: .trailing)
    }

    /// A dashed guide from a point down to the x axis and across to the y axis.
    func guides(to x: Double, _ y: Double, in context: inout GraphicsContext, down: Bool = true, across: Bool = true) {
        let p = point(x, y)
        var path = Path()
        if down { path.move(to: p); path.addLine(to: point(x, 0)) }
        if across { path.move(to: p); path.addLine(to: point(0, y)) }
        context.stroke(path, with: .color(FigurePalette.axis.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    func dot(_ x: Double, _ y: Double, color: Color, in context: inout GraphicsContext) {
        let p = point(x, y)
        context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color))
    }

    func label(_ text: String, at p: CGPoint, color: Color, anchor: UnitPoint, in context: inout GraphicsContext) {
        context.draw(Text(text).font(.graspUI(size: 11, weight: .semibold)).foregroundColor(color), at: p, anchor: anchor)
    }

    static func format(_ value: Double) -> String { QuestionFigureView.format(value) }
}

// MARK: - Supply and demand with a price floor

private struct PriceFloorPlot: View {
    let figure: QuestionFigure.PriceFloor

    var body: some View {
        Canvas { context, size in
            var context = context
            let f = figure
            let xMax = (max(f.suppliedAtFloor, f.demandedAtFloor, f.marketQuantity) * 1.22 / 10).rounded(.up) * 10
            let yMax = max(f.demandPrice(at: 0), f.floor * 1.4, f.marketPrice * 1.4).rounded(.up)
            let plot = PlotArea(size: size, xMax: xMax, yMax: yMax)
            plot.axes(in: &context, xTitle: f.unit.prefix(1).uppercased() + f.unit.dropFirst(), yTitle: "Price ($ a bushel)")

            // Where demand reaches the axis, so the line stays inside the plot.
            func clipped(_ price: (Double) -> Double, from: Double, to: Double) -> (Double, Double) {
                var end = to
                while end > from, price(end) < 0 || price(end) > yMax { end -= 1 }
                return (from, end)
            }
            let demand = clipped(f.demandPrice(at:), from: 0, to: xMax)
            var demandPath = Path()
            demandPath.move(to: plot.point(demand.0, f.demandPrice(at: demand.0)))
            demandPath.addLine(to: plot.point(demand.1, f.demandPrice(at: demand.1)))
            context.stroke(demandPath, with: .color(FigurePalette.lineOne), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            let supply = clipped(f.supplyPrice(at:), from: 0, to: xMax)
            var supplyPath = Path()
            supplyPath.move(to: plot.point(supply.0, f.supplyPrice(at: supply.0)))
            supplyPath.addLine(to: plot.point(supply.1, f.supplyPrice(at: supply.1)))
            context.stroke(supplyPath, with: .color(FigurePalette.lineTwo), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            // The floor.
            var floorPath = Path()
            floorPath.move(to: plot.point(0, f.floor))
            floorPath.addLine(to: plot.point(xMax, f.floor))
            context.stroke(floorPath, with: .color(FigurePalette.highlight), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

            plot.guides(to: f.demandedAtFloor, f.floor, in: &context, across: false)
            plot.guides(to: f.suppliedAtFloor, f.floor, in: &context, across: false)
            plot.guides(to: f.marketQuantity, f.marketPrice, in: &context)
            plot.guides(to: f.supplyPoint.quantity, f.supplyPoint.price, in: &context, down: false)
            for (x, y) in [(f.demandedAtFloor, f.floor), (f.suppliedAtFloor, f.floor), (f.marketQuantity, f.marketPrice),
                           (f.supplyPoint.quantity, f.supplyPoint.price)] {
                plot.dot(x, y, color: GRASPColor.textPrimary, in: &context)
            }
            for q in Set([f.demandedAtFloor, f.suppliedAtFloor, f.marketQuantity]).sorted() { plot.tickX(q, in: &context) }
            for p in Set([f.floor, f.marketPrice, f.supplyPoint.price]).sorted() { plot.tickY(p, in: &context, label: "$" + PlotArea.format(p)) }

            // Labels in clear space: demand at its high end, supply at its right end,
            // the floor between the axis and the first point.
            plot.label("Demand", at: plot.point(demand.0, f.demandPrice(at: demand.0)).applying(.init(translationX: 12, y: 2)),
                       color: FigurePalette.lineOne, anchor: .leading, in: &context)
            plot.label("Supply", at: plot.point(supply.1, f.supplyPrice(at: supply.1)).applying(.init(translationX: -4, y: -8)),
                       color: FigurePalette.lineTwo, anchor: .trailing, in: &context)
            plot.label("Price floor", at: plot.point(0, f.floor).applying(.init(translationX: 8, y: -9)),
                       color: FigurePalette.highlight, anchor: .leading, in: &context)
        }
    }
}

// MARK: - A production frontier

private struct FrontierPlot: View {
    let frontier: QuestionFigure.Frontier

    var body: some View {
        Canvas { context, size in
            var context = context
            let f = frontier
            let plot = PlotArea(size: size, xMax: f.maxX * 1.15, yMax: f.maxY * 1.15)
            plot.axes(in: &context, xTitle: f.xGood, yTitle: f.yGood)
            var line = Path()
            line.move(to: plot.point(0, f.maxY))
            line.addLine(to: plot.point(f.maxX, 0))
            context.stroke(line, with: .color(FigurePalette.lineOne), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            plot.tickX(f.maxX, in: &context)
            plot.tickY(f.maxY, in: &context)
            plot.label(f.name, at: CGPoint(x: plot.rect.minX + 8, y: plot.rect.minY + 6), color: GRASPColor.textPrimary,
                       anchor: .topLeading, in: &context)
            if let marker = f.marker {
                plot.guides(to: marker.x, marker.y, in: &context)
                plot.tickX(marker.x, in: &context)
                plot.tickY(marker.y, in: &context)
                plot.dot(marker.x, marker.y, color: FigurePalette.highlight, in: &context)
                plot.label("After the trade", at: plot.point(marker.x, marker.y).applying(.init(translationX: 8, y: -6)),
                           color: FigurePalette.highlight, anchor: .bottomLeading, in: &context)
            }
        }
    }
}
