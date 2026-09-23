import Foundation

/// Rejoins lines that were hard-wrapped mid-sentence by whatever produced
/// these notes (a slide export, by the look of it). Without this pass, a
/// naive term/definition scan yields mostly garbage -- verified against the
/// real vault: 1,704 candidate pairs before reflow, most nonsense
/// ("bang" / "2.Gravity pulls gas and dust"), collapsing to 857 usable
/// pairs after. This is the single highest-leverage transform in the
/// ingest pipeline and must run before `PairParser`.
public enum Reflow {
    public static func reflow(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var inFence = false

        for rawLine in lines {
            let s = rawLine.trimmingCharacters(in: .whitespaces)
            // Fenced code passes through exactly as written. Reflowing it
            // stripped the indentation and joined lowercase lines, so
            // `self.plate = plate` and `self.passengers = []` became one
            // line -- in the note viewer and in the context the AI reads.
            if s.hasPrefix("```") {
                inFence.toggle()
                out.append(rawLine)
                continue
            }
            if inFence {
                out.append(rawLine)
                continue
            }
            if s == "undefined" { continue }
            if s.isEmpty {
                out.append("")
                continue
            }
            if let last = out.last, !last.isEmpty, !last.hasPrefix("```") {
                let startsLikeContinuation = s.first.map {
                    $0.isLowercase || $0 == ")" || $0 == "," || $0 == ";"
                } ?? false
                let previousEndsSentence = last.hasSuffix(".") || last.hasSuffix(":")
                    || last.hasSuffix("?") || last.hasSuffix("!")
                let isStructural = isStructuralLine(s) || isStructuralLine(last)
                if startsLikeContinuation && !previousEndsSentence && !isStructural {
                    out[out.count - 1] = last + " " + s
                    continue
                }
            }
            out.append(s)
        }
        return out.joined(separator: "\n")
    }

    private static let numberedListRegex = try! NSRegularExpression(pattern: #"^\d+[.)]"#)

    private static func isStructuralLine(_ s: String) -> Bool {
        if s.hasPrefix("#") || s.hasPrefix(">") || s.hasPrefix("-") || s.hasPrefix("*")
            || s.hasPrefix("|") || s.hasPrefix("!") {
            return true
        }
        let range = NSRange(s.startIndex..., in: s)
        return numberedListRegex.firstMatch(in: s, range: range) != nil
    }
}
