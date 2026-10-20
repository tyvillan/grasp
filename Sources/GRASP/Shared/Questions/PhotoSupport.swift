import Foundation
import ImageIO
import Vision
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Reading a photo of a page, on this device. Nothing here leaves the device:
/// the text is read with Apple's Vision framework, and the picture is shrunk
/// to a small JPEG to keep beside the questions made from it.
enum PhotoSupport {
    /// A picture ready to keep and to read.
    struct Prepared {
        /// Compressed for storage: long edge about 1600 px, JPEG.
        let jpeg: Data
        let width: Int
        let height: Int
        /// Larger, for reading (small print needs the pixels).
        let readable: CGImage
    }

    static let storedLongEdge = 1600
    static let readableLongEdge = 2600

    private static func decoded(_ data: Data, longEdge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Applies the camera's rotation, so a phone photo taken sideways reads upright.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Nil when the data is not a readable picture.
    static func prepare(_ data: Data, maxBytes: Int = 600_000) -> Prepared? {
        guard let readable = decoded(data, longEdge: readableLongEdge),
              let stored = decoded(data, longEdge: storedLongEdge) else { return nil }
        var quality = 0.72
        var jpeg = jpegData(stored, quality: quality)
        while let current = jpeg, current.count > maxBytes, quality > 0.3 {
            quality -= 0.12
            jpeg = jpegData(stored, quality: quality)
        }
        guard let jpeg, jpeg.count <= maxBytes else { return nil }
        return Prepared(jpeg: jpeg, width: stored.width, height: stored.height, readable: readable)
    }

    /// The text on the page, one printed line per line, top to bottom. Empty
    /// when nothing could be read.
    static func recognizeText(in image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil else { return "" }
            let observations = request.results ?? []
            // Reading order: highest on the page first, then left to right on
            // the same line (a small tolerance, since lines are never level).
            let sorted = observations.sorted {
                let a = $0.boundingBox, b = $1.boundingBox
                if abs(a.midY - b.midY) < 0.008 { return a.minX < b.minX }
                return a.midY > b.midY
            }
            var lines: [String] = []
            var lastY: CGFloat?
            for observation in sorted {
                guard let text = observation.topCandidates(1).first?.string else { continue }
                let y = observation.boundingBox.midY
                if let last = lastY, abs(last - y) < 0.008, !lines.isEmpty {
                    lines[lines.count - 1] += " " + text
                } else {
                    lines.append(text)
                }
                lastY = y
            }
            return lines.joined(separator: "\n")
        }.value
    }
}
