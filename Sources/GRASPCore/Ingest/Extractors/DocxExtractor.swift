import Foundation
#if canImport(AppKit)
import AppKit
#else
import ZIPFoundation
#endif

/// Plain-text extraction for .docx.
///
/// On the Mac, Cocoa's built-in Office Open XML reader -- far less code
/// than walking the zip by hand, and good enough fidelity for lecture notes
/// and essays (only the text runs matter here). iOS has no such reader, so
/// there the document's XML is read directly: a .docx is a zip whose
/// `word/document.xml` holds the text in `<w:t>` runs inside `<w:p>`
/// paragraphs -- the same shape `PptxExtractor` already reads for slides.
public enum DocxExtractor {
    public static func extractText(from url: URL) -> String? {
        #if canImport(AppKit)
        guard let attributed = try? NSAttributedString(
            url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil
        ) else { return nil }
        return attributed.string
        #else
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil),
              let entry = archive["word/document.xml"]
        else { return nil }
        var data = Data()
        guard (try? archive.extract(entry, consumer: { data.append($0) })) != nil else { return nil }
        let reader = ParagraphReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        return reader.paragraphs.joined(separator: "\n")
        #endif
    }
}

#if !canImport(AppKit)
/// Collects each `<w:p>` paragraph's `<w:t>` runs as one line.
private final class ParagraphReader: NSObject, XMLParserDelegate {
    private(set) var paragraphs: [String] = []
    private var paragraph = ""
    private var inText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "w:t" { inText = true }
        if elementName == "w:tab" { paragraph += "\t" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { paragraph += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "w:t":
            inText = false
        case "w:p":
            paragraphs.append(paragraph)
            paragraph = ""
        default:
            break
        }
    }
}
#endif
