import Foundation

/// Grades a free-text written answer against the correct answer.
/// Exact-match is too harsh for this content (minor spelling, punctuation,
/// article variance) -- normalize first, then fall back to a Levenshtein
/// similarity ratio with two thresholds: a close-enough band still counts
/// as correct (flagged so the UI can say "close -- check your spelling")
/// rather than failing a student who clearly knew the answer.
public enum AnswerGrading {
    public enum Verdict: Sendable, Equatable {
        case correct
        case close   // counts as correct, but the UI should flag it
        case incorrect
    }

    public static func grade(given: String, correct: String) -> Verdict {
        let a = normalize(given)
        let b = normalize(correct)
        if a == b { return .correct }
        guard !a.isEmpty, !b.isEmpty else { return .incorrect }
        // Signs, operators and numbers aren't spelling. Stripping them let
        // sin(a+b) pass for sin(a-b), AB + AB for AB' + A'B, and 1946 for
        // 1945 -- a different answer, one character away. Those have to
        // match exactly; only the words around them get the fuzzy pass.
        if significant(a) != significant(b) { return .incorrect }
        if a.replacingOccurrences(of: " ", with: "") == b.replacingOccurrences(of: " ", with: "") {
            return .correct
        }
        let ratio = similarityRatio(a, b)
        if ratio >= 0.9 { return .correct }
        // The "close" band is for a misspelt word. On a short answer 75%
        // similar is one letter in four wrong -- another word, not a typo.
        if ratio >= 0.8, b.count >= 8 { return .close }
        return .incorrect
    }

    /// Characters that change what an answer means rather than how it's
    /// spelt.
    private static let symbols: Set<Character> = ["+", "-", "=", "<", ">", "'", "^", "/", "*", "%"]

    private static func significant(_ normalized: String) -> String {
        String(normalized.filter { $0.isNumber || symbols.contains($0) })
    }

    static func normalize(_ s: String) -> String {
        // Unicode minus and dashes, curly quotes, and line breaks first, so
        // what follows only has to know one of each.
        var t = s
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2032}", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        t = String(punctuationKept(in: t))
        t = t.lowercased()
        for article in ["the ", "a ", "an "] where t.hasPrefix(article) {
            t.removeFirst(article.count)
        }
        return t.split(separator: " ").joined(separator: " ")
    }

    /// Drops ordinary punctuation and keeps the symbols that carry meaning,
    /// telling apart the two jobs a hyphen and an apostrophe do: joining
    /// words ("self-esteem", "don't", "Newton's") versus meaning minus or
    /// complement ("x-3", "A'B", "AB'").
    private static func punctuationKept(in text: String) -> [Character] {
        let chars = Array(text)
        var out: [Character] = []
        for (i, c) in chars.enumerated() {
            let before = i > 0 ? chars[i - 1] : nil
            let after = i + 1 < chars.count ? chars[i + 1] : nil
            if c.isLetter || c.isNumber || c == " " {
                out.append(c)
            } else if c == "-" {
                // Between two letters it joins words; anywhere else it's a sign.
                if let before, let after, before.isLetter, after.isLetter, before.isLowercase || after.isLowercase {
                    out.append(" ")
                } else {
                    out.append(c)
                }
            } else if c == "'" {
                // After a lowercase letter it's a contraction or possessive;
                // after a capital or a closing bracket it's a complement.
                if let before, before.isLowercase { continue }
                out.append(c)
            } else if symbols.contains(c) {
                out.append(c)
            } else {
                // Brackets, commas, full stops: dropped. A space stands in
                // so "cell,wall" doesn't become one word.
                if c.isWhitespace || c == "," || c == ";" { out.append(" ") }
            }
        }
        return out
    }

    /// 1 - (Levenshtein distance / longer length), in [0, 1].
    static func similarityRatio(_ a: String, _ b: String) -> Double {
        let distance = levenshteinDistance(Array(a), Array(b))
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1 }
        return 1 - Double(distance) / Double(maxLen)
    }

    static func levenshteinDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }
}
