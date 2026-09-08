import Foundation

/// A candidate term/definition pair extracted deterministically from a
/// reflowed note body, before any card generator (LLM or manual review)
/// touches it.
public struct CandidatePair: Sendable, Equatable {
    public let front: String
    public let back: String
    /// 1-based line number in the reflowed text this pair was found at,
    /// so a card can always be traced back to its source note.
    public let sourceLine: Int

    public init(front: String, back: String, sourceLine: Int) {
        self.front = front
        self.back = back
        self.sourceLine = sourceLine
    }
}

/// Deterministic term/definition extraction over reflowed note text.
/// Recognizes two shapes, matching the corpus:
///   1. A short bare term line followed by a longer definition paragraph
///      (the dominant shape -- lecture-slide definition dumps).
///   2. "Term: definition" on a single line.
/// Ported and validated against the real vault corpus (857 pairs from the
/// reflowed text, spot-checked for quality) before being written in Swift.
public enum PairParser {
    private static let inlineTermRegex = try! NSRegularExpression(
        pattern: #"^([A-Z][A-Za-z0-9 /'\-]{2,45}):\s+(.{25,})$"#
    )
    private static let numberedListRegex = try! NSRegularExpression(pattern: #"^\d+[.)]"#)

    public static func parse(_ reflowedText: String) -> [CandidatePair] {
        let lines = reflowedText.components(separatedBy: "\n")
        var out: [CandidatePair] = []

        var i = 0
        while i < lines.count {
            let s = lines[i].trimmingCharacters(in: .whitespaces)
            defer { i += 1 }
            if s.isEmpty || isStructural(s) || s.hasPrefix("*Date:") { continue }

            let words = s.split(separator: " ")
            let isBareTermLine = (1...6).contains(words.count)
                && s.count < 55
                && !s.hasSuffix(".") && !s.hasSuffix(",") && !s.hasSuffix(":") && !s.hasSuffix("=")
                && s.first?.isUppercase == true

            if isBareTermLine {
                var j = i + 1
                while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count {
                    let d = lines[j].trimmingCharacters(in: .whitespaces)
                    let dWords = d.split(separator: " ")
                    if dWords.count >= 8, d.first?.isUppercase == true, !isStructural(d) {
                        out.append(CandidatePair(front: s, back: d, sourceLine: i + 1))
                        continue
                    }
                }
            }

            let range = NSRange(s.startIndex..., in: s)
            if let match = inlineTermRegex.firstMatch(in: s, range: range),
               let frontRange = Range(match.range(at: 1), in: s),
               let backRange = Range(match.range(at: 2), in: s) {
                out.append(CandidatePair(
                    front: String(s[frontRange]), back: String(s[backRange]), sourceLine: i + 1
                ))
            }
        }
        return out
    }

    private static func isStructural(_ s: String) -> Bool {
        if s.hasPrefix("#") || s.hasPrefix(">") || s.hasPrefix("-") || s.hasPrefix("*")
            || s.hasPrefix("|") || s.hasPrefix("!") {
            return true
        }
        let range = NSRange(s.startIndex..., in: s)
        return numberedListRegex.firstMatch(in: s, range: range) != nil
    }
}
