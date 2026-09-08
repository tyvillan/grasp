import Foundation
import PDFKit

/// Plain-text extraction for PDFs (Calculus 2's 33 homework/exam-review
/// files, plus scattered PDFs in other courses). A scanned-image PDF with
/// no text layer returns an empty string, not nil -- callers should treat
/// that distinctly from a hard failure (there's nothing wrong with the
/// file, it just has nothing OCR-able to extract here).
public enum PDFExtractor {
    public static func extractText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        return document.string
    }
}
