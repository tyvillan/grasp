import CoreGraphics
import Foundation
import ImageIO
import GRASPCore
import Vision
#if os(macOS)
import AppKit
#else
import UIKit
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Reading a photo of a page, on this device. Nothing here leaves the device:
/// the text is read with Apple's Vision framework, and the picture is shrunk
/// to a small JPEG to keep beside the questions made from it.
nonisolated enum PhotoSupport {
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

    /// One printed line of a page, and where it is.
    struct PageLine {
        let text: String
        /// Fractions of the upright page from its top left corner.
        let box: PhotoBox
        let confidence: Float
    }

    /// A page read and ready: stored upright, with its lines in reading order.
    struct PageReading {
        let jpeg: Data
        let width: Int
        let height: Int
        let lines: [PageLine]
        /// How much the picture was turned to stand it upright (quarter turns clockwise).
        let quarterTurns: Int
        /// The reader was unsure of much of the text: blur, poor light, handwriting.
        let hardToRead: Bool

        var text: String { lines.map(\.text).joined(separator: "\n") }
    }

    /// Reads a photo of a page: finds which way up it is (a phone photo can be sideways or
    /// upside down), reads its lines top to bottom even when the page is tilted, and keeps the
    /// upright picture. Nil when the data is not a picture.
    static func read(_ data: Data, maxBytes: Int = 600_000) async -> PageReading? {
        guard let readable = decoded(data, longEdge: readableLongEdge) else { return nil }
        let (upright, lines, turns) = await Task.detached(priority: .userInitiated) { () -> (CGImage, [PageLine], Int) in
            var best: (image: CGImage, lines: [PageLine], turns: Int, score: Double)?
            for turns in 0..<4 {
                let image = turns == 0 ? readable : (rotated(readable, quarterTurns: turns) ?? readable)
                let lines = recognizeLines(in: image)
                // Upright wins a close call: another way up has to read clearly better.
                let score = turns == 0 ? orientationScore(lines) : orientationScore(lines) * 0.85 - 20
                if best == nil || score > best!.score { best = (image, lines, turns, score) }
                // A page that reads upright, with its numbers counting up, is not turned further.
                if turns == 0, numbering(lines).ascending >= 2, numbering(lines).descending == 0 { break }
            }
            return (best!.image, best!.lines, best!.turns)
        }.value
        guard let stored = scaled(upright, longEdge: storedLongEdge) else { return nil }
        var quality = 0.72
        var jpeg = jpegData(stored, quality: quality)
        while let current = jpeg, current.count > maxBytes, quality > 0.3 {
            quality -= 0.12
            jpeg = jpegData(stored, quality: quality)
        }
        guard let jpeg, jpeg.count <= maxBytes else { return nil }
        let characters = Double(lines.reduce(0) { $0 + $1.text.count })
        let unsure = Double(lines.filter { $0.confidence < 0.5 }.reduce(0) { $0 + $1.text.count })
        let average = characters == 0 ? 1 : lines.reduce(0.0) { $0 + Double($1.confidence) * Double($1.text.count) } / characters
        // Vision stays confident about handwriting it misreads, so words that are not words count too.
        let spelling = await misspelledShare(lines.map(\.text).joined(separator: "\n"))
        let hard = characters > 0 && (average < 0.65 || unsure / characters > 0.3 || spelling > 0.025)
        return PageReading(jpeg: jpeg, width: stored.width, height: stored.height, lines: lines, quarterTurns: turns, hardToRead: hard)
    }

    /// Just the part of a stored picture a box covers, as a small JPEG for a thumbnail.
    static func cropJPEG(_ data: Data, to box: PhotoBox, maxEdge: Int = 420) -> Data? {
        guard let image = decoded(data, longEdge: storedLongEdge) else { return nil }
        let rect = CGRect(x: box.x * Double(image.width), y: box.y * Double(image.height),
                          width: box.width * Double(image.width), height: box.height * Double(image.height)).integral
        guard let part = image.cropping(to: rect), let small = scaled(part, longEdge: maxEdge) else { return nil }
        return jpegData(small, quality: 0.8)
    }

    /// The share of the page's ordinary words that the system spell checker does not know.
    @MainActor static func misspelledShare(_ text: String) -> Double {
        let words = text.split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init).filter { $0.count >= 3 && $0.first?.isLowercase == true }
        guard words.count >= 8 else { return 0 }
        #if os(macOS)
        let checker = NSSpellChecker.shared
        let wrong = words.filter { checker.checkSpelling(of: $0, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound }.count
        #else
        let checker = UITextChecker()
        let wrong = words.filter { checker.rangeOfMisspelledWord(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length), startingAt: 0, wrap: false, language: "en").location != NSNotFound }.count
        #endif
        return Double(wrong) / Double(words.count)
    }

    // MARK: Orientation

    private static let numberStart = try! NSRegularExpression(pattern: #"^\s*(?:Q|Question|Problem)?\s*\.?\s*(\d{1,3})\s*[\.\):]\s*\S"#,
                                                              options: [.caseInsensitive])

    /// How many numbered lines run up the page, and how many run down it.
    private static func numbering(_ lines: [PageLine]) -> (ascending: Int, descending: Int) {
        let numbers = lines.compactMap { line -> Int? in
            guard let match = numberStart.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)),
                  let range = Range(match.range(at: 1), in: line.text) else { return nil }
            return Int(line.text[range])
        }
        var up = 0, down = 0
        for pair in zip(numbers, numbers.dropFirst()) {
            if pair.1 == pair.0 + 1 { up += 1 } else if pair.1 == pair.0 - 1 { down += 1 }
        }
        return (up, down)
    }

    /// Higher is more likely upright: numbers counting up, then how much was read with confidence.
    private static func orientationScore(_ lines: [PageLine]) -> Double {
        let n = numbering(lines)
        let sure = lines.filter { $0.confidence >= 0.5 }.reduce(0) { $0 + $1.text.count }
        return Double(n.ascending - n.descending) * 1000 + Double(sure)
    }

    private static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let w = image.width, h = image.height
        let swap = quarterTurns % 2 == 1
        guard let context = CGContext(data: nil, width: swap ? h : w, height: swap ? w : h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        switch quarterTurns % 4 {
        case 1: context.translateBy(x: 0, y: CGFloat(w)); context.rotate(by: -.pi / 2)
        case 2: context.translateBy(x: CGFloat(w), y: CGFloat(h)); context.rotate(by: .pi)
        case 3: context.translateBy(x: CGFloat(h), y: 0); context.rotate(by: .pi / 2)
        default: break
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    private static func scaled(_ image: CGImage, longEdge: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > longEdge else { return image }
        let factor = Double(longEdge) / Double(longest)
        let w = max(1, Int(Double(image.width) * factor)), h = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    // MARK: Reading

    /// The lines on an upright picture in reading order. A tilted page is straightened in the
    /// ordering (not in the picture), so a line stays one line however the page was held.
    private static func recognizeLines(in image: CGImage) -> [PageLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        let observations = request.results ?? []
        guard !observations.isEmpty else { return [] }
        let w = Double(image.width), h = Double(image.height)

        // How far the page is tilted: the median slope of the lines.
        let slopes = observations.map { atan2(Double($0.topRight.y - $0.topLeft.y) * h, Double($0.topRight.x - $0.topLeft.x) * w) }.sorted()
        var tilt = slopes[slopes.count / 2]
        if abs(tilt) < 0.01 || abs(tilt) > 0.6 { tilt = 0 }

        struct Item { let text: String; let box: CGRect; let along: Double; let across: Double; let height: Double; let confidence: Float }
        let items: [Item] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            let cx = Double(box.midX) * w, cy = Double(box.midY) * h
            // Position along the page's own axes: `across` grows going up the page.
            let across = cy * cos(tilt) - cx * sin(tilt)
            let along = cx * cos(tilt) + cy * sin(tilt)
            let lineHeight = hypot(Double(observation.topLeft.x - observation.bottomLeft.x) * w,
                                   Double(observation.topLeft.y - observation.bottomLeft.y) * h)
            return Item(text: text, box: box, along: along, across: across, height: max(lineHeight, 1), confidence: candidate.confidence)
        }
        let sorted = items.sorted { $0.across > $1.across }

        var rows: [[Item]] = []
        for item in sorted {
            if let last = rows.last?.first, abs(last.across - item.across) < last.height * 0.5 { rows[rows.count - 1].append(item) } else { rows.append([item]) }
        }
        return rows.map { row in
            let ordered = row.sorted { $0.along < $1.along }
            let union = ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            let characters = Float(ordered.reduce(0) { $0 + $1.text.count })
            let confidence = ordered.reduce(Float(0)) { $0 + $1.confidence * Float($1.text.count) } / max(characters, 1)
            return PageLine(text: ordered.map(\.text).joined(separator: " "),
                            box: PhotoBox(x: Double(union.minX), y: 1 - Double(union.maxY), width: Double(union.width), height: Double(union.height)),
                            confidence: confidence)
        }
    }

    /// The text on the page, one printed line per line, top to bottom. Empty
    /// when nothing could be read.
    static func recognizeText(in image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            recognizeLines(in: image).map(\.text).joined(separator: "\n")
        }.value
    }
}
