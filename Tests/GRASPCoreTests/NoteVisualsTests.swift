import Testing
import Foundation
@testable import GRASPCore

/// Pictures found in a note's own text: no model, nothing invented.
@Suite("Note visuals")
struct NoteVisualsTests {
    private func pipeline(_ v: NoteVisual) -> [String]? { if case .pipeline(let s) = v.kind { return s } else { return nil } }

    @Test("an arrow chain in a code block is a pipeline, one stage per box")
    func fencedPipeline() {
        let raw = """
        ## The Compilation Pipeline

        ```
        source (.cpp, plain text)
           → compiler checks syntax → object file
           → linker joins your objects + OS/library objects
           → executable / application
           → loaded and run
        ```
        """
        let found = NoteVisuals.visuals(in: raw)
        #expect(found.count == 1)
        #expect(found.first.flatMap(pipeline) == ["source", "compiler checks syntax", "object file",
                                                  "linker joins your objects + OS/library objects",
                                                  "executable / application", "loaded and run"])
        #expect(found.first?.title == "The Compilation Pipeline")
    }

    @Test("the same pipeline written twice is one picture, with the plainer names")
    func dedupe() {
        let raw = """
        - **Compiled language** — source → compile → object files → **link** → executable → load and run.

        ```
        source (.cpp, plain text)
           → compiler checks syntax → object file
           → linker joins your objects + OS/library objects
           → executable / application
        ```
        """
        let found = NoteVisuals.visuals(in: raw)
        #expect(found.count == 1)
        #expect(found.first.flatMap(pipeline) == ["source", "compile", "object files", "link", "executable", "load and run"])
    }

    @Test("a pointer arrow in C++ is not a pipeline, and two stages are not a chain")
    func notPipelines() {
        let raw = "```cpp\nnode->next->next = head;\nint x = 3; // a counter\n```\n\nRead it as a → b only."
        #expect(NoteVisuals.visuals(in: raw).allSatisfy { pipeline($0) == nil })
    }

    @Test("a markdown table is a table, with the markup removed")
    func table() {
        let raw = """
        ## Data Types Introduced

        | Type | Notes |
        | --- | --- |
        | `int` | whole numbers |
        | `double` | **twice the size of an int** |
        | `char` | **single** quotation marks |
        """
        let found = NoteVisuals.visuals(in: raw)
        guard case .table(let header, let rows)? = found.first?.kind else { Issue.record("no table"); return }
        #expect(header == ["Type", "Notes"])
        #expect(rows == [["int", "whole numbers"], ["double", "twice the size of an int"], ["char", "single quotation marks"]])
        #expect(found.first?.title == "Data Types Introduced")
    }

    static let listing = """
    ```cpp
    #include <iostream>   // needed in every program in this class
    #include <string>     // needed whenever you use the string class
    using namespace std;

    int main()
    {
        int numPies, numSlices, totalSlices;
        int count = 6;     // how many
        return 0;         // 0 means it ran correctly
    }
    ```
    """

    @Test("a listing with comments shows each comment beside its line, and its declarations become boxes")
    func codeAndMemory() {
        let found = NoteVisuals.visuals(in: Self.listing)
        guard case .annotatedCode(let lines)? = found.first(where: { if case .annotatedCode = $0.kind { return true } else { return false } })?.kind
        else { Issue.record("no annotated code"); return }
        #expect(lines.first == .init(code: "#include <iostream>", note: "needed in every program in this class"))
        #expect(lines.first { $0.code.contains("return 0") }?.note == "0 means it ran correctly")
        #expect(lines.first { $0.code == "using namespace std;" }?.note == nil)
        guard case .memory(let boxes)? = found.first(where: { if case .memory = $0.kind { return true } else { return false } })?.kind
        else { Issue.record("no memory boxes"); return }
        #expect(boxes.map(\.name) == ["numPies", "numSlices", "totalSlices", "count"])
        #expect(boxes.map(\.type) == ["int", "int", "int", "int"])
        #expect(boxes.map(\.value) == [nil, nil, nil, "6"])
    }

    @Test("a comment inside a string is not a note, and one comment is not enough to annotate")
    func commentRules() {
        #expect(NoteVisuals.splitComment("cout << \"see // not a comment\";").note == nil)
        #expect(NoteVisuals.splitComment("x = 1; // set x").note == "set x")
        let one = "```cpp\nint a; // only one\nint b;\n```"
        #expect(NoteVisuals.visuals(in: one).allSatisfy { if case .annotatedCode = $0.kind { return false } else { return true } })
    }

    @Test("a banner of stars is left out, and a short snippet with two comments is not annotated")
    func bannerAndShort() {
        let banner = "```cpp\n/*****\n * Your Name\n *****/\n#include <iostream> // io\n#include <string> // strings\nint main()\n{\n    return 0;\n}\n```"
        guard case .annotatedCode(let lines)? = NoteVisuals.visuals(in: banner).first?.kind else { Issue.record("no code"); return }
        #expect(!lines.contains { $0.code.contains("*****") })
        #expect(lines.contains { $0.code == " * Your Name" })
        let short = "```cpp\n#include <iostream> // io\n#include <string> // strings\nusing namespace std;\n```"
        #expect(NoteVisuals.visuals(in: short).isEmpty)
    }

    @Test("a syllabus gets none: its tables are weights and dates")
    func syllabus() {
        let raw = """
        # Syllabus overview

        Instructor office hours are Tuesdays. Late work is not accepted. Attendance is not graded.
        Submit on Canvas; TopHat in class. Midterm and final exam on paper.

        | Part | Weight |
        | --- | --- |
        | Homework | 35% |
        | Labs | 15% |
        | Midterm | 25% |
        """
        #expect(NoteVisuals.visuals(in: raw, noteTitle: "First Day Syllabus Overview").isEmpty)
    }

    @Test("a visual goes under the section that uses its words, and the rest are left over")
    func placing() {
        let raw = """
        ```
        source → compiler checks syntax → object file → linker joins objects → executable
        ```

        | Type | Notes |
        | --- | --- |
        | int | whole numbers |
        | double | twice the size |
        """
        let sections = [
            OverviewSection(heading: "A program is built by compiling and linking",
                            paragraphs: ["The compiler turns source into an object file, then the linker makes an executable."]),
            OverviewSection(heading: "Braces make blocks", paragraphs: ["A block starts and ends with braces."]),
        ]
        let placed = NoteVisuals.placements(of: NoteVisuals.visuals(in: raw), in: sections)
        #expect(placed.bySection[0]?.count == 1 && placed.bySection[0]?.first.flatMap(pipeline) != nil)
        #expect(placed.bySection[1] == nil)
        #expect(placed.rest.count == 1)
    }
}

