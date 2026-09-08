import Foundation

/// Semester chronology is driven by the frontmatter tag, never the folder
/// name: `Spring Semester 2026-2027/` is tagged `spring-2026` and
/// chronologically precedes `Summer Semester 2026/` -- folder names don't
/// sort correctly on their own (verified against the real vault).
public enum SemesterSlug {
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"^(fall|spring|summer)-(\d{4})$"#
    )
    private static let folderRegex = try! NSRegularExpression(
        pattern: #"(Fall|Spring|Summer) Semester (\d{4})"#
    )

    /// (slug, displayName, sortKey) derived from a note's frontmatter tags,
    /// falling back to the containing folder name if no semester tag is
    /// present (all 280 vault notes have one, but manually-added future
    /// material may not).
    public static func resolve(tags: [String], folderName: String) -> (slug: String, name: String, sortKey: Int) {
        for tag in tags {
            let range = NSRange(tag.startIndex..., in: tag)
            if let m = tagRegex.firstMatch(in: tag, range: range),
               let termRange = Range(m.range(at: 1), in: tag),
               let yearRange = Range(m.range(at: 2), in: tag),
               let year = Int(tag[yearRange]) {
                let term = String(tag[termRange])
                return (tag, displayName(term: term, year: year), sortKey(term: term, year: year))
            }
        }
        // Fallback: parse "Fall Semester 2025-2026" style folder names.
        let range = NSRange(folderName.startIndex..., in: folderName)
        if let m = folderRegex.firstMatch(in: folderName, range: range),
           let termRange = Range(m.range(at: 1), in: folderName),
           let yearRange = Range(m.range(at: 2), in: folderName),
           let year = Int(folderName[yearRange]) {
            let term = String(folderName[termRange]).lowercased()
            let slug = "\(term)-\(year)"
            return (slug, displayName(term: term, year: year), sortKey(term: term, year: year))
        }
        return ("unknown", folderName, Int.max)
    }

    private static func displayName(term: String, year: Int) -> String {
        "\(term.capitalized) \(year)"
    }

    /// Spring < Summer < Fall within a year, matching the US academic
    /// calendar. Encoded as year*10 + termOrder so cross-year comparisons
    /// stay correct.
    private static func sortKey(term: String, year: Int) -> Int {
        let order: Int
        switch term.lowercased() {
        case "spring": order = 1
        case "summer": order = 2
        case "fall": order = 3
        default: order = 0
        }
        return year * 10 + order
    }
}
