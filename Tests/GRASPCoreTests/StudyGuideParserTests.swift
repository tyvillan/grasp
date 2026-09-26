import Testing
import Foundation
@testable import GRASPCore

/// `StudyGuideParser` against invented guides in the two shapes it was
/// built from: a professor's (OCR'd screenshots, question counts, skills,
/// traps, "Example N - question" with the answer straight after) and a
/// student's own (a text layer with bullets on lines of their own, terms,
/// formulas, "Question:" / "Step N:" / "Answer:" / "Why?" examples). The
/// real guides are checked by `RealStudyGuideTests`, which stays off the repo.
@Suite("StudyGuideParser")
struct StudyGuideParserTests {
    static let professorStyle = [
        """
        Exam 2 • Study Guide
        What Exam 2 Tests, and How to Prepare
        Thursday, October 29, 2026 • 30 multiple-choice questions • closed note
        On this page
        • Part 1 • Firms and Costs (12)
        • Part 2 • Market Power (18)
        Thirty questions in the order the topics were taught, each with five options and one best answer to choose.
        """,
        """
        Part 1 • Firms and Costs (12 questions)
        You should be able to
        • Tell a fixed cost from a variable cost, and say which ones matter for a decision to shut down.
        Compute average total cost from a table of output and total cost, and find where it is lowest.
        • Explain why marginal cost crosses average cost at its lowest point, using
        an example with numbers.
        Traps the wrong answers are built on
        • Counting a fixed cost in a shutdown decision.
        • Reading total cost as average cost.
        • Example 1 - A bakery pays $300 a week in rent and $2 of flour per loaf. What is the cost of baking 100 more loaves?
        $200. The rent is paid whether or not it bakes them, so only the flour changes with the choice.
        v Example 2 — Output rises from 10 to 20 units and total cost from $100 to $180. Did average cost rise or
        fall?
        It fell, from $10 to $9 a unit, because each extra unit cost $8.
        • Example 3 - Which is a refutable positive claim? (a) “A tax on flour raises bread prices.” (b)
        “Taxing flour is unfair‚¿¿
        (a). It can be checked against bread prices after the tax, and it could turn out wrong.
        """,
        """
        Part 2 • Market Power (18 questions)
        You should be able to
        • Find a monopolist's profit-maximizing output where marginal revenue equals marginal cost.
        Traps the wrong answers are built on
        • Setting price equal to marginal cost for a monopolist.
        Price
        $10
        $8
        $6
        Try it, then open the answer
        • Example 4 - At which price in the table does the firm sell its third unit?
        $6, where the third unit's marginal revenue still covers its marginal cost.
        """,
    ]

    static let studentStyle = """
        ECO 2023 - EXAM 2 STUDY GUIDE
        PART 1 - FIRMS AND COSTS
        A) Fixed Cost: A cost that does not change with how much you make.
        ●
        Rent is a fixed cost.
        Variable Cost: A cost that rises with each unit you make.
        Average Total Cost = Total Cost ÷ Quantity
        Example: A bakery bakes 100 loaves.
        ●
        Rent: $300
        ●
        Flour: $2 a loaf
        Question: What is the average total cost of a loaf?
        Step 1: Find total cost.
        $300 + (100 × $2) = $500
        Step 2: Divide by quantity.
        $500 ÷ 100 = $5
        Answer: $5 a loaf.
        Why? Rent is spread over every loaf.
        ★ REMEMBER: Fixed costs don't change a shutdown decision. Only costs
        that change with the choice count.
        B) Shutting Down
        Example: You own a cart that sells coffee.
        PART 2 - MARKET POWER
        Monopoly = A market with one seller and no close substitutes.
        ★ Other firms can't enter easily.
        """

    @Test("reads a professor's guide: exam date and format, parts with question counts and pages")
    func professorHeader() {
        let guide = StudyGuideParser.parse(pages: Self.professorStyle)
        #expect(guide.title == "Exam 2 • Study Guide")
        #expect(guide.examDate == "2026-10-29")
        #expect(guide.questionCount == 30)
        #expect(guide.format == ["30 multiple-choice questions", "closed note"])
        #expect(guide.parts.map(\.title) == ["Firms and Costs", "Market Power"])
        #expect(guide.parts.map(\.questionCount) == [12, 18])
        #expect(guide.parts.map(\.page) == [2, 3])
        #expect(guide.totalQuestions == 30)
        // The contents list under "On this page" is not a part, and the
        // date line is not a note.
        #expect(guide.notes.count == 1)
        #expect(guide.notes.first?.hasPrefix("Thirty questions") == true)
    }