@Suite("Note visuals on the real Module 1 notes", .enabled(if: FileManager.default.fileExists(atPath: Fixture.lecture.path)))
struct RealNoteVisualsTests {
    @Test("the lecture gives a pipeline, the data types table, an annotated listing and its variables as boxes")
    func lecture() throws {
        let raw = try String(contentsOf: Fixture.lecture, encoding: .utf8)
        let found = NoteVisuals.visuals(in: raw, noteTitle: "2026-08-27_Module-01_Introduction-to-C++")
        var kinds: [String] = []
        for v in found {
            switch v.kind {
            case .pipeline(let s): kinds.append("pipeline \(s.count)")
            case .table(let h, let r): kinds.append("table \(h.count)x\(r.count)")
            case .annotatedCode(let l): kinds.append("code \(l.filter { $0.note != nil }.count)")
            case .memory(let b): kinds.append("memory \(b.count)")
            }
        }
        #expect(kinds.contains { $0.hasPrefix("pipeline") }, "\(kinds)")
        #expect(kinds.contains("table 2x4"), "\(kinds)")
        #expect(kinds.contains { $0.hasPrefix("code") }, "\(kinds)")
        #expect(kinds.contains("memory 3"), "\(kinds)")
        #expect(found.count <= NoteVisuals.limit)
    }

    @Test("the syllabus note gets none")
    func syllabus() throws {
        let raw = try String(contentsOf: Fixture.syllabus, encoding: .utf8)
        #expect(NoteVisuals.visuals(in: raw, noteTitle: "2026-08-25_Module-01_First-Day-Syllabus-Overview").isEmpty)
    }
}

enum Fixture {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/grasp-fixtures")
    static let lecture = dir.appendingPathComponent("cpp-intro-lecture.md")
    static let syllabus = dir.appendingPathComponent("cpp-syllabus-note.md")
}
