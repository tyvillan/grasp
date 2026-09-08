import Foundation

/// Parses the vault's two observed note filename conventions:
///   "<Class> - MM.DD.YY - <Topic>.md"   (newer)
///   "<Class> MM.DD.YY.md"               (older, no topic)
public enum FilenameParsing {
    private static let newerRegex = try! NSRegularExpression(
        pattern: #"^(.+?) - (\d{1,2})\.(\d{1,2})\.(\d{2}) - (.+)$"#
    )
    private static let olderRegex = try! NSRegularExpression(
        pattern: #"^(.+?) (\d{1,2})\.(\d{1,2})\.(\d{2})$"#
    )
    private static let chapterInWords = try! NSRegularExpression(
        pattern: #"Chapter\s+(\d+)"#, options: [.caseInsensitive]
    )
    private static let chapterInNumber = try! NSRegularExpression(
        pattern: #"^(\d+)\."#
    )

    public struct Parsed {
        public let topic: String?
        public let dateFromFilename: Date?
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM.dd.yy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func parse(fileNameWithoutExtension name: String) -> Parsed {
        let range = NSRange(name.startIndex..., in: name)
        if let m = newerRegex.firstMatch(in: name, range: range),
           let topicRange = Range(m.range(at: 5), in: name) {
            let dateStr = dateComponentString(m, in: name)
            return Parsed(topic: String(name[topicRange]), dateFromFilename: dateFormatter.date(from: dateStr))
        }
        if let m = olderRegex.firstMatch(in: name, range: range) {
            let dateStr = dateComponentString(m, in: name)
            return Parsed(topic: nil, dateFromFilename: dateFormatter.date(from: dateStr))
        }
        return Parsed(topic: nil, dateFromFilename: nil)
    }

    private static func dateComponentString(_ m: NSTextCheckingResult, in name: String) -> String {
        // Groups 2,3,4 are month, day, year across both regexes.
        func g(_ i: Int) -> String {
            guard let r = Range(m.range(at: i), in: name) else { return "0" }
            return String(name[r])
        }
        return "\(g(2)).\(g(3)).\(g(4))"
    }

    /// Extracts a chapter label from a parsed topic segment, e.g.
    /// "Beginning Chapter 6 Relations" -> "Chapter 6", or a leading section
    /// number "3.1 Propositions and Logical Operators" -> "Chapter 3".
    /// Returns nil when the topic carries no chapter/section signal.
    public static func chapter(fromTopic topic: String) -> String? {
        let range = NSRange(topic.startIndex..., in: topic)
        if let m = chapterInWords.firstMatch(in: topic, range: range),
           let numRange = Range(m.range(at: 1), in: topic) {
            return "Chapter \(topic[numRange])"
        }
        if let m = chapterInNumber.firstMatch(in: topic, range: range),
           let numRange = Range(m.range(at: 1), in: topic) {
            return "Chapter \(topic[numRange])"
        }
        return nil
    }
}
