import Foundation
import Testing
@testable import GRASPCore

/// Lab 1 of Intro to Software Design, as the raw note writes its code.
private let labOne = """
## The Worked Example

```python
class BankAccount:
    \"\"\"A simple bank account class demonstrating encapsulation.\"\"\"

    def __init__(self, owner, initial_balance):
        self.owner = owner                  # public
        self.__balance = initial_balance    # private

    def deposit(self, amount):
        if amount > 0:
            self.__balance += amount
        else:
            print("Deposit amount must be positive")
```

```python
alice = BankAccount("Alice", 100)
john  = BankAccount("John", 2500)
```

Matrix, not code:

```
[ 1  -7 | 5 ]
[ 0   1 | 2 ]
```
"""

@Suite("Overview review and clean-up")
struct OverviewReviewTests {
    @Test("a fact-check fix lands only where it quotes the section exactly")
    func fixes() {
        let section = OverviewSection(
            heading: "Editing the identity isolates each action",
            paragraphs: ["Swapping the two diagonal ones produces a reflection across the line x1 = x2. Scaling a diagonal entry stretches the square."],
            check: OverviewCheck(question: "What does a zero on the diagonal do?", answer: "It rotates the square by ninety degrees.")
        )
        let fixed = OverviewReview.apply([
            OverviewFix(original: "Swapping the two diagonal ones produces a reflection across the line x1 = x2.",
                        corrected: "Swapping the two columns produces a reflection across the line x1 = x2."),
            OverviewFix(original: "It rotates the square by ninety degrees.", corrected: nil),
            OverviewFix(original: "A paraphrase that isn't in the text at all.", corrected: "Anything"),
        ], to: section)
        #expect(fixed.paragraphs[0].hasPrefix("Swapping the two columns"))
        #expect(fixed.paragraphs[0].hasSuffix("stretches the square."))
        #expect(fixed.check == nil)   // its answer was removed
    }

    @Test("a repeated section is dropped and its new terms move to the original")
    func repetition() {
        let document = OverviewDocument(
            sections: [
                OverviewSection(heading: "A", paragraphs: ["a"], terms: [OverviewDefinition(term: "Ambiguity", text: "x")]),
                OverviewSection(heading: "B", paragraphs: ["b"]),
                OverviewSection(heading: "C", paragraphs: ["c"], terms: [OverviewDefinition(term: "Multiple inheritance", text: "y"),
                                                                          OverviewDefinition(term: "ambiguity", text: "z")]),
            ],
            takeaways: ["one", "two", "one again"]
        )
        let result = OverviewReview.apply(OverviewRepetition(sections: [(repeated: 2, original: 0)], takeaways: [2]), to: document)
        #expect(result.sections.map(\.heading) == ["A", "B"])
        #expect(result.sections[0].terms.map(\.term) == ["Ambiguity", "Multiple inheritance"])
        #expect(result.takeaways == ["one", "two"])
        // Nonsense pairs are ignored rather than trusted.
        let bogus = OverviewReview.apply(OverviewRepetition(sections: [(repeated: 0, original: 2), (repeated: 9, original: 1)], takeaways: [0, 1, 2]), to: document)
        #expect(bogus.sections.count == 3)
        #expect(bogus.takeaways.count == 3)
    }

    @Test("invented math is stripped from a lecture that isn't about math, dollar amounts are not")
    func fakeMath() {
        let document = OverviewDocument(
            sections: [OverviewSection(
                heading: "Popularity is not safety",
                paragraphs: ["If we assume popularity equals safety, then $P_{popular} = S_{safe}$ would hold. The $20 plan lacks the data processing you need.",
                             "Consider \\text{Total Execution } E = T - \\text{Friction}."],
                terms: [OverviewDefinition(term: "Total Execution E", text: "a measure of execution"),
                        OverviewDefinition(term: "Context Vault", text: "text files that give AI context")]
            )],
            takeaways: ["Verify skills before installing them."],
            formulas: [OverviewFormula(name: "Cost Efficiency Ratio", plain: "human_cost_divided_by_AI_cost")]
        )
        let cleaned = OverviewReview.cleaned(document, noteText: "An AI agents workshop about skills, vaults and plans.")
        #expect(cleaned.sections[0].paragraphs == ["The $20 plan lacks the data processing you need."])
        #expect(cleaned.sections[0].terms.map(\.term) == ["Context Vault"])
        #expect(cleaned.formulas.isEmpty)
    }

    @Test("a math lecture keeps its equations")
    func realMath() {
        let document = OverviewDocument(sections: [OverviewSection(heading: "h", paragraphs: ["We solve x = 3 - y by substituting."])])
        let note = "A linear equation, a system of equations, a matrix, vectors and the theorem about solutions."
        #expect(OverviewReview.cleaned(document, noteText: note).sections[0].paragraphs.count == 1)
    }

