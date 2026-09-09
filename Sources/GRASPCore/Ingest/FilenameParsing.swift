import Foundation

/// Parses the vault's three observed note filename conventions:
///   "<Class> - MM.DD.YY - <Topic>.md"          (older courses, newer style)
///   "<Class> MM.DD.YY.md"                      (older courses, no topic)
///   "YYYY-MM-DD_<Unit>-NN_<Topic>.md"          (Fall 2026 onward)
///
/// The third is the structured convention the current semester's notes
/// use, and it carries more than the other two ever did: an ISO date that
/// sorts correctly as text, and an explicit course unit (`Week-01`,
/// `Lecture-03`, `Module-02`, `Lab-01`, `Ch-07`). That unit is the
/// course's own organising spine, so it drives deck grouping directly
/// rather than having to be inferred from a topic string. Either or both
/// leading segments may be absent -- `Module-01_Ch-01_What-is-Anthropology`
/// has no date, `Practice-Tools` has neither.
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

    /// `[YYYY-MM-DD_]` then optionally `<Unit>-<NN>[-<NN>]_` then the topic.
    /// The trailing `-NN` covers `Lecture-02-03` (a session spanning two
    /// numbered lectures), which groups under the first of them.
    private static let structuredRegex = try! NSRegularExpression(
        pattern: #"^(?:(\d{4})-(\d{2})-(\d{2})_)?"#
            + #"(?:(Week|Lecture|Module|Lab|Chapter|Ch|Unit)-(\d{1,2})(?:-\d{1,2})?_)?"#
            + #"(.*)$"#,
        options: [.caseInsensitive]
    )

    public struct Parsed {
        public let topic: String?
        public let dateFromFilename: Date?
        /// Deck grouping label taken straight from the filename's unit
        /// segment ("Week 1", "Module 3"), when it has one.
        public let unitLabel: String?

        public init(topic: String?, dateFromFilename: Date?, unitLabel: String? = nil) {
            self.topic = topic
            self.dateFromFilename = dateFromFilename
            self.unitLabel = unitLabel
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM.dd.yy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
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
        if let parsed = parseStructured(name) { return parsed }
        return Parsed(topic: nil, dateFromFilename: nil)
    }

    /// Returns nil when the name carries neither a date nor a unit -- there
    /// is nothing structured to report, and claiming the whole filename as
    /// a "topic" would put every unstructured note in its own deck.
    private static func parseStructured(_ name: String) -> Parsed? {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = structuredRegex.firstMatch(in: name, range: range) else { return nil }

        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: name) else { return nil }
            return String(name[r])
        }

        var date: Date?
        if let y = group(1), let mo = group(2), let d = group(3) {
            date = isoFormatter.date(from: "\(y)-\(mo)-\(d)")
        }

        var unitLabel: String?
        if let rawUnit = group(4), let number = group(5).flatMap(Int.init) {
            // "Ch" is spelled out so a deck reads "Chapter 7", matching the
            // label the older courses' decks already use.
            let unit = rawUnit.lowercased() == "ch" ? "Chapter" : rawUnit.capitalized
            unitLabel = "\(unit) \(number)"
        }

        guard date != nil || unitLabel != nil else { return nil }

        let remainder = group(6).map(humanize) ?? ""
        return Parsed(
            topic: remainder.isEmpty ? nil : remainder,
            dateFromFilename: date,
            unitLabel: unitLabel
        )
    }

    /// "First-Day-and-Course-Overview" -> "First Day and Course Overview".
    /// Underscores separate the filename's segments and hyphens separate
    /// words within one, so both become spaces.
    private static func humanize(_ segment: String) -> String {
        segment
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
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
