import Foundation
import AppKit

/// Plain-text extraction for .docx via Cocoa's built-in Office Open XML
/// reader -- far less code than walking the zip/XML by hand, and good
/// enough fidelity for lecture notes and essays (no attempt to preserve
/// formatting; only the text runs matter here). AppKit is imported for
/// this one file only -- it does not affect testability, since AppKit
/// links fine in a headless test process on macOS.
public enum DocxExtractor {
    public static func extractText(from url: URL) -> String? {
        guard let attributed = try? NSAttributedString(
            url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil
        ) else { return nil }
        return attributed.string
    }
}
