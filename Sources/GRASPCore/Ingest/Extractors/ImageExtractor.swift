import Foundation
#if canImport(Vision)
import ImageIO
import CoreGraphics
import Vision
#endif

/// On-device OCR for PNG/JPEG images, via Vision -- no network call, no
/// model download, works the moment the app launches. A photo/diagram with
/// no legible text returns an empty string, not nil, matching
/// `PDFExtractor`'s convention for a scanned-image PDF with no text layer:
/// there's nothing wrong with the file, it just has nothing OCR-able on
/// it. `nil` is reserved for the file itself failing to load at all.
public enum ImageExtractor {
    public static func extractText(from url: URL) -> String? {
        #if !canImport(Vision)
        // Windows: not yet -- Windows.Media.Ocr is the planned reader.
        return nil
        #else
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        // `GRASP_SKIP_OCR` is never set outside `swift test` and has zero
        // effect on a real import -- checked only after confirming the
        // file is a real, loadable image, so "not a valid image" still
        // correctly returns nil either way. It exists because the actual
        // `VNRecognizeTextRequest` call below -- reliable as a standalone
        // call (every real PNG/JPEG in the vault, individually, all well
        // under 1s) -- reproducibly hangs deep inside Apple's own
        // on-device `TextRecognition` internals when invoked from within
        // the test suite's heavily concurrent host process (confirmed via
        // `sample` on a stuck run: the whole sampling window sat on one
        // `dispatch_semaphore_wait_slow` frame inside Vision itself, not
        // this file). See `RealVaultScanGate` in the test target for
        // where this gets set.
        guard ProcessInfo.processInfo.environment["GRASP_SKIP_OCR"] != "1" else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
        #endif
    }
}
