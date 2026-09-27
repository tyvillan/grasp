#if os(Windows)
import Testing
import Foundation
@testable import GRASPCore

@Suite("Windows OCR")
struct WindowsOCRTests {
    /// A two-page PDF with a line of Helvetica on each page, built by hand
    /// so the test needs no fixture file.
    private func makePDF() throws -> URL {
        let pages = ["Row reduction keeps the solution set.", "Free variables have no pivot."]
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>"]
        for (index, text) in pages.enumerated() {
            let content = "BT /F1 24 Tf 72 700 Td (\(text)) Tj ET"
            let contentNumber = objects.count + 2
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(contentNumber) 0 R "
                           + "/Resources << /Font << /F1 \(index == 0 ? 7 : 7) 0 R >> >> >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-ocr-test-\(UUID().uuidString).pdf")
        try Data(pdf.utf8).write(to: url)
        return url
    }

    @Test("a PDF's pages are rendered and read by Windows' OCR")
    func pdf() throws {
        let url = try makePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try #require(PDFExtractor.extractText(from: url))
        #expect(text.localizedCaseInsensitiveContains("solution set"))
        #expect(text.localizedCaseInsensitiveContains("pivot"))
    }

    @Test("a file that isn't a PDF or image comes back nil, not text")
    func unreadable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-ocr-test-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PDFExtractor.extractText(from: url) == nil)
    }
}
#endif
