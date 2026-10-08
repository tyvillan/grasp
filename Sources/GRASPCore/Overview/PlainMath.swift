import Foundation

/// Makes text a model wrote readable where GRASP can't typeset LaTeX:
/// `$x_3 v$` becomes "x₃ v", `\frac{1}{2}` becomes "(1)/(2)", a
/// `pmatrix` becomes bracketed rows, while a price like "$4 to $5" is left
/// alone. Built on `LatexPlainText`, so the same symbols and the same rule
/// -- anything unrecognised passes through unchanged -- apply here.
public enum PlainMath {
    public static func clean(_ text: String) -> String {
        guard text.contains("$") || text.contains("\\") else { return text }
        var result = text
        // Display and `\(...\)` spans, then `$...$` spans that are really math.
        result = replaceSpans(in: result, pattern: #"\$\$(.+?)\$\$"#)
        result = replaceSpans(in: result, pattern: #"\\\[(.+?)\\\]"#)
        result = replaceSpans(in: result, pattern: #"\\\((.+?)\\\)"#)
        result = replaceSpans(in: result, pattern: #"(?<![\\$])\$([^$\n]+?)\$(?!\d)"#, accepting: looksLikeMath)
        // Commands left outside any delimiters.
        if result.range(of: #"\\[A-Za-z]"#, options: .regularExpression) != nil {
            result = renderMath(result, trimming: false)
        }
        return result
    }

    /// Whether the text between two dollar signs is math rather than the
    /// stretch between two prices ("4 to " in "$4 to $5").
    static func looksLikeMath(_ inner: String) -> Bool {
        guard let first = inner.first, let last = inner.last, !first.isWhitespace, !last.isWhitespace else { return false }
        if inner.contains(where: { "\\^_{}".contains($0) }) { return true }
        return !first.isNumber && first != "," && first != "."
    }

    private static func replaceSpans(in text: String, pattern: String,
                                     accepting: (String) -> Bool = { _ in true }) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: match.range(at: 1))
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += accepting(inner) ? renderMath(inner, trimming: true) : ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// One piece of math as plain text.
    static func renderMath(_ latex: String, trimming: Bool) -> String {
        var text = expandMatrices(latex)
        text = LatexPlainText.dropTypographyMacros(text)
        text = LatexPlainText.expandStructures(text)
        text = LatexPlainText.substituteSymbols(text)
        text = LatexPlainText.applyScripts(text)
        text = text.replacingOccurrences(of: #"\\\\"#, with: "; ", options: .regularExpression)
        return trimming ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    /// `\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}` as bracketed rows on
    /// lines of their own.
    static func expandMatrices(_ latex: String) -> String {
        let pattern = #"\\begin\{(?:p|b|B|v|V|small)?matrix\}(.+?)\\end\{(?:p|b|B|v|V|small)?matrix\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return latex }
        let ns = latex as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: latex, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let rows = ns.substring(with: match.range(at: 1)).components(separatedBy: "\\\\")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                .map { row in
                    "[ " + row.components(separatedBy: "&").map { $0.trimmingCharacters(in: .whitespaces) }
                        .joined(separator: "  ") + " ]"
                }
            result += "\n" + rows.joined(separator: "\n") + "\n"
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// The same cleanup for a list.
    public static func clean(_ texts: [String]) -> [String] { texts.map(clean) }
}

extension OverviewDocument {
    /// This lesson with its prose in plain notation, for stored lessons
    /// written before the model was told to avoid LaTeX.
    public func plainNotation() -> OverviewDocument {
        var copy = self
        copy.title = title.map(PlainMath.clean)
        copy.hook = hook.map(PlainMath.clean)
        copy.objectives = PlainMath.clean(objectives)
        copy.takeaways = PlainMath.clean(takeaways)
        copy.sections = sections.map { section in
            var s = section
            s.heading = PlainMath.clean(section.heading)
            s.paragraphs = PlainMath.clean(section.paragraphs)
            s.terms = section.terms.map { term in
                var t = term
                t.term = PlainMath.clean(term.term)
                t.text = PlainMath.clean(term.text)
                t.example = term.example.map(PlainMath.clean)
                t.nonExample = term.nonExample.map(PlainMath.clean)
                return t
            }
            if var example = section.example {
                example.title = example.title.map(PlainMath.clean)
                example.setup = example.setup.map(PlainMath.clean)
                example.outcome = example.outcome.map(PlainMath.clean)
                example.steps = example.steps.map { step in
                    var st = step
                    st.action = PlainMath.clean(step.action)
                    st.result = step.result.map(PlainMath.clean)
                    st.why = step.why.map(PlainMath.clean)
                    return st
                }
                s.example = example
            }
            if let check = section.check {
                s.check = OverviewCheck(question: PlainMath.clean(check.question), answer: PlainMath.clean(check.answer))
            }
            return s
        }
        copy.formulas = formulas.map { formula in
            var f = formula
            f.name = PlainMath.clean(formula.name)
            f.meaning = formula.meaning.map(PlainMath.clean)
            return f
        }
        return copy
    }
}
