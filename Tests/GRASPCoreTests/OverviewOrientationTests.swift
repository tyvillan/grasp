import Testing
import Foundation
@testable import GRASPCore

/// A syllabus or first-day note teaches no concepts yet, so it gets an
/// orientation, not a lesson. These pin what counts as one and what that
/// changes in the prompts.
@Suite("Overview orientation")
struct OverviewOrientationTests {
    static let syllabus = """
    Syllabus overview. Instructor office hours are Tuesdays. Grading: homework and quizzes 35%, labs 15%, \
    midterm 25%, final exam 25%. Late work is not accepted; there is a grace period until 8:00 AM. \
    Attendance is not graded. Assignments are submitted on Canvas. TopHat is used in class.
    """

    @Test("a syllabus, a first-day overview and a note that is mostly rules are orientations")
    func found() {
        #expect(OverviewOrientation.isOrientation(noteTitle: "Module 1 First Day Syllabus Overview", noteContext: Self.syllabus))
        // No title: still found, because it is mostly rules and weights.
        let rules = Self.syllabus + " The textbook is optional. Academic integrity applies. Make-up exams need documentation."
        #expect(OverviewOrientation.isOrientation(noteContext: rules))
    }

    @Test("a lecture that mentions a deadline, a lecture titled with a syllabus section, and a math first day are not")
    func notFound() {
        let lecture = "Pointers hold addresses. The midterm covers this. Submit the lab on Canvas. Arrays decay to pointers."
        #expect(!OverviewOrientation.isOrientation(noteTitle: "Module 7 Arrays and Pointers", noteContext: lecture))
        // A course-series tag in the title is not an announcement on its own.
        #expect(!OverviewOrientation.isOrientation(noteTitle: "Calculus - Syllabus.2.1 Average Rate of Change",
                                                   noteContext: "Average rate of change. Office hours are Friday."))
        // A first-day lecture that teaches real math is still a lecture.
        let math = Self.syllabus + " Today: a system of linear equations, the matrix of coefficients, and a proof by vectors."
        #expect(!OverviewOrientation.isOrientation(noteTitle: "First Day Systems of Linear Equations", noteContext: math))
    }

    @Test("the real Module 1 syllabus note is one, and the real Module 1 lecture is not")
    func realNotes() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/grasp-fixtures")
        let syllabus = dir.appendingPathComponent("cpp-syllabus-note.md"), lecture = dir.appendingPathComponent("cpp-intro-lecture.md")
        guard FileManager.default.fileExists(atPath: syllabus.path), FileManager.default.fileExists(atPath: lecture.path) else { return }
        #expect(OverviewOrientation.isOrientation(noteTitle: "2026-08-25_Module-01_First-Day-Syllabus-Overview",
                                                  noteContext: try String(contentsOf: syllabus, encoding: .utf8)))
        #expect(!OverviewOrientation.isOrientation(noteTitle: "2026-08-27_Module-01_Introduction-to-C++",
                                                   noteContext: try String(contentsOf: lecture, encoding: .utf8)))
    }

    @Test("an orientation plan asks for the course in plain words, and a lesson plan is unchanged")
    func planPrompt() {
        let plan = OllamaGenerator.lessonPlanPrompt(noteTitle: "Syllabus", courseName: "Systems Programming",
                                                    noteContext: Self.syllabus, includeFormulas: false, orientation: true)
        #expect(plan.contains("orientation for a student's first look at this course"))
        #expect(plan.contains("Leave out grading, weights, deadlines, late work and exam dates"))
        #expect(plan.contains("what the course is about and what the student will be able to do"))
        #expect(plan.contains("the tools and how the work is done week to week"))
        #expect(!plan.contains("how grades are made up"))
        #expect(plan.contains("sections: 2 or 3"))
        #expect(plan.contains("Never an objective that needs lessons the note does not give"))
        let lesson = OllamaGenerator.lessonPlanPrompt(noteTitle: "Pointers", courseName: "Systems Programming",
                                                      noteContext: "Pointers hold addresses.", includeFormulas: false)
        #expect(!lesson.contains("orientation"))
        #expect(lesson.contains("most familiar idea to the least"))
    }

    @Test("an orientation section has no worked example, no invented scene, and says later lectures teach the subject")
    func sectionPrompt() {
        let prompt = OllamaGenerator.sectionPrompt(courseName: "Systems Programming", noteContext: Self.syllabus,
                                                   heading: "Your grade is mostly weekly work", covers: "grade weights",
                                                   lessonHeadings: ["Your grade is mostly weekly work"], orientation: true)
        #expect(prompt.contains("example: null"))
        #expect(prompt.contains("check: null. An orientation asks no questions."))
        #expect(prompt.contains("\"check\": \\\n        null") || prompt.contains("null, \"claim\""))
        #expect(prompt.contains("One or two short paragraphs, each at most two sentences"))
        #expect(prompt.contains("Never make up a scene, a student, a program or an example"))
        #expect(prompt.contains("say later lectures teach it"))
        #expect(prompt.contains("\"example\": null"))
        #expect(!prompt.contains("3Blue1Brown"))
    }

    @Test("the single-shot fallback carries the orientation rules only for an orientation")
    func singleShot() {
        let on = OllamaGenerator.overviewPrompt(noteTitle: "Syllabus", courseName: "C", noteContext: Self.syllabus,
                                                includeFormulas: false, orientation: true)
        let off = OllamaGenerator.overviewPrompt(noteTitle: "Lecture", courseName: "C", noteContext: "Pointers.",
                                                 includeFormulas: false)
        #expect(on.contains(OllamaGenerator.orientationRules))
        #expect(!off.contains(OllamaGenerator.orientationRules))
    }

    @Test("an orientation's section can't come back with a question, and a lecture's still does")
    func noQuestionForOrientation() {
        let orientation = OllamaGenerator.sectionPrompt(courseName: "C", noteContext: Self.syllabus, heading: "H", covers: "c",
                                                        lessonHeadings: ["H"], orientation: true)
        let lecture = OllamaGenerator.sectionPrompt(courseName: "C", noteContext: "Pointers hold addresses.", heading: "H",
                                                    covers: "c", lessonHeadings: ["H"])
        #expect(!orientation.contains("\"question\""))
        #expect(lecture.contains("\"question\""))
        #expect(lecture.contains("check: one question that makes the reader think"))
    }

    @Test("the fact-check stops calling an orientation's course facts an error, and checks its numbers instead")
    func review() {
        let section = OverviewSection(heading: "Grades", paragraphs: ["Homework is 35% of the grade."])
        let orientation = OllamaGenerator.reviewPrompt(noteContext: Self.syllabus, section: section)
        #expect(orientation.contains("A number, date or rule that differs from the notes is an error"))
        #expect(!orientation.contains("really a fact about the course"))
        let lecture = OllamaGenerator.reviewPrompt(noteContext: "Pointers hold addresses.", section: section)
        #expect(lecture.contains("really a fact about the course"))
    }
}
