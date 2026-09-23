import Testing
@testable import GRASPCore

/// This is not a typesetter and isn't trying to become one. What it has to
/// guarantee is narrower: what it recognises reads as a formula a person
/// chose to write in plain text, and what it doesn't recognise comes back
/// unharmed rather than half-rewritten into nonsense.
@Suite("LaTeX plain text")
struct LatexPlainTextTests {

    @Test("strips every delimiter spelling")
    func delimiters() {
        #expect(LatexPlainText.render("\\(x + y\\)") == "x + y")
        #expect(LatexPlainText.render("\\[x + y\\]") == "x + y")
        #expect(LatexPlainText.render("$x + y$") == "x + y")
        #expect(LatexPlainText.render("$$x + y$$") == "x + y")
        #expect(LatexPlainText.render("x + y") == "x + y")
    }

    @Test("substitutes the symbols a lecture note actually uses")
    func symbols() {
        #expect(LatexPlainText.render("\\alpha") == "α")
        #expect(LatexPlainText.render("\\Omega") == "Ω")
        #expect(LatexPlainText.render("a \\leq b") == "a ≤ b")
        #expect(LatexPlainText.render("a \\neq b") == "a ≠ b")
        #expect(LatexPlainText.render("a \\times b") == "a × b")
        #expect(LatexPlainText.render("A \\to B") == "A → B")
        #expect(LatexPlainText.render("\\sum") == "∑")
        #expect(LatexPlainText.render("\\infty") == "∞")
    }

    @Test("matches the longest macro name, so \\leq never becomes ≤ plus a stray q")
    func longestMatchWins() {
        #expect(LatexPlainText.render("\\leq") == "≤")
        #expect(LatexPlainText.render("\\le") == "≤")
        #expect(LatexPlainText.render("\\geq") == "≥")
    }

    @Test("keeps the parentheses when flattening a fraction")
    func fractionsKeepParentheses() {
        // Dropping them would turn this into a+b/c, a different and wrong
        // formula -- which is the whole reason they're there.
        #expect(LatexPlainText.render("\\frac{a+b}{c}") == "(a+b)/(c)")
        #expect(LatexPlainText.render("\\frac{1}{2}") == "(1)/(2)")
    }

    @Test("handles a nested fraction without losing its structure")
    func nestedFractions() {
        let result = LatexPlainText.render("\\frac{\\frac{a}{b}}{c}")
        #expect(result.contains("/"))
        #expect(!result.contains("\\frac"))
    }

    @Test("drops macros that only affect spacing or face")
    func typographyMacros() {
        #expect(LatexPlainText.render("\\left( x \\right)") == "( x )")
        #expect(LatexPlainText.render("a \\, b").contains("a"))
        #expect(LatexPlainText.render("\\text{per mole}") == "per mole")
        #expect(LatexPlainText.render("\\mathrm{d}x") == "dx")
    }

    @Test("lifts single-character scripts to Unicode and leaves the rest alone")
    func scripts() {
        #expect(LatexPlainText.render("x^2") == "x²")
        #expect(LatexPlainText.render("x_1") == "x₁")
        #expect(LatexPlainText.render("x^{2}") == "x²")
        // No Unicode form for a multi-character exponent, so the original
        // notation stands rather than being flattened into a guess.
        #expect(LatexPlainText.render("x^{ab}") == "x^{ab}")
    }

    @Test("renders a realistic formula as something readable")
    func realisticFormula() {
        #expect(LatexPlainText.render("\\alpha \\leq \\frac{1}{2}") == "α ≤ (1)/(2)")
        #expect(LatexPlainText.render("\\(E = mc^2\\)") == "E = mc²")
    }

    @Test("passes an unknown macro through rather than mangling it")
    func unknownMacrosSurvive() {
        #expect(LatexPlainText.render("\\weirdmacro{x}") == "\\weirdmacro{x}")
    }

    @Test("leaves unbalanced braces alone instead of guessing where they ended")
    func unbalancedBracesAreSafe() {
        let result = LatexPlainText.render("\\frac{a}{b")
        #expect(result.contains("a"))
        #expect(!result.isEmpty)
    }

    @Test("handles empty and whitespace input without crashing")
    func emptyInput() {
        #expect(LatexPlainText.render("") == "")
        #expect(LatexPlainText.render("   ") == "")
    }

    @Test("expands a square root")
    func squareRoot() {
        #expect(LatexPlainText.render("\\sqrt{2}") == "√(2)")
    }
}
