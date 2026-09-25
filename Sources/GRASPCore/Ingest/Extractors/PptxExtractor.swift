import Foundation
#if canImport(FoundationXML)
// XMLParser lives here off Apple platforms.
import FoundationXML
#endif
import ZIPFoundation

/// Plain-text extraction for PowerPoint decks. A `.pptx` is a zip of XML
/// parts; this reads only the two kinds it needs -- `ppt/slides/slideN.xml`
/// (the visible title/bullet text) and `ppt/notesSlides/notesSlideN.xml`
/// (the presenter's speaker notes for that same slide) -- rather than
/// modeling the full OOXML presentation schema. Both often matter: a slide
/// that's just a diagram or a bare bullet frequently has its actual
/// explanation in the notes, not on the slide itself.
public enum PptxExtractor {
    public static func extractText(from url: URL) -> String? {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return nil }

        // Sorted numerically, not lexically -- "slide10.xml" must not sort
        // before "slide2.xml", which a plain string sort would do.
        let slideEntries = archive
            .filter { $0.path.hasPrefix("ppt/slides/slide") && $0.path.hasSuffix(".xml") }
            .sorted { slideNumber(in: $0.path) < slideNumber(in: $1.path) }
        guard !slideEntries.isEmpty else { return "" }

        var sections: [String] = []
        for entry in slideEntries {
            var lines = textRuns(in: entry, archive: archive)
            let notesPath = "ppt/notesSlides/notesSlide\(slideNumber(in: entry.path)).xml"
            if let notesEntry = archive[notesPath] {
                lines += textRuns(in: notesEntry, archive: archive)
            }
            guard !lines.isEmpty else { continue }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func slideNumber(in path: String) -> Int {
        let base = (path as NSString).lastPathComponent
        let digits = base.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    private static func textRuns(in entry: Entry, archive: Archive) -> [String] {
        var data = Data()
        guard (try? archive.extract(entry) { data.append($0) }) != nil else { return [] }
        let parser = SlideTextExtractor()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.textRuns
    }
}

/// Every visible text run in a slide or notes-slide part lives in a
/// DrawingML `<a:t>` element -- pulling just that tag out with `XMLParser`
/// is simpler and more robust than modeling the surrounding shape/paragraph
/// structure this doesn't need.
private final class SlideTextExtractor: NSObject, XMLParserDelegate {
    private(set) var textRuns: [String] = []
    private var isInTextRun = false
    private var current = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "a:t" {
            isInTextRun = true
            current = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInTextRun else { return }
        current += string
    }

    /// The runs of the paragraph being read. A paragraph is emitted whole
    /// when it closes: one line per run split a sentence wherever its
    /// formatting changed -- a bolded word became its own line, and the
    /// parser read those fragments as a term and its definition.
    private var paragraph = ""

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        switch elementName {
        case "a:t":
            paragraph += current
            isInTextRun = false
        case "a:p":
            let line = paragraph.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { textRuns.append(line) }
            paragraph = ""
        default:
            break
        }
    }
}
