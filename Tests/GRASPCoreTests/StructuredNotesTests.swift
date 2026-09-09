import Testing
import Foundation
@testable import GRASPCore

/// The Fall 2026-2027 semester introduced a second note convention that
/// nothing in the vault used before: nested `01_Lectures`/`02_Readings`
/// folders, `YYYY-MM-DD_Unit-NN_Topic` filenames, and notes written as
/// markdown prose rather than the hard-wrapped slide dumps the original
/// parser was tuned against. These lock in the rules added for it.
@Suite("StructuredNotes")
struct StructuredNotesTests {

    // MARK: - Filenames

    @Test("parses an ISO-dated lecture filename into date, unit and topic")
    func parsesDatedUnitFilename() {
        let parsed = FilenameParsing.parse(
            fileNameWithoutExtension: "2026-09-08_Week-03_SOLID-Design-Principles"
        )
        #expect(parsed.unitLabel == "Week 3")
        #expect(parsed.topic == "SOLID Design Principles")
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day], from: try! #require(parsed.dateFromFilename))
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 8)
    }

    @Test("parses a unit-only filename with no date")
    func parsesUndatedUnitFilename() {
        let parsed = FilenameParsing.parse(
            fileNameWithoutExtension: "Module-01_Ch-01_What-is-Anthropology"
        )
        #expect(parsed.unitLabel == "Module 1")
        #expect(parsed.dateFromFilename == nil)
    }

    @Test("a session spanning two numbered lectures groups under the first")
    func parsesLectureRange() {
        let parsed = FilenameParsing.parse(
            fileNameWithoutExtension: "2026-09-03_Lecture-02-03_Demand-Wrap-up-and-Elasticity"
        )
        #expect(parsed.unitLabel == "Lecture 2")
    }

    @Test("'Ch' is spelled out so its deck matches the older courses' labels")
    func spellsOutChapter() {
        #expect(FilenameParsing.parse(fileNameWithoutExtension: "Ch-07_Settling-Down").unitLabel == "Chapter 7")
    }

    @Test("a filename with neither date nor unit reports no structure")
    func unstructuredFilename() {
        let parsed = FilenameParsing.parse(fileNameWithoutExtension: "Practice-Tools")
        #expect(parsed.unitLabel == nil)
        #expect(parsed.topic == nil)
        #expect(parsed.dateFromFilename == nil)
    }

    @Test("the original two conventions still parse unchanged")
    func legacyConventionsUnaffected() {
        let newer = FilenameParsing.parse(
            fileNameWithoutExtension: "Foundations of Computing - 03.31.26 - Chapter 9 Graph Theory"
        )
        #expect(newer.topic == "Chapter 9 Graph Theory")
        #expect(newer.dateFromFilename != nil)
        #expect(FilenameParsing.parse(fileNameWithoutExtension: "Physical Geology 10.28.25").topic == nil)
    }

    // MARK: - Pair extraction

    @Test("extracts a bold term and definition from a markdown bullet")
    func extractsBoldTermBullet() {
        let pairs = PairParser.parse("- **Sunk cost** - a cost already incurred that cannot be recovered.")
        #expect(pairs.count == 1)
        #expect(pairs.first?.front == "Sunk cost")
        #expect(pairs.first?.back == "a cost already incurred that cannot be recovered.")
    }

    @Test("strips markdown so a card front is never literal asterisks or backticks")
    func stripsMarkdownFromPairs() {
        let pairs = PairParser.parse("- **`__init__` constructor** - the method Python calls when an *object* is created.")
        #expect(pairs.first?.front == "__init__ constructor")
        #expect(pairs.first?.back == "the method Python calls when an object is created.")
    }

    @Test("pairs a heading with the blockquote that states its idea")
    func extractsHeadingQuotePair() {
        let text = """
        ### Single Responsibility Principle

        > **A class should have only one responsibility.**
        """
        let pairs = PairParser.parse(text)
        #expect(pairs.first?.front == "Single Responsibility Principle")
        #expect(pairs.first?.back == "A class should have only one responsibility.")
    }

    @Test("the wiki-link footer every structured note carries produces no card")
    func rejectsLinkOnlyFooter() {
        let text = "Related: [[_Course Index]] · [[2026-09-03_Week-02_UML-Modeling]] · [[00_Syllabus]]"
        #expect(PairParser.parse(text).isEmpty)
    }

    @Test("a discourse lead is not a term")
    func rejectsDiscourseLead() {
        #expect(PairParser.parse("- **Note** - the Module 3 essay covers Chapter 5 only.").isEmpty)
        #expect(PairParser.parse("- **Reading** - Chapter 1, pages 3 to 29 of the textbook.").isEmpty)
    }

    @Test("a bare section locator is not a term, so homework lists make no cards")
    func rejectsLocatorTerm() {
        #expect(PairParser.parse("- **§1.4** - every 4th of the first 20, then 21-34, plus #50.").isEmpty)
        #expect(PairParser.parse("- **Week 3** - read the chapter before the quiz opens.").isEmpty)
    }

    @Test("a real term that merely starts with a locator word is kept")
    func keepsTermContainingLocatorWord() {
        let pairs = PairParser.parse(
            "- **Chapter objectives** - the outcomes a module lists for the reader to meet."
        )
        #expect(pairs.count == 1)
    }

    // MARK: - Reference documents

    @Test("course-logistics documents are excluded from card generation")
    func detectsReferenceDocuments() {
        #expect(VaultScanner.isReferenceDocument(title: "_Course Index"))
        #expect(VaultScanner.isReferenceDocument(title: "00_Syllabus_and_Assessments"))
        #expect(VaultScanner.isReferenceDocument(title: "Course-Schedule_Lectures-and-Problem-Sets"))
        #expect(VaultScanner.isReferenceDocument(title: "Practice-Tools"))
        #expect(VaultScanner.isReferenceDocument(title: "00_Course-Roadmap_Modules-and-Labs"))
    }

    @Test("a dated lecture is never a reference document, whatever its topic says")
    func lectureIdentityBeatsKeyword() {
        // Without the escape hatch this real 419-word lecture is discarded
        // for containing the word "syllabus".
        #expect(!VaultScanner.isReferenceDocument(
            title: "2026-08-25_Module-01_First-Day-Syllabus-Overview", hasLectureIdentity: true
        ))
        #expect(VaultScanner.isReferenceDocument(
            title: "2026-08-25_Module-01_First-Day-Syllabus-Overview", hasLectureIdentity: false
        ))
    }

    @Test("an index file stays a reference document even with a lecture identity")
    func underscorePrefixIsAbsolute() {
        #expect(VaultScanner.isReferenceDocument(title: "_Course Index", hasLectureIdentity: true))
    }

    // MARK: - Frontmatter

    @Test("reads the course code out of the structured notes' course field")
    func readsCourseCode() {
        let (fm, _) = FrontmatterParser.split("""
        ---
        course: "CEN 3062C / Intro to Software Design"
        tags: [course-notes, grasp-context]
        ---

        Body.
        """)
        #expect(fm.courseCode == "CEN 3062C")
        #expect(fm.tags == ["course-notes", "grasp-context"])
    }

    @Test("a course field with no code half yields no code rather than a wrong one")
    func handlesCourseFieldWithoutCode() {
        let (fm, _) = FrontmatterParser.split("---\ncourse: \"Matrix Theory\"\n---\n\nBody.")
        #expect(fm.courseCode == nil)
    }
}
