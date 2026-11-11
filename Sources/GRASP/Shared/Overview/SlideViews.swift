import SwiftUI
import GRASPCore
import PDFKit

/// A slide from the lecture's deck, beside the overview section it matches.
struct SlideRef: Identifiable, Equatable {
    let slide: SlideDeck.Slide
    let deckPath: String
    var id: String { "\(deckPath)#\(slide.page)" }
}

/// Reads a lecture's deck once and places its slides against an overview's
/// sections. Page text is cached by file and modification date, so opening
/// the same lesson again costs nothing.
@MainActor
final class SlideCache {
    static let shared = SlideCache()
    private var decks: [String: (modified: Date, slides: [SlideDeck.Slide])] = [:]

    func slides(atDeck path: String) -> [SlideDeck.Slide] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        if let cached = decks[path], cached.modified == modified { return cached.slides }
        let slides = SlideDeck.slides(from: SlideDeck.pages(ofDeckAt: path))
        decks[path] = (modified, slides)
        return slides
    }
}

extension AppStore {
    /// The slides beside each of a note's overview sections, by section id.
    /// Empty when the deck isn't saved beside the note (always on the phone,
    /// which has no vault).
    @MainActor
    func slidePlacements(for overview: RenderedOverview) -> [String: [SlideRef]] {
        guard let material = (try? material(overview.materialId)) ?? nil else { return [:] }
        let path = material.relativePath
        // A syllabus overview is about the course, not the lecture's slides.
        let raw = (try? database.queue.read { try NoteText.fetchOne($0, key: material.id)?.raw }) ?? nil
        if OverviewOrientation.isOrientation(noteTitle: material.title, noteContext: raw ?? "") { return [:] }
        var refs: [SlideRef] = []
        for deck in SlideDeck.existingDecks(forNote: path) {
            refs += SlideCache.shared.slides(atDeck: deck).map { SlideRef(slide: $0, deckPath: deck) }
        }
        guard !refs.isEmpty else { return [:] }
        let sections = overview.sections.map { section in
            OverviewSection(heading: section.heading, paragraphs: section.paragraphs,
                            terms: section.terms.map { OverviewDefinition(term: $0.term, text: $0.text, example: $0.example, nonExample: $0.nonExample) },
                            example: section.example)
        }
        let placed = SlideDeck.placements(of: refs.map(\.slide), in: sections)
        var result: [String: [SlideRef]] = [:]
        for (index, slides) in placed where overview.sections.indices.contains(index) {
            result[overview.sections[index].id] = slides.compactMap { slide in refs.first { $0.slide.page == slide.page } }
        }
        return result
    }
}

/// The slides that match a section, as small pictures. Tapping one opens
/// the page full size.
struct SlideStrip: View {
    let slides: [SlideRef]
    var onOpen: (SlideRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.graspUI(size: 10, weight: .semibold))
                Text("FROM THE SLIDES")
                    .graspType(.eyebrow)
            }
            .foregroundStyle(GRASPColor.textTertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(slides) { ref in
                        Button { onOpen(ref) } label: { SlideCard(ref: ref) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Slide \(ref.slide.page), \(ref.slide.title)")
                            .accessibilityHint("Opens the slide")
                    }
                }
            }
        }
    }
}

struct SlideCard: View {
    let ref: SlideRef
    @State private var image: CGImage?

    /// `preloaded` is for a preview or a test, which can't wait for the page to draw.
    init(ref: SlideRef, preloaded: CGImage? = nil) {
        self.ref = ref
        self._image = State(initialValue: preloaded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(GRASPColor.inset)
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .frame(width: 240, height: 135)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(GRASPColor.hairline, lineWidth: 1))

            Text("Slide \(ref.slide.page) \u{00B7} \(ref.slide.title)")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textSecondary)
                .lineLimit(1)
                .frame(width: 240, alignment: .leading)
        }
        .task(id: ref.id) {
            guard image == nil else { return }
            let path = ref.deckPath, page = ref.slide.page
            image = await Task.detached(priority: .userInitiated) { SlideRender.image(deckPath: path, page: page, width: 480) }.value
        }
    }
}

/// One deck page drawn to a bitmap, for the strip. CoreGraphics, so the
/// same code serves the Mac and the phone.
nonisolated enum SlideRender {
    static func image(deckPath: String, page: Int, width: CGFloat) -> CGImage? {
        guard let pdf = CGPDFDocument(URL(fileURLWithPath: deckPath) as CFURL), let pdfPage = pdf.page(at: page) else { return nil }
        let box = pdfPage.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = width * 2 / box.width
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(pdfPage)
        return context.makeImage()
    }
}
