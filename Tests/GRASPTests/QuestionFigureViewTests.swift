import Testing
import SwiftUI
import GRASPCore
@testable import GRASP

@Suite("Question figure views")
struct QuestionFigureViewTests {
    static let q1 = "Figure 1, a price floor on lentils: demand meets the $9 floor at 80 million bushels and supply meets it at 140 million. The market-clearing point is 100 million bushels at $7, and supply passes through $6 at 80 million bushels."
    static let q29 = "Figure 2, Preston's and Rudy's weekly frontiers, each a straight line. Preston can make up to 54 wind chimes or 36 doormats a week. Rudy can make up to 18 wind chimes or 30 doormats a week. Rudy makes only doormats, 30 a week, and trades 10 of them to Preston for 10 wind chimes, so Rudy ends the week with 20 doormats and 10 wind chimes."

    /// Renders both figures to PNG files (in light and dark), and checks they
    /// drew something. Where the files go: `GRASP_FIGURE_DIR`, else the temp folder.
    @MainActor @Test("the two figures render in light and dark")
    func renders() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GRASP_FIGURE_DIR"] ?? NSTemporaryDirectory())
        let figures: [(String, QuestionFigure?)] = [("figure1", QuestionFigure.detect(in: Self.q1)),
                                                    ("figure2", QuestionFigure.detect(in: Self.q29))]
        for (name, figure) in figures {
            let figure = try #require(figure)
            for scheme in [ColorScheme.light, .dark] {
                let view = QuestionFigureView(figure: figure)
                    .environment(\.colorScheme, scheme)
                    .frame(width: 600)
                    .padding(20)
                    .background(GRASPColor.canvas)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(image.width > 600 && image.height > 200)
                let rep = NSBitmapImageRep(cgImage: image)
                let data = try #require(rep.representation(using: .png, properties: [:]))
                try data.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    @Test("the spoken description names the numbers")
    func described() throws {
        let f1 = try #require(QuestionFigure.detect(in: Self.q1))
        #expect(QuestionFigureView.description(of: f1).contains("price floor of $9"))
        let f2 = try #require(QuestionFigure.detect(in: Self.q29))
        #expect(QuestionFigureView.description(of: f2).contains("Rudy can make up to 18 wind chimes or 30 doormats"))
    }
}
