import Foundation
import Testing
@testable import GRASPCore

@Suite("PlainMath")
struct PlainMathTests {
    @Test("inline and display math lose their delimiters and symbols become plain")
    func inlineMath() {
        #expect(PlainMath.clean("Find $v$ so that $x = x_3 v$.") == "Find v so that x = x₃ v.")
        #expect(PlainMath.clean(#"We need \(A^T A\) and $\alpha \leq \frac{1}{2}$."#) == "We need A^T A and α ≤ (1)/(2).")
        #expect(PlainMath.clean("$$x^2 + y^2 = 1$$") == "x² + y² = 1")
        #expect(PlainMath.clean(#"\[ 3 \times 4 \]"#) == "3 × 4")
    }

    @Test("prices are left alone")
    func keepsMoney() {
        #expect(PlainMath.clean("The price rises from $4 to $5, a $1 change.") == "The price rises from $4 to $5, a $1 change.")
        #expect(PlainMath.clean("Costs $1,200 or $30 a month.") == "Costs $1,200 or $30 a month.")
        #expect(PlainMath.clean("Buy at $5 + $3 total") == "Buy at $5 + $3 total")
    }

    @Test("matrix environments become bracketed rows")
    func matrices() {
        let cleaned = PlainMath.clean(#"Let $A = \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}$."#)
        #expect(cleaned.contains("[ 1  2 ]"))
        #expect(cleaned.contains("[ 3  4 ]"))
        #expect(!cleaned.contains("$"))
        #expect(!cleaned.contains("pmatrix"))
    }

    @Test("commands outside delimiters are converted too, and plain text is untouched")
    func bareCommands() {
        #expect(PlainMath.clean(#"the limit as n \to \infty"#) == "the limit as n → ∞")
        let plain = "A 3x3 matrix with x_1 = 4 and 5 > 3."
        #expect(PlainMath.clean(plain) == plain)
    }

    @Test("a stored overview is cleaned when it is read")
    func overviewDecode() {
        var document = OverviewDocument(sections: [OverviewSection(heading: "The rank of $A$", paragraphs: ["If $x_1 = 2$ then it holds."])])
        document.takeaways = ["Remember $A^{-1}$ exists only if \\(\\det A \\neq 0\\)."]
        let decoded = OverviewCoding.decode(OverviewCoding.encode(document))
        #expect(decoded?.sections.first?.heading == "The rank of A")
        #expect(decoded?.sections.first?.paragraphs == ["If x₁ = 2 then it holds."])
        #expect(decoded?.takeaways.first?.contains("$") == false)
    }

    @Test("a stored problem is cleaned when it is read")
    func problemDecode() {
        let problem = ProblemQuestion(kind: .number, subject: .math, prompt: "Find $\\det(A)$ for $A$ below.", number: 2,
                                      explanation: "Use $ad - bc$.")
        let decoded = ProblemQuestion.decode(problem.encoded())
        #expect(decoded?.prompt.contains("$") == false)
        #expect(decoded?.explanation == "Use ad - bc.")
    }
}
