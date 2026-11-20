import Foundation
import GRASPCore

/// Reads the text of the optional extra file a student attaches when writing
/// a study guide, the same way GRASP reads a file added to a course.
nonisolated enum ExtraSourceReader {
    static let allowedExtensions = ["pdf", "docx", "pptx", "ipynb", "md", "markdown", "txt", "html", "htm", "png", "jpg", "jpeg", "heic"]

    static func text(from url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text: String?
        switch url.pathExtension.lowercased() {
        case "pdf": text = PDFExtractor.extractText(from: url)
        case "docx": text = DocxExtractor.extractText(from: url)
        case "pptx": text = PptxExtractor.extractText(from: url)
        case "ipynb": text = IpynbExtractor.extractText(from: url)
        case "png", "jpg", "jpeg", "heic": text = ImageExtractor.extractText(from: url)
        case "html", "htm": text = (try? String(contentsOf: url, encoding: .utf8)).flatMap(HTMLTextReader.text(from:))
        default: text = try? String(contentsOf: url, encoding: .utf8)
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