    @Test("skills and traps survive OCR dropping bullets and wrapping lines")
    func skillsAndTraps() {
        let part = StudyGuideParser.parse(pages: Self.professorStyle).parts[0]
        #expect(part.skills.count == 3)
        #expect(part.skills[1].hasPrefix("Compute average total cost"))
        #expect(part.skills[2].hasSuffix("using an example with numbers."))
        #expect(part.traps == ["Counting a fixed cost in a shutdown decision.",
                               "Reading total cost as average cost."])
    }

    @Test("an example's question ends where its answer starts, with no marker between them")
    func professorExamples() {
        let examples = StudyGuideParser.parse(pages: Self.professorStyle).parts[0].examples
        #expect(examples.map(\.label) == ["Example 1", "Example 2", "Example 3"])
        #expect(examples.allSatisfy { $0.isPractice })
        #expect(examples[0].question.hasSuffix("What is the cost of baking 100 more loaves?"))
        #expect(examples[0].answer?.hasPrefix("$200.") == true)
        // The question mark sits on the wrapped second line.
        #expect(examples[1].question.hasSuffix("fall?"))
        #expect(examples[1].answer?.hasPrefix("It fell") == true)
        // "(b)" at a line's end opens the next option; the OCR'd closing
        // quote ends the question.
        #expect(examples[2].question.contains("unfair”"))
        #expect(examples[2].answer?.hasPrefix("(a). It can be checked") == true)
    }

    @Test("table cells read out one per line are dropped, and boilerplate skipped")
    func tableDebris() {
        let part = StudyGuideParser.parse(pages: Self.professorStyle).parts[1]
        #expect(part.notes.isEmpty)
        #expect(part.examples.count == 1)
        #expect(part.examples[0].page == 3)
        #expect(part.examples[0].answer?.hasPrefix("$6,") == true)
    }

    @Test("reads a student's guide: terms with their bullets, formulas, callouts")
    func studentTerms() {
        let guide = StudyGuideParser.parse(Self.studentStyle)
        #expect(guide.title == "ECO 2023 - Exam 2 Study Guide")
        #expect(guide.parts.map(\.title) == ["Firms and Costs", "Market Power"])
        #expect(guide.parts.map(\.number) == [1, 2])
        let part = guide.parts[0]
        #expect(part.terms.map(\.term) == ["Fixed Cost", "Variable Cost"])
        #expect(part.terms[0].definition == "A cost that does not change with how much you make.\n• Rent is a fixed cost.")
        #expect(part.formulas == ["Average Total Cost = Total Cost ÷ Quantity"])
        #expect(part.remember == ["Fixed costs don't change a shutdown decision. Only costs that change with the choice count."])
        #expect(guide.parts[1].terms.map(\.term) == ["Monopoly"])
        #expect(guide.parts[1].remember == ["Other firms can't enter easily."])
    }

    @Test("a worked example splits into its question, its steps and its answer")
    func studentExample() {
        let examples = StudyGuideParser.parse(Self.studentStyle).parts[0].examples
        #expect(examples.count == 2)
        let worked = examples[0]
        #expect(worked.label == nil)
        #expect(worked.question == "A bakery bakes 100 loaves.\n• Rent: $300\n• Flour: $2 a loaf\nWhat is the average total cost of a loaf?")
        #expect(worked.steps == ["Step 1: Find total cost. $300 + (100 × $2) = $500",
                                 "Step 2: Divide by quantity. $500 ÷ 100 = $5"])
        #expect(worked.answer == "$5 a loaf.\nWhy? Rent is spread over every loaf.")
        // Asks nothing: an illustration, and "B) Shutting Down" is a
        // heading, not a term.
        #expect(!examples[1].isPractice)
        #expect(examples[1].question == "You own a cart that sells coffee.")
    }

    @Test("titles in capitals read as titles, keeping a course code's capitals")
    func displayTitles() {
        #expect(StudyGuideParser.displayTitle("THE ECONOMIC WAY OF THINKING") == "The Economic Way of Thinking")
        #expect(StudyGuideParser.displayTitle("ECO 2023 - EXAM 1 STUDY GUIDE") == "ECO 2023 - Exam 1 Study Guide")
        #expect(StudyGuideParser.displayTitle("Gains from Exchange") == "Gains from Exchange")
    }

    @Test("a document with no parts is empty, and round-trips through its JSON")
    func coding() throws {
        #expect(StudyGuideParser.parse("Just some notes about nothing in particular.").isEmpty)
        let guide = StudyGuideParser.parse(pages: Self.professorStyle)
        let json = try StudyGuideCoding.encode(guide)
        #expect(StudyGuideCoding.decode(json) == guide)
    }
}
