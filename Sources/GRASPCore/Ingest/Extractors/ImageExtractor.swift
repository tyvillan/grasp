import Foundation
#if canImport(Vision)
import ImageIO
import CoreGraphics
#endif

/// On-device OCR for PNG/JPEG images, via Vision (see `TextRecognition`). A
/// photo/diagram with no legible text returns an empty string, not nil,
/// matching `PDFExtractor`'s convention for a page with nothing to read:
/// there's nothing wrong with the file, it just has nothing OCR-able on
/// it. `nil` is reserved for the file itself failing to load at all.
public enum ImageExtractor {
    public static func extractText(from url: URL) -> String? {
        #if os(Windows)
        // Windows' own OCR engine (see WindowsOCR); skipped under tests like Vision below.
        guard ProcessInfo.processInfo.environment["GRASP_SKIP_OCR"] != "1" else { return "" }
        return WindowsOCR.extractText(from: url)
        #elseif !canImport(Vision)
        return nil
        #else
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        // Checked only after confirming the file is a real, loadable image,
        // so "not a valid image" still correctly returns nil in tests.
        guard TextRecognition.isEnabled else { return "" }
        return TextRecognition.recognizeText(in: cgImage)
        #endif
    }
}
