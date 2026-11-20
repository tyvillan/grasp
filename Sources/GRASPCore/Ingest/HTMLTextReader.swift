import Foundation

/// Turns an HTML page into plain lines for the rest of the import: headings,
/// paragraphs and list items each on a line of their own, list items marked
/// with a bullet, table cells side by side. A saved web page of a study
/// guide then reads like the PDF of the same guide. No scripts are run and
/// nothing is fetched.
public enum HTMLTextReader {
    /// `html` as plain text, or nil when it has no readable text.
    public static func text(from html: String) -> String? {
        var s = html
        // Whole elements that are never document text.
        for pattern in [
            "<!--.*?-->", "<head\\b.*?</head>", "<script\\b.*?</script>", "<style\\b.*?</style>",
            "<noscript\\b.*?</noscript>", "<svg\\b.*?</svg>", "<math\\b.*?</math>",
            // A reading tool's own toolbar and credit line, as in a Beeline copy.
            "<header\\b[^>]*data-beeline-skip[^>]*>.*?</header>",
            "<footer\\b[^>]*>\\s*<a\\b[^>]*>\\s*<span\\b[^>]*beeline-logo.*?</footer>",
        ] {
            // (?s): a dot also matches a line break, so a block spanning lines goes whole.
            s = s.replacingOccurrences(of: "(?s)" + pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // List items become bullets; the other block ends become line breaks.
        s = s.replacingOccurrences(of: "<li\\b[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</t[dh]\\s*>", with: "  ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(
            of: "<br\\s*/?>|</?(p|div|h[1-6]|ul|ol|li|tr|table|thead|tbody|section|article|header|footer|nav|main|details|summary|blockquote|pre|dl|dt|dd|figure|figcaption)\\b[^>]*>",
            with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)

        let lines = s.components(separatedBy: .newlines).map { line -> String in
            line.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && $0 != "•" }
        let result = lines.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    static func decodeEntities(_ text: String) -> String {
        var s = text
        let named: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
            "&#39;": "'", "&ndash;": "–", "&mdash;": "—", "&hellip;": "…", "&middot;": "·",
            "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&times;": "×", "&minus;": "−",
        ]
        for (entity, value) in named where entity != "&amp;" { s = s.replacingOccurrences(of: entity, with: value) }
        // Numeric references: &#8212; and &#x2014;.
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            let ns = s as NSString
            var out = "", last = 0
            for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let code = ns.substring(with: match.range(at: 1))
                let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let value, let scalar = Unicode.Scalar(value) { out.unicodeScalars.append(scalar) }
                last = match.range.location + match.range.length
            }
            s = out + ns.substring(from: last)
        }
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }
}
