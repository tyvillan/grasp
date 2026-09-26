import Foundation
#if canImport(Vision)
import CoreGraphics
import Vision
#endif

/// On-device OCR, shared by `ImageExtractor` (photos of handouts) and
/// `PDFExtractor` (scanned or screenshot PDFs with no text layer). Vision
/// runs locally: no network call, no model download.
enum TextRecognition {
    /// Whether OCR should run at all. `GRASP_SKIP_OCR` is only ever set by
    /// `swift test`: the `VNRecognizeTextRequest` below reliably hangs deep
    /// inside Apple's `TextRecognition` internals when invoked from the test
    /// suite's heavily concurrent host process (a `sample` of a stuck run sat
    /// on one `dispatch_semaphore_wait_slow` frame inside Vision itself).
    /// See `RealVaultScanGate` in the test target for where it's set.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GRASP_SKIP_OCR"] != "1"
    }

    #if canImport(Vision)
    /// The recognized lines, top to bottom, or nil if Vision itself failed.
    /// An image with no legible text gives an empty string.
    static func recognizeText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
    #endif
}
