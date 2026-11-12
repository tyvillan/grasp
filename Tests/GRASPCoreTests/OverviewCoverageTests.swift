import Testing
@testable import GRASPCore

@Suite("Overview coverage")
struct OverviewCoverageTests {
    private let deck = """
    # 2026-09-08 · Module 3 — C++ Basics (full deck) → Functions
    ## Key Terms
    ## Key Concepts
    ## Slide Summary
    ### S2 · C++ Overview — the common set of features
    ### S4 · Memory
    ### S7, S15 · Variables and data types
    ### S11 · `void`
    ### S16 · Type casting
    ### S19 · `cout` and `cin`
    ### S40–S42 · Function prototypes
    """

    @Test("the note's own headings are found, without slide numbers or generic ones")
    func headings() {
        let found = OverviewCoverage.noteHeadings(in: deck)
        #expect(found == ["C++ Overview — the common set of features", "Memory", "Variables and data types",
                          "void", "Type casting", "cout and cin", "Function prototypes"])
    }

    @Test("a plan that stops partway is told what it left out")
    func missingParts() {
        let headings = OverviewCoverage.noteHeadings(in: deck)
        let planned = ["Memory is numbered slots Memory addresses", "Casting forces math Type casting",
                       "Variables need a type Variables and data types, void"]
        let left = OverviewCoverage.missing(headings: headings, plannedText: planned)
        #expect(left.contains("Function prototypes"))
        #expect(left.contains("cout and cin"))
        #expect(!left.contains("Memory"))
        #expect(!left.contains("Type casting"))
        #expect(!left.contains("void"))
    }

    @Test("a long note gets room for more sections, a short one keeps four or five")
    func range() {
        #expect(OverviewCoverage.sectionRange(headingCount: 3) == "4 or 5")
        #expect(OverviewCoverage.sectionRange(headingCount: 12) == "5 to 7")
        #expect(OverviewCoverage.sectionRange(headingCount: 25) == "6 to 8")
    }

    @Test("the plan prompt lists a long note's headings and asks for the ones left out")
    func promptNamesHeadings() {
        let prompt = OllamaGenerator.lessonPlanPrompt(
            noteTitle: "Deck", courseName: "C++", noteContext: "## A1\n## B2\n## C3\n## D4\n## E5\n## F6\nbody",
            includeFormulas: false, alsoCover: ["F6"])
        #expect(prompt.contains("A1; B2; C3; D4; E5; F6"))
        #expect(prompt.contains("left these parts of the notes out: F6"))
        #expect(prompt.contains("sections: 4 or 5"))
    }

    @Test("quotation marks a model dropped from code come back")
    func quotesRestored() {
        let note = "int main() {\n    cout << \"Total slices: \" << totalSlices << endl;\n}"
        let model = "If you removed the line using namespace std, how would you rewrite cout << Total slices: << totalSlices << endl; to be valid?"
        let fixed = OverviewCoverage.restoringCode(in: model, noteText: note)
        #expect(fixed.contains("cout << \"Total slices: \" << totalSlices << endl;"))
        let single = OverviewCoverage.restoringCode(in: "Line: cout << 'Total slices: ' << totalSlices << endl;", noteText: note)
        #expect(single.contains("cout << \"Total slices: \" << totalSlices << endl;"))
    }

    @Test("a file name takes the note's capitals")
    func fileNames() {
        let note = "Save the file as main.cpp and compile Main.cpp"
        #expect(OverviewCoverage.restoringCode(in: "Open MAIN.CPP now", noteText: note) == "Open main.cpp now")
    }

    @Test("a paragraph that only announces the section is dropped, unless it is the only one")
    func announcements() {
        #expect(OverviewCoverage.isAnnouncement("This section explains how to organize these early definitions."))
        #expect(!OverviewCoverage.isAnnouncement("Semicolons end a statement."))
        let section = OverviewSection(heading: "H", paragraphs: ["Real idea here.", "This section explains the rest."])
        let only = OverviewSection(heading: "H", paragraphs: ["This section explains the rest."])
        let result = OverviewCoverage.withoutFiller([section, only])
        #expect(result[0].paragraphs == ["Real idea here."])
        #expect(result[1].paragraphs.count == 1)
    }

    @Test("a check question that repeats an earlier one is dropped")
    func repeatedChecks() {
        func section(_ q: String) -> OverviewSection {
            OverviewSection(heading: "H", paragraphs: ["p"], check: OverviewCheck(question: q, answer: "a"))
        }
        let result = OverviewCoverage.withoutFiller([
            section("If you define a variable named Car and then try to access it later as car, what will the compiler do?"),
            section("If you define a variable named Car but later try to use car in an assignment statement, what happens?"),
            section("Why does a do-while loop run at least once?"),
        ])
        #expect(result[0].check != nil)
        #expect(result[1].check == nil)
        #expect(result[2].check != nil)
    }
}
