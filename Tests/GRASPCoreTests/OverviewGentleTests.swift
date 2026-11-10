import Testing
import Foundation
@testable import GRASPCore

/// An overview should ease a beginner in, and say only what is true. These
/// pin the wording of the prompts that ask for it, and the one place the
/// fact-check can now correct a worked example's setup.
@Suite("Overview, gentler for a beginner")
struct OverviewGentleTests {
    private let note = "The syllabus defines systems programming as working close to the machine."

    @Test("the plan asks for a plain two-sentence start, and for sections ordered familiar to new")
    func planPrompt() {
        let prompt = OllamaGenerator.lessonPlanPrompt(noteTitle: "Module 1", courseName: "Systems Programming",
                                                      noteContext: note, includeFormulas: false)
        #expect(prompt.contains("two plain sentences"))
        #expect(prompt.contains("everyday words a beginner understands"))
        #expect(prompt.contains("a complete grammatical sentence"))
        #expect(prompt.contains("most familiar idea to the least"))
        #expect(prompt.contains("which technical terms it introduces"))
    }

    @Test("a math note's start is plain too")
    func planPromptMath() {
        let prompt = OllamaGenerator.lessonPlanPrompt(noteTitle: "Rows", courseName: "Matrix Theory",
                                                      noteContext: "x + 5y = 7\nR2 -> R2 - 2R1\n[1 2 | 3]\n[4 5 | 6]",
                                                      includeFormulas: false)
        #expect(prompt.contains("in words a beginner understands"))
    }

    @Test("a section defines a term before using it, keeps to two new terms, and never fills a gap with logistics or a made-up scene")
    func sectionPrompt() {
        let prompt = OllamaGenerator.sectionPrompt(courseName: "Systems Programming", noteContext: note,
                                                   heading: "A system call asks the OS for a service", covers: "system calls",
                                                   lessonHeadings: ["A system call asks the OS for a service"])
        #expect(prompt.contains("meeting this subject for the first time"))
        #expect(prompt.contains("Before you use any technical term, say what it means in everyday words"))
        #expect(prompt.contains("Never use a term in a section before the section that introduces it"))
        #expect(prompt.contains("at most two key terms"))
        #expect(!prompt.contains("at most three key terms"))
        #expect(prompt.contains("Never fill the gap with course logistics"))
        #expect(prompt.contains("Never make up a student, program or situation"))
        #expect(prompt.contains("never a fact about the course"))
        #expect(prompt.contains("If you are not sure a statement is true, leave it out"))
    }

    @Test("the single-shot fallback carries the same rules")
    func singleShot() {
        let prompt = OllamaGenerator.overviewPrompt(noteTitle: "Module 1", courseName: "Systems Programming",
                                                    noteContext: note, includeFormulas: false)
        #expect(prompt.contains(OllamaGenerator.beginnerRules))
        #expect(prompt.contains("with no technical term the notes have not explained yet"))
    }

    @Test("the fact-check also looks for reversed claims, made-up scenes and course facts passed off as examples")
    func reviewPrompt() {
        var section = OverviewSection(heading: "Manual memory leaks", paragraphs: ["Manual management prevents leaks."])
        section.terms = [OverviewDefinition(term: "multi-threaded program", text: "Runs several threads.",
                                            example: "A Canvas lab worth 15%", nonExample: nil)]
        section.example = OverviewWorkedExample(title: "Memory control", setup: "A student allocates a buffer in C++",
                                                steps: [OverviewExampleStep(action: "call new", result: "memory assigned", why: nil, label: nil),
                                                        OverviewExampleStep(action: "call delete", result: "memory freed", why: nil, label: nil)])
        let prompt = OllamaGenerator.reviewPrompt(noteContext: note, section: section)
        #expect(prompt.contains("reverse what the subject says"))
        #expect(prompt.contains("made-up scene"))
        #expect(prompt.contains("really a fact about the course"))
        #expect(prompt.contains("A true statement the notes don't happen to mention is NOT an error"))
        // What it is asked to check now includes the parts that carried the problems.
        #expect(prompt.contains("Example setup: A student allocates a buffer in C++"))
        #expect(prompt.contains("Term example: A Canvas lab worth 15%"))
    }

    @Test("a fix lands on an example's setup, and an emptied setup is dropped")
    func fixesSetup() {
        var section = OverviewSection(heading: "H", paragraphs: ["Memory is handed out by new and returned by delete."])
        section.example = OverviewWorkedExample(
            setup: "A student allocates a buffer in C++ before reading a file",
            steps: [OverviewExampleStep(action: "call new", result: "memory assigned", why: nil, label: nil),
                    OverviewExampleStep(action: "call delete", result: "memory freed", why: nil, label: nil)])
        let removed = OverviewReview.apply([OverviewFix(original: "A student allocates a buffer in C++ before reading a file",
                                                        corrected: nil)], to: section)
        #expect(removed.example?.setup == nil)
        #expect(removed.example?.steps.count == 2)
        let rewritten = OverviewReview.apply([OverviewFix(original: "A student allocates a buffer in C++ before reading a file",
                                                          corrected: "Memory is requested before it is used")], to: section)
        #expect(rewritten.example?.setup == "Memory is requested before it is used")
    }
}
