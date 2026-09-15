import Testing
import Foundation
@testable import GRASPCore

/// No fixture-based OCR round-trip test here, deliberately -- matching
/// this test target's existing precedent for `PDFExtractor`/`DocxExtractor`
/// (neither has one either). A real Vision `VNRecognizeTextRequest` call,
/// run from inside `swift test`'s concurrent host process alongside the
/// rest of this suite, reproducibly hung deep inside Apple's own
/// `TextRecognition` internals (`sample` on the stuck process showed every
/// frame parked on one `dispatch_semaphore_wait_slow`, not this repo's
/// code) -- with two different synthetic test images, and independent of
/// `.accurate` vs `.fast` recognition level. The same call, from a plain
/// standalone compiled binary (no test harness, no concurrent test load)
/// against all 50 real PNG/JPEG files in the actual vault, succeeded every
/// time in well under 1 second each. That's a real concurrency fragility
/// in Vision under this specific host process, not a bug in
/// `ImageExtractor` -- and not something worth an automated test hanging
/// the whole suite over.
@Suite("ImageExtractor")
struct ImageExtractorTests {
    @Test("a file that isn't a valid image returns nil")
    func invalidFileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-image-\(UUID().uuidString).png")
        try Data("definitely not a png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ImageExtractor.extractText(from: url) == nil)
    }
}
