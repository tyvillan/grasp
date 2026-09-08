import Foundation

/// Cleanup passes applied to a note body before anything else touches it.
/// Order matters -- base64 stripping must run first, or a downstream pass
/// (reflow, pair parsing, or eventually an LLM prompt) chokes on a single
/// line that can run past 100,000 characters.
public enum TextCleaning {
    private static let base64ImageRegex = try! NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(data:image\/[^)]*\)"#
    )

    /// Three Intro-to-Python notes carry inline
    /// `![](data:image/jpeg;base64,...)` blocks -- measured at 335 KB of the
    /// corpus's 623 KB of note text, one line alone 138,468 characters. This
    /// must run before reflow or pair parsing ever see the string.
    public static func stripBase64Images(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return base64ImageRegex.stringByReplacingMatches(
            in: text, range: range, withTemplate: "[image]"
        )
    }

    /// Import-artifact lines that are exactly the literal word `undefined`.
    public static func stripUndefinedArtifacts(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != "undefined" }
            .joined(separator: "\n")
    }

    /// True for the 42 vault stubs whose body is only
    /// "*No notes or outline available for this entry.*" -- these carry a
    /// frontmatter block and a heading but no real content.
    public static func isEmptyStub(_ body: String) -> Bool {
        body.contains("No notes or outline available")
    }

    private static let dateLineRegex = try! NSRegularExpression(
        pattern: #"^\*Date:\s*(.+?)\*\s*$"#, options: [.anchorsMatchLines]
    )
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Pulls the `*Date: October 28, 2025*` line some notes carry and
    /// returns the parsed date plus the body with that line removed.
    public static func extractDateLine(_ body: String) -> (date: Date?, body: String) {
        let range = NSRange(body.startIndex..., in: body)
        guard let match = dateLineRegex.firstMatch(in: body, range: range),
              let dateRange = Range(match.range(at: 1), in: body) else {
            return (nil, body)
        }
        let dateString = String(body[dateRange])
        let date = dateFormatter.date(from: dateString)
        let cleaned = dateLineRegex.stringByReplacingMatches(
            in: body, range: range, withTemplate: ""
        )
        return (date, cleaned)
    }

    /// Full cleanup pipeline in the required order.
    public static func clean(_ raw: String) -> String {
        var t = stripBase64Images(raw)
        t = stripUndefinedArtifacts(t)
        t = t.replacingOccurrences(of: "\u{2013}", with: "-")  // en dash
             .replacingOccurrences(of: "\u{2014}", with: "-")  // em dash
        return t
    }
}
