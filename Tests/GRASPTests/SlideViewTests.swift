import Testing
import SwiftUI
import GRASPCore
@testable import GRASP

@Suite("Slide views", .enabled(if: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Mobile Documents/iCloud~md~obsidian/Documents/Master Vault/College/Fall Semester 2026-2027/Systems Programming with C++/01_Lectures/2026-10-20_Module-07_Arrays-and-Pointers.slides.pdf")))
struct SlideViewTests {
    nonisolated static let deck = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Mobile Documents/iCloud~md~obsidian/Documents/Master Vault/College/Fall Semester 2026-2027/Systems Programming with C++/01_Lectures/2026-10-20_Module-07_Arrays-and-Pointers.slides.pdf")

    @Test("a deck page draws to an image the right shape, and a page that isn't there draws nothing")
    func drawsPages() throws {
        let image = try #require(SlideRender.image(deckPath: Self.deck.path, page: 14, width: 480))
        #expect(image.width == 960 && abs(Double(image.height) / Double(image.width) - 540.0 / 960.0) < 0.01)
        #expect(SlideRender.image(deckPath: Self.deck.path, page: 999, width: 480) == nil)
        #expect(SlideRender.image(deckPath: "/no/such/deck.pdf", page: 1, width: 480) == nil)
    }

    /// Renders three real slides as the strip draws them, to PNG. Where:
    /// `GRASP_FIGURE_DIR`, else the temp folder.
    @MainActor @Test("the slide cards render with a caption")
    func rendersCards() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GRASP_FIGURE_DIR"] ?? NSTemporaryDirectory())
        let pages = SlideDeck.slides(from: SlideDeck.pages(ofDeckAt: Self.deck.path))
        let chosen = pages.filter { [8, 14, 20].contains($0.page) }
        #expect(chosen.count == 3)
        let view = HStack(alignment: .top, spacing: 12) {
            ForEach(chosen) { slide in
                SlideCard(ref: SlideRef(slide: slide, deckPath: Self.deck.path),
                          preloaded: SlideRender.image(deckPath: Self.deck.path, page: slide.page, width: 480))
            }
        }
        .padding(20)
        .background(GRASPColor.canvas)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width > 1400)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: dir.appendingPathComponent("slide-cards.png"))
    }
}