    @Test("a figure stays only beside a section that discusses it")
    func figureRelevance() {
        let transform = OverviewFigure(kind: .linearTransform, matrix: [[2, 0], [0, 1]])
        let aboutCoefficients = OverviewSection(heading: "Matrices organize coefficients", paragraphs: ["Rows hold equations and columns hold variables."])
        let aboutShear = OverviewSection(heading: "An off-diagonal entry shears the square", paragraphs: ["The unit square tilts."])
        #expect(!OverviewReview.figureFits(transform, in: aboutCoefficients))
        #expect(OverviewReview.figureFits(transform, in: aboutShear))

        let lines = OverviewFigure(kind: .systemOfLines, equations: [[1, 1, 3], [2, 3, 7]])
        let proof = OverviewSection(heading: "Dependence exposes a vector built from earlier ones", paragraphs: ["Divide by a_j to isolate v_j."])
        let example = OverviewSection(heading: "Row operations keep the solution", paragraphs: ["Take x + y = 3 and 2x + 3y = 7."])
        #expect(!OverviewReview.figureFits(lines, in: proof))
        #expect(OverviewReview.figureFits(lines, in: example))
    }

    @Test("near-copy takeaways and leaked plan fields are dropped")
    func junk() {
        let document = OverviewDocument(
            objectives: ["Test linear independence with homogeneous systems.", "covers", "Use getters.],[{"],
            sections: [OverviewSection(heading: "h", paragraphs: ["p"])],
            takeaways: ["A set containing more vectors than entries is always dependent.",
                        "A set containing more vectors than entries is always linearly dependent."]
        )
        let cleaned = OverviewReview.cleaned(document, noteText: "matrix vectors theorem equations linear system")
        #expect(cleaned.objectives == ["Test linear independence with homogeneous systems."])
        #expect(cleaned.takeaways.count == 1)
    }
}

@Suite("Code from notes")
struct NoteCodeTests {
    @Test("fenced code is read with its indentation; a matrix block isn't code")
    func snippets() {
        let snippets = NoteCode.snippets(in: labOne)
        #expect(snippets.count == 2)
        #expect(snippets[0].language == "python")
        #expect(snippets[0].code.contains("\n    def deposit(self, amount):"))
        #expect(snippets[0].identifiers.isSuperset(of: ["BankAccount", "deposit", "__balance", "owner"]))
        #expect(!snippets[0].identifiers.contains("demonstrating"))
    }

    @Test("each snippet goes beside the section that names the most of it")
    func placement() {
        let sections = [
            OverviewSection(heading: "One blueprint serves many customers", paragraphs: ["alice and john share one BankAccount class."]),
            OverviewSection(heading: "Private data hides the balance", paragraphs: ["self.__balance is private while owner is public, and deposit guards it."]),
            OverviewSection(heading: "Why OOP", paragraphs: ["Fewer functions to track."]),
        ]
        let placed = NoteCode.placements(of: NoteCode.snippets(in: labOne), in: sections)
        #expect(placed[1]?.code.contains("class BankAccount") == true)
        #expect(placed[0]?.code.contains("alice = BankAccount") == true)
        #expect(placed[2] == nil)
    }

    @Test("a rewrite reads the note's code with its line breaks, however it was stored")
    func freshReflow() {
        let stored = NoteText(materialId: "m", raw: labOne, reflowed: "```python class BankAccount: def deposit(self):", wordCount: 60, hasMath: false)
        let fresh = OverviewComposer.freshlyReflowed(stored)
        #expect(fresh.reflowed.contains("class BankAccount:\n"))
    }
}

@Suite("Spelled-out notation")
struct SpelledNotationTests {
    @Test("x sub three reads as x₃")
    func spelled() {
        #expect(MathNotation.prettify("x sub three changes while x sub 1 is fixed") == "x₃ changes while x₁ is fixed")
    }
}

@Suite("Review safety")
struct ReviewSafetyTests {
    @Test("a review that would delete most of a section only gets to correct it")
    func massRemovalIgnored() {
        let sentences = ["A shear tilts one axis.", "A zero on the diagonal projects the square.",
                         "A negative entry reflects it.", "Scaling by k stretches it."]
        let section = OverviewSection(heading: "h", paragraphs: [sentences.joined(separator: " ")])
        var fixes = sentences.map { OverviewFix(original: $0, corrected: nil) }
        fixes.append(OverviewFix(original: "A negative entry reflects it.", corrected: "A negative diagonal entry reflects it."))
        let result = OverviewReview.apply(fixes, to: section)
        #expect(result.paragraphs == ["A shear tilts one axis. A zero on the diagonal projects the square. A negative diagonal entry reflects it. Scaling by k stretches it."])
    }
}
