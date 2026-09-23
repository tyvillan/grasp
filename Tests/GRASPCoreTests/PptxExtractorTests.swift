import Testing
import Foundation
import ZIPFoundation
@testable import GRASPCore

/// Builds real, minimal `.pptx` zip archives at test time (just the
/// `ppt/slides/slideN.xml` / `ppt/notesSlides/notesSlideN.xml` parts
/// `PptxExtractor` actually reads, not a full OOXML package) rather than
/// checking in binary fixtures -- matches this test target's existing
/// "no binary fixtures" convention for the other extractors.
@Suite("PptxExtractor")
struct PptxExtractorTests {
    private func slideXML(_ texts: [String]) -> String {
        // One paragraph per text, as PowerPoint writes it.
        let runs = texts.map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined()
        return "<p:sld xmlns:a=\"a\" xmlns:p=\"p\"><p:cSld><p:spTree><p:sp><p:txBody>\(runs)</p:txBody></p:sp></p:spTree></p:cSld></p:sld>"
    }

    private func makeArchive(_ entries: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pptx-test-\(UUID().uuidString).pptx")
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        for (path, xml) in entries {
            let data = Data(xml.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return url
    }

    @Test("extracts slide text in numeric slide order, not lexical")
    func extractsSlidesInNumericOrder() throws {
        let url = try makeArchive([
            "ppt/slides/slide2.xml": slideXML(["Second"]),
            "ppt/slides/slide10.xml": slideXML(["Tenth"]),
            "ppt/slides/slide1.xml": slideXML(["First"]),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try #require(PptxExtractor.extractText(from: url))
        let sections = text.components(separatedBy: "\n\n")
        #expect(sections == ["First", "Second", "Tenth"])
    }

    @Test("appends the matching speaker notes after a slide's own text")
    func includesSpeakerNotes() throws {
        let url = try makeArchive([
            "ppt/slides/slide1.xml": slideXML(["Mitosis"]),
            "ppt/notesSlides/notesSlide1.xml": slideXML(["The process of cell division"]),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try #require(PptxExtractor.extractText(from: url))
        #expect(text == "Mitosis\nThe process of cell division")
    }

    @Test("a slide with no matching notes file is not affected by other slides' notes")
    func onlyMatchingNotesAreAppended() throws {
        let url = try makeArchive([
            "ppt/slides/slide1.xml": slideXML(["First"]),
            "ppt/slides/slide2.xml": slideXML(["Second"]),
            "ppt/notesSlides/notesSlide2.xml": slideXML(["Notes for second only"]),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try #require(PptxExtractor.extractText(from: url))
        let sections = text.components(separatedBy: "\n\n")
        #expect(sections == ["First", "Second\nNotes for second only"])
    }

    @Test("a deck with no slide parts at all returns an empty string, not nil")
    func noSlidesReturnsEmptyString() throws {
        let url = try makeArchive(["ppt/presentation.xml": "<p:presentation/>"])
        defer { try? FileManager.default.removeItem(at: url) }

        let text = PptxExtractor.extractText(from: url)
        #expect(text == "")
    }

    @Test("a file that isn't a valid zip returns nil")
    func invalidFileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-zip-\(UUID().uuidString).pptx")
        try Data("definitely not a zip archive".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PptxExtractor.extractText(from: url) == nil)
    }

    @Test("keeps a sentence whole when its formatting changes mid-way")
    func joinsRunsWithinAParagraph() throws {
        // "The <b>mitochondria</b> makes energy" is three runs, one paragraph.
        let slide = "<p:sld xmlns:a=\"a\" xmlns:p=\"p\"><p:cSld><p:spTree><p:sp><p:txBody>"
            + "<a:p><a:r><a:t>The </a:t></a:r><a:r><a:t>mitochondria</a:t></a:r><a:r><a:t> makes energy</a:t></a:r></a:p>"
            + "</p:txBody></p:sp></p:spTree></p:cSld></p:sld>"
        let url = try makeArchive(["ppt/slides/slide1.xml": slide])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PptxExtractor.extractText(from: url) == "The mitochondria makes energy")
    }
}
