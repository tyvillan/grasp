import Foundation
#if canImport(PDFKit)
import PDFKit
import CoreGraphics
#endif

/// Plain-text extraction for PDFs (Calculus 2's 33 homework/exam-review
/// files, study guides, plus scattered PDFs in other courses).
///
/// Most PDFs carry a text layer and are read directly. A page without one
/// -- a scan, or a study guide saved as a stack of screenshots -- is drawn
/// to an image and read with on-device OCR instead, page by page, so a
/// mixed document keeps its real text where it has it. A PDF where no page
/// yields anything returns an empty string, not nil: there's nothing wrong
/// with the file, it just has nothing to read.
public enum PDFExtractor {
    /// Below this many characters a page is treated as having no text
    /// layer: a scanned page can still carry a stray page number or a
    /// watermark in real text.
    static let textLayerMinimum = 20

    /// OCR works best with text around 20-30 px tall; drawing the page so
    /// its longer side is about this many pixels gets a slide-sized
    /// screenshot there without making a huge bitmap of a large page.
    static let ocrTargetPixels: CGFloat = 2600

    public static func extractText(from url: URL) -> String? {
        extractPages(from: url)?.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Each page's text in order, one entry per page (empty for a page with
    /// nothing to read, so numbering stays true) -- what a study guide is
    /// parsed from, so its parts and examples keep their page numbers.
    public static func extractPages(from url: URL) -> [String]? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else { return nil }
        let pdf = CGPDFDocument(url as CFURL)
        var pages: [String] = []
        for index in 0..<document.pageCount {
            let layer = document.page(at: index)?.string ?? ""
            if layer.trimmingCharacters(in: .whitespacesAndNewlines).count >= textLayerMinimum {
                pages.append(layer)
            } else if TextRecognition.isEnabled,
                      // CGPDFDocument pages are 1-based.
                      let page = pdf?.page(at: index + 1),
                      let image = render(page),
                      let recognized = TextRecognition.recognizeText(in: image) {
                pages.append(recognized)
            } else {
                pages.append(layer)
            }
        }
        return pages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        #else
        // Windows: not yet -- Windows.Data.Pdf is the planned reader. nil
        // reads as "couldn't extract", so the file is listed, not guessed at.
        return nil
        #endif
    }

    #if canImport(PDFKit)
    /// Draws one page on white at OCR resolution. CoreGraphics rather than
    /// `PDFPage.thumbnail`, which returns an NSImage or a UIImage depending
    /// on the platform.
    static func render(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.mediaBox)
        let longest = max(box.width, box.height)
        guard longest > 0 else { return nil }
        let scale = min(4, max(1, ocrTargetPixels / longest))
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        context.drawPDFPage(page)
        return context.makeImage()
    }
    #endif
}
