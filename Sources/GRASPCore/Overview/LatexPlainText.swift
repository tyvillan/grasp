import Foundation

/// Turns a LaTeX fragment into a line a person can read at a glance and
/// paste into a message.
///
/// Explicitly **not** a typesetter, and not a step toward one. A credible
/// LaTeX engine is a font-metrics-and-box-and-glue project, and what a
/// student actually needs from a formula in a study overview is to read it
/// and copy it -- not for the integral sign to be the right size. What this
/// does buy over simply stripping the delimiters is the difference between
/// `α ≤ (1)/(2)` and `\alpha \leq \frac{1}{2}`: one reads as a formula
/// somebody chose to write in plain text, the other reads as a rendering
/// failure.
///
/// Anything it doesn't recognise passes through verbatim rather than being
/// mangled, so the worst case is the original source -- never something
/// half-rewritten into nonsense.
public enum LatexPlainText {
    public static func render(_ latex: String) -> String {
        var text = stripDelimiters(latex)
        text = dropTypographyMacros(text)
        text = expandStructures(text)
        text = substituteSymbols(text)
        text = applyScripts(text)
        return text
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Delimiters

    static func stripDelimiters(_ latex: String) -> String {
        var text = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs = [("\\[", "\\]"), ("\\(", "\\)"), ("$$", "$$"), ("$", "$")]
        for (open, close) in pairs where text.hasPrefix(open) && text.hasSuffix(close) {
            guard text.count >= open.count + close.count else { continue }
            text = String(text.dropFirst(open.count).dropLast(close.count))
            break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Macros that only affect spacing or face

    private static let droppedMacros = [
        "\\displaystyle", "\\textstyle", "\\scriptstyle", "\\limits", "\\nolimits",
        "\\left", "\\right", "\\bigl", "\\bigr", "\\Bigl", "\\Bigr",
        "\\quad", "\\qquad", "\\,", "\\;", "\\:", "\\!", "\\ ",
    ]

    /// Wrappers whose contents should survive but whose name shouldn't.
    private static let unwrappedMacros = [
        "\\text", "\\mathrm", "\\mathbf", "\\mathit", "\\mathsf", "\\mathbb",
        "\\operatorname", "\\textbf", "\\textit",
    ]

    static func dropTypographyMacros(_ latex: String) -> String {
        var text = latex
        for macro in unwrappedMacros {
            while let range = text.range(of: macro + "{") {
                guard let close = matchingBrace(in: text, openingAt: range.upperBound) else { break }
                let inner = String(text[range.upperBound..<close])
                text.replaceSubrange(range.lowerBound...close, with: inner)
            }
        }
        for macro in droppedMacros {
            text = replacingMacro(macro, in: text, with: macro == "\\ " ? " " : "")
        }
        return text
    }

    /// Replaces a macro only where it ends -- where the next character
    /// isn't a letter. As a plain substring, dropping `\right` turned
    /// `\rightarrow` into "arrow", and `\in` turned `\inf` into "∈f".
    static func replacingMacro(_ macro: String, in text: String, with replacement: String) -> String {
        guard let last = macro.last, last.isLetter else {
            return text.replacingOccurrences(of: macro, with: replacement)
        }
        let pattern = NSRegularExpression.escapedPattern(for: macro) + "(?![A-Za-z])"
        return text.replacingOccurrences(
            of: pattern, with: NSRegularExpression.escapedTemplate(for: replacement),
            options: .regularExpression
        )
    }

    /// Index of the `}` closing the `{` that starts at `index`, or nil when
    /// the source is unbalanced -- in which case the caller leaves the text
    /// alone rather than guessing where it should have ended.
    private static func matchingBrace(in text: String, openingAt index: String.Index) -> String.Index? {
        var depth = 1
        var cursor = index
        while cursor < text.endIndex {
            if text[cursor] == "{" { depth += 1 }
            if text[cursor] == "}" {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    // MARK: - Structure

    /// `\frac{a}{b}` becomes `(a)/(b)`, parentheses included. Dropping them
    /// would turn `\frac{a+b}{c}` into `a+b/c`, which is a different -- and
    /// wrong -- formula, and a wrong formula is worse than an ugly one.
    static func expandStructures(_ latex: String) -> String {
        var text = latex
        var guardCounter = 0
        while let range = text.range(of: "\\frac{"), guardCounter < 64 {
            guardCounter += 1
            let numeratorStart = range.upperBound
            guard let numeratorEnd = matchingBrace(in: text, openingAt: numeratorStart) else { break }
            let afterNumerator = text.index(after: numeratorEnd)
            guard afterNumerator < text.endIndex, text[afterNumerator] == "{" else { break }
            let denominatorStart = text.index(after: afterNumerator)
            guard let denominatorEnd = matchingBrace(in: text, openingAt: denominatorStart) else { break }

            let numerator = String(text[numeratorStart..<numeratorEnd])
            let denominator = String(text[denominatorStart..<denominatorEnd])
            text.replaceSubrange(
                range.lowerBound...denominatorEnd,
                with: "(\(numerator))/(\(denominator))"
            )
        }

        guardCounter = 0
        while let range = text.range(of: "\\sqrt{"), guardCounter < 64 {
            guardCounter += 1
            guard let close = matchingBrace(in: text, openingAt: range.upperBound) else { break }
            let inner = String(text[range.upperBound..<close])
            text.replaceSubrange(range.lowerBound...close, with: "√(\(inner))")
        }
        return text
    }

    // MARK: - Symbols

    /// Sorted longest-first at use, so `\leq` is never matched as `\le`
    /// followed by a stray `q`.
    static let symbols: [String: String] = [
        "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ", "\\epsilon": "ε",
        "\\varepsilon": "ε", "\\zeta": "ζ", "\\eta": "η", "\\theta": "θ", "\\iota": "ι",
        "\\kappa": "κ", "\\lambda": "λ", "\\mu": "μ", "\\nu": "ν", "\\xi": "ξ",
        "\\pi": "π", "\\rho": "ρ", "\\sigma": "σ", "\\tau": "τ", "\\upsilon": "υ",
        "\\phi": "φ", "\\varphi": "φ", "\\chi": "χ", "\\psi": "ψ", "\\omega": "ω",
        "\\Gamma": "Γ", "\\Delta": "Δ", "\\Theta": "Θ", "\\Lambda": "Λ", "\\Xi": "Ξ",
        "\\Pi": "Π", "\\Sigma": "Σ", "\\Phi": "Φ", "\\Psi": "Ψ", "\\Omega": "Ω",

        "\\leq": "≤", "\\le": "≤", "\\geq": "≥", "\\ge": "≥", "\\neq": "≠", "\\ne": "≠",
        "\\approx": "≈", "\\equiv": "≡", "\\sim": "∼", "\\propto": "∝",
        "\\ll": "≪", "\\gg": "≫",

        "\\times": "×", "\\cdot": "·", "\\div": "÷", "\\pm": "±", "\\mp": "∓",
        "\\ast": "∗", "\\circ": "∘",

        "\\to": "→", "\\rightarrow": "→", "\\leftarrow": "←", "\\Rightarrow": "⇒",
        "\\Leftarrow": "⇐", "\\leftrightarrow": "↔", "\\Leftrightarrow": "⇔",
        "\\uparrow": "↑", "\\downarrow": "↓",

        "\\sum": "∑", "\\prod": "∏", "\\int": "∫", "\\oint": "∮", "\\partial": "∂",
        "\\nabla": "∇", "\\infty": "∞", "\\sqrt": "√",

        "\\in": "∈", "\\notin": "∉", "\\subset": "⊂", "\\subseteq": "⊆",
        "\\cup": "∪", "\\cap": "∩", "\\emptyset": "∅", "\\forall": "∀", "\\exists": "∃",
        "\\land": "∧", "\\lor": "∨", "\\neg": "¬",

        "\\degree": "°", "\\prime": "′", "\\ldots": "…", "\\dots": "…", "\\cdots": "⋯",
    ]

    static func substituteSymbols(_ latex: String) -> String {
        var text = latex
        for key in symbols.keys.sorted(by: { $0.count > $1.count }) {
            guard let replacement = symbols[key] else { continue }
            text = replacingMacro(key, in: text, with: replacement)
        }
        return text
    }

    // MARK: - Scripts

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "n": "ⁿ", "i": "ⁱ", "+": "⁺", "-": "⁻",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "a": "ₐ", "e": "ₑ", "i": "ᵢ", "o": "ₒ", "x": "ₓ", "+": "₊", "-": "₋",
    ]

    /// Only single characters, and only where a Unicode form exists. `x^2`
    /// becomes `x²`; `x^{ab}` is left as written, because a made-up
    /// flattening reads worse than the original notation a student already
    /// knows how to interpret.
    static func applyScripts(_ latex: String) -> String {
        var result = ""
        let characters = Array(latex)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "^" || character == "_" {
                let table = character == "^" ? superscripts : subscripts
                // `x^{2}` is the same single character as `x^2`.
                var target: Character?
                var consumed = 0
                if index + 1 < characters.count, characters[index + 1] == "{" ,
                   index + 3 < characters.count, characters[index + 3] == "}" {
                    target = characters[index + 2]
                    consumed = 4
                } else if index + 1 < characters.count {
                    target = characters[index + 1]
                    consumed = 2
                }
                if let target, let replacement = table[target] {
                    result.append(replacement)
                    index += consumed
                    continue
                }
            }
            result.append(character)
            index += 1
        }
        return result
    }
}
