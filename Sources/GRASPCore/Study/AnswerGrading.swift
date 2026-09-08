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
        let ratio = similarityRatio(a, b)
        if ratio >= 0.9 { return .correct }
        if ratio >= 0.75 { return .close }
        return .incorrect
    }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "a ", "an "] where t.hasPrefix(article) {
            t.removeFirst(article.count)
        }
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        t = String(t.unicodeScalars.filter { allowed.contains($0) })
        return t.split(separator: " ").joined(separator: " ")
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
